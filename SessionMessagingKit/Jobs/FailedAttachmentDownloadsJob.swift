// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import SessionUtilitiesKit

// MARK: - Log.Category

private extension Log.Category {
    static let cat: Log.Category = .create("FailedAttachmentDownloadsJob", defaultLevel: .info)
}

// MARK: - FailedAttachmentDownloadsJob

public enum FailedAttachmentDownloadsJob: JobExecutor {
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
        let changeCount: Int = try await dependencies[singleton: .storage].writeAsync { db in
            let attachmentIds: Set<String> = try Attachment
                .select(.id)
                .filter(Attachment.Columns.state == Attachment.State.downloading)
                .asRequest(of: String.self)
                .fetchSet(db)
            let interactionAttachment: [InteractionAttachment] = try InteractionAttachment
                .filter(attachmentIds.contains(InteractionAttachment.Columns.attachmentId))
                .fetchAll(db)
            
            try Attachment
                .filter(attachmentIds.contains(Attachment.Columns.id))
                .updateAll(db, Attachment.Columns.state.set(to: Attachment.State.failedDownload))
            
            interactionAttachment.forEach { val in
                db.addAttachmentEvent(
                    id: val.attachmentId,
                    messageId: val.interactionId,
                    type: .updated(.state(.failedDownload))
                )
            }
            
            /// Shouldn't be possible but just in case
            if attachmentIds.count != interactionAttachment.count {
                let remainingIds: Set<String> = attachmentIds
                    .removing(contentsOf: Set(interactionAttachment.map { $0.attachmentId }))
                
                remainingIds.forEach { id in
                    db.addAttachmentEvent(id: id, messageId: nil, type: .updated(.state(.failedDownload)))
                }
            }
            
            return attachmentIds.count
        }
        try Task.checkCancellation()
        
        Log.info(.cat, "Marked \(changeCount) attachments as failed")
        return .success
    }
}
