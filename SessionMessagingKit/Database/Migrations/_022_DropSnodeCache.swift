// Copyright © 2024 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit

/// This migration drops the current `SnodePool` and `SnodeSet` and their associated jobs as they are handled by `libSession` now
enum _022_DropSnodeCache: Migration {
    static let identifier: String = "snodeKit.DropSnodeCache"
    static let minExpectedRunDuration: TimeInterval = 0.1
    static let createdTables: [(TableRecord & FetchableRecord).Type] = []
    
    static func migrate(_ db: ObservingDatabase, using dependencies: Dependencies) throws {
        try db.drop(table: "snode")
        try db.drop(table: "snodeSet")
        
        // Drop the old snode cache jobs as well
        let variantsToDelete: String = [
            Job.Variant._legacy_getSnodePool,
            Job.Variant._legacy_buildPaths,
            Job.Variant._legacy_getSwarm
        ].map { "\($0.rawValue)" }.joined(separator: ", ")
        try db.execute(sql: "DELETE FROM job WHERE variant IN (\(variantsToDelete))")
        
        MigrationExecution.updateProgress(1)
    }
}
