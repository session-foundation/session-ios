// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit

/// This migration adds a flag indicating whether a profile has indicated it is blocking community message requests
enum _015_BlockCommunityMessageRequests: Migration {
    static let target: TargetMigrations.Identifier = .messagingKit
    static let identifier: String = "BlockCommunityMessageRequests"
    static let minExpectedRunDuration: TimeInterval = 0.01
    static let createdTables: [(TableRecord & FetchableRecord).Type] = []
    
    static func migrate(_ db: ObservingDatabase, using dependencies: Dependencies) throws {
        // Add the new 'Profile' properties
        try db.alter(table: "profile") { t in
            t.add(column: "blocksCommunityMessageRequests", .boolean)
            t.add(column: "lastBlocksCommunityMessageRequests", .integer).defaults(to: 0)
        }
        
        // If the user exists and the 'checkForCommunityMessageRequests' hasn't already been set then default it to "false"
        if
            MigrationHelper.userExists(db),
            let numSettings: Int = try? Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM setting WHERE key == 'checkForCommunityMessageRequests'"
            ),
            numSettings == 0,
            let userEd25519SecretKey: Data = MigrationHelper.fetchIdentityValue(db, key: "ed25519SecretKey")
        {
            let userSessionId: SessionId = MigrationHelper.userSessionId(db)
            let cache: LibSession.Cache = LibSession.Cache(userSessionId: userSessionId, using: dependencies)
            let configDump: Data? = try? Data.fetchOne(
                db,
                sql: """
                    SELECT data
                    FROM configDump
                    WHERE (
                        variant = 'userProfile' AND
                        publicKey = ?
                    )
                """,
                arguments: [userSessionId.hexString]
            )
            try cache.loadState(
                for: .userProfile,
                sessionId: userSessionId,
                userEd25519SecretKey: Array(userEd25519SecretKey),
                groupEd25519SecretKey: nil,
                cachedData: configDump
            )
            
            // Use the value in the config if we happen to have one, otherwise use the default
            try db.execute(sql: """
                DELETE FROM setting
                WHERE key = 'checkForCommunityMessageRequests'
            """)
            
            var targetValue: Bool = (!cache.has(.checkForCommunityMessageRequests) ?
                true :
                cache.get(.checkForCommunityMessageRequests)
            )
            let boolAsData: Data = withUnsafeBytes(of: &targetValue) { Data($0) }
            try db.execute(
                sql: """
                    INSERT INTO setting (key, value)
                    VALUES ('checkForCommunityMessageRequests', ?)
                """,
                arguments: [boolAsData]
            )
        }
        
        MigrationExecution.updateProgress(1)
    }
}
