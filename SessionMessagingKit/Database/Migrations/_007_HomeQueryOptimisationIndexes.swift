// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import GRDB
import SessionUtilitiesKit

/// This migration adds an index to the interaction table in order to improve the performance of retrieving the number of unread interactions
enum _007_HomeQueryOptimisationIndexes: Migration {
    static let target: TargetMigrations.Identifier = .messagingKit
    static let identifier: String = "HomeQueryOptimisationIndexes"
    static let minExpectedRunDuration: TimeInterval = 0.01
    static let fetchedTables: [(TableRecord & FetchableRecord).Type] = []
    static let createdOrAlteredTables: [(TableRecord & FetchableRecord).Type] = []
    static let droppedTables: [(TableRecord & FetchableRecord).Type] = []
    
    static func migrate(_ db: Database, using dependencies: Dependencies) throws {
        try db.create(
            index: "interaction_on_wasRead_and_hasMention_and_threadId",
            on: "interaction",
            columns: [
                "wasRead",
                "hasMention",
                "threadId"
            ]
        )
        
        try db.create(
            index: "interaction_on_threadId_and_timestampMs_and_variant",
            on: "interaction",
            columns: [
                "threadId",
                "timestampMs",
                "variant"
            ]
        )
        
        Storage.update(progress: 1, for: self, in: target, using: dependencies)
    }
}
