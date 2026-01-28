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
    
    public static func canRunConcurrentlyWith(
        runningJobs: [JobState],
        jobState: JobState,
        using dependencies: Dependencies
    ) -> Bool {
        /// No point running more than 1 at a time
        return false
    }
    
    public static func run(_ job: Job, using dependencies: Dependencies) async throws -> JobExecutionResult {
        guard dependencies[cache: .general].userExists else { return .success }
        
        /// Update all 'sending' message states to 'failed'
        let (changeCount, attachmentChangeCount): (Int, Int) = try await dependencies[singleton: .storage].writeAsync { db in
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
            let attachmentChangeCount: Int = try Attachment
                .filter(attachmentIds.contains(Attachment.Columns.id))
                .updateAll(db, Attachment.Columns.state.set(to: Attachment.State.failedUpload))
            let changeCount: Int = (sendChangeCount + syncChangeCount)
            
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
            
            return (changeCount, attachmentChangeCount)
        }
        try Task.checkCancellation()
        
        Log.info(.cat, "Messages marked as failed: \(changeCount), Uploads cancelled: \(attachmentChangeCount)")
        return .success
    }
}

private struct InteractionIdThreadId: Codable, Hashable, FetchableRecord {
    let id: Int64
    let threadId: String
}
