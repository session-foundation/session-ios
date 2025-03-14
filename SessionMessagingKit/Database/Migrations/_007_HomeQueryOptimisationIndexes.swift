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
    static let createdTables: [(TableRecord & FetchableRecord).Type] = []
    
    static func migrate(_ db: Database, using dependencies: Dependencies) throws {
        try db.create(
            indexOn: "interaction",
            columns: ["wasRead", "hasMention", "threadId"]
        )
        try db.create(
            indexOn: "interaction",
            columns: ["threadId", "timestampMs", "variant"]
        )
        
        Storage.update(progress: 1, for: self, in: target, using: dependencies)
    }
}
