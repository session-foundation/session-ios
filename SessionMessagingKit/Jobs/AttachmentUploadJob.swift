// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import UniformTypeIdentifiers
import Combine
import GRDB
import SessionNetworkingKit
import SessionUtilitiesKit

// MARK: - Log.Category

private extension Log.Category {
    static let cat: Log.Category = .create("AttachmentUploadJob", defaultLevel: .info)
}

// MARK: - AttachmentUploadJob

public enum AttachmentUploadJob: JobExecutor {
    public static var maxFailureCount: Int = 10
    public static var requiresThreadId: Bool = true
    public static let requiresInteractionId: Bool = true
    
    public static func canStart(
        jobState: JobState,
        alongside runningJobs: [JobState],
        using dependencies: Dependencies
    ) -> Bool {
        /// If we can't get the details then just run the job (it'll fail permanently)
        guard
            let detailsData: Data = jobState.job.details,
            let details: Details = try? JSONDecoder(using: dependencies)
                .decode(Details.self, from: detailsData)
        else { return true }
        
        /// Prevent multiple uploads for the same attachment from running at the same time
        return !runningJobs.contains { otherJobState in
            guard
                let otherDetailsData: Data = otherJobState.job.details,
                let otherDetails: Details = try? JSONDecoder(using: dependencies)
                    .decode(Details.self, from: otherDetailsData)
            else { return false }
            
            return (details.attachmentId == otherDetails.attachmentId)
        }
    }
    
