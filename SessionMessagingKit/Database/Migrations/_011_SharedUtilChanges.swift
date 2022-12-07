// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtil
import SessionUtilitiesKit

/// This migration recreates the interaction FTS table and adds the threadId so we can do a performant in-conversation
/// searh (currently it's much slower than the global search)
enum _011_SharedUtilChanges: Migration {
    static let target: TargetMigrations.Identifier = .messagingKit
    static let identifier: String = "SharedUtilChanges"
    static let needsConfigSync: Bool = true
    static let minExpectedRunDuration: TimeInterval = 0.1
    
    static func migrate(_ db: Database) throws {
        try db.create(table: ConfigDump.self) { t in
            t.column(.variant, .text)
                .notNull()
                .primaryKey()
            t.column(.data, .blob)
                .notNull()
        }
        
        // If we don't have an ed25519 key then no need to create cached dump data
        guard let secretKey: [UInt8] = Identity.fetchUserEd25519KeyPair(db)?.secretKey else {
            Storage.update(progress: 1, for: self, in: target) // In case this is the last migration
            return
        }
        
        // Create a dump for the user profile data
        let userProfileConf: UnsafeMutablePointer<config_object>? = try SessionUtil.loadState(
            for: .userProfile,
            secretKey: secretKey,
            cachedData: nil
        )
        let confResult: SessionUtil.ConfResult = try SessionUtil.update(
            profile: Profile.fetchOrCreateCurrentUser(db),
            in: .custom(conf: Atomic(userProfileConf))
        )
        
        if confResult.needsDump {
            try SessionUtil.saveState(db, conf: userProfileConf, for: .userProfile)
        }
        
        Storage.update(progress: 1, for: self, in: target) // In case this is the last migration
    }
}
