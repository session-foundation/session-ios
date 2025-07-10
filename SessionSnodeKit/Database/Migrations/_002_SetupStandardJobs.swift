// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit

/// This migration sets up the standard jobs, since we want these jobs to run before any "once-off" jobs we do this migration
/// before running the `YDBToGRDBMigration`
enum _002_SetupStandardJobs: Migration {
    static let target: TargetMigrations.Identifier = .snodeKit
    static let identifier: String = "SetupStandardJobs"
    static let minExpectedRunDuration: TimeInterval = 0.1
    static let createdTables: [(TableRecord & FetchableRecord).Type] = []
    
    static func migrate(_ db: ObservingDatabase, using dependencies: Dependencies) throws {
        /// Only insert jobs if the `jobs` table exists or we aren't running tests (when running tests this allows us to skip running the
        /// SNUtilitiesKit migrations)
        guard
            !SNUtilitiesKit.isRunningTests ||
            ((try? db.tableExists("job")) == true)
        else { return MigrationExecution.updateProgress(1) }
        
        // Note: We also want this job to run both onLaunch and onActive as we want it to block
        // 'onLaunch' and 'onActive' doesn't support blocking jobs
        try db.execute(sql: """
            INSERT INTO job (variant, behaviour, shouldBlock, shouldSkipLaunchBecomeActive)
            VALUES
                (
                    \(Job.Variant._legacy_getSnodePool.rawValue),
                    \(Job.Behaviour.recurringOnLaunch.rawValue),
                    true,
                    false
                ),
                (
                    \(Job.Variant._legacy_getSnodePool.rawValue),
                    \(Job.Behaviour.recurringOnActive.rawValue),
                    false,
                    true
                )
        """)
        
        MigrationExecution.updateProgress(1)
    }
}
