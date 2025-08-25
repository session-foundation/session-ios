// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit

/// This migration sets up the standard jobs, since we want these jobs to run before any "once-off" jobs we do this migration
/// before running the `YDBToGRDBMigration`
enum _002_SUK_SetupStandardJobs: Migration {
    static let identifier: String = "utilitiesKit.SetupStandardJobs"
    static let minExpectedRunDuration: TimeInterval = 0.1
    static let createdTables: [(TableRecord & FetchableRecord).Type] = []
    
    static func migrate(_ db: ObservingDatabase, using dependencies: Dependencies) throws {
        /// This job exists in the 'Session' target but that doesn't have it's own migrations
        ///
        /// **Note:** We actually need this job to run both onLaunch and onActive as the logic differs slightly and there are cases
        /// where a user might not be registered in 'onLaunch' but is in 'onActive' (see the `SyncPushTokensJob` for more info)
        try db.execute(sql: """
            INSERT INTO job (variant, behaviour, shouldSkipLaunchBecomeActive)
            VALUES
                (
                    \(Job.Variant.syncPushTokens.rawValue),
                    \(Job.Behaviour.recurringOnLaunch.rawValue),
                    false
                ),
                (
                    \(Job.Variant.syncPushTokens.rawValue),
                    \(Job.Behaviour.recurringOnActive.rawValue),
                    true
                )
        """)
        
        MigrationExecution.updateProgress(1)
    }
}
