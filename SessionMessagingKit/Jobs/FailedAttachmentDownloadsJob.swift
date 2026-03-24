// Copyright © 2026 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

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
        /// Need to wait until the `general` cache has been initialised, otherwise this can race the startup process and may not run
        await dependencies.untilInitialised(cache: .general)
        
        guard dependencies[cache: .general].userExists else {
            return .success
        }
        
        /// Update all 'sending' message states to 'failed'
        let (changeCount, attachmentInfo): (Int, Set<FetchablePair<String, Attachment.State>>) = try await dependencies[singleton: .storage].write { db in
            let attachmentInfo: Set<FetchablePair<String, Attachment.State>> = try Attachment
                .select(.id, .state)
                .filter(
                    Attachment.Columns.state != Attachment.State.downloaded &&
                    Attachment.Columns.state != Attachment.State.uploaded
                )
                .asRequest(of: FetchablePair<String, Attachment.State>.self)
                .fetchSet(db)
            let attachmentIds: Set<String> = Set(attachmentInfo.map(\.first))
            let interactionAttachments: [InteractionAttachment] = try InteractionAttachment
                .filter(attachmentIds.contains(InteractionAttachment.Columns.attachmentId))
                .fetchAll(db)
            
            /// Create a single set of the attachment data
            let interactionIds: [String: Int64] = interactionAttachments.reduce(into: [:]) { result, next in
                result[next.attachmentId] = next.interactionId
            }
            
            /// If there are pending attachments then check if they have `AttachmentDownloadJobs` and if so we don't want to
            /// mark them as failed
            let targetInteractionIds: Set<Int64> = Set(interactionIds.values)
            let attachmentDownloadJobInteractionIds: Set<Int64> = try Job
                .select(Job.Columns.interactionId)
                .filter(targetInteractionIds.contains(Job.Columns.interactionId))
                .filter(Job.Columns.variant == Job.Variant.attachmentDownload)
                .asRequest(of: Int64.self)
                .fetchSet(db)
            let attachmentIdsToMarkAsFailed: Set<String> = Set(attachmentInfo.compactMap { info in
                guard info.second != .downloaded else { return nil }     /// Just in case
                guard info.second != .uploaded else { return nil }       /// Just in case
                guard info.second != .failedDownload else { return nil } /// No change needed
                guard info.second != .failedUpload else { return nil }   /// No change needed
                guard
                    info.second == .downloading ||
                    !attachmentDownloadJobInteractionIds.contains(interactionIds[info.first] ?? -1)
                else { return nil }
                
                return info.first
            })
            
            if !attachmentIdsToMarkAsFailed.isEmpty {
                try Attachment
                    .filter(attachmentIdsToMarkAsFailed.contains(Attachment.Columns.id))
                    .updateAll(db, Attachment.Columns.state.set(to: Attachment.State.failedDownload))
                
                for attachmentId in attachmentIdsToMarkAsFailed {
                    db.addAttachmentEvent(
                        id: attachmentId,
                        messageId: interactionIds[attachmentId],
                        type: .updated(.state(.failedDownload))
                    )
                }
            }
            
            return (attachmentIdsToMarkAsFailed.count, attachmentInfo)
        }
        try Task.checkCancellation()
        
        let states: [Attachment.State: Int] = attachmentInfo.reduce(into: [:]) { result, next in
            result[next.second, default: 0] += 1
        }
        let stateString: String = "failedDownload: \(states[.failedDownload] ?? -1), pendingDownload: \(states[.pendingDownload] ?? 0), downloading: \(states[.downloading] ?? 0), failedUpload: \(states[.failedUpload] ?? 0), uploading: \(states[.uploading] ?? 0)"
        
        Log.info(.cat, "Marked \(changeCount) attachments as failed (incomplete states before change - \(stateString))")
        return .success
    }
}
