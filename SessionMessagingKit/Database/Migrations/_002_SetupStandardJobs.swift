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
    static let fetchedTables: [(TableRecord & FetchableRecord).Type] = []
    static let createdOrAlteredTables: [(TableRecord & FetchableRecord).Type] = []
    static let droppedTables: [(TableRecord & FetchableRecord).Type] = []
    
    static func migrate(_ db: Database, using dependencies: Dependencies) throws {
        // Start by adding the jobs that don't have collections (in the jobs like these
        // will be added via migrations)
        let jobInfo: [(variant: Job.Variant, behaviour: Job.Behaviour, shouldBlock: Bool)] = [
            (.disappearingMessages, .recurringOnLaunch, true),
            (.failedMessageSends, .recurringOnLaunch, true),
            (.failedAttachmentDownloads, .recurringOnLaunch, true),
            (.updateProfilePicture, .recurringOnActive, false),
            (.retrieveDefaultOpenGroupRooms, .recurringOnActive, false),
            (.garbageCollection, .recurringOnActive, false)
        ]
        
        try jobInfo.forEach { variant, behaviour, shouldBlock in
            try db.execute(
                sql: """
                    INSERT INTO job VALUES (?, ?, ?)
                """,
                arguments: [variant.rawValue, behaviour.rawValue, shouldBlock]
            )
        }
        
        Storage.update(progress: 1, for: self, in: target, using: dependencies)
    }
}
