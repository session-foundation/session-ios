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
    
    public static func run<S: Scheduler>(
        _ job: Job,
        scheduler: S,
        success: @escaping (Job, Bool) -> Void,
        failure: @escaping (Job, Error, Bool) -> Void,
        deferred: @escaping (Job) -> Void,
        using dependencies: Dependencies
    ) {
        guard
            let threadId: String = job.threadId,
            let interactionId: Int64 = job.interactionId,
            let detailsData: Data = job.details,
            let details: Details = try? JSONDecoder(using: dependencies).decode(Details.self, from: detailsData)
        else { return failure(job, JobRunnerError.missingRequiredDetails, true) }
        
        Task {
            do {
                let attachment: Attachment = try await dependencies[singleton: .storage].readAsync { db in
                    guard let attachment: Attachment = try? Attachment.fetchOne(db, id: details.attachmentId) else {
                        throw JobRunnerError.missingRequiredDetails
                    }
                    
                    /// If the original interaction no longer exists then don't bother uploading the attachment (ie. the message was
                    /// deleted before it even got sent)
                    guard (try? Interaction.exists(db, id: interactionId)) == true else {
                        throw StorageError.objectNotFound
                    }
                    
                    /// If the attachment is still pending download the hold off on running this job
                    guard attachment.state != .pendingDownload && attachment.state != .downloading else {
                        throw AttachmentError.uploadIsStillPendingDownload
                    }
                    
                    return attachment
                }
                try Task.checkCancellation()
                
                let authMethod: AuthenticationMethod = try await dependencies[singleton: .storage].readAsync { db in
                    let threadVariant: SessionThread.Variant = try SessionThread
                        .select(.variant)
                        .filter(id: threadId)
                        .asRequest(of: SessionThread.Variant.self)
                        .fetchOne(db, orThrow: StorageError.objectNotFound)
                    return try Authentication.with(
                        db,
                        threadId: threadId,
                        threadVariant: threadVariant,
                        using: dependencies
                    )
                }
                try Task.checkCancellation()
                
                try await upload(
                    attachment: attachment,
                    threadId: threadId,
                    interactionId: interactionId,
                    messageSendJobId: details.messageSendJobId,
                    authMethod: authMethod,
                    onEvent: standardEventHandling(using: dependencies),
                    using: dependencies
                )
                try Task.checkCancellation()
                
                return scheduler.schedule {
                    success(job, false)
                }
            }
            catch JobRunnerError.missingRequiredDetails {
                return scheduler.schedule {
                    failure(job, JobRunnerError.missingRequiredDetails, true)
                }
            }
            catch StorageError.objectNotFound {
                return scheduler.schedule {
                    Log.info(.cat, "Failed due to missing interaction")
                    failure(job, StorageError.objectNotFound, true)
                }
            }
            catch AttachmentError.uploadIsStillPendingDownload {
                return scheduler.schedule {
                    Log.info(.cat, "Deferred as attachment is still being downloaded")
                    return deferred(job)
                }
            }
            catch {
                let triggeredMessageSendFailure: Bool? = try? await dependencies[singleton: .storage].writeAsync { db in
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
                        error: .other(.cat, "Failed", error),
                        interactionId: interactionId,
                        using: dependencies
                    )
                    return true
                }
                
                return scheduler.schedule {
                    if triggeredMessageSendFailure == false {
                        Log.error(.cat, "Failed due to error: \(error)")
                    }
                    
                    failure(job, error, false)
                }
            }
        }
    }
}

// MARK: - AttachmentUploadJob.Details

extension AttachmentUploadJob {
    public struct Details: Codable {
        /// This is the id for the messageSend job this attachmentUpload job is associated to, the value isn't used for any of
        /// the logic but we want to mandate that the attachmentUpload job can only be used alongside a messageSend job
        ///
        /// **Note:** If we do decide to remove this the `_003_YDBToGRDBMigration` will need to be updated as it
        /// fails if this connection can't be made
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
        attachment: PreparedAttachment
    )
    
    enum Event {
        case willUpload(Attachment, threadId: String, interactionId: Int64?, messageSendJobId: Int64?)
        case success(Attachment, interactionId: Int64?)
    }
    
