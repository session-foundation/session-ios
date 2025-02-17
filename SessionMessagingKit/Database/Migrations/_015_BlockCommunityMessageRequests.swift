// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit

/// This migration adds a flag indicating whether a profile has indicated it is blocking community message requests
enum _015_BlockCommunityMessageRequests: Migration {
    static let target: TargetMigrations.Identifier = .messagingKit
    static let identifier: String = "BlockCommunityMessageRequests"
    static let minExpectedRunDuration: TimeInterval = 0.01
    static var requirements: [MigrationRequirement] = [.sessionIdCached, .libSessionStateLoaded]
    static let fetchedTables: [(TableRecord & FetchableRecord).Type] = [
        Identity.self, Setting.self
    ]
    static let createdOrAlteredTables: [(TableRecord & FetchableRecord).Type] = [Profile.self]
    static let droppedTables: [(TableRecord & FetchableRecord).Type] = []
    
    static func migrate(_ db: Database, using dependencies: Dependencies) throws {
        // Add the new 'Profile' properties
        try db.alter(table: "profile") { t in
            t.add(column: "blocksCommunityMessageRequests", .boolean)
            t.add(column: "lastBlocksCommunityMessageRequests", .integer).defaults(to: 0)
        }
        
        // If the user exists and the 'checkForCommunityMessageRequests' hasn't already been set then default it to "false"
        if
            let numEdSecretKeys: Int = try? Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM identity WHERE variant == ?",
                arguments: [
                    Identity.Variant.ed25519SecretKey.rawValue
                ]
            ),
            numEdSecretKeys > 0,
            let numSettings: Int = try? Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM setting WHERE key == ?",
                arguments: [
                    Setting.BoolKey.checkForCommunityMessageRequests.rawValue
                ]
            ),
            numSettings == 0
        {
            let userSessionId: SessionId = SessionId(
                .standard,
                publicKey: Array((try? Data.fetchOne(
                    db,
                    sql: "SELECT data FROM identity WHERE variant == ?",
                    arguments: [Identity.Variant.x25519PublicKey.rawValue]
                )).defaulting(to: Data()))
            )
            let rawBlindedMessageRequestValue: Int32 = try dependencies.mutate(cache: .libSession) { cache in
                try LibSession.rawBlindedMessageRequestValue(
                    in: cache.config(for: .userProfile, sessionId: userSessionId)
                )
            }
            
            // Use the value in the config if we happen to have one, otherwise use the default
            try db.execute(sql: """
                DELETE FROM setting
                WHERE key = \(Setting.BoolKey.checkForCommunityMessageRequests.rawValue)
            """)
            
            var targetValue: Bool = (rawBlindedMessageRequestValue < 0 ?
                true :
                (rawBlindedMessageRequestValue > 0)
            )
            let boolAsData: Data = withUnsafeBytes(of: &targetValue) { Data($0) }
            try db.execute(
                sql: """
                    INSERT INTO setting (key, value)
                    VALUES (?, ?)
                    SET pinnedPriority = 1
                    WHERE isPinned = true
                """,
                arguments: [
                    Setting.BoolKey.checkForCommunityMessageRequests.rawValue,
                    boolAsData
                ]
            )
        }
        
        Storage.update(progress: 1, for: self, in: target, using: dependencies)
    }
}
