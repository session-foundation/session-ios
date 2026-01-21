// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import SessionUtilitiesKit
import SessionNetworkingKit

// MARK: - Log.Category

private extension Log.Category {
    static let cat: Log.Category = .create("MessageSendJob", defaultLevel: .info)
}

// MARK: - MessageSendJob

public enum MessageSendJob: JobExecutor {
    public static var maxFailureCount: Int = 10
    public static var requiresThreadId: Bool = true
    public static let requiresInteractionId: Bool = false   // Some messages don't have interactions
    
    public static func run(_ job: Job, using dependencies: Dependencies) async throws -> JobExecutionResult {
        guard
            let threadId: String = job.threadId,
            let detailsData: Data = job.details,
            let details: Details = try? JSONDecoder(using: dependencies).decode(Details.self, from: detailsData)
        else { throw JobRunnerError.missingRequiredDetails }
        
        /// We need to include `fileIds` when sending messages with attachments to Open Groups so extract them from any
        /// associated attachments
        var messageAttachments: [(attachment: Attachment, fileId: String)] = []
        let messageType: String = {
            switch details.destination {
                case .syncMessage: return "\(type(of: details.message)) (SyncMessage)"
                default: return "\(type(of: details.message))"
            }
        }()
        
        /// If this should be sent after the next config sync but the config has pending changes then defer the job
        if let conficSyncVariant: ConfigDump.Variant = details.requiredConfigSyncVariant {
            let sessionId: SessionId = try {
                guard ConfigDump.Variant.groupVariants.contains(conficSyncVariant) else {
                    return dependencies[cache: .general].sessionId
                }
                
                return try ((try? SessionId(from: threadId)) ?? {
                    throw JobRunnerError.missingRequiredDetails
                }())
            }()
            
            let needsPush: Bool? = dependencies.mutate(cache: .libSession) { cache in
                cache.config(for: conficSyncVariant, sessionId: sessionId)?.needsPush
            }
            try Task.checkCancellation()
            
            /// If the config needs to be pushed then schedule and wait for a config sync to complete
            guard needsPush == false else {
                Log.info(.cat, "For \(messageType) (\(job.id ?? -1)) waiting for config sync due to local changes")
                let jobId: Int64 = try job.id ?? { throw JobRunnerError.missingRequiredDetails }()
                
                try await dependencies[singleton: .storage].writeAsync { db in
                    try dependencies[singleton: .jobRunner].addJobDependency(
                        db,
                        forJobId: jobId,
                        variant: .configSync,
                        otherJobId: nil,
                        threadId: sessionId.hexString
                    )
                }
                await ConfigurationSyncJob.enqueue(swarmPublicKey: sessionId.hexString, using: dependencies)
                try Task.checkCancellation()
                
                if needsPush == nil {
                    Log.warn(.cat, "Config for \(messageType) (\(job.id ?? -1)) wasn't found, if this continues the message will be deferred indefinitely")
                }
                
                return .deferred(job)
            }
        }
        
        /// Ensure any associated attachments have already been uploaded before sending the message
        ///
        /// **Note:** Reactions reference their original message so we need to ignore this logic for reaction messages to ensure we don't
        /// incorrectly re-upload incoming attachments that the user reacted to, we also want to exclude "sync" messages since they should
        /// already have attachments in a valid state
        if
            details.message is VisibleMessage,
            (details.message as? VisibleMessage)?.reaction == nil
        {
            guard
                let jobId: Int64 = job.id,
                let interactionId: Int64 = job.interactionId
            else { throw JobRunnerError.missingRequiredDetails }
            
            /// Retrieve the current attachment state
            let attachmentState: AttachmentState = ((try? await dependencies[singleton: .storage].readAsync { db in
                try MessageSendJob.fetchAttachmentState(
                    db,
                    interactionId: interactionId,
                    using: dependencies
                )
            }) ?? AttachmentState(error: StorageError.invalidQueryResult))
            try Task.checkCancellation()

            /// If we got an error when trying to retrieve the attachment state then this job is actually invalid so it
            /// should permanently fail
            guard attachmentState.error == nil else {
                let finalError: Error = (attachmentState.error ?? NetworkError.unknown)
                
                switch finalError {
                    case StorageError.objectNotFound:
                        Log.warn(.cat, "Failing \(messageType) (\(job.id ?? -1)) due to missing interaction")
                        
                    case AttachmentError.notUploaded:
                        Log.info(.cat, "Failing \(messageType) (\(job.id ?? -1)) due to failed attachment upload")
                        
                    default:
                        Log.error(.cat, "Failed \(messageType) (\(job.id ?? -1)) due to invalid attachment state")
                }
                
                throw JobRunnerError.permanentFailure(finalError)
            }

            /// If we have any pending (or failed) attachment uploads then we should create jobs for them and insert them into the
            /// queue before the current job and defer it (this will mean the current job will re-run after these inserted jobs complete)
            guard attachmentState.pendingUploadAttachmentIds.isEmpty else {
                var attachmentIdsMissingDependencies: [String] = []
                attachmentIdsMissingDependencies.reserveCapacity(
                    attachmentState.pendingUploadAttachmentIds.count
                )
                
                for attachmentId in attachmentState.pendingUploadAttachmentIds {
                    let matchingJobs: [JobQueue.JobQueueId: JobState] = ((try? await dependencies[singleton: .jobRunner].jobsMatching(
                        filters: JobRunner.Filters(
                            include: [
                                .details(
                                    AttachmentUploadJob.Details(
                                        messageSendJobId: jobId,
                                        attachmentId: attachmentId
                                    )
                                )
                            ]
                        )
                    )) ?? [:])
                    
                    if matchingJobs.isEmpty {
                        attachmentIdsMissingDependencies.append(attachmentId)
                    }
                }
                
                /// If there are missing `AttachmentUploadJobs` then create them and add them as dependencies on this job
                if !attachmentIdsMissingDependencies.isEmpty {
                    try await dependencies[singleton: .storage].writeAsync { db in
                        for attachmentId in attachmentIdsMissingDependencies {
                            let job: Job? = dependencies[singleton: .jobRunner].add(
                                db,
                                job: Job(
                                    variant: .attachmentUpload,
                                    threadId: job.threadId,
                                    interactionId: interactionId,
                                    details: AttachmentUploadJob.Details(
                                        messageSendJobId: jobId,
                                        attachmentId: attachmentId
                                    )
                                )
                            )
                            
                            guard let attachmentJobId: Int64 = job?.id else {
                                throw JobRunnerError.missingRequiredDetails
                            }
                            
                            try dependencies[singleton: .jobRunner].addJobDependency(
                                db,
                                forJobId: jobId,
                                variant: .job,
                                otherJobId: attachmentJobId,
                                threadId: nil
                            )
                        }
                    }
                    try Task.checkCancellation()
                }

                Log.info(.cat, "Deferring \(messageType) (\(job.id ?? -1)) due to pending attachment uploads")
                return .deferred(job)
            }

            /// Store the fileIds so they can be sent with the open group message content
            messageAttachments = attachmentState.preparedAttachments
        }
        
        /// If this message is being sent to an updated group then we should first make sure that we have a encryption keys
        /// for the group before we try to send the message, if not then defer the job 1 second to give the poller the chance to
        /// receive the keys
        ///
        /// **Note:** If we have already deferred this message once then we should only continue to defer if we have a config
        /// for the message (this way we won't get stuck deferring permanently if config state isn't loaded and we will instead try,
        /// and fail, to send the message)
        var previousDeferralsMessage: String = ""
        
        switch details.destination {
            case .group(let publicKey) where publicKey.starts(with: SessionId.Prefix.group.rawValue):
                let deferalDuration: TimeInterval = 1
                let groupSessionId: SessionId = SessionId(.group, hex: publicKey)
                let numGroupKeys: Int = (try? LibSession.numKeys(groupSessionId: groupSessionId, using: dependencies))
                    .defaulting(to: 0)
                let deferCount: Int = await dependencies[singleton: .jobRunner].deferCount(
                    for: job.id,
                    of: job.variant
                )
                previousDeferralsMessage = " and \(.seconds(Double(deferCount) * deferalDuration), unit: .s) of deferrals"  // stringlint:ignore
                
                guard
                    numGroupKeys > 0 && (
                        deferCount == 0 ||
                        dependencies[cache: .libSession].hasConfig(for: .groupKeys, sessionId: groupSessionId)
                    )
                else {
                    /// Defer the job by 1s to give it a little more time to receive updated keys
                    Log.info(.cat, "Deferring \(messageType) (\(job.id ?? -1)) as we haven't received the group encryption keys yet")
                    return .deferred(
                        job.with(
                            nextRunTimestamp: dependencies.dateNow.timeIntervalSince1970 + deferalDuration
                        )
                    )
                }
                
            default: break
        }
        
        /// Store the `sentTimestamp` from the message in case it fails due to a `clockOutOfSync` error
        let originalSentTimestampMs: UInt64? = details.message.sentTimestampMs
        let startTime: TimeInterval = dependencies.dateNow.timeIntervalSince1970
        
        /// Perform the actual message sending - this will timeout if the entire process takes longer than `Network.defaultTimeout * 2`
        /// which can occur if it needs to build a new onion path (which doesn't actually have any limits so can take forever in rare cases)
        ///
        /// **Note:** No need to upload attachments as part of this process as the above logic splits that out into it's own job
        /// so we shouldn't get here until attachments have already been uploaded
        do {
            let authMethod: AuthenticationMethod = try await dependencies[singleton: .storage].readAsync { db in
                try Authentication.with(
                    db,
                    threadId: {
                        switch details.destination {
                            case .syncMessage: return dependencies[cache: .general].sessionId.hexString
                            default: return threadId
                        }
                    }(),
                    threadVariant: details.destination.threadVariant,
                    using: dependencies
                )
            }
            try Task.checkCancellation()
            
            let request = try MessageSender.preparedSend(
                message: details.message,
                to: details.destination,
                namespace: details.destination.defaultNamespace,
                interactionId: job.interactionId,
                attachments: messageAttachments,
                authMethod: authMethod,
                onEvent: MessageSender.standardEventHandling(using: dependencies),
                using: dependencies
            )
            
            // FIXME: Refactor to async/await
            let response = try await request.send(using: dependencies)
                .values
                .first(where: { _ in true })?.1 ?? { throw NetworkError.invalidResponse }()
            try Task.checkCancellation()
            
            Log.info(.cat, "Completed sending \(messageType) (\(job.id ?? -1)) after \(.seconds(dependencies.dateNow.timeIntervalSince1970 - startTime), unit: .s)\(previousDeferralsMessage).")
            dependencies.setAsync(.hasSentAMessage, true)
            return .success
        }
        catch {
            Log.info(.cat, "Failed to send \(messageType) (\(job.id ?? -1)) after \(.seconds(dependencies.dateNow.timeIntervalSince1970 - startTime), unit: .s)\(previousDeferralsMessage) due to error: \(error).")
            
            /// Actual error handling
            switch (error, details.message, details.ignorePermanentFailure) {
                case (is MessageError, _, false): throw JobRunnerError.permanentFailure(error)
                case (SnodeAPIError.rateLimited, _, false): throw JobRunnerError.permanentFailure(error)
                    
                case (SnodeAPIError.clockOutOfSync, _, _):
                    Log.error(.cat, "\(originalSentTimestampMs != nil ? "Permanently Failing" : "Failing") to send \(messageType) (\(job.id ?? -1)) due to clock out of sync issue.")
                    if originalSentTimestampMs != nil {
                        throw JobRunnerError.permanentFailure(error)
                    }
                    
                    throw error
                    
                /// Don't bother retrying (it can just send a new one later but allowing retries can result in a large number of
                /// `MessageSendJobs` backing up)
                case (_, is TypingIndicator, _): throw JobRunnerError.permanentFailure(error)
                    
                default:
                    if details.message is VisibleMessage && !details.ignorePermanentFailure {
                        let interactionExists: Bool = ((try? await {
                            guard let interactionId: Int64 = job.interactionId else { return false }
                            
                            return try await dependencies[singleton: .storage].readAsync { db in
                                try Interaction.exists(db, id: interactionId)
                            }
                        }()) ?? false)
                        
                        guard interactionExists else {
                            /// The message has been deleted so permanently fail the job
                            throw JobRunnerError.permanentFailure(error)
                        }
                    }
                    
                    throw error
            }
        }
    }
}

