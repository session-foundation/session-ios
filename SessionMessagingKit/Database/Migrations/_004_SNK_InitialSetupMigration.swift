// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import GRDB
import SessionUtilitiesKit

enum _004_SNK_InitialSetupMigration: Migration {
    static let identifier: String = "snodeKit.initialSetup"
    static let minExpectedRunDuration: TimeInterval = 0.1
    static let createdTables: [(TableRecord & FetchableRecord).Type] = []
    
    static func migrate(_ db: ObservingDatabase, using dependencies: Dependencies) throws {
        try db.create(table: "snode") { t in
            t.column("public_ip", .text)
            t.column("storage_port", .integer)
            t.column("ed25519PublicKey", .text)
            t.column("pubkey_x25519", .text)
        }
        
        try db.create(table: "snodeSet") { t in
            t.column("key", .text)
            t.column("nodeIndex", .integer)
            t.column("address", .text)
            t.column("port", .integer)
        }
        
        try db.create(table: "snodeReceivedMessageInfo") { t in
            t.column("id", .integer)
                .notNull()
                .primaryKey(autoincrement: true)
            t.column("key", .text)
                .notNull()
                .indexed()                                            // Quicker querying
            t.column("hash", .text)
                .notNull()
                .indexed()                                            // Quicker querying
            t.column("expirationDateMs", .integer)
                .notNull()
                .indexed()                                            // Quicker querying
            
            t.uniqueKey(["key", "hash"])
        }
        
        MigrationExecution.updateProgress(1)
    }
}
