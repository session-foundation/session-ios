// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit

enum _037_GroupsExpiredFlag: Migration {
    static let identifier: String = "messagingKit.GroupsExpiredFlag"
    static let minExpectedRunDuration: TimeInterval = 0.1
    static var createdTables: [(FetchableRecord & TableRecord).Type] = []
    
    static func migrate(_ db: ObservingDatabase, using dependencies: Dependencies) throws {
        try db.alter(table: "closedGroup") { t in
            t.add(column: "expired", .boolean).defaults(to: false)
        }
        
        MigrationExecution.updateProgress(1)
    }
}

