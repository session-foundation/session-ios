// Copyright © 2026 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit

enum _050_AddEmptyPollTrackingForGroups: Migration {
    static let identifier: String = "AddEmptyPollTrackingForGroups"
    static let minExpectedRunDuration: TimeInterval = 0.1
    static var createdTables: [(FetchableRecord & TableRecord).Type] = []
    
    static func migrate(_ db: ObservingDatabase, using dependencies: Dependencies) throws {
        try db.alter(table: "closedGroup") { t in
            t.add(column: "numConsecutiveEmptyPolls", .integer).defaults(to: 0)
        }
        
        /// SQLite doesn't retroactively insert default values into columns so we need to add them now
        try db.execute(sql: """
            UPDATE closedGroup 
            SET numConsecutiveEmptyPolls = 0
        """)
        
        MigrationExecution.updateProgress(1)
    }
}
