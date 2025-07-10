// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit

/// Legacy closed groups are no longer supported so we can drop the `closedGroupKeyPair` table from
/// the database
enum _025_DropLegacyClosedGroupKeyPairTable: Migration {
    static let target: TargetMigrations.Identifier = .messagingKit
    static let identifier: String = "DropLegacyClosedGroupKeyPairTable"
    static let minExpectedRunDuration: TimeInterval = 0.1
    static var createdTables: [(FetchableRecord & TableRecord).Type] = []
    
    static func migrate(_ db: ObservingDatabase, using dependencies: Dependencies) throws {
        try db.drop(table: "closedGroupKeyPair")
        
        MigrationExecution.updateProgress(1)
    }
}

