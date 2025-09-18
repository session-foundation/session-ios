// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit

enum _032_DisappearingMessagesConfiguration: Migration {
    static let identifier: String = "messagingKit.DisappearingMessagesWithTypes"
    static let minExpectedRunDuration: TimeInterval = 0.1
    static let createdTables: [(TableRecord & FetchableRecord).Type] = []
    
    static func migrate(_ db: ObservingDatabase, using dependencies: Dependencies) throws {
        try db.alter(table: "disappearingMessagesConfiguration") { t in
            t.add(column: "type", .integer)
        }
        
        try db.alter(table: "contact") { t in
            t.add(column: "lastKnownClientVersion", .integer)
        }
        
        /// Add index on interaction table for wasRead and variant
        /// 
        /// This is due to new disappearing messages will need some info messages to be able to be unread,
        /// but we only want to count the unread message number by incoming visible messages and call messages.
        try db.create(
            indexOn: "interaction",
            columns: ["wasRead", "variant"]
        )
        
        // If there isn't already a user account then we can just finish here (there will be no
        // threads/configs to update and the configs won't be setup which would cause this to crash
        guard
            MigrationHelper.userExists(db),
            let userEd25519SecretKey: Data = MigrationHelper.fetchIdentityValue(db, key: "ed25519SecretKey")
        else { return MigrationExecution.updateProgress(1) }
        
        // Set the disappearing messages type per conversation
        let userSessionId: SessionId = MigrationHelper.userSessionId(db)
        let timestampMs: Int64 = Int64(dependencies.dateNow.timeIntervalSince1970 * TimeInterval(1000))
        let userProfileType: DisappearingMessagesConfiguration.DisappearingMessageType = .disappearAfterSend
        let contactType: DisappearingMessagesConfiguration.DisappearingMessageType = .disappearAfterRead
        let legacyGroupType: DisappearingMessagesConfiguration.DisappearingMessageType = .disappearAfterSend
        try db.execute(sql: """
            UPDATE disappearingMessagesConfiguration
            SET type = \(userProfileType.rawValue)
            WHERE disappearingMessagesConfiguration.threadId = '\(userSessionId.hexString)'
        """)
        try db.execute(sql: """
            UPDATE disappearingMessagesConfiguration
            SET type = \(contactType.rawValue)
            WHERE threadId IN (
                SELECT id FROM thread WHERE variant = \(SessionThread.Variant.contact.rawValue)
            )
        """)
        try db.execute(sql: """
            UPDATE disappearingMessagesConfiguration
            SET type = \(legacyGroupType.rawValue)
            WHERE threadId IN (
                SELECT id FROM thread WHERE variant = \(SessionThread.Variant.legacyGroup.rawValue)
            )
        """)
        
        // Also need to update libSession with the new settings
        let disappearingMessageInfo: [Row] = try Row.fetchAll(db, sql: """
            SELECT
                thread.id,
                thread.variant,
                disappearingMessagesConfiguration.isEnabled,
                disappearingMessagesConfiguration.durationSeconds
            FROM disappearingMessagesConfiguration
            JOIN thread ON thread.id = disappearingMessagesConfiguration.threadId
        """)
        
        let cache: LibSession.Cache = LibSession.Cache(userSessionId: userSessionId, using: dependencies)
        let userProfileConfig: LibSession.Config = try cache.loadState(
            for: .userProfile,
            sessionId: userSessionId,
            userEd25519SecretKey: Array(userEd25519SecretKey),
            groupEd25519SecretKey: nil,
            cachedData: MigrationHelper.configDump(db, for: ConfigDump.Variant.userProfile.rawValue)
        )
        let contactsConfig: LibSession.Config = try cache.loadState(
            for: .contacts,
            sessionId: userSessionId,
            userEd25519SecretKey: Array(userEd25519SecretKey),
            groupEd25519SecretKey: nil,
            cachedData: MigrationHelper.configDump(db, for: ConfigDump.Variant.contacts.rawValue)
        )
        let userGroupsConfig: LibSession.Config = try cache.loadState(
            for: .userGroups,
            sessionId: userSessionId,
            userEd25519SecretKey: Array(userEd25519SecretKey),
            groupEd25519SecretKey: nil,
            cachedData: MigrationHelper.configDump(db, for: ConfigDump.Variant.userGroups.rawValue)
        )
        
        // Update the configs so the settings are synced
        if let noteToSelfInfo: Row = disappearingMessageInfo.first(where: { $0["id"] == userSessionId.hexString }) {
            try LibSession.updateNoteToSelf(
                disappearingMessagesConfig: DisappearingMessagesConfiguration(
                    threadId: noteToSelfInfo["id"],
                    isEnabled: noteToSelfInfo["isEnabled"],
                    durationSeconds: noteToSelfInfo["durationSeconds"],
                    type: userProfileType
                ),
                in: userProfileConfig
            )
        }
        
        try LibSession.upsert(
            contactData: disappearingMessageInfo
                .filter {
                    $0["id"] != userSessionId.hexString &&
                    $0["variant"] == SessionThread.Variant.contact.rawValue
                }
                .map {
                    LibSession.ContactUpdateInfo(
                        id: $0["id"],
                        disappearingMessagesConfig: DisappearingMessagesConfiguration(
                            threadId: $0["id"],
                            isEnabled: $0["isEnabled"],
                            durationSeconds: $0["durationSeconds"],
                            type: contactType
                        )
                    )
                },
            in: contactsConfig,
            using: dependencies
        )
        
        // Now that the state is updated we need to save the updated config dumps
        if cache.configNeedsDump(userProfileConfig), let dumpData: Data = try userProfileConfig.dump() {
            try db.execute(
                sql: """
                    INSERT INTO configDump (variant, publicKey, data, timestampMs)
                    VALUES ('userProfile', '\(userSessionId.hexString)', ?, \(timestampMs))
                    ON CONFLICT(variant, publicKey) DO UPDATE SET
                        data = ?,
                        timestampMs = \(timestampMs)
                """,
                arguments: [dumpData, dumpData]
            )
        }
        if cache.configNeedsDump(contactsConfig), let dumpData: Data = try contactsConfig.dump() {
            try db.execute(
                sql: """
                    INSERT INTO configDump (variant, publicKey, data, timestampMs)
                    VALUES ('contacts', '\(userSessionId.hexString)', ?, \(timestampMs))
                    ON CONFLICT(variant, publicKey) DO UPDATE SET
                        data = ?,
                        timestampMs = \(timestampMs)
                """,
                arguments: [dumpData, dumpData]
            )
        }
        if cache.configNeedsDump(userGroupsConfig), let dumpData: Data = try userGroupsConfig.dump() {
            try db.execute(
                sql: """
                    INSERT INTO configDump (variant, publicKey, data, timestampMs)
                    VALUES ('userGroups', '\(userSessionId.hexString)', ?, \(timestampMs))
                    ON CONFLICT(variant, publicKey) DO UPDATE SET
                        data = ?,
                        timestampMs = \(timestampMs)
                """,
                arguments: [dumpData, dumpData]
            )
        }
        
        MigrationExecution.updateProgress(1)
    }
}
