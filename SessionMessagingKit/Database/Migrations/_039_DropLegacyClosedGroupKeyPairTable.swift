// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit

/// Legacy closed groups are no longer supported so we can drop the `closedGroupKeyPair` table from
/// the database
enum _039_DropLegacyClosedGroupKeyPairTable: Migration {
    static let identifier: String = "messagingKit.DropLegacyClosedGroupKeyPairTable"
    static let minExpectedRunDuration: TimeInterval = 0.1
    static var createdTables: [(FetchableRecord & TableRecord).Type] = []
    
    static func migrate(_ db: ObservingDatabase, using dependencies: Dependencies) throws {
        try db.drop(table: "closedGroupKeyPair")
        
        MigrationExecution.updateProgress(1)
    }
}

