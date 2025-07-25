// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB

enum _005_AddJobUniqueHash: Migration {
    static let target: TargetMigrations.Identifier = .utilitiesKit
    static let identifier: String = "AddJobUniqueHash"
    static let minExpectedRunDuration: TimeInterval = 0.1
    static let createdTables: [(TableRecord & FetchableRecord).Type] = []
    
    static func migrate(_ db: ObservingDatabase, using dependencies: Dependencies) throws {
        // Add `uniqueHashValue` to the job table
        try db.alter(table: "job") { t in
            t.add(column: "uniqueHashValue", .integer)
        }
        
        MigrationExecution.updateProgress(1)
    }
}
