// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtil
import SessionUtilitiesKit

// MARK: - Size Restrictions

public extension SessionUtil {
    static var sizeMaxGroupDescriptionBytes: Int { GROUP_INFO_DESCRIPTION_MAX_LENGTH }
}

// MARK: - Group Info Handling

internal extension SessionUtil {
    static let columnsRelatedToGroupInfo: [ColumnExpression] = [
        ClosedGroup.Columns.name,
        ClosedGroup.Columns.displayPictureUrl,
        ClosedGroup.Columns.displayPictureEncryptionKey,
        DisappearingMessagesConfiguration.Columns.isEnabled,
        DisappearingMessagesConfiguration.Columns.type,
        DisappearingMessagesConfiguration.Columns.durationSeconds
    ]
    
    // MARK: - Incoming Changes
    
    static func handleGroupInfoUpdate(
        _ db: Database,
        in config: Config?,
        groupSessionId: SessionId,
        serverTimestampMs: Int64,
        using dependencies: Dependencies
    ) throws {
        typealias GroupData = (profileName: String, profilePictureUrl: String?, profilePictureKey: Data?)
        
        guard config.needsDump else { return }
        guard case .object(let conf) = config else { throw SessionUtilError.invalidConfigObject }
        
        // If the group is destroyed then remove the group date (want to keep the group itself around because
        // the UX of conversations randomly disappearing isn't great) - no other changes matter and this
        // can't be reversed
        guard !groups_info_is_destroyed(conf) else {
            try ClosedGroup.removeData(
                db,
                threadIds: [groupSessionId.hexString],
                dataToRemove: [
                    .poller, .pushNotifications, .messages, .members,
                    .encryptionKeys, .authDetails, .libSessionState
                ],
                calledFromConfigHandling: true,
                using: dependencies
            )
            return
        }

        // A group must have a name so if this is null then it's invalid and can be ignored
        guard let groupNamePtr: UnsafePointer<CChar> = groups_info_get_name(conf) else { return }

        let groupDescPtr: UnsafePointer<CChar>? = groups_info_get_description(conf)
        let groupName: String = String(cString: groupNamePtr)
        let groupDesc: String? = groupDescPtr.map { String(cString: $0) }
        let formationTimestamp: TimeInterval = TimeInterval(groups_info_get_created(conf))
        let displayPic: user_profile_pic = groups_info_get_pic(conf)
        let displayPictureUrl: String? = String(libSessionVal: displayPic.url, nullIfEmpty: true)
        let displayPictureKey: Data? = Data(
            libSessionVal: displayPic.key,
            count: DisplayPictureManager.aes256KeyByteLength
        )

        // Update the group name
        let existingGroup: ClosedGroup? = try? ClosedGroup
            .filter(id: groupSessionId.hexString)
            .fetchOne(db)
        let needsDisplayPictureUpdate: Bool = (
            existingGroup?.displayPictureUrl != displayPictureUrl ||
            existingGroup?.displayPictureEncryptionKey != displayPictureKey
        )

        let groupChanges: [ConfigColumnAssignment] = [
            ((existingGroup?.name == groupName) ? nil :
                ClosedGroup.Columns.name.set(to: groupName)
            ),
            ((existingGroup?.groupDescription == groupDesc) ? nil :
                ClosedGroup.Columns.groupDescription.set(to: groupDesc)
            ),
            ((existingGroup?.formationTimestamp != formationTimestamp && formationTimestamp != 0) ? nil :
                ClosedGroup.Columns.formationTimestamp.set(to: formationTimestamp)
            ),
            // If we are removing the display picture do so here
            (!needsDisplayPictureUpdate || displayPictureUrl != nil ? nil :
                ClosedGroup.Columns.displayPictureUrl.set(to: nil)
            ),
            (!needsDisplayPictureUpdate || displayPictureUrl != nil ? nil :
                ClosedGroup.Columns.displayPictureFilename.set(to: nil)
            ),
            (!needsDisplayPictureUpdate || displayPictureUrl != nil ? nil :
                ClosedGroup.Columns.displayPictureEncryptionKey.set(to: nil)
            ),
            (!needsDisplayPictureUpdate || displayPictureUrl != nil ? nil :
                ClosedGroup.Columns.lastDisplayPictureUpdate.set(to: dependencies.dateNow)
            )
        ].compactMap { $0 }

        if !groupChanges.isEmpty {
            try ClosedGroup
                .filter(id: groupSessionId.hexString)
                .updateAll( // Handling a config update so don't use `updateAllAndConfig`
                    db,
                    groupChanges
                )
        }
        if needsDisplayPictureUpdate && displayPictureUrl != nil {
        }

        // Update the disappearing messages configuration
        let targetExpiry: Int32 = groups_info_get_expiry_timer(conf)
        let targetIsEnable: Bool = (targetExpiry > 0)
        let targetConfig: DisappearingMessagesConfiguration = DisappearingMessagesConfiguration(
            threadId: groupSessionId.hexString,
            isEnabled: targetIsEnable,
            durationSeconds: TimeInterval(targetExpiry),
            type: (targetIsEnable ? .disappearAfterSend : .unknown),
            lastChangeTimestampMs: serverTimestampMs
        )
        let localConfig: DisappearingMessagesConfiguration = try DisappearingMessagesConfiguration
            .fetchOne(db, id: groupSessionId.hexString)
            .defaulting(to: DisappearingMessagesConfiguration.defaultWith(groupSessionId.hexString))

        if
            let remoteLastChangeTimestampMs = targetConfig.lastChangeTimestampMs,
            let localLastChangeTimestampMs = localConfig.lastChangeTimestampMs,
            remoteLastChangeTimestampMs > localLastChangeTimestampMs
        {
            _ = try localConfig.with(
                isEnabled: targetConfig.isEnabled,
                durationSeconds: targetConfig.durationSeconds,
                type: targetConfig.type,
                lastChangeTimestampMs: targetConfig.lastChangeTimestampMs
            ).upsert(db)
        }
    }
}

