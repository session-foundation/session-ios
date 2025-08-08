// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit

enum _020_AddJobUniqueHash: Migration {
    static let identifier: String = "utilitiesKit.AddJobUniqueHash"
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
