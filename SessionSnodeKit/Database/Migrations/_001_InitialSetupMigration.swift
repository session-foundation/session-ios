// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit

enum _001_InitialSetupMigration: Migration {
    static let target: TargetMigrations.Identifier = .snodeKit
    static let identifier: String = "initialSetup" // stringlint:disable
    static let needsConfigSync: Bool = false
    static let minExpectedRunDuration: TimeInterval = 0.1
    static let fetchedTables: [(TableRecord & FetchableRecord).Type] = []
    static let createdOrAlteredTables: [(TableRecord & FetchableRecord).Type] = [
        Snode.self, SnodeSet.self, SnodeReceivedMessageInfo.self
    ]
    
    static func migrate(_ db: Database) throws {
        try db.create(table: Snode.self) { t in
            t.deprecatedColumn(name: "public_ip", .text)
            t.deprecatedColumn(name: "storage_port", .integer)
            t.column(.ed25519PublicKey, .text)
            t.deprecatedColumn(name: "pubkey_x25519", .text)
        }
        
        try db.create(table: SnodeSet.self) { t in
            t.column(.key, .text)
            t.column(.nodeIndex, .integer)
            t.deprecatedColumn(name: "address", .text)
            t.deprecatedColumn(name: "port", .integer)
        }
        
        try db.create(table: SnodeReceivedMessageInfo.self) { t in
            t.deprecatedColumn(name: "id", .integer)                  // stringlint:disable
                .notNull()
                .primaryKey(autoincrement: true)
            t.column(.key, .text)
                .notNull()
                .indexed()                                            // Quicker querying
            t.column(.hash, .text)
                .notNull()
                .indexed()                                            // Quicker querying
            t.column(.expirationDateMs, .integer)
                .notNull()
                .indexed()                                            // Quicker querying
            
            t.uniqueKey([.key, .hash])
        }
        
        Storage.update(progress: 1, for: self, in: target) // In case this is the last migration
    }
}
