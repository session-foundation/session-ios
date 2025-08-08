// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit

enum _030_AddProfileProProof: Migration {
    static let target: TargetMigrations.Identifier = .messagingKit
    static let identifier: String = "AddProfileProProof"
    static let minExpectedRunDuration: TimeInterval = 0.1
    static var createdTables: [(FetchableRecord & TableRecord).Type] = []
    
    static func migrate(_ db: ObservingDatabase, using dependencies: Dependencies) throws {
        try db.alter(table: "profile") { t in
            t.add(column: "sessionProProof", .text)
        }
        
        MigrationExecution.updateProgress(1)
    }
}