    static func preparePriorToUpload(
        attachments: [PendingAttachment],
        using dependencies: Dependencies
    ) throws -> [Attachment] {
        return try attachments.compactMap { pendingAttachment in
            /// Strip any metadata from the attachment
            let preparedAttachment: PreparedAttachment = try pendingAttachment.prepare(
                transformations: [
                    .stripImageMetadata
                ],
                using: dependencies
            )
            
            /// The attachment will have been stored in a temporary location during preparation so we need to move it to the
            /// "pending upload" file path (which will be relocated to the deterministic final path after upload)
            try dependencies[singleton: .fileManager].moveItem(
                atPath: preparedAttachment.temporaryFilePath,
                toPath: preparedAttachment.pendingUploadFilePath
            )
            
            return preparedAttachment.attachment
        }
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
    ) async throws -> Attachment {
        let shouldEncrypt: Bool = {
            switch authMethod {
                case is Authentication.community: return false
                default: return true
            }
        }()
        
        /// This can occur if an `AttachmentUploadJob` was explicitly created for a message dependant on the attachment being
        /// uploaded (in this case the attachment has already been uploaded so just succeed)
        if
            attachment.state == .uploaded,
            Network.FileServer.fileId(for: attachment.downloadUrl) != nil
        {
            return attachment
        }
        
        /// If the attachment is a downloaded attachment, check if it came from the server and if so just succeed immediately (no use
        /// re-uploading an attachment that is already present on the server) - or if we want it to be encrypted and it's not currently encrypted
        ///
        /// **Note:** The most common cases for this will be for `LinkPreviews`
        if
            attachment.state == .downloaded,
            Network.FileServer.fileId(for: attachment.downloadUrl) != nil,
            (
                !shouldEncrypt ||
                attachment.encryptionKey != nil
            )
        {
            return attachment
        }
        
        /// If we have gotten here then we need to upload
        try await onEvent?(.willUpload(attachment, threadId: threadId, interactionId: interactionId, messageSendJobId: messageSendJobId))
        try Task.checkCancellation()
        
        /// Encrypt the attachment if needed
        let pendingAttachment: PendingAttachment = try PendingAttachment(
            attachment: attachment,
            using: dependencies
        )
        let preparedAttachment: PreparedAttachment = try pendingAttachment.prepare(
            transformations: Set([
                // FIXME: Remove the `legacy` encryption option
                (shouldEncrypt ? .encrypt(legacy: true, domain: .attachment) : nil)
            ].compactMap { $0 }),
            using: dependencies
        )
        let maybePreparedData: Data? = dependencies[singleton: .fileManager]
            .contents(atPath: preparedAttachment.temporaryFilePath)
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
            case let communityAuth as Authentication.community:
                request = try Network.SOGS.preparedUpload(
                    data: preparedData,
                    roomToken: communityAuth.roomToken,
                    authMethod: communityAuth,
                    using: dependencies
                )
                
            default:
                // TODO: Handle custom URLs
                request = try Network.preparedUpload(data: preparedData, using: dependencies)
        }
        
        // FIXME: Make this async/await when the refactored networking is merged
        let response: FileUploadResponse = try await request
            .send(using: dependencies)
            .values
            .first(where: { _ in true })?.1 ?? { throw AttachmentError.uploadFailed }()
        try Task.checkCancellation()
        
        /// If the `downloadUrl` previously had a value and we are updating it then we need to move the file from it's current location
        /// to the hash that would be generated for the new location
        let finalDownloadUrl: String = {
            let isPlaceholderUploadUrl: Bool = dependencies[singleton: .attachmentManager]
                .isPlaceholderUploadUrl(preparedAttachment.attachment.downloadUrl)

            switch (preparedAttachment.attachment.downloadUrl, isPlaceholderUploadUrl, authMethod) {
                case (.some(let downloadUrl), false, _): return downloadUrl
                case (_, _, let community as Authentication.community):
                    return Network.SOGS.downloadUrlString(
                        for: response.id,
                        server: community.server,
                        roomToken: community.roomToken
                    )
                    
                default:
                    // TODO: Handle Custom URLs
                    return Network.FileServer.downloadUrlString(for: response.id)
            }
        }()
        
        if
            let oldUrl: String = preparedAttachment.attachment.downloadUrl,
            finalDownloadUrl != oldUrl,
            let oldPath: String = try? dependencies[singleton: .attachmentManager].path(for: oldUrl),
            let newPath: String = try? dependencies[singleton: .attachmentManager].path(for: finalDownloadUrl)
        {
            try dependencies[singleton: .fileManager].moveItem(atPath: oldPath, toPath: newPath)
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
        
        return uploadedAttachment
    }
    
