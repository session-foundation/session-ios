// Copyright © 2026 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import GRDB
import SessionNetworkingKit
import SessionUtilitiesKit

/// Recovers community (SOGS) attachments which failed to download because they were sent with a legacy room-less
/// download url (`<server>/file/<id>`) that our (post `2.15.0`) url parser can't handle.
///
/// Such attachments would be stuck in a failed/invalid state with no way to recover automatically. This migration
/// normalises their url to the canonical `<server>/room/<room>/file/<id>` form, resets them to `pendingDownload`
/// and enqueues a fresh download for each so they recover without the user needing to do anything.
///
/// **Note:** Attachments whose url is already valid are left untouched (`normalizedDownloadUrlString` returns them
/// unchanged), so this only affects attachments actually broken by the room-less url issue.
enum _052_RecoverBrokenCommunityAttachments: Migration {
    static let identifier: String = "RecoverBrokenCommunityAttachments"
    static let minExpectedRunDuration: TimeInterval = 0.1
    static let createdTables: [(FetchableRecord & TableRecord).Type] = []

    static func migrate(_ db: ObservingDatabase, using dependencies: Dependencies) throws {
        /// Files are pruned from the server after `defaultExpirationDuration`, so there's no point trying to recover an
        /// attachment whose file has likely already expired (it'd just 404). We gate on the message timestamp rather than
        /// the attachment's `creationTimestamp` because received attachments that never downloaded have a `nil`
        /// `creationTimestamp`, whereas the message timestamp reflects roughly when the file was uploaded
        let earliestNonExpiredTimestampMs: Int64 = Int64(
            (dependencies.dateNow.timeIntervalSince1970 - Network.FileServer.defaultExpirationDuration) * 1000
        )

        /// Fetch community attachments which haven't successfully downloaded/uploaded, along with the `server`/`roomToken`
        /// needed to rebuild their download url
        let rows: [Row] = try Row.fetchAll(db, sql: """
            SELECT
                attachment.id AS id,
                attachment.downloadUrl AS downloadUrl,
                interactionAttachment.interactionId AS interactionId,
                interaction.threadId AS threadId,
                openGroup.server AS server,
                openGroup.roomToken AS roomToken
            FROM attachment
            JOIN interactionAttachment ON interactionAttachment.attachmentId = attachment.id
            JOIN interaction ON interaction.id = interactionAttachment.interactionId
            JOIN openGroup ON openGroup.threadId = interaction.threadId
            WHERE attachment.downloadUrl IS NOT NULL
                AND attachment.state != \(Attachment.State.downloaded.rawValue)
                AND attachment.state != \(Attachment.State.uploaded.rawValue)
                AND interaction.timestampMs > \(earliestNonExpiredTimestampMs)
        """)

        var recoveredCount: Int = 0

        for row in rows {
            guard
                let id: String = row["id"],
                let downloadUrl: String = row["downloadUrl"],
                let interactionId: Int64 = row["interactionId"],
                let threadId: String = row["threadId"],
                let server: String = row["server"],
                let roomToken: String = row["roomToken"]
            else { continue }

            /// Only recover attachments whose url actually needed normalising (ie. the room-less legacy form) - a url which
            /// is already valid is returned unchanged and left alone
            let normalizedUrl: String = Network.SOGS.normalizedDownloadUrlString(
                for: downloadUrl,
                server: server,
                roomToken: roomToken
            )

            guard normalizedUrl != downloadUrl else { continue }

            /// Update the url and reset the attachment so it will be downloaded again
            try db.execute(
                sql: """
                    UPDATE attachment
                    SET downloadUrl = ?, state = ?, isValid = false
                    WHERE id = ?
                """,
                arguments: [normalizedUrl, Attachment.State.pendingDownload.rawValue, id]
            )

            /// Enqueue a fresh download job (persisted here and picked up when the JobRunner starts after migrations complete)
            if let job: Job = Job(
                variant: .attachmentDownload,
                threadId: threadId,
                interactionId: interactionId,
                details: AttachmentDownloadJob.Details(attachmentId: id)
            ) {
                _ = try job.inserted(db)
            }

            recoveredCount += 1
        }

        Log.info(.migration, "Recovered \(recoveredCount) community attachment(s) with legacy download urls")

        MigrationExecution.updateProgress(1)
    }
}
