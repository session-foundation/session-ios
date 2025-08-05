// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB

enum _004_AddJobPriority: Migration {
    static let target: TargetMigrations.Identifier = .utilitiesKit
    static let identifier: String = "AddJobPriority"
    static let minExpectedRunDuration: TimeInterval = 0.1
    static let createdTables: [(TableRecord & FetchableRecord).Type] = []
    
    static func migrate(_ db: ObservingDatabase, using dependencies: Dependencies) throws {
        // Add `priority` to the job table
        try db.alter(table: "job") { t in
            t.add(column: "priority", .integer).defaults(to: 0)
        }
        
        // Update the priorities for the below job types (want to ensure they run in the order
        // specified to avoid weird bugs)
        let variantPriorities: [Int: [Job.Variant]] = [
            7: [Job.Variant.disappearingMessages],
            6: [Job.Variant.failedMessageSends, Job.Variant.failedAttachmentDownloads],
            5: [Job.Variant._legacy_getSnodePool],
            4: [Job.Variant.syncPushTokens],
            3: [Job.Variant.retrieveDefaultOpenGroupRooms],
            2: [Job.Variant.updateProfilePicture],
            1: [Job.Variant.garbageCollection]
        ]
        
        try variantPriorities.forEach { priority, variants in
            try db.execute(sql: """
                UPDATE job
                SET priority = \(priority)
                WHERE variant IN (\(variants.map { "\($0.rawValue)" }.joined(separator: ", ")))
            """)
        }
        
        MigrationExecution.updateProgress(1)
    }
}
