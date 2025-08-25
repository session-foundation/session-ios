// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import UIKit.UIImage
import GRDB
import SessionNetworkingKit
import SessionUtilitiesKit

enum _036_GroupsRebuildChanges: Migration {
    static let identifier: String = "messagingKit.GroupsRebuildChanges"
    static let minExpectedRunDuration: TimeInterval = 0.1
    static var createdTables: [(FetchableRecord & TableRecord).Type] = []
    
    static func migrate(_ db: ObservingDatabase, using dependencies: Dependencies) throws {
        try db.alter(table: "thread") { t in
            t.add(column: "isDraft", .boolean).defaults(to: false)
        }
        
        try db.alter(table: "closedGroup") { t in
            t.add(column: "groupDescription", .text)
            t.add(column: "displayPictureUrl", .text)
            t.add(column: "displayPictureFilename", .text)
            t.add(column: "displayPictureEncryptionKey", .blob)
            t.add(column: "lastDisplayPictureUpdate", .integer).defaults(to: 0)
            t.add(column: "shouldPoll", .boolean).defaults(to: false)
            t.add(column: "groupIdentityPrivateKey", .blob)
            t.add(column: "authData", .blob)
            t.add(column: "invited", .boolean).defaults(to: false)
        }
        
        try db.alter(table: "openGroup") { t in
            t.add(column: "displayPictureFilename", .text)
            t.add(column: "lastDisplayPictureUpdate", .integer).defaults(to: 0)
        }
        
        try db.alter(table: "groupMember") { t in
            t.add(column: "roleStatus", .integer)
                .notNull()
                .defaults(to: GroupMember.RoleStatus.accepted)
        }
        
        guard
            MigrationHelper.userExists(db),
            let userEd25519SecretKey: Data = MigrationHelper.fetchIdentityValue(db, key: "ed25519SecretKey")
        else { return MigrationExecution.updateProgress(1) }
        
        let userSessionId: SessionId = MigrationHelper.userSessionId(db)
        
        // Update existing groups where the current user is a member to have `shouldPoll` as `true`
        try db.execute(sql: """
            UPDATE closedGroup
            SET shouldPoll = true
            WHERE EXISTS (
                SELECT 1
                FROM groupMember
                WHERE groupMember.groupId = closedGroup.threadId
                AND groupMember.profileId = '\(userSessionId.hexString)'
            )
        """)
        
        // If a user had upgraded a different device their config could already contain V2 groups
        // so we should check and, if so, create those
        let cache: LibSession.Cache = LibSession.Cache(userSessionId: userSessionId, using: dependencies)
        let userGroupsConfig: LibSession.Config = try cache.loadState(
            for: .userGroups,
            sessionId: userSessionId,
            userEd25519SecretKey: Array(userEd25519SecretKey),
            groupEd25519SecretKey: nil,
            cachedData: MigrationHelper.configDump(db, for: ConfigDump.Variant.userGroups.rawValue)
        )
        let convoInfoVolatileConfig: LibSession.Config = try cache.loadState(
            for: .convoInfoVolatile,
            sessionId: userSessionId,
            userEd25519SecretKey: Array(userEd25519SecretKey),
            groupEd25519SecretKey: nil,
            cachedData: MigrationHelper.configDump(db, for: ConfigDump.Variant.convoInfoVolatile.rawValue)
        )
        
        // Extract all of the user group info
        if case .userGroups(let conf) = userGroupsConfig, case .convoInfoVolatile(let convoInfoVolatileConf) = convoInfoVolatileConfig {
            let extractedUserGroups: LibSession.ExtractedUserGroups = try LibSession.extractUserGroups(
                from: conf,
                using: dependencies
            )
            let volatileThreadInfo: [String: LibSession.VolatileThreadInfo] = try LibSession
                .extractConvoVolatileInfo(from: convoInfoVolatileConf)
                .reduce(into: [:]) { result, next in result[next.threadId] = next }
            
            try extractedUserGroups.groups.forEach { group in
                let markedAsUnread: Bool = (volatileThreadInfo[group.groupSessionId]?.changes
                    .contains(where: { change in
                        switch change {
                            case .markedAsUnread(let value): return value
                            default: return false
                        }
                    }))
                    .defaulting(to: false)
                
                try db.execute(sql: """
                    INSERT INTO thread (
                        id,
                        variant,
                        creationDateTimestamp,
                        shouldBeVisible,
                        isPinned,
                        markedAsUnread,
                        pinnedPriority
                    )
                    VALUES (
                        '\(group.groupSessionId)',
                        \(SessionThread.Variant.group.rawValue),
                        \(group.joinedAt),
                        true,
                        false,
                        \(markedAsUnread),
                        \(group.priority)
                    )
                """)
                try db.execute(
                    sql: """
                        INSERT INTO closedGroup (
                            threadId,
                            name,
                            formationTimestamp,
                            shouldPoll,
                            groupIdentityPrivateKey,
                            authData,
                            invited
                        )
                        VALUES (
                            '\(group.groupSessionId)',
                            '\(group.name)',
                            \(group.joinedAt),
                            \(group.invited == false),
                            ?,
                            ?,
                            \(group.invited)
                        )
                    """,
                    arguments: [group.groupIdentityPrivateKey, group.authData]
                )
                
                /// If the group isn't in the invited state then make sure to subscribe for PNs once the migrations are done
                if !group.invited, let token: String = dependencies[defaults: .standard, key: .deviceToken] {
                    db.afterCommit {
                        dependencies[singleton: .storage]
                            .readPublisher { db in
                                try PushNotificationAPI.preparedSubscribe(
                                    db,
                                    token: Data(hex: token),
                                    sessionIds: [SessionId(.group, hex: group.groupSessionId)],
                                    using: dependencies
                                )
                            }
                            .flatMap { $0.send(using: dependencies) }
                            .subscribe(on: DispatchQueue.global(qos: .userInitiated), using: dependencies)
                            .sinkUntilComplete()
                    }
                }
            }
        }
        
        // Move the `imageData` out of the `OpenGroup` table and on to disk to be consistent with
        // the other display picture logic
        let timestampMs: TimeInterval = TimeInterval(dependencies[cache: .snodeAPI].currentOffsetTimestampMs() / 1000)
        let existingImageInfo: [Row] = try Row.fetchAll(db, sql: """
            SELECT threadid, imageData
            FROM openGroup
            WHERE imageData IS NOT NULL
        """)
        
        existingImageInfo.forEach { imageInfo in
            guard
                let threadId: String = imageInfo["threadId"],
                let imageData: Data = imageInfo["imageData"]
            else {
                Log.error("[GroupsRebuildChanges] Failed to extract imageData from community")
                return
            }
            
            let filename: String = generateFilename(
                format: MediaUtils.guessedImageFormat(data: imageData),
                using: dependencies
            )
            let filePath: String = URL(fileURLWithPath: dependencies[singleton: .displayPictureManager].sharedDataDisplayPictureDirPath())
                .appendingPathComponent(filename)
                .path
            
            // Save the decrypted display picture to disk
            try? imageData.write(to: URL(fileURLWithPath: filePath), options: [.atomic])
            
            guard UIImage(contentsOfFile: filePath) != nil else {
                Log.error("[GroupsRebuildChanges] Failed to save Community imageData for \(threadId)")
                return
            }
            
            // Update the database with the new info
            try? db.execute(sql: """
                UPDATE openGroup
                SET
                    imageData = NULL,
                    displayPictureFilename = '\(filename)',
                    lastDisplayPictureUpdate = \(timestampMs)
                WHERE threadId = '\(threadId)'
            """)
        }
        
        MigrationExecution.updateProgress(1)
    }
}

private extension _036_GroupsRebuildChanges {
    static func generateFilename(format: ImageFormat = .jpeg, using dependencies: Dependencies) -> String {
        return dependencies[singleton: .crypto]
            .generate(.uuid())
            .defaulting(to: UUID())
            .uuidString
            .appendingFileExtension(format.fileExtension)
    }
}
