// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit

enum _003_SUK_YDBToGRDBMigration: Migration {
    static let identifier: String = "utilitiesKit.YDBToGRDBMigration"
    static let minExpectedRunDuration: TimeInterval = 0.1
    static let createdTables: [(TableRecord & FetchableRecord).Type] = []
    
    static func migrate(_ db: ObservingDatabase, using dependencies: Dependencies) throws {
        MigrationExecution.updateProgress(1)
    }
}
