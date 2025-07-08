// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit

/// This migration updates the tiemstamps added to the `Profile` in earlier migrations to be nullable (having it not null
/// results in migration issues when a user jumps between multiple versions)
enum _016_MakeBrokenProfileTimestampsNullable: Migration {
    static let target: TargetMigrations.Identifier = .messagingKit
    static let identifier: String = "MakeBrokenProfileTimestampsNullable"
    static let minExpectedRunDuration: TimeInterval = 0.1
    static let createdTables: [(TableRecord & FetchableRecord).Type] = []
    
    static func migrate(_ db: ObservingDatabase, using dependencies: Dependencies) throws {
        try db.create(table: "tmpProfile") { t in
            t.column("id", .text)
                .notNull()
                .primaryKey()
            t.column("name", .text).notNull()
            t.column("nickname", .text)
            t.column("profilePictureUrl", .text)
            t.column("profilePictureFileName", .text)
            t.column("profileEncryptionKey", .blob)
            t.column("lastNameUpdate", .integer).defaults(to: 0)
            t.column("lastProfilePictureUpdate", .integer).defaults(to: 0)
            t.column("blocksCommunityMessageRequests", .boolean)
            t.column("lastBlocksCommunityMessageRequests", .integer).defaults(to: 0)
        }
        
        // Insert into the new table, drop the old table and rename the new table to be the old one
        try db.execute(sql: """
            INSERT INTO tmpProfile
            SELECT profile.*
            FROM profile
        """)
        
        try db.drop(table: "profile")
        try db.rename(table: "tmpProfile", to: "profile")
        
        MigrationExecution.updateProgress(1)
    }
}
