// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit
import SessionSnodeKit

/// This migration sets up the standard jobs, since we want these jobs to run before any "once-off" jobs we do this migration
/// before running the `YDBToGRDBMigration`
enum _002_SetupStandardJobs: Migration {
    static let target: TargetMigrations.Identifier = .messagingKit
    static let identifier: String = "SetupStandardJobs"
    static let minExpectedRunDuration: TimeInterval = 0.1
    static let createdTables: [(TableRecord & FetchableRecord).Type] = []
    
    static func migrate(_ db: Database, using dependencies: Dependencies) throws {
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
        
        Storage.update(progress: 1, for: self, in: target, using: dependencies)
    }
}
