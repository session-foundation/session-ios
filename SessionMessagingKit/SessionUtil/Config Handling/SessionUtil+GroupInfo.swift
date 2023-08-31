// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtil
import SessionUtilitiesKit

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
        latestConfigSentTimestampMs: Int64,
        using dependencies: Dependencies
    ) throws {
        typealias GroupData = (profileName: String, profilePictureUrl: String?, profilePictureKey: Data?)
        
        guard config.needsDump else { return }
        guard case .object(let conf) = config else { throw SessionUtilError.invalidConfigObject }
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
            .filter { SessionId(from: $0.id)?.prefix == .group }
        
        // If we only updated the current user contact then no need to continue
        guard !targetGroups.isEmpty else { return updated }
        
        // Loop through each of the groups and update their settings
        try targetGroups.forEach { group in
            try SessionUtil.performAndPushChange(
                db,
                for: .groupInfo,
                publicKey: group.threadId,
                using: dependencies
            ) { config in
                guard case .object(let conf) = config else { throw SessionUtilError.invalidConfigObject }
                
                // Update the name
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
            .filter { SessionId.Prefix(from: $0.id) == .group }
        
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
            .forEach { groupIdentityPublicKey, updatedConfig in
            try SessionUtil.performAndPushChange(
                db,
                for: .groupInfo,
                publicKey: groupIdentityPublicKey,
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
        groupIdentityPublicKey: String,
        name: String? = nil,
        disappearingConfig: DisappearingMessagesConfiguration? = nil,
        using dependencies: Dependencies
    ) throws {
        try SessionUtil.performAndPushChange(
            db,
            for: .groupInfo,
            publicKey: groupIdentityPublicKey,
            using: dependencies
        ) { config in
            guard case .object(let conf) = config else { throw SessionUtilError.invalidConfigObject }
            
            if let name: String = name {
                groups_info_set_name(conf, name.toLibSession())
            }
            
            if let config: DisappearingMessagesConfiguration = disappearingConfig {
                groups_info_set_expiry_timer(conf, Int32(config.durationSeconds))
            }
        }
    }
}