// MARK: - Convenience

public extension MessageSendJob {
    struct AttachmentState {
        public let error: Error?
        public let pendingUploadAttachmentIds: [String]
        public let allAttachmentIds: [String]
        public let preparedAttachments: [(attachment: Attachment, fileId: String)]
        
        init(
            error: Error? = nil,
            pendingUploadAttachmentIds: [String] = [],
            allAttachmentIds: [String] = [],
            preparedAttachments: [(Attachment, String)] = []
        ) {
            self.error = error
            self.pendingUploadAttachmentIds = pendingUploadAttachmentIds
            self.allAttachmentIds = allAttachmentIds
            self.preparedAttachments = preparedAttachments
        }
    }
    
    static func fetchAttachmentState(
        _ db: ObservingDatabase,
        interactionId: Int64,
        using dependencies: Dependencies
    ) throws -> AttachmentState {
        // If the original interaction no longer exists then don't bother sending the message (ie. the
        // message was deleted before it even got sent)
        guard try Interaction.exists(db, id: interactionId) else {
            return AttachmentState(error: StorageError.objectNotFound)
        }

        // Get the current state of the attachments
        let allAttachmentStateInfo: [Attachment.StateInfo] = try Attachment
            .stateInfo(interactionId: interactionId)
            .fetchAll(db)
        let allAttachmentIds: [String] = allAttachmentStateInfo.map(\.attachmentId)

        // If there were failed attachments then this job should fail (can't send a
        // message which has associated attachments if the attachments fail to upload)
        guard !allAttachmentStateInfo.contains(where: { $0.state == .failedDownload }) else {
            return AttachmentState(
                error: AttachmentError.notUploaded,
                allAttachmentIds: allAttachmentIds
            )
        }

        /// Find all attachmentIds for attachments which need to be uploaded
        ///
        /// **Note:** If there are any 'downloaded' attachments then they also need to be uploaded (as a
        /// 'downloaded' attachment will be on the current users device but not on the message recipients
        /// device - both `LinkPreview` and `Quote` can have this case)
        let pendingUploadAttachmentIds: [String] = allAttachmentStateInfo
            .filter { attachment -> Bool in
                switch attachment.state {
                    case .uploading, .pendingDownload, .downloading, .failedUpload, .downloaded:
                        return true
                        
                    // If we've somehow got an attachment that is in an 'uploaded' state but doesn't
                    // have a 'downloadUrl' then it's invalid and needs to be re-uploaded
                    case .uploaded: return (attachment.downloadUrl == nil)

                    default: return false
                }
            }
            .map { $0.attachmentId }
        let preparedAttachmentIds: [String] = allAttachmentIds.filter { !pendingUploadAttachmentIds.contains($0) }
        let attachments: [String: Attachment] = try Attachment
            .fetchAll(db, ids: preparedAttachmentIds)
            .reduce(into: [:]) { result, next in result[next.id] = next }
        let preparedAttachments: [(Attachment, String)] = allAttachmentStateInfo
            .sorted { lhs, rhs in lhs.albumIndex < rhs.albumIndex }
            .compactMap { info in
                guard
                    let attachment: Attachment = attachments[info.attachmentId],
                    !dependencies[singleton: .attachmentManager]
                        .isPlaceholderUploadUrl(attachment.downloadUrl),
                    let fileId: String = Network.FileServer.fileId(for: info.downloadUrl)
                else { return nil }
                
                return (attachment, fileId)
            }
        
        return AttachmentState(
            pendingUploadAttachmentIds: pendingUploadAttachmentIds,
            allAttachmentIds: allAttachmentIds,
            preparedAttachments: preparedAttachments
        )
    }
}

