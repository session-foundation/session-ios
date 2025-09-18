// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit

enum _044_AddProMessageFlag: Migration {
    static let identifier: String = "messagingKit.AddProMessageFlag"
    static let minExpectedRunDuration: TimeInterval = 0.1
    static var createdTables: [(FetchableRecord & TableRecord).Type] = []
    
    static func migrate(_ db: ObservingDatabase, using dependencies: Dependencies) throws {
        try db.alter(table: "interaction") { t in
            t.add(column: "isProMessage", .boolean).defaults(to: false)
        }
        
        MigrationExecution.updateProgress(1)
    }
}
