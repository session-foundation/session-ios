// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import SessionSnodeKit
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
            let details: Details = try? JSONDecoder(using: dependencies).decode(Details.self, from: detailsData),
            let attachment: Attachment = dependencies[singleton: .storage]
                .read({ db in try Attachment.fetchOne(db, id: details.attachmentId) })
        else { return failure(job, JobRunnerError.missingRequiredDetails, true) }
        
        // If the original interaction no longer exists then don't bother uploading the attachment (ie. the
        // message was deleted before it even got sent)
        guard dependencies[singleton: .storage].read({ db in try Interaction.exists(db, id: interactionId) }) == true else {
            Log.info(.cat, "Failed due to missing interaction")
            return failure(job, StorageError.objectNotFound, true)
        }
        
        // If the attachment is still pending download the hold off on running this job
        guard attachment.state != .pendingDownload && attachment.state != .downloading else {
            Log.info(.cat, "Deferred as attachment is still being downloaded")
            return deferred(job)
        }
        
        /// If this upload is related to sending a message then trigger the `handleMessageWillSend` logic as if this is a retry the
        /// logic wouldn't run until after the upload has completed resulting in a potentially incorrect delivery status
        dependencies[singleton: .storage]
            .writePublisher { db -> AuthenticationMethod in
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
                
                guard
                    let sendJob: Job = try Job.fetchOne(db, id: details.messageSendJobId),
                    let sendJobDetails: Data = sendJob.details,
                    let details: MessageSendJob.Details = try? JSONDecoder(using: dependencies)
                        .decode(MessageSendJob.Details.self, from: sendJobDetails)
                else { return authMethod }
                
                MessageSender.handleMessageWillSend(
                    db,
                    message: details.message,
                    destination: details.destination,
                    interactionId: interactionId
                )
                
                return authMethod
            }
            .subscribe(on: scheduler, using: dependencies)
            .receive(on: scheduler, using: dependencies)
            .tryMap { authMethod -> Network.PreparedRequest<(attachment: Attachment, fileId: String)> in
                try AttachmentUploader.preparedUpload(
                    attachment: attachment,
                    logCategory: .cat,
                    authMethod: authMethod,
                    using: dependencies
                )
            }
            .flatMapStorageWritePublisher(using: dependencies) { db, uploadRequest -> Network.PreparedRequest<(attachment: Attachment, fileId: String)> in
                /// If we have a `cachedResponse` (ie. already uploaded) then don't change the attachment state to uploading
                /// as it's already been done
                guard uploadRequest.cachedResponse == nil else { return uploadRequest }
                
                /// Update the attachment to the `uploading` state
                _ = try? Attachment
                    .filter(id: attachment.id)
                    .updateAll(db, Attachment.Columns.state.set(to: Attachment.State.uploading))
                
                return uploadRequest
            }
            .flatMap { $0.send(using: dependencies) }
            .map { _, value -> Attachment in value.attachment }
            .handleEvents(
                receiveCancel: {
                    /// If the stream gets cancelled then `receiveCompletion` won't get called, so we need to handle that
                    /// case and flag the upload as cancelled
                    dependencies[singleton: .storage].writeAsync { db in
                        try Attachment
                            .filter(id: attachment.id)
                            .updateAll(db, Attachment.Columns.state.set(to: Attachment.State.failedUpload))
                    }
                }
            )
            .flatMapStorageWritePublisher(using: dependencies) { db, updatedAttachment in
                /// Ensure there were changes before triggering a db write to avoid unneeded write queue use and UI updates
                guard updatedAttachment != attachment else { return }
                
                try updatedAttachment.upserted(db)
            }
            .sinkUntilComplete(
                receiveCompletion: { result in
                    switch result {
                        case .finished: success(job, false)
                        
                        case .failure(let error):
                            dependencies[singleton: .storage].writeAsync(
                                updates: { db in
                                    /// Update the attachment state
                                    try Attachment
                                        .filter(id: attachment.id)
                                        .updateAll(db, Attachment.Columns.state.set(to: Attachment.State.failedUpload))
                                    
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
                                        message: details.message,
                                        destination: nil,
                                        error: .other(.cat, "Failed", error),
                                        interactionId: interactionId,
                                        using: dependencies
                                    )
                                    return true
                                },
                                completion: { result in
                                    /// If we didn't log an error above then log it now
                                    switch result {
                                        case .failure, .success(true): break
                                        case .success(false): Log.error(.cat, "Failed due to error: \(error)")
                                    }
                                    
                                    failure(job, error, false)
                                }
                            )
                    }
                }
            )
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