    public static func run(_ job: Job, using dependencies: Dependencies) async throws -> JobExecutionResult {
        guard
            let threadId: String = job.threadId,
            let interactionId: Int64 = job.interactionId,
            let detailsData: Data = job.details,
            let details: Details = try? JSONDecoder(using: dependencies).decode(Details.self, from: detailsData)
        else { throw JobRunnerError.missingRequiredDetails }
        
        typealias Info = (
            attachment: Attachment,
            authMethod: AuthenticationMethod,
            isPendingDownload: Bool
        )
        
        let info: Info = try await dependencies[singleton: .storage].readAsync { db -> Info in
            guard let attachment: Attachment = try? Attachment.fetchOne(db, id: details.attachmentId) else {
                throw JobRunnerError.missingRequiredDetails
            }
            
            /// If the original interaction no longer exists then don't bother uploading the attachment (ie. the message was
            /// deleted before it even got sent)
            guard (try? Interaction.exists(db, id: interactionId)) == true else {
                Log.info(.cat, "Failed due to missing interaction")
                throw StorageError.objectNotFound
            }
            
            /// Get the `authMethod` needed to perform the download
            let threadVariant: SessionThread.Variant = try SessionThread
                .select(.variant)
                .filter(id: threadId)
                .asRequest(of: SessionThread.Variant.self)
                .fetchOne(db, orThrow: StorageError.objectNotFound)
            let authMethod: AuthenticationMethod = try Authentication.with(
                db,
                threadId: threadId,
                threadVariant: threadVariant,
                using: dependencies
            )
            
            /// If the attachment is still pending download the hold off on running this job
            guard attachment.state != .pendingDownload && attachment.state != .downloading else {
                Log.info(.cat, "Attachment is still being downloaded")
                return (attachment, authMethod, true)
            }
            
            return (attachment, authMethod, false)
        }
        try Task.checkCancellation()
        
        guard !info.isPendingDownload else {
            guard let jobId: Int64 = job.id else {
                throw JobRunnerError.jobIdMissing
            }
            
            /// Find the pending download
            let existingDownloadJobState: JobState? = await dependencies[singleton: .jobRunner].firstJobMatching(
                filters: JobRunner.Filters(
                    include: [
                        try .details(
                            AttachmentDownloadJob.Details(
                                attachmentId: details.attachmentId
                            )
                        )
                    ]
                )
            )
            try await dependencies[singleton: .storage].writeAsync { db in
                let downloadJobId: Int64
                
                if existingDownloadJobState == nil {
                    let interactionAttachment: InteractionAttachment = try InteractionAttachment
                        .filter(InteractionAttachment.Columns.attachmentId == details.attachmentId)
                        .fetchOne(db) ?? {
                            Log.info(.cat, "Failed to find original interaction for attachment")
                            throw JobRunnerError.missingDependencies
                        }()
                    
                    let maybeDownloadJob: Job? = dependencies[singleton: .jobRunner].add(
                        db,
                        job: Job(
                            variant: .attachmentDownload,
                            threadId: threadId,
                            interactionId: interactionAttachment.interactionId,
                            details: AttachmentDownloadJob.Details(
                                attachmentId: details.attachmentId
                            )
                        )
                    )
                    
                    downloadJobId = try maybeDownloadJob?.id ?? {
                        Log.info(.cat, "Failed to create download job for pending attachment")
                        throw JobRunnerError.missingDependencies
                    }()
                }
                else {
                    downloadJobId = try existingDownloadJobState?.job.id ?? {
                        Log.info(.cat, "Failed to retrieve existing download job id")
                        throw JobRunnerError.missingDependencies
                    }()
                }
                
                /// Add a dependency on the download job in case the app restarts before this job completes
                try dependencies[singleton: .jobRunner].addJobDependency(
                    db,
                    .job(jobId: jobId, otherJobId: downloadJobId)
                )
            }
            
            /// Defer the upload until the download completes
            Log.info(.cat, "Deferred as attachment is still being downloaded")
            return .deferred
        }
        
        /// If this is associated with a `messageSend` job then we need to update it's state
        try? await dependencies[singleton: .storage].writeAsync { db in
            guard
                let sendJob: Job = try Job.fetchOne(db, id: details.messageSendJobId),
                let sendJobDetails: Data = sendJob.details,
                let details: MessageSendJob.Details = try? JSONDecoder(using: dependencies)
                    .decode(MessageSendJob.Details.self, from: sendJobDetails)
            else { return }
            
            MessageSender.handleMessageWillSend(
                db,
                threadId: threadId,
                message: details.message,
                destination: details.destination,
                interactionId: interactionId,
                using: dependencies
            )
        }
        do {
            try Task.checkCancellation()
            
            try await upload(
                attachment: info.attachment,
                threadId: threadId,
                interactionId: interactionId,
                messageSendJobId: details.messageSendJobId,
                authMethod: info.authMethod,
                onEvent: standardEventHandling(using: dependencies),
                using: dependencies
            )
            try Task.checkCancellation()
            
            return .success
        }
        catch {
            let alreadyLoggedError: Bool? = try? await dependencies[singleton: .storage].writeAsync { db in
                /// Update the attachment state
                try Attachment
                    .filter(id: details.attachmentId)
                    .updateAll(db, Attachment.Columns.state.set(to: Attachment.State.failedUpload))
                db.addAttachmentEvent(
                    id: details.attachmentId,
                    messageId: job.interactionId,
                    type: .updated(.state(.failedUpload))
                )
                
                /// If this upload is related to sending a message then trigger the `handleFailedMessageSend` logic
                /// as we want to ensure the message has the correct delivery status
                guard
                    let sendJob: Job = try Job.fetchOne(db, id: details.messageSendJobId),
                    let sendJobDetails: Data = sendJob.details,
                    let details: MessageSendJob.Details = try? JSONDecoder(using: dependencies)
                        .decode(MessageSendJob.Details.self, from: sendJobDetails)
                else { return false }
                
                MessageSender.handleFailedMessageSend(
                    db,
                    threadId: threadId,
                    message: details.message,
                    destination: nil,
                    error: .sendFailure(.cat, "Failed", error),
                    interactionId: interactionId,
                    using: dependencies
                )
                return true
            }
            
            /// If we didn't log an error above then log it now
            if alreadyLoggedError != true {
                Log.error(.cat, "Failed due to error: \(error)")
            }
            
            throw error
        }
    }
}

// MARK: - AttachmentUploadJob.Details

extension AttachmentUploadJob {
    public struct Details: Codable {
        /// This is the id for the messageSend job this attachmentUpload job is associated to
        public let messageSendJobId: Int64
        
        /// The id of the `Attachment` to upload
        public let attachmentId: String
        
        public init(messageSendJobId: Int64, attachmentId: String) {
            self.messageSendJobId = messageSendJobId
            self.attachmentId = attachmentId
        }
    }
}

// MARK: - Uploading

public extension AttachmentUploadJob {
    typealias PreparedUpload = (
        request: Network.PreparedRequest<FileUploadResponse>,
        attachment: Attachment,
        preparedAttachment: PreparedAttachment
    )
    
    enum Event {
        case willUpload(Attachment, threadId: String, interactionId: Int64?, messageSendJobId: Int64?)
        case success(Attachment, interactionId: Int64?)
    }
    
    static func preparePriorToUpload(
        attachments: [PendingAttachment],
        using dependencies: Dependencies
    ) async throws -> [Attachment] {
        var result: [Attachment] = []
        
        for pendingAttachment in attachments {
            /// Strip any metadata from the attachment and store at a "Pending Upload" file path
            let preparedAttachment: PreparedAttachment = try await pendingAttachment.prepare(
                operations: [
                    .stripImageMetadata
                ],
                storeAtPendingAttachmentUploadPath: true,
                using: dependencies
            )
            
            result.append(preparedAttachment.attachment)
        }
        
        return result
    }
    
