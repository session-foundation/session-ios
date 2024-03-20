// Copyright © 2024 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit

/// This migration drops the current `SnodePool` and `SnodeSet` and replaces their strucutres with the updated
/// data requiremets to support sending libQuic requests
enum _006_SnodePoolLibQuicSupport: Migration {
    static let target: TargetMigrations.Identifier = .snodeKit
    static let identifier: String = "SnodePoolLibQuicSupport" // stringlint:disable
    static let needsConfigSync: Bool = false
    static let minExpectedRunDuration: TimeInterval = 0.1
    static let fetchedTables: [(TableRecord & FetchableRecord).Type] = [Snode.self]
    static let createdOrAlteredTables: [(TableRecord & FetchableRecord).Type] = [Snode.self]
    
    static func migrate(_ db: Database) throws {
        try db.drop(table: Snode.self)
        try db.drop(table: SnodeSet.self)
        
        try db.create(table: Snode.self) { t in
            t.column(.ip, .text).notNull()
            t.column(.lmqPort, .integer).notNull()
            t.column(.ed25519PublicKey, .text).notNull()
            
            t.primaryKey([.ip, .lmqPort])
        }
        
        try db.create(table: SnodeSet.self) { t in
            t.column(.key, .text).notNull()
            t.column(.nodeIndex, .integer).notNull()
            t.column(.ip, .text).notNull()
            t.column(.lmqPort, .integer).notNull()
            
            t.foreignKey(
                [.ip, .lmqPort],
                references: Snode.self,
                columns: [.ip, .lmqPort],
                onDelete: .cascade                                    // Delete if Snode deleted
            )
            t.primaryKey([.key, .nodeIndex])
        }
        
        Storage.update(progress: 1, for: self, in: target)
    }
}
