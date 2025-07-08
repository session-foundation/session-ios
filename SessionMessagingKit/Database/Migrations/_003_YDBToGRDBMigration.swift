// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit

enum _003_YDBToGRDBMigration: Migration {
    static let target: TargetMigrations.Identifier = .messagingKit
    static let identifier: String = "YDBToGRDBMigration"
    static let minExpectedRunDuration: TimeInterval = 0.1
    static let createdTables: [(TableRecord & FetchableRecord).Type] = []
    
    static func migrate(_ db: ObservingDatabase, using dependencies: Dependencies) throws {
        guard
            !SNUtilitiesKit.isRunningTests,
            MigrationHelper.userExists(db)
        else { return MigrationExecution.updateProgress(1) }
        
        Log.error(.migration, "Attempted to perform legacy migation")
        throw StorageError.migrationNoLongerSupported
    }
}