    static func link(
        _ db: ObservingDatabase,
        attachments: [Attachment]?,
        toInteractionWithId interactionId: Int64?
    ) throws {
        guard
            let attachments: [Attachment] = attachments,
            let interactionId: Int64 = interactionId
        else { return }
                
        try attachments
            .enumerated()
            .forEach { index, attachment in
                let interactionAttachment: InteractionAttachment = InteractionAttachment(
                    albumIndex: index,
                    interactionId: interactionId,
                    attachmentId: attachment.id
                )
                
                try attachment.insert(db)
                try interactionAttachment.insert(db)
            }
    }
    
    @discardableResult
    static func upload(
        attachment: Attachment,
        threadId: String,
        interactionId: Int64?,
        messageSendJobId: Int64?,
        authMethod: AuthenticationMethod,
        onEvent: ((Event) async throws -> Void)?,
        using dependencies: Dependencies
    ) async throws -> (attachment: Attachment, response: FileUploadResponse) {
        let shouldEncrypt: Bool = {
            switch authMethod {
                case is Authentication.Community: return false
                default: return true
            }
        }()
        
        /// This can occur if an `AttachmentUploadJob` was explicitly created for a message dependant on the attachment being
        /// uploaded (in this case the attachment has already been uploaded so just succeed)
        if
            attachment.state == .uploaded,
            let fileId: String = Network.FileServer.fileId(for: attachment.downloadUrl),
            !dependencies[singleton: .attachmentManager].isPlaceholderUploadUrl(attachment.downloadUrl)
        {
            return (attachment, FileUploadResponse(id: fileId, uploaded: nil, expires: nil))
        }
        
        /// If the attachment is a downloaded attachment, check if it came from the server and if so just succeed immediately (no use
        /// re-uploading an attachment that is already present on the server) - or if we want it to be encrypted and it's not currently encrypted
        ///
        /// **Note:** The most common cases for this will be for `LinkPreviews`
        if
            attachment.state == .downloaded,
            let fileId: String = Network.FileServer.fileId(for: attachment.downloadUrl),
            !dependencies[singleton: .attachmentManager].isPlaceholderUploadUrl(attachment.downloadUrl),
            (
                !shouldEncrypt ||
                attachment.encryptionKey != nil
            )
        {
            return (attachment, FileUploadResponse(id: fileId, uploaded: nil, expires: nil))
        }
        
        /// If we have gotten here then we need to upload
        try await onEvent?(.willUpload(attachment, threadId: threadId, interactionId: interactionId, messageSendJobId: messageSendJobId))
        try Task.checkCancellation()
        
        /// Encrypt the attachment if needed
        let pendingAttachment: PendingAttachment = try PendingAttachment(
            attachment: attachment,
            using: dependencies
        )
        let preparedAttachment: PreparedAttachment = try await pendingAttachment.prepare(
            operations: (shouldEncrypt ? [.encrypt(domain: .attachment)] : []),
            using: dependencies
        )
        let maybePreparedData: Data? = try? dependencies[singleton: .fileManager]
            .contents(atPath: preparedAttachment.filePath)
        try Task.checkCancellation()
        
        guard let preparedData: Data = maybePreparedData else {
            Log.error(.cat, "Couldn't retrieve prepared attachment data.")
            throw AttachmentError.invalidData
        }
            
        /// Ensure the file size is smaller than our upload limit
        Log.info(.cat, "File size: \(preparedData.count) bytes.")
        guard preparedData.count <= Network.maxFileSize else {
            throw NetworkError.maxFileSizeExceeded
        }
        
        let request: Network.PreparedRequest<FileUploadResponse>
        
        /// Return the request and the prepared attachment
        switch authMethod {
            case let communityAuth as Authentication.Community:
                request = try Network.SOGS.preparedUpload(
                    data: preparedData,
                    roomToken: communityAuth.roomToken,
                    authMethod: communityAuth,
                    using: dependencies
                )
                
            default:
                request = try Network.FileServer.preparedUpload(
                    data: preparedData,
                    using: dependencies
                )
        }
        
        // FIXME: Make this async/await when the refactored networking is merged
        let response: FileUploadResponse = try await request
            .send(using: dependencies)
            .values
            .first(where: { _ in true })?.1 ?? { throw AttachmentError.uploadFailed }()
        try Task.checkCancellation()
        
        /// If the `downloadUrl` previously had a value and we are updating it then we need to move the file from it's current location
        /// to the hash that would be generated for the new location
        ///
        /// **Note:** Attachments are currently stored unencrypted so we need to move the original `attachment` file to the
        ///  `finalFilePath` rather than the encrypted one
        // FIXME: Should probably store display pictures encrypted and decrypt on load
        let finalDownloadUrl: String = {
            let isPlaceholderUploadUrl: Bool = dependencies[singleton: .attachmentManager]
                .isPlaceholderUploadUrl(attachment.downloadUrl)

            switch (attachment.downloadUrl, isPlaceholderUploadUrl, authMethod) {
                case (.some(let downloadUrl), false, _): return downloadUrl
                case (_, _, let community as Authentication.Community):
                    return Network.SOGS.downloadUrlString(
                        for: response.id,
                        server: community.server,
                        roomToken: community.roomToken
                    )
                    
                default:
                    return Network.FileServer.downloadUrlString(
                        for: response.id,
                        using: dependencies
                    )
            }
        }()
        
        if
            let oldUrl: String = attachment.downloadUrl,
            finalDownloadUrl != oldUrl,
            let oldPath: String = try? dependencies[singleton: .attachmentManager].path(for: oldUrl),
            let newPath: String = try? dependencies[singleton: .attachmentManager].path(for: finalDownloadUrl)
        {
            if !dependencies[singleton: .fileManager].fileExists(atPath: newPath) {
                try dependencies[singleton: .fileManager].moveItem(atPath: oldPath, toPath: newPath)
            }
            else {
                try? dependencies[singleton: .fileManager].removeItem(atPath: oldPath)
                Log.info(.cat, "File already existed at final path, assuming re-upload of existing attachment")
            }
        }
        
        /// Generate the final uploaded attachment data and trigger the success callback
        let uploadedAttachment: Attachment = Attachment(
            id: preparedAttachment.attachment.id,
            serverId: response.id,
            variant: preparedAttachment.attachment.variant,
            state: .uploaded,
            contentType: preparedAttachment.attachment.contentType,
            byteCount: preparedAttachment.attachment.byteCount,
            creationTimestamp: (
                preparedAttachment.attachment.creationTimestamp ??
                (dependencies[cache: .snodeAPI].currentOffsetTimestampMs() / 1000)
            ),
            sourceFilename: preparedAttachment.attachment.sourceFilename,
            downloadUrl: finalDownloadUrl,
            width: preparedAttachment.attachment.width,
            height: preparedAttachment.attachment.height,
            duration: preparedAttachment.attachment.duration,
            isVisualMedia: preparedAttachment.attachment.isVisualMedia,
            isValid: preparedAttachment.attachment.isValid,
            encryptionKey: preparedAttachment.attachment.encryptionKey,
            digest: preparedAttachment.attachment.digest
        )
        try await onEvent?(.success(uploadedAttachment, interactionId: interactionId))
        try Task.checkCancellation()
        
        return (uploadedAttachment, response)
    }
    