    @available(*, deprecated, message: "Replace with an async/await call to `upload`")
    static func preparedUpload(
        attachment: Attachment,
        authMethod: AuthenticationMethod,
        using dependencies: Dependencies
    ) throws -> (request: Network.PreparedRequest<FileUploadResponse>, attachment: PreparedAttachment) {
        let endpoint: (any EndpointType) = {
            switch authMethod {
                case let community as Authentication.community:
                    return Network.SOGS.Endpoint.roomFile(community.roomToken)
                    
                default: return Network.FileServer.Endpoint.file
            }
        }()
        let shouldEncrypt: Bool = {
            switch authMethod {
                case is Authentication.community: return false
                default: return true
            }
        }()
        
        /// This can occur if an `AttachmentUploadJob` was explicitly created for a message dependant on the attachment being
        /// uploaded (in this case the attachment has already been uploaded so just succeed)
        if
            attachment.state == .uploaded,
            let fileId: String = Network.FileServer.fileId(for: attachment.downloadUrl)
        {
            return (
                try Network.PreparedRequest<FileUploadResponse>.cached(
                    FileUploadResponse(id: fileId, uploaded: nil, expires: nil),
                    endpoint: endpoint,
                    using: dependencies
                ),
                PreparedAttachment(
                    attachment: attachment,
                    temporaryFilePath: "",
                    pendingUploadFilePath: ""
                )
            )
        }
        
        /// If the attachment is a downloaded attachment, check if it came from the server and if so just succeed immediately (no use
        /// re-uploading an attachment that is already present on the server) - or if we want it to be encrypted and it's not then encrypt it
        ///
        /// **Note:** The most common cases for this will be for `LinkPreviews`
        if
            attachment.state == .downloaded,
            let fileId: String = Network.FileServer.fileId(for: attachment.downloadUrl),
            (
                !shouldEncrypt || (
                    attachment.encryptionKey != nil &&
                    attachment.digest != nil
                )
            )
        {
            return (
                try Network.PreparedRequest.cached(
                    FileUploadResponse(id: fileId, uploaded: nil, expires: nil),
                    endpoint: endpoint,
                    using: dependencies
                ),
                PreparedAttachment(
                    attachment: attachment,
                    temporaryFilePath: "",
                    pendingUploadFilePath: ""
                )
            )
        }
        
        /// Encrypt the attachment if needed
        let pendingAttachment: PendingAttachment = try PendingAttachment(
            attachment: attachment,
            using: dependencies
        )
        let preparedAttachment: PreparedAttachment = try pendingAttachment.prepare(
            transformations: Set([
                // FIXME: Remove the `legacy` encryption option
                (shouldEncrypt ? .encrypt(legacy: true, domain: .attachment) : nil)
            ].compactMap { $0 }),
            using: dependencies
        )
        let maybePreparedData: Data? = dependencies[singleton: .fileManager]
            .contents(atPath: preparedAttachment.temporaryFilePath)
        
        guard let preparedData: Data = maybePreparedData else {
            Log.error(.cat, "Couldn't retrieve prepared attachment data.")
            throw AttachmentError.invalidData
        }
            
        /// Ensure the file size is smaller than our upload limit
        Log.info(.cat, "File size: \(preparedData.count) bytes.")
        guard preparedData.count <= Network.maxFileSize else { throw NetworkError.maxFileSizeExceeded }
        
        /// Return the request and the prepared attachment
        switch authMethod {
            case let communityAuth as Authentication.community:
                return (
                    try Network.SOGS.preparedUpload(
                        data: preparedData,
                        roomToken: communityAuth.roomToken,
                        authMethod: communityAuth,
                        using: dependencies
                    ),
                    preparedAttachment
                )
                
            default:
                return (
                    try Network.preparedUpload(data: preparedData, using: dependencies),
                    preparedAttachment
                )
        }
    }
    
    @available(*, deprecated, message: "Replace with an async/await call to `upload`")
    static func processUploadResponse(
        preparedAttachment: PreparedAttachment,
        authMethod: AuthenticationMethod,
        response: FileUploadResponse,
        using dependencies: Dependencies
    ) throws -> Attachment {
        /// If the `downloadUrl` previously had a value and we are updating it then we need to move the file from it's current location
        /// to the hash that would be generated for the new location
        let finalDownloadUrl: String = {
            let isPlaceholderUploadUrl: Bool = dependencies[singleton: .attachmentManager]
                .isPlaceholderUploadUrl(preparedAttachment.attachment.downloadUrl)

            switch (preparedAttachment.attachment.downloadUrl, isPlaceholderUploadUrl, authMethod) {
                case (.some(let downloadUrl), false, _): return downloadUrl
                case (_, _, let community as Authentication.community):
                    return Network.SOGS.downloadUrlString(
                        for: response.id,
                        server: community.server,
                        roomToken: community.roomToken
                    )
                    
                default:
                    return Network.FileServer.downloadUrlString(for: response.id)
            }
        }()
        
        if
            let oldUrl: String = preparedAttachment.attachment.downloadUrl,
            finalDownloadUrl != oldUrl,
            let oldPath: String = try? dependencies[singleton: .attachmentManager].path(for: oldUrl),
            let newPath: String = try? dependencies[singleton: .attachmentManager].path(for: finalDownloadUrl)
        {
            try dependencies[singleton: .fileManager].moveItem(atPath: oldPath, toPath: newPath)
        }
        
        return Attachment(
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
