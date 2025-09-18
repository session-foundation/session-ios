// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit
import SessionNetworkingKit

/// This migration sets up the standard jobs, since we want these jobs to run before any "once-off" jobs we do this migration
/// before running the `YDBToGRDBMigration`
enum _007_SMK_SetupStandardJobs: Migration {
    static let identifier: String = "messagingKit.SetupStandardJobs"
    static let minExpectedRunDuration: TimeInterval = 0.1
    static let createdTables: [(TableRecord & FetchableRecord).Type] = []
    
    static func migrate(_ db: ObservingDatabase, using dependencies: Dependencies) throws {
        /// Only insert jobs if the `jobs` table exists or we aren't running tests (when running tests this allows us to skip running the
        /// SNUtilitiesKit migrations)
        guard
            !SNUtilitiesKit.isRunningTests ||
            ((try? db.tableExists("job")) == true)
        else { return MigrationExecution.updateProgress(1) }
        
        // Start by adding the jobs that don't have collections (in the jobs like these
        // will be added via migrations)
        try db.execute(sql: """
            INSERT INTO job (variant, behaviour, shouldBlock)
            VALUES
                (
                    \(Job.Variant.disappearingMessages.rawValue),
                    \(Job.Behaviour.recurringOnLaunch.rawValue),
                    true
                ),
                (
                    \(Job.Variant.failedMessageSends.rawValue),
                    \(Job.Behaviour.recurringOnLaunch.rawValue),
                    true
                ),
                (
                    \(Job.Variant.failedAttachmentDownloads.rawValue),
                    \(Job.Behaviour.recurringOnLaunch.rawValue),
                    true
                ),
                (
                    \(Job.Variant.updateProfilePicture.rawValue),
                    \(Job.Behaviour.recurringOnActive.rawValue),
                    false
                ),
                (
                    \(Job.Variant.retrieveDefaultOpenGroupRooms.rawValue),
                    \(Job.Behaviour.recurringOnActive.rawValue),
                    false
                ),
                (
                    \(Job.Variant.garbageCollection.rawValue),
                    \(Job.Behaviour.recurringOnActive.rawValue),
                    false
                )
        """)
        
        MigrationExecution.updateProgress(1)
    }
}