    /// This function performs the standard database actions when various upload events occur
    ///
    /// Returns `true` if the event resulted in a `MessageSendJob` being updated
    static func standardEventHandling(using dependencies: Dependencies) -> ((Event) async throws -> Void) {
        return { event in
            try await dependencies[singleton: .storage].writeAsync { db in
                switch event {
                    case .willUpload(let attachment, let threadId, let interactionId, let messageSendJobId):
                        _ = try? Attachment
                            .filter(id: attachment.id)
                            .updateAll(db, Attachment.Columns.state.set(to: Attachment.State.uploading))
                        db.addAttachmentEvent(
                            id: attachment.id,
                            messageId: interactionId,
                            type: .updated(.state(.uploading))
                        )
                        
                        /// If this upload is related to sending a message then trigger the `handleMessageWillSend` logic as if
                        /// this is a retry the logic wouldn't run until after the upload has completed resulting in a potentially incorrect
                        /// delivery status
                        guard
                            let sendJob: Job = try Job.fetchOne(db, id: messageSendJobId),
                            let sendJobDetails: Data = sendJob.details,
                            let details: MessageSendJob.Details = try? JSONDecoder(using: dependencies)
                                .decode(MessageSendJob.Details.self, from: sendJobDetails)
                        else { return }
                        
                        MessageSender.handleMessageWillSend(
                            db,
                            threadId: threadId,
                            message: details.message,
                            destination: details.destination,
                            interactionId: interactionId,
                            using: dependencies
                        )
                        
                    case .success(let updatedAttachment, let interactionId):
                        try updatedAttachment.upsert(db)
                        
                        db.addAttachmentEvent(
                            id: updatedAttachment.id,
                            messageId: interactionId,
                            type: .updated(.state(updatedAttachment.state))
                        )
                }
            }
        }
    }
}
