// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import SessionUtilitiesKit
import SessionSnodeKit

public enum AttachmentDownloadJob: JobExecutor {
    public static var maxFailureCount: Int = 3
    public static var requiresThreadId: Bool = true
    public static let requiresInteractionId: Bool = true
    
    public static func run(_ job: Job, using dependencies: Dependencies) async throws -> JobExecutionResult {
        guard
            dependencies[singleton: .appContext].isValid,
            let threadId: String = job.threadId,
            let detailsData: Data = job.details,
            let details: Details = try? JSONDecoder(using: dependencies).decode(Details.self, from: detailsData)
        else { throw JobRunnerError.missingRequiredDetails }
        
        let otherCurrentJobAttachmentIds: Set<String> = await dependencies[singleton: .jobRunner]
            .jobInfoFor(
                state: .running,
                filters: JobRunner.Filters(
                    include: [.variant(.attachmentDownload)],
                    exclude: [job.id.map { .jobId($0) }].compactMap { $0 }
                )
            )
            .values
            .compactMap { info -> String? in
                guard let data: Data = info.detailsData else { return nil }
                
                return (try? JSONDecoder(using: dependencies).decode(Details.self, from: data))?
                    .attachmentId
            }
            .asSet()
        
        // FIXME: Refactor this to use async/await
        let publisher = dependencies[singleton: .storage]
            .writePublisher { db -> Attachment in
                guard let attachment: Attachment = try? Attachment.fetchOne(db, id: details.attachmentId) else {
                    throw JobRunnerError.missingRequiredDetails
                }
                
                // Due to the complex nature of jobs and how attachments can be reused it's possible for
                // an AttachmentDownloadJob to get created for an attachment which has already been
                // downloaded/uploaded so in those cases just succeed immediately
                guard attachment.state != .downloaded && attachment.state != .uploaded else {
                    throw AttachmentDownloadError.alreadyDownloaded
                }
                
                // If we ever make attachment downloads concurrent this will prevent us from downloading
                // the same attachment multiple times at the same time (it also adds a "clean up" mechanism
                // if an attachment ends up stuck in a "downloading" state incorrectly
                guard attachment.state != .downloading else {
                    // If there isn't another currently running attachmentDownload job downloading this
                    // attachment then we should update the state of the attachment to be failed to
                    // avoid having attachments appear in an endlessly downloading state
                    if !otherCurrentJobAttachmentIds.contains(attachment.id) {
                        _ = try Attachment
                            .filter(id: attachment.id)
                            .updateAll(db, Attachment.Columns.state.set(to: Attachment.State.failedDownload))
                        db.addAttachmentEvent(
                            id: attachment.id,
                            messageId: job.interactionId,
                            type: .updated(.state(.failedDownload))
                        )
                    }
                    
                    // Note: The only ways we should be able to get into this state are if we enable
                    // concurrent downloads or if the app was closed/crashed while an attachmentDownload
                    // job was in progress
                    //
                    // If there is another current job then just fail this one permanently, otherwise
                    // let it retry (if there are more retry attempts available) and in the next retry
                    // it's state should be 'failedDownload' so we won't get stuck in a loop
                    throw JobRunnerError.possibleDuplicateJob(
                        permanentFailure: otherCurrentJobAttachmentIds.contains(attachment.id)
                    )
                }
                
                // Update to the 'downloading' state (no need to update the 'attachment' instance)
                try Attachment
                    .filter(id: attachment.id)
                    .updateAll(db, Attachment.Columns.state.set(to: Attachment.State.downloading))
                db.addAttachmentEvent(
                    id: attachment.id,
                    messageId: job.interactionId,
                    type: .updated(.state(.downloading))
                )
                
                return attachment
            }
            .tryMap { attachment -> (attachment: Attachment, temporaryFileUrl: URL, downloadUrl: URL) in
                guard let downloadUrl: URL = attachment.downloadUrl.map({ URL(string: $0) }) else {
                    throw AttachmentDownloadError.invalidUrl
                }
                
                let temporaryFileUrl: URL = URL(
                    fileURLWithPath: dependencies[singleton: .fileManager].temporaryDirectoryAccessibleAfterFirstAuth + UUID().uuidString
                )
                
                return (attachment, temporaryFileUrl, downloadUrl)
            }
            .flatMapStorageReadPublisher(using: dependencies, value: { db, info -> Network.PreparedRequest<(data: Data, attachment: Attachment, temporaryFileUrl: URL)> in
                let maybeRoomToken: String? = try OpenGroup
                    .select(.roomToken)
                    .filter(id: threadId)
                    .asRequest(of: String.self)
                    .fetchOne(db)
                
                switch maybeRoomToken {
                    case .some(let roomToken):
                        return try OpenGroupAPI
                            .preparedDownload(
                                url: info.downloadUrl,
                                roomToken: roomToken,
                                authMethod: try Authentication.with(
                                    db,
                                    threadId: threadId,
                                    threadVariant: .community,
                                    using: dependencies
                                ),
                                using: dependencies
                            )
                            .map { _, data in (data, info.attachment, info.temporaryFileUrl) }
                        
                    case .none:
                        return try Network
                            .preparedDownload(
                                url: info.downloadUrl,
                                using: dependencies
                            )
                            .map { _, data in (data, info.attachment, info.temporaryFileUrl) }
                }
            })
            .flatMap { downloadRequest in
                downloadRequest.send(using: dependencies).map { _, response in
                    (response.attachment, response.temporaryFileUrl, response.data)
                }
            }
            .tryMap { attachment, temporaryFileUrl, data -> Attachment in
                // Store the encrypted data temporarily
                try data.write(to: temporaryFileUrl, options: .atomic)
                
                // Decrypt the data
                let plaintext: Data = try {
                    guard
                        let key: Data = attachment.encryptionKey,
                        let digest: Data = attachment.digest,
                        key.count > 0,
                        digest.count > 0
                    else { return data } // Open group attachments are unencrypted
                    
                    return try dependencies[singleton: .crypto].tryGenerate(
                        .decryptAttachment(
                            ciphertext: data,
                            key: key,
                            digest: digest,
                            unpaddedSize: attachment.byteCount
                        )
                    )
                }()
                
                // Write the data to disk
                guard try attachment.write(data: plaintext, using: dependencies) else {
                    throw AttachmentDownloadError.failedToSaveFile
                }
                
                // Remove the temporary file
                try? dependencies[singleton: .fileManager].removeItem(atPath: temporaryFileUrl.path)
                
                return attachment
            }
            .flatMapStorageWritePublisher(using: dependencies) { db, attachment in
                /// Update the attachment state
                ///
                /// **Note:** We **MUST** use the `'with()` function here as it will update the
                /// `isValid` and `duration` values based on the downloaded data and the state
                let updatedAttachment: Attachment = try attachment
                    .with(
                        state: .downloaded,
                        creationTimestamp: (dependencies[cache: .snodeAPI].currentOffsetTimestampMs() / 1000),
                        using: dependencies
                    )
                    .upserted(db)
                db.addAttachmentEvent(
                    id: attachment.id,
                    messageId: job.interactionId,
                    type: .updated(.state(.downloaded))
                )
                
                return updatedAttachment
            }
        
        do {
            _ = try await publisher.values.first(where: { _ in true })
            return .success(job, stop: false)
        }
        catch {
            switch error {
                case AttachmentDownloadError.alreadyDownloaded: return .success(job, stop: false)
                case JobRunnerError.missingRequiredDetails: throw error
                    
                case JobRunnerError.possibleDuplicateJob(let permanentFailure):
                    throw JobRunnerError.possibleDuplicateJob(permanentFailure: permanentFailure)
                    
                default:
                    let targetState: Attachment.State
                    let permanentFailure: Bool
                    
                    switch error {
                        /// If we get a 404 then we got a successful response from the server but the attachment doesn't
                        /// exist, in this case update the attachment to an "invalid" state so the user doesn't get stuck in
                        /// a retry download loop
                        case NetworkError.notFound:
                            targetState = .invalid
                            permanentFailure = true
                            
                        /// If we got a 400 or a 401 then we want to fail the download in a way that has to be manually retried as it's
                        /// likely something else is going on that caused the failure
                        case NetworkError.badRequest, NetworkError.unauthorised,
                            SnodeAPIError.signatureVerificationFailed:
                            targetState = .failedDownload
                            permanentFailure = true
                        
                        /// For any other error it's likely either the server is down or something weird just happened with the request
                        /// so we want to automatically retry
                        default:
                            targetState = .failedDownload
                            permanentFailure = false
                    }
                    
                    /// To prevent the attachment from showing a state of downloading forever, we need to update the attachment
                    /// state here based on the type of error that occurred
                    ///
                    /// **Note:** We **MUST** use the `'with()` function here as it will update the
                    /// `isValid` and `duration` values based on the downloaded data and the state
                    try? await dependencies[singleton: .storage].writeAsync { db in
                        _ = try Attachment
                            .filter(id: details.attachmentId)
                            .updateAll(db, Attachment.Columns.state.set(to: targetState))
                        db.addAttachmentEvent(
                            id: details.attachmentId,
                            messageId: job.interactionId,
                            type: .updated(.state(targetState))
                        )
                    }
                    
                    /// Trigger the failure, but force to a `permanentFailure` if desired
                    switch permanentFailure {
                        case true: throw JobRunnerError.permanentFailure(error)
                        case false: throw error
                    }
            }
        }
    }
}

// MARK: - AttachmentDownloadJob.Details

extension AttachmentDownloadJob {
    public struct Details: Codable {
        public let attachmentId: String
        
        public init(attachmentId: String) {
            self.attachmentId = attachmentId
        }
    }
    
    public enum AttachmentDownloadError: LocalizedError {
        case failedToSaveFile
        case invalidUrl
        case alreadyDownloaded

        // stringlint:ignore_contents
        public var errorDescription: String? {
            switch self {
                case .failedToSaveFile: return "Failed to save file"
                case .invalidUrl: return "Invalid file URL"
                case .alreadyDownloaded: return "Attachment already downloaded."
            }
        }
    }
}
