// Copyright © 2026 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit

enum _051_AddUniqueJobConstraintBack: Migration {
    static let identifier: String = "AddUniqueJobConstraintBack"
    static let minExpectedRunDuration: TimeInterval = 0.1
    static var createdTables: [(FetchableRecord & TableRecord).Type] = []
    
    static func migrate(_ db: ObservingDatabase, using dependencies: Dependencies) throws {
        /// Fetch all existing `displayPictureDownload` jobs
        let rows: [Row] = try Row.fetchAll(db, sql: """
            SELECT id, details
            FROM job
            WHERE variant = \(Job.Variant.displayPictureDownload.rawValue)
            ORDER BY id ASC
        """)
        
        /// Compute the hash for each job
        var jobIdToHash: [(id: Int64, hash: Int)] = []
        var seenHashes: Set<Int> = []
        var duplicateIds: [Int64] = []

        for row in rows {
            guard
                let id: Int64 = row["id"] as? Int64,
                let detailsData: Data = row["details"] as? Data,
                let json = try? JSONSerialization.jsonObject(with: detailsData) as? [String: Any],
                let target = json["target"] as? [String: Any]
            else { continue }

            /// Extract the unique key from whichever target type is present, matching the "\(id)-\(url)" pattern used at the call site
            let uniqueKey: String? = {
                if
                    let profile = target["profile"] as? [String: Any],
                    let profileId = profile["id"] as? String,
                    let url = profile["url"] as? String
                { return "\(profileId)-\(url)" }

                if
                    let group = target["group"] as? [String: Any],
                    let groupId = group["id"] as? String,
                    let url = group["url"] as? String
                { return "\(groupId)-\(url)" }

                if
                    let community = target["community"] as? [String: Any],
                    let roomToken = community["roomToken"] as? String,
                    let server = community["server"] as? String,
                    let url = community["url"] as? String
                { return "\(_051_AddUniqueJobConstraintBack.communityIdFor(roomToken: roomToken, server: server))-\(url)" }

                return nil
            }()

            guard let key: String = uniqueKey else { continue }

            let hash: Int = Job.computeUniqueHash(variant: .displayPictureDownload, key: key)

            if seenHashes.contains(hash) {
                duplicateIds.append(id)
            }
            else {
                seenHashes.insert(hash)
                jobIdToHash.append((id: id, hash: hash))
            }
        }
        
        /// Delete duplicates (keeping the oldest job per unique key)
        if !duplicateIds.isEmpty {
            try db.execute(sql: """
                DELETE FROM job
                WHERE id IN (\(duplicateIds.map { "\($0)" }.joined(separator: ",")))
            """)
        }
        
        /// Add the new `UNIQUE` column
        try db.alter(table: "job") { t in
            t.add(column: "uniqueHashValue", .integer)
        }
        
        /// Backfill uniqueHashValue for surviving jobs
        for (id, hash) in jobIdToHash {
            try db.execute(
                sql: "UPDATE job SET uniqueHashValue = ? WHERE id = ?",
                arguments: [hash, id]
            )
        }
        
        /// Add the unique constraint for `uniqueHashValue`( IS NOT NULL mirrors SQLite's built-in behaviour of treating NULLs
        /// as distinct, but makes it explicit and slightly more efficient)
        try db.execute(sql: """
            CREATE UNIQUE INDEX job_on_uniqueHashValue
            ON job (uniqueHashValue)
            WHERE uniqueHashValue IS NOT NULL
        """)
        
        MigrationExecution.updateProgress(1)
    }
}

private extension _051_AddUniqueJobConstraintBack {
    static func communityIdFor(roomToken: String, server: String) -> String {
        // Always force the server to lowercase
        return "\(server.lowercased()).\(roomToken)"
    }
}
