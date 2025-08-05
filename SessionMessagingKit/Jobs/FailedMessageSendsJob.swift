// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import SessionUtilitiesKit

// MARK: - Log.Category

private extension Log.Category {
    static let cat: Log.Category = .create("FailedMessageSendsJob", defaultLevel: .info)
}

// MARK: - FailedMessageSendsJob

public enum FailedMessageSendsJob: JobExecutor {
    public static let maxFailureCount: Int = -1
    public static let requiresThreadId: Bool = false
    public static let requiresInteractionId: Bool = false
    
    public static func run<S: Scheduler>(
        _ job: Job,
        scheduler: S,
        success: @escaping (Job, Bool) -> Void,
        failure: @escaping (Job, Error, Bool) -> Void,
        deferred: @escaping (Job) -> Void,
        using dependencies: Dependencies
    ) {
        guard dependencies[cache: .general].userExists else { return success(job, false) }
        
        var changeCount: Int = -1
        var attachmentChangeCount: Int = -1
        
        // Update all 'sending' message states to 'failed'
        dependencies[singleton: .storage]
            .writePublisher { db in
                let sendInteractionInfo: Set<InteractionIdThreadId> = try Interaction
                    .select(.id, .threadId)
                    .filter(Interaction.Columns.state == Interaction.State.sending)
                    .asRequest(of: InteractionIdThreadId.self)
                    .fetchSet(db)
                let syncInteractionInfo: Set<InteractionIdThreadId> = try Interaction
                    .select(.id, .threadId)
                    .filter(Interaction.Columns.state == Interaction.State.syncing)
                    .asRequest(of: InteractionIdThreadId.self)
                    .fetchSet(db)
                let attachmentIds: Set<String> = try Attachment
                    .select(.id)
                    .filter(Attachment.Columns.state == Attachment.State.uploading)
                    .asRequest(of: String.self)
                    .fetchSet(db)
                let interactionAttachment: [InteractionAttachment] = try InteractionAttachment
                    .filter(attachmentIds.contains(InteractionAttachment.Columns.attachmentId))
                    .fetchAll(db)
                
                let sendChangeCount: Int = try Interaction
                    .filter(sendInteractionInfo.map { $0.id }.contains(Interaction.Columns.id))
                    .updateAll(db, Interaction.Columns.state.set(to: Interaction.State.failed))
                let syncChangeCount: Int = try Interaction
                    .filter(syncInteractionInfo.map { $0.id }.contains(Interaction.Columns.id))
                    .updateAll(db, Interaction.Columns.state.set(to: Interaction.State.failedToSync))
                attachmentChangeCount = try Attachment
                    .filter(attachmentIds.contains(Attachment.Columns.id))
                    .updateAll(db, Attachment.Columns.state.set(to: Attachment.State.failedUpload))
                changeCount = (sendChangeCount + syncChangeCount)
                
                /// Send the database events
                sendInteractionInfo.forEach { info in
                    db.addMessageEvent(id: info.id, threadId: info.threadId, type: .updated(.state(.failed)))
                }
                syncInteractionInfo.forEach { info in
                    db.addMessageEvent(id: info.id, threadId: info.threadId, type: .updated(.state(.failedToSync)))
                }
                interactionAttachment.forEach { val in
                    db.addAttachmentEvent(
                        id: val.attachmentId,
                        messageId: val.interactionId,
                        type: .updated(.state(.failedUpload))
                    )
                }
            }
            .subscribe(on: scheduler, using: dependencies)
            .receive(on: scheduler, using: dependencies)
            .sinkUntilComplete(
                receiveCompletion: { _ in
                    Log.info(.cat, "Messages marked as failed: \(changeCount), Uploads cancelled: \(attachmentChangeCount)")
                    success(job, false)
                }
            )
    }
}

private struct InteractionIdThreadId: Codable, Hashable, FetchableRecord {
    let id: Int64
    let threadId: String
}