// MARK: - Outgoing Changes

internal extension SessionUtil {
    static func updatingGroupInfo<T>(
        _ db: Database,
        _ updated: [T],
        using dependencies: Dependencies
    ) throws -> [T] {
        guard let updatedGroups: [ClosedGroup] = updated as? [ClosedGroup] else { throw StorageError.generic }
        
        // Exclude legacy groups as they aren't managed via SessionUtil
        let targetGroups: [ClosedGroup] = updatedGroups
            .filter { (try? SessionId(from: $0.id))?.prefix == .group }
        
        // If we only updated the current user contact then no need to continue
        guard !targetGroups.isEmpty else { return updated }
        
        // Loop through each of the groups and update their settings
        try targetGroups.forEach { group in
            try SessionUtil.performAndPushChange(
                db,
                for: .groupInfo,
                sessionId: SessionId(.group, hex: group.threadId),
                using: dependencies
            ) { config in
                guard case .object(let conf) = config else { throw SessionUtilError.invalidConfigObject }
                
                /// Update the name
                ///
                /// **Note:** We indentionally only update the `GROUP_INFO` and not the `USER_GROUPS` as once the
                /// group is synced between devices we want to rely on the proper group config to get display info
                var updatedName: [CChar] = group.name.cArray.nullTerminated()
                groups_info_set_name(conf, &updatedName)
                
                // Either assign the updated display pic, or sent a blank pic (to remove the current one)
                var displayPic: user_profile_pic = user_profile_pic()
                displayPic.url = group.displayPictureUrl.toLibSession()
                displayPic.key = group.displayPictureEncryptionKey.toLibSession()
                groups_info_set_pic(conf, displayPic)
            }
        }
        
        return updated
    }
    
    static func updatingDisappearingConfigsGroups<T>(
        _ db: Database,
        _ updated: [T],
        using dependencies: Dependencies
    ) throws -> [T] {
        guard let updatedDisappearingConfigs: [DisappearingMessagesConfiguration] = updated as? [DisappearingMessagesConfiguration] else { throw StorageError.generic }
        
        // Filter out any disappearing config changes not related to updated groups
        let targetUpdatedConfigs: [DisappearingMessagesConfiguration] = updatedDisappearingConfigs
            .filter { (try? SessionId.Prefix(from: $0.id)) == .group }
        
        guard !targetUpdatedConfigs.isEmpty else { return updated }
        
        // We should only sync disappearing messages configs which are associated to existing groups
        let existingGroupIds: [String] = (try? ClosedGroup
            .filter(ids: targetUpdatedConfigs.map { $0.id })
            .select(.threadId)
            .asRequest(of: String.self)
            .fetchAll(db))
            .defaulting(to: [])
        
        // If none of the disappearing messages configs are associated with existing groups then ignore
        // the changes (no need to do a config sync)
        guard !existingGroupIds.isEmpty else { return updated }
        
        // Loop through each of the groups and update their settings
        try existingGroupIds
            .compactMap { groupId in targetUpdatedConfigs.first(where: { $0.id == groupId }).map { (groupId, $0) } }
            .forEach { groupId, updatedConfig in
                try SessionUtil.performAndPushChange(
                    db,
                    for: .groupInfo,
                    sessionId: SessionId(.group, hex: groupId),
                    using: dependencies
                ) { config in
                    guard case .object(let conf) = config else { throw SessionUtilError.invalidConfigObject }
                    
                    groups_info_set_expiry_timer(conf, Int32(updatedConfig.durationSeconds))
                }
            }
        
        return updated
    }
}

// MARK: - External Outgoing Changes

public extension SessionUtil {
    static func update(
        _ db: Database,
        groupSessionId: SessionId,
        name: String? = nil,
        disappearingConfig: DisappearingMessagesConfiguration? = nil,
        using dependencies: Dependencies
    ) throws {
        try SessionUtil.performAndPushChange(
            db,
            for: .groupInfo,
            sessionId: groupSessionId,
            using: dependencies
        ) { config in
            guard case .object(let conf) = config else { throw SessionUtilError.invalidConfigObject }
            
            if let name: String = name {
                var updatedName: [CChar] = name.cArray.nullTerminated()
                groups_info_set_name(conf, &updatedName)
            }
            
            if let config: DisappearingMessagesConfiguration = disappearingConfig {
                groups_info_set_expiry_timer(conf, Int32(config.durationSeconds))
            }
        }
    }
    
    static func deleteGroupForEveryone(
        _ db: Database,
        groupSessionId: SessionId,
        using dependencies: Dependencies = Dependencies()
    ) throws {
        try SessionUtil.performAndPushChange(
            db,
            for: .groupInfo,
            sessionId: groupSessionId,
            using: dependencies
        ) { config in
            guard case .object(let conf) = config else { throw SessionUtilError.invalidConfigObject }
            
            groups_info_destroy_group(conf)
        }
    }
}
