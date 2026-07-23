// Copyright © 2026 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import Combine
import GRDB
import SessionNetworkingKit
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
        let (changeCount, attachmentInfo, numPendingDownloadsWithJobs): (Int, Set<FetchablePair<String, Attachment.State>>, Int) = try await dependencies[singleton: .storage].write { db in
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
            
            let remainingPendingDownloadIds = attachmentInfo
                .filter { !attachmentIdsToMarkAsFailed.contains($0.first) }
                .compactMap { interactionIds[$0.first] }
            let numPendingDownloadsWithJobs: Int = try Job
                .filter(remainingPendingDownloadIds.contains(Job.Columns.interactionId))
                .fetchCount(db)
            
            return (attachmentIdsToMarkAsFailed.count, attachmentInfo, numPendingDownloadsWithJobs)
        }
        try Task.checkCancellation()
        
        let states: [Attachment.State: Int] = attachmentInfo.reduce(into: [:]) { result, next in
            result[next.second, default: 0] += 1
        }
        let stateString: String = "failedDownload: \(states[.failedDownload] ?? -1), pendingDownload: \(states[.pendingDownload] ?? 0), downloading: \(states[.downloading] ?? 0), failedUpload: \(states[.failedUpload] ?? 0), uploading: \(states[.uploading] ?? 0)"
        
        Log.info(.cat, "Marked \(changeCount) attachments as failed, left \(numPendingDownloadsWithJobs) pending downloads due to existing jobs (incomplete states before change - \(stateString))")

        /// Finally, recover any attachments which claim to be `downloaded`/`uploaded` but whose file is missing from
        /// disk (eg. removed by the OS to reclaim space, garbage collection, or a failed file move during upload). Without
        /// this such an attachment would render as broken indefinitely as nothing else re-triggers its download
        try await reDownloadAttachmentsWithMissingFiles(using: dependencies)

        return .success
    }

    /// Finds attachments in a `downloaded`/`uploaded` state whose file is no longer present on disk and enqueues an
    /// `AttachmentDownloadJob` for each (the download job's own logic will re-download the file, or transition the
    /// attachment to a failed state if it genuinely can't be recovered)
    private static func reDownloadAttachmentsWithMissingFiles(using dependencies: Dependencies) async throws {
        /// Files are pruned from the server after `defaultExpirationDuration`, so there's no point trying to re-download an
        /// attachment old enough that its file has likely already expired (it'd just 404 and get marked invalid). Restricting
        /// to recent attachments also keeps this query bounded so it doesn't add meaningful time to this blocking startup job
        let earliestNonExpiredTimestamp: TimeInterval = (
            dependencies.dateNow.timeIntervalSince1970 - Network.FileServer.defaultExpirationDuration
        )
        let downloadedAttachments: [FetchablePair<String, String>] = try await dependencies[singleton: .storage].read { db in
            try Attachment
                .select(.id, .downloadUrl)
                .filter(
                    Attachment.Columns.state == Attachment.State.downloaded ||
                    Attachment.Columns.state == Attachment.State.uploaded
                )
                .filter(Attachment.Columns.downloadUrl != nil)
                .filter(Attachment.Columns.creationTimestamp > earliestNonExpiredTimestamp)
                .asRequest(of: FetchablePair<String, String>.self)
                .fetchAll(db)
        }

        guard !downloadedAttachments.isEmpty else { return }

        /// Determine which of these no longer have a file on disk (checked outside of a database transaction as it
        /// touches the file system)
        let attachmentManager = dependencies[singleton: .attachmentManager]
        let fileManager = dependencies[singleton: .fileManager]
        let idsWithMissingFiles: Set<String> = Set(downloadedAttachments.compactMap { info in
            guard
                let path: String = try? attachmentManager.path(for: info.second),
                !fileManager.fileExists(atPath: path)
            else { return nil }

            return info.first
        })

        guard !idsWithMissingFiles.isEmpty else { return }

        try await dependencies[singleton: .storage].write { db in
            /// Resolve the `interactionId`/`threadId` values needed to create the download jobs
            let interactionAttachments: [InteractionAttachment] = try InteractionAttachment
                .filter(idsWithMissingFiles.contains(InteractionAttachment.Columns.attachmentId))
                .fetchAll(db)
            let threadIdForInteraction: [Int64: String] = try Interaction
                .select(.id, .threadId)
                .filter(Set(interactionAttachments.map { $0.interactionId }).contains(Interaction.Columns.id))
                .asRequest(of: FetchablePair<Int64, String>.self)
                .fetchAll(db)
                .reduce(into: [:]) { result, next in result[next.first] = next.second }

            var enqueuedCount: Int = 0

            for interactionAttachment in interactionAttachments {
                guard let threadId: String = threadIdForInteraction[interactionAttachment.interactionId] else {
                    continue
                }

                dependencies[singleton: .jobRunner].add(
                    db,
                    job: Job(
                        variant: .attachmentDownload,
                        threadId: threadId,
                        interactionId: interactionAttachment.interactionId,
                        details: AttachmentDownloadJob.Details(attachmentId: interactionAttachment.attachmentId)
                    )
                )
                enqueuedCount += 1
            }

            if enqueuedCount > 0 {
                Log.info(.cat, "Re-enqueued \(enqueuedCount) attachment download(s) for files missing on disk")
            }
        }
    }
}
