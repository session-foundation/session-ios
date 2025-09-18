// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit

enum _018_OpenGroupPermission: Migration {
    static let identifier: String = "messagingKit.OpenGroupPermission"
    static let minExpectedRunDuration: TimeInterval = 0.01
    static let createdTables: [(TableRecord & FetchableRecord).Type] = []
    
    static func migrate(_ db: ObservingDatabase, using dependencies: Dependencies) throws {
        try db.alter(table: "openGroup") { t in
            t.add(column: "permissions", .integer)
                .defaults(to: OpenGroup.Permissions.all)
        }
        
        // When modifying OpenGroup behaviours we should always look to reset the `infoUpdates`
        // value for all OpenGroups to ensure they all have the correct state for newly
        // added/changed fields
        try db.execute(sql: "UPDATE openGroup SET infoUpdates = 0")
        
        MigrationExecution.updateProgress(1)
    }
}
