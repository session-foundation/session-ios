// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit

/// This migration adds a primary key to `SnodeReceivedMessageInfo` based on the key and hash to speed up lookup
enum _005_AddSnodeReveivedMessageInfoPrimaryKey: Migration {
    static let target: TargetMigrations.Identifier = .snodeKit
    static let identifier: String = "AddSnodeReveivedMessageInfoPrimaryKey"
    static let minExpectedRunDuration: TimeInterval = 0.2
    static let createdTables: [(TableRecord & FetchableRecord).Type] = [SnodeReceivedMessageInfo.self]
    
    static func migrate(_ db: ObservingDatabase, using dependencies: Dependencies) throws {
        // SQLite doesn't support adding a new primary key after creation so we need to create a new table with
        // the setup we want, copy data from the old table over, drop the old table and rename the new table
        try db.create(table: "tmpSnodeReceivedMessageInfo") { t in
            t.column("key", .text).notNull()
            t.column("hash", .text).notNull()
            t.column("expirationDateMs", .integer).notNull()
            t.column("wasDeletedOrInvalid", .boolean)
            
            t.primaryKey(["key", "hash"])
        }
        
        // Insert into the new table, drop the old table and rename the new table to be the old one
        try db.execute(literal: """
            INSERT INTO tmpSnodeReceivedMessageInfo
            SELECT key, hash, expirationDateMs, wasDeletedOrInvalid
            FROM snodeReceivedMessageInfo
        """)
        
        try db.drop(table: "snodeReceivedMessageInfo")
        try db.rename(table: "tmpSnodeReceivedMessageInfo", to: "snodeReceivedMessageInfo")
        
        // Need to create the indexes separately from creating 'TmpSnodeReceivedMessageInfo' to
        // ensure they have the correct names
        try db.create(indexOn: "snodeReceivedMessageInfo", columns: ["key"])
        try db.create(indexOn: "snodeReceivedMessageInfo", columns: ["hash"])
        try db.create(indexOn: "snodeReceivedMessageInfo", columns: ["expirationDateMs"])
        try db.create(indexOn: "snodeReceivedMessageInfo", columns: ["wasDeletedOrInvalid"])
        
        MigrationExecution.updateProgress(1)
    }
}
