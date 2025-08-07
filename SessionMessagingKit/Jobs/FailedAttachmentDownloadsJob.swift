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
        
        // Update all 'sending' message states to 'failed'
        dependencies[singleton: .storage]
            .writePublisher { db in
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
                changeCount = attachmentIds.count
                
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
            }
            .subscribe(on: scheduler, using: dependencies)
            .receive(on: scheduler, using: dependencies)
            .sinkUntilComplete(
                receiveCompletion: { _ in
                    Log.info(.cat, "Marked \(changeCount) attachments as failed")
                    success(job, false)
                }
            )
    }
}