// MARK: - MessageSendJob.Details

extension MessageSendJob {
    public struct Details: Codable {
        private enum CodingKeys: String, CodingKey {
            case destination
            case message
            case variant
            case requiredConfigSyncVariant
            case ignorePermanentFailure
        }
        
        public let destination: Message.Destination
        public let message: Message
        public let variant: Message.Variant?
        public let requiredConfigSyncVariant: ConfigDump.Variant?
        public let ignorePermanentFailure: Bool
        
        // MARK: - Initialization
        
        public init(
            destination: Message.Destination,
            message: Message,
            requiredConfigSyncVariant: ConfigDump.Variant? = nil,
            ignorePermanentFailure: Bool
        ) {
            self.destination = destination
            self.message = message
            self.variant = Message.Variant(from: message)
            self.requiredConfigSyncVariant = requiredConfigSyncVariant
            self.ignorePermanentFailure = ignorePermanentFailure
        }
        
        // MARK: - Codable
        
        public init(from decoder: Decoder) throws {
            let container: KeyedDecodingContainer<CodingKeys> = try decoder.container(keyedBy: CodingKeys.self)
            
            guard let variant: Message.Variant = try? container.decode(Message.Variant.self, forKey: .variant) else {
                Log.error(.cat, "Unable to decode messageSend job due to missing variant")
                throw StorageError.decodingFailed
            }
            
            let requiredConfigSyncVariant: ConfigDump.Variant? = try container
                .decodeIfPresent(ConfigDump.Variant.self, forKey: .requiredConfigSyncVariant)
            
            self = Details(
                destination: try container.decode(Message.Destination.self, forKey: .destination),
                message: try variant.decode(from: container, forKey: .message),
                requiredConfigSyncVariant: requiredConfigSyncVariant,
                ignorePermanentFailure: (
                    // TODO: After 2.15.0 has been release long enough this can be removed
                    try container.decodeIfPresent(Bool.self, forKey: .ignorePermanentFailure) ??
                    (requiredConfigSyncVariant != nil ? true : false)
                )
            )
        }
        
        public func encode(to encoder: Encoder) throws {
            var container: KeyedEncodingContainer<CodingKeys> = encoder.container(keyedBy: CodingKeys.self)
            
            guard let variant: Message.Variant = Message.Variant(from: message) else {
                Log.error(.cat, "Unable to encode messageSend job due to unsupported variant")
                throw StorageError.objectNotFound
            }

            try container.encode(destination, forKey: .destination)
            try container.encode(message, forKey: .message)
            try container.encode(variant, forKey: .variant)
            try container.encodeIfPresent(requiredConfigSyncVariant, forKey: .requiredConfigSyncVariant)
        }
    }
}
