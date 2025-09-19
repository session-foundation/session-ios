// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtil
import SessionUtilitiesKit

/// This migration goes through the current state of the database and generates config dumps for the user config types
enum _028_GenerateInitialUserConfigDumps: Migration {
    static let identifier: String = "messagingKit.GenerateInitialUserConfigDumps"
    static let minExpectedRunDuration: TimeInterval = 4.0
    static let createdTables: [(TableRecord & FetchableRecord).Type] = []
    
    static func migrate(_ db: ObservingDatabase, using dependencies: Dependencies) throws {
        // If we have no ed25519 key then there is no need to create cached dump data
        guard
            MigrationHelper.userExists(db),
            let userEd25519SecretKey: Data = MigrationHelper.fetchIdentityValue(db, key: "ed25519SecretKey")
        else { return MigrationExecution.updateProgress(1) }
        
        // Create the initial config state        
        let userSessionId: SessionId = MigrationHelper.userSessionId(db)
        let timestampMs: Int64 = Int64(dependencies.dateNow.timeIntervalSince1970 * TimeInterval(1000))
        let cache: LibSession.Cache = LibSession.Cache(userSessionId: userSessionId, using: dependencies)
        
        // Retrieve all threads (we are going to base the config dump data on the active
        // threads rather than anything else in the database)
        let allThreads: [String: Row] = try Row
            .fetchAll(
                db,
                sql: """
                    SELECT
                        id,
                        variant,
                        shouldBeVisible,
                        pinnedPriority,
                        creationDateTimestamp
                    FROM thread
                """
            )
            .reduce(into: [:]) { result, next in result[next["id"]] = next }
        
        // MARK: - UserProfile Config Dump
        
        let userProfileConfig: LibSession.Config = try cache.loadState(
            for: .userProfile,
            sessionId: userSessionId,
            userEd25519SecretKey: Array(userEd25519SecretKey),
            groupEd25519SecretKey: nil,
            cachedData: nil
        )
        cache.setConfig(for: .userProfile, sessionId: userSessionId, to: userProfileConfig)
        
        let userProfile: Row? = try? Row.fetchOne(
            db,
            sql: """
                SELECT name, profilePictureUrl, profileEncryptionKey
                FROM profile
                WHERE id = ?
            """,
            arguments: [userSessionId.hexString]
        )
        try cache.updateProfile(
            displayName: (userProfile?["name"] ?? ""),
            displayPictureUrl: userProfile?["profilePictureUrl"],
            displayPictureEncryptionKey: userProfile?["profileEncryptionKey"],
            isReuploadProfilePicture: false
        )
        
        try LibSession.updateNoteToSelf(
            priority: {
                guard allThreads[userSessionId.hexString]?["shouldBeVisible"] == true else {
                    return LibSession.hiddenPriority
                }
                
                let pinnedPriority: Int32? = allThreads[userSessionId.hexString]?["pinnedPriority"]
                return (pinnedPriority ?? 0)
            }(),
            in: userProfileConfig
        )
        
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
        
        // MARK: - Contact Config Dump
        
        // Exclude Note to Self, community, group and outgoing blinded message requests
        let contactsConfig: LibSession.Config = try cache.loadState(
            for: .contacts,
            sessionId: userSessionId,
            userEd25519SecretKey: Array(userEd25519SecretKey),
            groupEd25519SecretKey: nil,
            cachedData: nil
        )
        cache.setConfig(for: .contacts, sessionId: userSessionId, to: contactsConfig)
        
        let validContactIds: [String] = allThreads
            .values
            .filter { thread in
                thread["variant"] == SessionThread.Variant.contact.rawValue &&
                thread["id"] != userSessionId.hexString &&
                (try? SessionId(from: thread["id"]))?.prefix == .standard
            }
            .map { $0["id"] }
        let contactsData: [Row] = try Row.fetchAll(
            db,
            sql: """
                SELECT
                    contact.id,
                    contact.isApproved,
                    contact.isBlocked,
                    contact.didApproveMe,
                    profile.name,
                    profile.nickname,
                    profile.profilePictureUrl,
                    profile.profileEncryptionKey
                FROM contact
                LEFT JOIN profile ON profile.id = contact.id 
                WHERE (
                    contact.isBlocked = true OR
                    contact.id IN (\(validContactIds.map { "'\($0)'" }.joined(separator: ", ")))
                )
            """
        )
        let threadIdsNeedingContacts: [String] = validContactIds
            .filter { contactId in !contactsData.contains(where: { $0["id"] == contactId }) }
        
        try LibSession.upsert(
            contactData: contactsData
                .map { row in
                    let contactId: String = row["id"]
                    
                    return LibSession.ContactUpdateInfo(
                        id: contactId,
                        isApproved: row["isApproved"],
                        isBlocked: row["isBlocked"],
                        didApproveMe: row["didApproveMe"],
                        name: row["name"],
                        nickname: row["nickname"],
                        displayPictureUrl: row["profilePictureUrl"],
                        displayPictureEncryptionKey: row["profileEncryptionKey"],
                        priority: {
                            guard allThreads[contactId]?["shouldBeVisible"] == true else {
                                return -1 // Hidden priority
                            }
                            
                            let pinnedPriority: Int32? = allThreads[contactId]?["pinnedPriority"]
                            return (pinnedPriority ?? 0)
                        }(),
                        created: allThreads[contactId]?["creationDateTimestamp"]
                    )
                }
                .appending(
                    contentsOf: threadIdsNeedingContacts
                        .map { contactId in
                            LibSession.ContactUpdateInfo(
                                id: contactId,
                                isApproved: false,
                                isBlocked: false,
                                didApproveMe: false
                            )
                        }
                ),
            in: contactsConfig,
            using: dependencies
        )
        
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
        
        // MARK: - ConvoInfoVolatile Config Dump
        
        let convoInfoVolatileConfig: LibSession.Config = try cache.loadState(
            for: .convoInfoVolatile,
            sessionId: userSessionId,
            userEd25519SecretKey: Array(userEd25519SecretKey),
            groupEd25519SecretKey: nil,
            cachedData: nil
        )
        cache.setConfig(for: .convoInfoVolatile, sessionId: userSessionId, to: convoInfoVolatileConfig)
        
        let volatileThreadInfo: [Row] = try Row.fetchAll(db, sql: """
            SELECT
                thread.id,
                thread.variant,
                thread.markedAsUnread,
                interaction.timestampMs,
                openGroup.server,
                openGroup.roomToken,
                openGroup.publicKey
            FROM thread
            LEFT JOIN (
                SELECT interaction.threadId, MAX(interaction.timestampMs) AS timestampMs
                FROM interaction
                WHERE (
                    interaction.wasRead = true AND
                    -- Note: Due to the complexity of how call messages are handled and the short
                    -- duration they exist in the swarm, we have decided to exclude trying to
                    -- include them when syncing the read status of conversations (they are also
                    -- implemented differently between platforms so including them could be a
                    -- significant amount of work)
                    interaction.variant = \(Interaction.Variant.standardIncoming.rawValue)
                )
                GROUP BY interaction.threadId
            ) AS interaction ON interaction.threadId = thread.id
            LEFT JOIN openGroup ON openGroup.threadId = thread.id
            WHERE thread.id IN (\(allThreads.keys.map { "'\($0)'" }.joined(separator: ", ")))
            GROUP BY thread.id
        """)
        
        try LibSession.upsert(
            convoInfoVolatileChanges: volatileThreadInfo.compactMap { info -> LibSession.VolatileThreadInfo? in
                guard let variant: SessionThread.Variant = SessionThread.Variant(rawValue: info["variant"]) else {
                    return nil
                }
                
                var openGroupUrlInfo: LibSession.OpenGroupUrlInfo?
                
                if
                    let server: String = info["server"],
                    let roomToken: String = info["roomToken"],
                    let publicKey: String = info["publicKey"]
                {
                    openGroupUrlInfo = LibSession.OpenGroupUrlInfo(
                        threadId: info["id"],
                        server: server,
                        roomToken: roomToken,
                        publicKey: publicKey
                    )
                }
                
                let markedAsUnread: Bool? = info["markedAsUnread"]
                let timestampMs: Int64? = info["timestampMs"]
                
                return LibSession.VolatileThreadInfo(
                    threadId: info["id"],
                    variant: variant,
                    openGroupUrlInfo: openGroupUrlInfo,
                    changes: [
                        .markedAsUnread(markedAsUnread ?? false),
                        .lastReadTimestampMs(timestampMs ?? 0)
                    ]
                )
            },
            in: convoInfoVolatileConfig
        )
        
        if cache.configNeedsDump(convoInfoVolatileConfig), let dumpData: Data = try convoInfoVolatileConfig.dump() {
            try db.execute(
                sql: """
                    INSERT INTO configDump (variant, publicKey, data, timestampMs)
                    VALUES ('convoInfoVolatile', '\(userSessionId.hexString)', ?, \(timestampMs))
                    ON CONFLICT(variant, publicKey) DO UPDATE SET
                        data = ?,
                        timestampMs = \(timestampMs)
                """,
                arguments: [dumpData, dumpData]
            )
        }
        
        // MARK: - UserGroups Config Dump
        
        let userGroupsConfig: LibSession.Config = try cache.loadState(
            for: .userGroups,
            sessionId: userSessionId,
            userEd25519SecretKey: Array(userEd25519SecretKey),
            groupEd25519SecretKey: nil,
            cachedData: nil
        )
        cache.setConfig(for: .userGroups, sessionId: userSessionId, to: userGroupsConfig)
        
        let legacyGroupInfo: [Row] = try Row.fetchAll(db, sql: """
            SELECT
                closedGroup.threadId,
                closedGroup.name,
                closedGroup.formationTimestamp,
                thread.pinnedPriority,
                closedGroupKeyPair.publicKey,
                closedGroupKeyPair.secretKey,
                closedGroupKeyPair.receivedTimestamp,
                disappearingMessagesConfiguration.isEnabled,
                disappearingMessagesConfiguration.durationSeconds
            FROM closedGroup
            JOIN thread ON thread.id = closedGroup.threadId
            LEFT JOIN (
                SELECT
                    closedGroupKeyPair.threadId,
                    closedGroupKeyPair.publicKey,
                    closedGroupKeyPair.secretKey,
                    MAX(closedGroupKeyPair.receivedTimestamp) AS receivedTimestamp,
                    closedGroupKeyPair.threadKeyPairHash
                FROM closedGroupKeyPair
                GROUP BY closedGroupKeyPair.threadId
            ) AS closedGroupKeyPair ON closedGroupKeyPair.threadId = closedGroup.threadId
            LEFT JOIN disappearingMessagesConfiguration ON disappearingMessagesConfiguration.threadId = closedGroup.threadId
        """)
        let legacyGroupIds: [String] = legacyGroupInfo.map { $0["threadId"] }
        let allLegacyGroupMembers: [Row] = try Row.fetchAll(db, sql: """
            SELECT groupId, profileId, role
            FROM groupMember
            WHERE groupId IN (\(legacyGroupIds.map { "'\($0)'" }.joined(separator: ", ")))
        """)
        let groupedLegacyGroupMembers: [String: [LibSession.LegacyGroupMemberInfo]] = allLegacyGroupMembers
            .reduce(into: [:]) { result, next in
                let groupId: String = next["groupId"]
                result[groupId] = (result[groupId] ?? []).appending(
                    LibSession.LegacyGroupMemberInfo(
                        profileId: next["profileId"],
                        rawRole: next["role"]
                    )
                )
            }
        let communityInfo: [Row] = try Row.fetchAll(db, sql: """
            SELECT threadId, server, roomToken, publicKey
            FROM openGroup
            WHERE threadId IN (\(allThreads.keys.map { "'\($0)'" }.joined(separator: ", ")))
        """)
        
        try LibSession.upsert(
            legacyGroups: legacyGroupInfo.compactMap { info -> LibSession.LegacyGroupInfo? in
                let id: String = info["threadId"]
                
                return LibSession.LegacyGroupInfo(
                    id: id,
                    name: info["name"],
                    groupMembers: groupedLegacyGroupMembers[id]?.filter {
                        $0.rawRole == GroupMember.Role.standard.rawValue ||
                        $0.rawRole == GroupMember.Role.zombie.rawValue
                    },
                    groupAdmins: groupedLegacyGroupMembers[id]?.filter {
                        $0.rawRole == GroupMember.Role.admin.rawValue
                    },
                    priority: info["pinnedPriority"],
                    joinedAt: info["formationTimestamp"]
                )
            },
            in: userGroupsConfig
        )
        try LibSession.upsert(
            communities: communityInfo.compactMap { info in
                let threadId: String = info["threadId"]
                let pinnedPriority: Int32? = allThreads[threadId]?["pinnedPriority"]
                
                return LibSession.CommunityUpdateInfo(
                    urlInfo: LibSession.OpenGroupUrlInfo(
                        threadId: threadId,
                        server: info["server"],
                        roomToken: info["roomToken"],
                        publicKey: info["publicKey"]
                    ),
                    priority: (pinnedPriority ?? 0)
                )
            },
            in: userGroupsConfig
        )
        
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
