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
    
    static func migrate(_ db: Database, using dependencies: Dependencies) throws {
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
        
        Storage.update(progress: 1, for: self, in: target, using: dependencies)
    }
}
