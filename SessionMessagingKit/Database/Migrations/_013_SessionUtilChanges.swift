// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import CryptoKit
import GRDB
import SessionUtil
import SessionUtilitiesKit

/// This migration makes the neccessary changes to support the updated user config syncing system
enum _013_SessionUtilChanges: Migration {
    static let target: TargetMigrations.Identifier = .messagingKit
    static let identifier: String = "SessionUtilChanges"
    static let minExpectedRunDuration: TimeInterval = 0.4
    static var requirements: [MigrationRequirement] = [.sessionIdCached]
    static let fetchedTables: [(TableRecord & FetchableRecord).Type] = [
        Identity.self, GroupMember.self, ClosedGroupKeyPair.self, SessionThread.self
    ]
    static let createdOrAlteredTables: [(TableRecord & FetchableRecord).Type] = [
        SessionThread.self, Profile.self, GroupMember.self, ClosedGroupKeyPair.self, ConfigDump.self
    ]
    static let droppedTables: [(TableRecord & FetchableRecord).Type] = []
    
    static func migrate(_ db: Database, using dependencies: Dependencies) throws {
        // Add `markedAsUnread` to the thread table
        try db.alter(table: "thread") { t in
            t.add(column: "markedAsUnread", .boolean)
            t.add(column: "pinnedPriority", .integer)
        }
        
        // Add `lastNameUpdate` and `lastProfilePictureUpdate` columns to the profile table
        try db.alter(table: "profile".self) { t in
            t.add(column: "lastNameUpdate", .integer).defaults(to: 0)
            t.add(column: "lastProfilePictureUpdate", .integer).defaults(to: 0)
        }
        
        try db.create(table: "tmpGroupMember") { t in
            // Note: Since we don't know whether this will be stored against a 'ClosedGroup' or
            // an 'OpenGroup' we add the foreign key constraint against the thread itself (which
            // shares the same 'id' as the 'groupId') so we can cascade delete automatically
            t.column("groupId", .text)
                .notNull()
                .references("thread", onDelete: .cascade)             // Delete if Thread deleted
            t.column("profileId", .text)
                .notNull()
            t.column("role", .integer).notNull()
            t.column("isHidden", .boolean)
                .notNull()
                .defaults(to: false)
            
            t.primaryKey(["groupId", "profileId", "role"])
        }
        
        // Retrieve the non-duplicate group member entries from the old table
        try db.execute(sql: """
            INSERT INTO tmpGroupMember (groupId, profileId, role, isHidden)
            SELECT groupId, profileId, role, MAX(isHidden) AS isHidden
            FROM groupMember
            GROUP BY groupId, profileId, role
        """)
        
        // Insert into the new table, drop the old table and rename the new table to be the old one
        try db.drop(table: "groupMember")
        try db.rename(table: "tmpGroupMember", to: "groupMember")
        
        // Need to create the indexes separately from creating 'tmpGroupMember' to ensure they
        // have the correct names
        try db.create(index: "groupMember_on_groupId", on: "groupMember", columns: ["groupId"])
        try db.create(index: "groupMember_on_profileId", on: "groupMember", columns: ["profileId"])
        
        try db.alter(table: "closedGroupKeyPair") { t in
            t.add(column: "threadKeyPairHash", .text).defaults(to: "")
        }
        try db.create(table: "tmpClosedGroupKeyPair") { t in
            t.column("threadId", .text)
                .notNull()
                .references("closedGroup", onDelete: .cascade)        // Delete if ClosedGroup deleted
            t.column("publicKey", .blob).notNull()
            t.column("secretKey", .blob).notNull()
            t.column("receivedTimestamp", .double)
                .notNull()
            t.column("threadKeyPairHash", .integer)
                .notNull()
                .unique()
        }
        
        // Insert into the new table, drop the old table and rename the new table to be the old one
        let existingKeyPairs: [Row] = try Row.fetchAll(db, sql: "SELECT * FROM closedGroupKeyPair")
        existingKeyPairs.forEach { row in
            let threadId: String = row["threadId"]
            let publicKey: Data = row["publicKey"]
            let secretKey: Data = row["secretKey"]
            
            // Optional try as we want to ignore duplicate values
            try? db.execute(
                sql: """
                    INSERT INTO tmpClosedGroupKeyPair (threadId, publicKey, secretKey, receivedTimestamp, threadKeyPairHash)
                    VALUES (?, ?, ?, ?, ?)
                    FROM groupMember
                    GROUP BY groupId, profileId, role
                """,
                arguments: [
                    threadId,
                    publicKey,
                    secretKey,
                    row["receivedTimestamp"],
                    ClosedGroupKeyPair.generateHash(
                        threadId: threadId,
                        publicKey: publicKey,
                        secretKey: secretKey
                    )
                ]
            )
        }
        try db.drop(table: "closedGroupKeyPair")
        try db.rename(table: "tmpClosedGroupKeyPair", to: "closedGroupKeyPair")
        
        // Add an index for the 'ClosedGroupKeyPair' so we can lookup existing keys more easily
        //
        // Note: Need to create the indexes separately from creating 'TmpClosedGroupKeyPair' to ensure they
        // have the correct names
        try db.create(
            index: "closedGroupKeyPair_on_threadId",
            on: "closedGroupKeyPair",
            columns: ["threadId"]
        )
        try db.create(
            index: "closedGroupKeyPair_on_receivedTimestamp",
            on: "closedGroupKeyPair",
            columns: ["receivedTimestamp"]
        )
        try db.create(
            index: "closedGroupKeyPair_on_threadKeyPairHash",
            on: "closedGroupKeyPair",
            columns: ["threadKeyPairHash"]
        )
        try db.create(
            index: "closedGroupKeyPair_on_threadId_and_threadKeyPairHash",
            on: "closedGroupKeyPair",
            columns: ["threadId", "threadKeyPairHash"]
        )
        
        // Add an index for the 'Quote' table to speed up queries
        try db.create(
            index: "quote_on_timestampMs",
            on: "quote",
            columns: ["timestampMs"]
        )
        
        // New table for storing the latest config dump for each type
        try db.create(table: "configDump") { t in
            t.column("variant", .text)
                .notNull()
            t.column("publicKey", .text)
                .notNull()
                .indexed()
            t.column("data", .blob)
                .notNull()
            t.column("timestampMs", .integer)
                .notNull()
                .defaults(to: 0)
            
            t.primaryKey(["variant", "publicKey"])
        }
        
        // Migrate the 'isPinned' value to 'pinnedPriority'
        try db.execute(sql: """
            UPDATE openGroup
            SET pinnedPriority = 1
            WHERE isPinned = true
        """)
        
        // If we don't have an ed25519 key then no need to create cached dump data
        let userSessionId: SessionId = SessionId(
            .standard,
            publicKey: Array((try? Data.fetchOne(
                db,
                sql: "SELECT data FROM identity WHERE variant == ?",
                arguments: [Identity.Variant.x25519PublicKey.rawValue]
            )).defaulting(to: Data()))
        )
        
        /// Remove any hidden threads to avoid syncing them (they are basically shadow threads created by starting a conversation
        /// but not sending a message so can just be cleared out)
        ///
        /// **Note:** Our settings defer foreign key checks to the end of the migration, unfortunately the `PRAGMA foreign_keys`
        /// setting is also a no-on during transactions so we can't enable it for the delete action, as a result we need to manually clean
        /// up any data associated with the threads we want to delete, at the time of this migration the following tables should cascade
        /// delete when a thread is deleted:
        /// - DisappearingMessagesConfiguration
        /// - ClosedGroup
        /// - GroupMember
        /// - Interaction
        /// - ThreadTypingIndicator
        /// - PendingReadReceipt
        let threadIdsToDelete: [String] = try String.fetchAll(
            db,
            sql: """
                SELECT id
                FROM thread
                WHERE (
                    shouldBeVisible = false AND
                    id != ?
                )
            """,
            arguments: [userSessionId.hexString]
        )
        try db.execute(sql: """
            DELETE FROM thread
            WHERE id IN \(threadIdsToDelete)
        """)
        try db.execute(sql: """
            DELETE FROM disappearingMessagesConfiguration
            WHERE threadId IN \(threadIdsToDelete)
        """)
        try db.execute(sql: """
            DELETE FROM closedGroup
            WHERE threadId IN \(threadIdsToDelete)
        """)
        try db.execute(sql: """
            DELETE FROM groupMember
            WHERE groupId IN \(threadIdsToDelete)
        """)
        try db.execute(sql: """
            DELETE FROM interaction
            WHERE threadId IN \(threadIdsToDelete)
        """)
        try db.execute(sql: """
            DELETE FROM threadTypingIndicator
            WHERE threadId IN \(threadIdsToDelete)
        """)
        try db.execute(sql: """
            DELETE FROM pendingReadReceipt
            WHERE threadId IN \(threadIdsToDelete)
        """)
        
        /// There was previously a bug which allowed users to fully delete the 'Note to Self' conversation but we don't want that, so
        /// create it again if it doesn't exists
        ///
        /// **Note:** Since migrations are run when running tests creating a random SessionThread will result in unexpected thread
        /// counts so don't do this when running tests (this logic is the same as in `MainAppContext.isRunningTests`
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            if (try SessionThread.exists(db, id: userSessionId.hexString)) == false {
                try db.execute(
                    sql: """
                        INSERT INTO thread (
                            id,
                            variant,
                            creationDateTimestamp,
                            shouldBeVisible,
                            isPinned,
                            messageDraft,
                            notificationSound,
                            mutedUntilTimestamp,
                            onlyNotifyForMentions,
                            markedAsUnread,
                            pinnedPriority
                        )
                        VALUES (?, ?, ?, ?, ?, NULL, NULL, NULL, ?, ?, ?)
                    """,
                    arguments: [
                        userSessionId.hexString,
                        SessionThread.Variant.contact.rawValue,
                        (dependencies[cache: .snodeAPI].currentOffsetTimestampMs() / 1000),
                        LibSession.shouldBeVisible(priority: LibSession.hiddenPriority),
                        false,
                        false,
                        false,
                        LibSession.hiddenPriority
                    ]
                )
            }
        }
        
        Storage.update(progress: 1, for: self, in: target, using: dependencies)
    }
}
