// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit

/// This migration recreates the interaction FTS table and adds the threadId so we can do a performant in-conversation
/// searh (currently it's much slower than the global search)
enum _011_SharedUtilChanges: Migration {
    static let target: TargetMigrations.Identifier = .messagingKit
    static let identifier: String = "SharedUtilChanges"
    static let needsConfigSync: Bool = false
    static let minExpectedRunDuration: TimeInterval = 0.1
    
    static func migrate(_ db: Database) throws {
        try db.create(table: ConfigDump.self) { t in
            t.column(.variant, .text)
                .notNull()
                .primaryKey()
            t.column(.data, .blob)
                .notNull()
        }
        
        // TODO: Create dumps for current data
        
        Storage.update(progress: 1, for: self, in: target) // In case this is the last migration
    }
}
