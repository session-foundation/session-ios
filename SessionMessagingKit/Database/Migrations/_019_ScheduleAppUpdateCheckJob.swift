// Copyright © 2024 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit

enum _019_ScheduleAppUpdateCheckJob: Migration {
    static let target: TargetMigrations.Identifier = .messagingKit
    static let identifier: String = "ScheduleAppUpdateCheckJob"
    static let minExpectedRunDuration: TimeInterval = 0.1
    static let createdTables: [(TableRecord & FetchableRecord).Type] = []
    
    static func migrate(_ db: ObservingDatabase, using dependencies: Dependencies) throws {
        /// Only insert jobs if the `jobs` table exists or we aren't running tests (when running tests this allows us to skip running the
        /// SNUtilitiesKit migrations)
        guard
            !SNUtilitiesKit.isRunningTests ||
            ((try? db.tableExists("job")) == true)
        else { return MigrationExecution.updateProgress(1) }
        
        try db.execute(sql: """
            INSERT INTO job (variant, behaviour)
            VALUES (\(Job.Variant.checkForAppUpdates.rawValue), \(Job.Behaviour.recurring.rawValue))
        """)
        
        MigrationExecution.updateProgress(1)
    }
}
