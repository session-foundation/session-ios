// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
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
                
                let authMethod: AuthenticationMethod = try await dependencies[singleton: .storage].writeAsync { db in
                    /// If this upload is related to sending a message then trigger the `handleMessageWillSend` logic as if
                    /// this is a retry the logic wouldn't run until after the upload has completed resulting in a potentially incorrect
                    /// delivery status
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
                        threadId: threadId,
                        message: details.message,
                        destination: details.destination,
                        interactionId: interactionId,
                        using: dependencies
                    )
                    
                    return authMethod
                }
                try Task.checkCancellation()
                
                let request: Network.PreparedRequest<(attachment: Attachment, fileId: String)> = try AttachmentUploader.preparedUpload(
                    attachment: attachment,
                    logCategory: .cat,
                    authMethod: authMethod,
                    using: dependencies
                )
                
                /// If we have a `cachedResponse` (ie. already uploaded) then don't change the attachment state to uploading
                /// as it's already been done
                if request.cachedResponse == nil {
                    /// Update the attachment to the `uploading` state
                    try? await dependencies[singleton: .storage].writeAsync { db in
                        _ = try? Attachment
                            .filter(id: details.attachmentId)
                            .updateAll(db, Attachment.Columns.state.set(to: Attachment.State.uploading))
                        db.addAttachmentEvent(
                            id: details.attachmentId,
                            messageId: job.interactionId,
                            type: .updated(.state(.uploading))
                        )
                    }
                }
                
                // FIXME: Make this async/await when the refactored networking is merged
                let response: (attachment: Attachment, fileId: String) = try await request
                    .send(using: dependencies)
                    .values
                    .first(where: { _ in true })?.1 ?? { throw AttachmentError.uploadFailed }()
                try Task.checkCancellation()
                
                /// Save the updated attachment
                try await dependencies[singleton: .storage].writeAsync { db in
                    try response.attachment.upsert(db)
                    db.addAttachmentEvent(
                        id: response.attachment.id,
                        messageId: job.interactionId,
                        type: .updated(.state(response.attachment.state))
                    )
                }
                
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
                let triggeredSendFailed: Bool? = try? await dependencies[singleton: .storage].writeAsync { db in
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
                    if triggeredSendFailed == false {
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
