// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import GRDB

/// Since we want to avoid using logic outside of the database during migrations wherever possible these functions provide funcitonality
/// shared across multiple migrations
public enum MigrationHelper {
    public static func userExists(_ db: ObservingDatabase) -> Bool {
        let numEdSecretKeys: Int? = try? Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM identity WHERE variant == 'ed25519SecretKey'"
        )
        
        return ((numEdSecretKeys ?? 0) > 0)
    }
    
    public static func userSessionId(_ db: ObservingDatabase) -> SessionId {
        let pubkey: Data? = fetchIdentityValue(db, key: "x25519PublicKey")
        
        return SessionId(.standard, publicKey: (pubkey.map { Array($0) } ?? []))
    }
    
    public static func fetchIdentityValue(_ db: ObservingDatabase, key: String) -> Data? {
        return try? Data.fetchOne(
            db,
            sql: "SELECT data FROM identity WHERE variant == ?",
            arguments: [key]
        )
    }
    
    public static func configDump(_ db: ObservingDatabase, for rawVariant: String) -> Data? {
        return try? Data.fetchOne(
            db,
            sql: "SELECT data FROM configDump WHERE variant == ?",
            arguments: [rawVariant]
        )
    }
}
