// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtil
import SessionUtilitiesKit
import SessionSnodeKit

// MARK: - Size Restrictions

public extension LibSession {
    static var sizeMaxGroupNameBytes: Int { GROUP_NAME_MAX_LENGTH }
    static var sizeMaxCommunityBaseUrlBytes: Int { COMMUNITY_BASE_URL_MAX_LENGTH }
    static var sizeMaxCommunityFullUrlBytes: Int { COMMUNITY_FULL_URL_MAX_LENGTH }
    static var sizeMaxCommunityRoomBytes: Int { COMMUNITY_ROOM_MAX_LENGTH }
 
    static var sizeCommunityPubkeyBytes: Int { 32 }
    static var sizeLegacyGroupPubkeyBytes: Int { 32 }
    static var sizeLegacyGroupSecretKeyBytes: Int { 32 }
    static var sizeGroupSecretKeyBytes: Int { 64 }
    static var sizeGroupAuthDataBytes: Int { 100 }
    
    static func isTooLong(groupName: String) -> Bool {
        return (groupName.utf8CString.count > LibSession.sizeMaxGroupNameBytes)
    }
}

// MARK: - UserGroups Handling

internal extension LibSession {
    static let columnsRelatedToUserGroups: [ColumnExpression] = [
        ClosedGroup.Columns.name,
        ClosedGroup.Columns.authData,
        ClosedGroup.Columns.groupIdentityPrivateKey,
        ClosedGroup.Columns.invited
    ]
}

// MARK: - Incoming Changes

internal extension LibSessionCacheType {
    func handleUserGroupsUpdate(
        _ db: Database,
        in config: LibSession.Config?,
        serverTimestampMs: Int64
    ) throws {
        guard configNeedsDump(config) else { return }
        guard case .userGroups(let conf) = config else { throw LibSessionError.invalidConfigObject }
        
        // Extract all of the user group info
        let extractedUserGroups: LibSession.ExtractedUserGroups = try LibSession.extractUserGroups(
            from: conf,
            using: dependencies
        )
        
        // Extract all community/legacyGroup/group thread priorities
        let existingThreadInfo: [String: LibSession.PriorityVisibilityInfo] = (try? SessionThread
            .select(.id, .variant, .pinnedPriority, .shouldBeVisible)
            .filter(
                [
                    SessionThread.Variant.community,
                    SessionThread.Variant.legacyGroup,
                    SessionThread.Variant.group
                ].contains(SessionThread.Columns.variant)
            )
            .asRequest(of: LibSession.PriorityVisibilityInfo.self)
            .fetchAll(db))
            .defaulting(to: [])
            .reduce(into: [:]) { result, next in result[next.id] = next }
        
        // MARK: -- Handle Community Changes
        
        // Add any new communities (via the OpenGroupManager)
        extractedUserGroups.communities.forEach { community in
            let successfullyAddedGroup: Bool = dependencies[singleton: .openGroupManager].add(
                db,
                roomToken: community.data.roomToken,
                server: community.data.server,
                publicKey: community.data.publicKey,
                forceVisible: true
            )
            
            if successfullyAddedGroup {
                db.afterNextTransactionNested(using: dependencies) { [dependencies] _ in
                    dependencies[singleton: .openGroupManager].performInitialRequestsAfterAdd(
                        queue: DispatchQueue.global(qos: .userInitiated),
                        successfullyAddedGroup: successfullyAddedGroup,
                        roomToken: community.data.roomToken,
                        server: community.data.server,
                        publicKey: community.data.publicKey
                    )
                    .subscribe(on: DispatchQueue.global(qos: .userInitiated))
                    .sinkUntilComplete()
                }
            }
            
            // Set the priority if it's changed (new communities will have already been inserted at
            // this stage)
            if existingThreadInfo[community.data.threadId]?.pinnedPriority != community.priority {
                _ = try? SessionThread
                    .filter(id: community.data.threadId)
                    .updateAllAndConfig(
                        db,
                        SessionThread.Columns.pinnedPriority.set(to: community.priority),
                        using: dependencies
                    )
            }
        }
        
        // Remove any communities which are no longer in the config
        let communityIdsToRemove: Set<String> = Set(existingThreadInfo
            .filter { $0.value.variant == .community }
            .keys)
            .subtracting(extractedUserGroups.communities.map { $0.data.threadId })
        
        if !communityIdsToRemove.isEmpty {
            LibSession.kickFromConversationUIIfNeeded(removedThreadIds: Array(communityIdsToRemove), using: dependencies)
            
            try SessionThread.deleteOrLeave(
                db,
                type: .deleteCommunityAndContent,
                threadIds: Array(communityIdsToRemove),
                threadVariant: .community,
                using: dependencies
            )
        }
        
        // MARK: -- Handle Legacy Group Changes
        
        let existingLegacyGroupIds: Set<String> = Set(existingThreadInfo
            .filter { $0.value.variant == .legacyGroup }
            .keys)
        let existingLegacyGroups: [String: ClosedGroup] = (try? ClosedGroup
            .fetchAll(db, ids: existingLegacyGroupIds))
            .defaulting(to: [])
            .reduce(into: [:]) { result, next in result[next.id] = next }
        let existingLegacyGroupMembers: [String: [GroupMember]] = (try? GroupMember
            .filter(existingLegacyGroupIds.contains(GroupMember.Columns.groupId))
            .fetchAll(db))
            .defaulting(to: [])
            .grouped(by: \.groupId)
        
        try extractedUserGroups.legacyGroups.forEach { group in
            guard
                let name: String = group.name,
                let lastKeyPair: LibSession.LastKeyPairInfo = group.lastKeyPair
            else { return }
            
            let members: [LibSession.LegacyGroupMemberInfo] = (group.groupMembers ?? [])
            let admins: Set<LibSession.LegacyGroupMemberInfo> = (group.groupAdmins ?? []).asSet()
            
            // There were some bugs (somewhere) where the `joinedAt` valid could be in seconds, milliseconds
            // or even microseconds so we need to try to detect this and convert it to proper seconds (if we don't
            // have a value then we want it to be at the bottom of the list, so default to `0`)
            let joinedAt: TimeInterval = {
                guard let value: Double = group.joinedAt else { return 0 }
                
                if value > 9_000_000_000_000 {  // Microseconds
                    return (value / 1_000_000)
                } else if value > 9_000_000_000 {  // Milliseconds
                    return (value / 1000)
                }
                
                return TimeInterval(value)  // Seconds
            }()
            
            if !existingLegacyGroupIds.contains(group.id) {
                // Add a new group if it doesn't already exist
                try MessageReceiver.handleNewLegacyClosedGroup(
                    db,
                    legacyGroupSessionId: group.id,
                    name: name,
                    encryptionKeyPair: KeyPair(
                        publicKey: lastKeyPair.publicKey.bytes,
                        secretKey: lastKeyPair.secretKey.bytes
                    ),
                    members: members
                        .asSet()
                        // In legacy groups admins should also have 'standard' member entries
                        .inserting(contentsOf: admins)
                        .map { $0.profileId },
                    admins: admins.map { $0.profileId },
                    expirationTimer: UInt32(group.disappearingMessageInfo?.durationSeconds ?? 0),
                    formationTimestampMs: UInt64(joinedAt * 1000),
                    forceApprove: true,
                    using: dependencies
                )
            }
            else {
                // Otherwise update the existing group
                let groupChanges: [ConfigColumnAssignment] = [
                    (existingLegacyGroups[group.id]?.name == name ? nil :
                        ClosedGroup.Columns.name.set(to: name)
                    ),
                    (existingLegacyGroups[group.id]?.formationTimestamp == TimeInterval(joinedAt) ? nil :
                        ClosedGroup.Columns.formationTimestamp.set(to: TimeInterval(joinedAt))
                    )
                ].compactMap { $0 }
                
                // Apply any group changes
                if !groupChanges.isEmpty {
                    _ = try? ClosedGroup
                        .filter(id: group.id)
                        .updateAllAndConfig(
                            db,
                            groupChanges,
                            using: dependencies
                        )
                }
                
                // Add the lastKey if it doesn't already exist
                let lastKeyPairHash: String = ClosedGroupKeyPair.generateHash(
                    threadId: group.id,
                    publicKey: lastKeyPair.publicKey,
                    secretKey: lastKeyPair.secretKey
                )
                let keyPairExists: Bool = ClosedGroupKeyPair
                    .filter(ClosedGroupKeyPair.Columns.threadKeyPairHash == lastKeyPairHash)
                    .isNotEmpty(db)
                
                if !keyPairExists {
                    try ClosedGroupKeyPair(
                        threadId: group.id,
                        publicKey: lastKeyPair.publicKey,
                        secretKey: lastKeyPair.secretKey,
                        receivedTimestamp: lastKeyPair.receivedTimestamp
                    ).insert(db)
                }
                
                // Update the disappearing messages timer
                let localConfig: DisappearingMessagesConfiguration = try DisappearingMessagesConfiguration
                    .fetchOne(db, id: group.id)
                    .defaulting(to: DisappearingMessagesConfiguration.defaultWith(group.id))
                
                if let updatedConfig = group.disappearingMessageInfo?.generateConfig(for: group.id), localConfig != updatedConfig {
                    try updatedConfig
                        .saved(db)
                        .clearUnrelatedControlMessages(
                            db,
                            threadVariant: .legacyGroup,
                            using: dependencies
                        )
                }
                
                // Update the members
                let updatedMembers: Set<GroupMember> = members
                    .map { member in
                        GroupMember(
                            groupId: group.id,
                            profileId: member.profileId,
                            role: .standard,
                            roleStatus: .accepted,  // Legacy group members don't have role statuses
                            isHidden: false
                        )
                    }
                    .appending(
                        contentsOf: admins.map { admin in
                            GroupMember(
                                groupId: group.id,
                                profileId: admin.profileId,
                                role: .standard,
                                roleStatus: .accepted,  // Legacy group members don't have role statuses
                                isHidden: false
                            )
                        }
                    )
                    .asSet()
                let updatedAdmins: Set<GroupMember> = admins
                    .map { member in
                        GroupMember(
                            groupId: group.id,
                            profileId: member.profileId,
                            role: .admin,
                            roleStatus: .accepted,  // Legacy group members don't have role statuses
                            isHidden: false
                        )
                    }
                    .asSet()
                
                if
                    let existingMembers: Set<GroupMember> = existingLegacyGroupMembers[group.id]?
                        .filter({ $0.role == .standard || $0.role == .zombie })
                        .asSet(),
                    existingMembers != updatedMembers
                {
                    // Add in any new members and remove any removed members
                    try updatedMembers.forEach { try $0.upsert(db) }
                    try existingMembers
                        .filter { !updatedMembers.contains($0) }
                        .forEach { member in
                            try GroupMember
                                .filter(
                                    GroupMember.Columns.groupId == group.id &&
                                    GroupMember.Columns.profileId == member.profileId && (
                                        GroupMember.Columns.role == GroupMember.Role.standard ||
                                        GroupMember.Columns.role == GroupMember.Role.zombie
                                    )
                                )
                                .deleteAll(db)
                        }
                }

                if
                    let existingAdmins: Set<GroupMember> = existingLegacyGroupMembers[group.id]?
                        .filter({ $0.role == .admin })
                        .asSet(),
                    existingAdmins != updatedAdmins
                {
                    // Add in any new admins and remove any removed admins
                    try updatedAdmins.forEach { try $0.upsert(db) }
                    try existingAdmins
                        .filter { !updatedAdmins.contains($0) }
                        .forEach { member in
                            try GroupMember
                                .filter(
                                    GroupMember.Columns.groupId == group.id &&
                                    GroupMember.Columns.profileId == member.profileId &&
                                    GroupMember.Columns.role == GroupMember.Role.admin
                                )
                                .deleteAll(db)
                        }
                }
            }
            
            // Make any thread-specific changes if needed
            if existingThreadInfo[group.id]?.pinnedPriority != group.priority {
                _ = try? SessionThread
                    .filter(id: group.id)
                    .updateAllAndConfig(
                        db,
                        SessionThread.Columns.pinnedPriority.set(to: group.priority),
                        using: dependencies
                    )
            }
        }
        
        // Remove any legacy groups which are no longer in the config
        let legacyGroupIdsToRemove: Set<String> = existingLegacyGroupIds
            .subtracting(extractedUserGroups.legacyGroups.map { $0.id })
        
        if !legacyGroupIdsToRemove.isEmpty {
            LibSession.kickFromConversationUIIfNeeded(removedThreadIds: Array(legacyGroupIdsToRemove), using: dependencies)
            
            try SessionThread.deleteOrLeave(
                db,
                type: .deleteGroupAndContent,
                threadIds: Array(legacyGroupIdsToRemove),
                threadVariant: .legacyGroup,
                using: dependencies
            )
        }
        
        // MARK: -- Handle Group Changes
        
        let existingGroupSessionIds: Set<String> = Set(existingThreadInfo
            .filter { $0.value.variant == .group }
            .keys)
        let existingGroups: [String: ClosedGroup] = (try? ClosedGroup
            .fetchAll(db, ids: existingGroupSessionIds))
            .defaulting(to: [])
            .reduce(into: [:]) { result, next in result[next.id] = next }
        
        try extractedUserGroups.groups.forEach { group in
            switch (existingGroups[group.groupSessionId], existingGroupSessionIds.contains(group.groupSessionId)) {
                case (.none, _), (_, false):
                    // Add a new group if it doesn't already exist
                    try MessageReceiver.handleNewGroup(
                        db,
                        groupSessionId: group.groupSessionId,
                        groupIdentityPrivateKey: group.groupIdentityPrivateKey,
                        name: group.name,
                        authData: group.authData,
                        joinedAt: group.joinedAt,
                        invited: group.invited,
                        forceMarkAsInvited: false,
                        using: dependencies
                    )
                    
                case (.some(let existingGroup), _):
                    /// Otherwise update the existing group
                    ///
                    /// **Note:** We only include the `name` value here if the user was kicked from the group (as we update the value
                    /// before removing the group state), if the user hasn't been kicked from the group then we assume we will get the
                    /// proper name by polling for the `GROUP_INFO` instead of via syncing the `USER_GROUPS` data
                    let groupChanges: [ConfigColumnAssignment] = [
                        (!group.wasKickedFromGroup || existingGroup.name == group.name ? nil :
                            ClosedGroup.Columns.name.set(to: group.name)
                        ),
                        (existingGroup.formationTimestamp == group.joinedAt ? nil :
                            ClosedGroup.Columns.formationTimestamp.set(to: TimeInterval(group.joinedAt))
                        ),
                        (existingGroup.authData == group.authData ? nil :
                            ClosedGroup.Columns.authData.set(to: group.authData)
                        ),
                        (existingGroup.groupIdentityPrivateKey == group.groupIdentityPrivateKey ? nil :
                            ClosedGroup.Columns.groupIdentityPrivateKey.set(to: group.groupIdentityPrivateKey)
                        ),
                        (existingGroup.invited == group.invited ? nil :
                            ClosedGroup.Columns.invited.set(to: group.invited)
                        )
                    ].compactMap { $0 }

                    // Apply any group changes
                    if !groupChanges.isEmpty {
                        _ = try? ClosedGroup
                            .filter(id: group.groupSessionId)
                            .updateAllAndConfig(
                                db,
                                groupChanges,
                                using: dependencies
                            )
                        
                        // If the group changed to no longer be in the invited state then we need to trigger the
                        // group approval process
                        if !group.invited && existingGroup.invited != group.invited {
                            try ClosedGroup.approveGroupIfNeeded(
                                db,
                                group: existingGroup,
                                using: dependencies
                            )
                        }
                    }
            }

            // Make any thread-specific changes if needed
            if existingThreadInfo[group.groupSessionId]?.pinnedPriority != group.priority {
                _ = try? SessionThread
                    .filter(id: group.groupSessionId)
                    .updateAllAndConfig(
                        db,
                        SessionThread.Columns.pinnedPriority.set(to: group.priority),
                        using: dependencies
                    )
            }
        }
        
        // Remove any groups which are no longer in the config
        let groupSessionIdsToRemove: Set<String> = existingGroupSessionIds
            .subtracting(extractedUserGroups.groups.map { $0.groupSessionId })
        
        if !groupSessionIdsToRemove.isEmpty {
            LibSession.kickFromConversationUIIfNeeded(removedThreadIds: Array(groupSessionIdsToRemove), using: dependencies)
            
            try SessionThread.deleteOrLeave(
                db,
                type: .deleteGroupAndContent,
                threadIds: Array(groupSessionIdsToRemove),
                threadVariant: .group,
                using: dependencies
            )
            
            groupSessionIdsToRemove.forEach { groupSessionId in
                removeGroupStateIfNeeded(db, groupSessionId: SessionId(.group, hex: groupSessionId))
            }
        }
    }
    
    func wasKickedFromGroup(
        groupSessionId: SessionId,
        config: LibSession.Config?
    ) -> Bool {
        guard
            case .userGroups(let conf) = config,
            var cGroupId: [CChar] = groupSessionId.hexString.cString(using: .utf8)
        else { return false }
        
        // If the group doesn't exist then assume the user hasn't been kicked
        var userGroup: ugroups_group_info = ugroups_group_info()
        guard user_groups_get_group(conf, &userGroup, &cGroupId) else { return false }
        
        return ugroups_group_is_kicked(&userGroup)
    }
    
    func markAsInvited(
        _ db: Database,
        groupSessionIds: [String],
        using dependencies: Dependencies
    ) throws {
        try performAndPushChange(db, for: .userGroups, sessionId: dependencies[cache: .general].sessionId) { config in
            guard case .userGroups(let conf) = config else { throw LibSessionError.invalidConfigObject }
            
            try groupSessionIds.forEach { groupId in
                var cGroupId: [CChar] = try groupId.cString(using: .utf8) ?? { throw LibSessionError.invalidCConversion }()
                var userGroup: ugroups_group_info = ugroups_group_info()
                
                guard user_groups_get_group(conf, &userGroup, &cGroupId) else { return }
                
                ugroups_group_set_invited(&userGroup)
                user_groups_set_group(conf, &userGroup)
            }
        }
    }
    
    func markAsKicked(
        _ db: Database,
        groupSessionIds: [String],
        using dependencies: Dependencies
    ) throws {
        try performAndPushChange(db, for: .userGroups, sessionId: dependencies[cache: .general].sessionId) { config in
            guard case .userGroups(let conf) = config else { throw LibSessionError.invalidConfigObject }
            
            try groupSessionIds.forEach { groupId in
                var cGroupId: [CChar] = try groupId.cString(using: .utf8) ?? { throw LibSessionError.invalidCConversion }()
                var userGroup: ugroups_group_info = ugroups_group_info()
                
                guard user_groups_get_group(conf, &userGroup, &cGroupId) else { return }
                
                ugroups_group_set_kicked(&userGroup)
                user_groups_set_group(conf, &userGroup)
            }
        }
    }
    
    func markAsDestroyed(
        _ db: Database,
        groupSessionIds: [String],
        using dependencies: Dependencies
    ) throws {
        try performAndPushChange(db, for: .userGroups, sessionId: dependencies[cache: .general].sessionId) { config in
            guard case .userGroups(let conf) = config else { throw LibSessionError.invalidConfigObject }
            
            try groupSessionIds.forEach { groupId in
                var cGroupId: [CChar] = try groupId.cString(using: .utf8) ?? { throw LibSessionError.invalidCConversion }()
                var userGroup: ugroups_group_info = ugroups_group_info()
                
                guard user_groups_get_group(conf, &userGroup, &cGroupId) else { return }
                
                ugroups_group_set_destroyed(&userGroup)
                user_groups_set_group(conf, &userGroup)
            }
        }
    }
}

internal extension LibSession {
    fileprivate static func memberInfo(in legacyGroup: UnsafeMutablePointer<ugroups_legacy_group_info>) -> [String: Bool] {
        let membersIt: OpaquePointer = ugroups_legacy_members_begin(legacyGroup)
        var members: [String: Bool] = [:]
        var maybeMemberSessionId: UnsafePointer<CChar>? = nil
        var memberAdmin: Bool = false

        while ugroups_legacy_members_next(membersIt, &maybeMemberSessionId, &memberAdmin) {
            guard let memberSessionId: UnsafePointer<CChar> = maybeMemberSessionId else {
                continue
            }

            members[String(cString: memberSessionId)] = memberAdmin
        }
        
        return members
    }
    
    // MARK: - Outgoing Changes
    
    static func upsert(
        legacyGroups: [LegacyGroupInfo],
        in config: Config?
    ) throws {
        guard case .userGroups(let conf) = config else { throw LibSessionError.invalidConfigObject }
        guard !legacyGroups.isEmpty else { return }
        
        try legacyGroups
            .forEach { legacyGroup in
                var cGroupId: [CChar] = try legacyGroup.id.cString(using: .utf8) ?? {
                    throw LibSessionError.invalidCConversion
                }()
                
                guard let userGroup: UnsafeMutablePointer<ugroups_legacy_group_info> = user_groups_get_or_construct_legacy_group(conf, &cGroupId) else {
                    /// It looks like there are some situations where this object might not get created correctly (and
                    /// will throw due to the implicit unwrapping) as a result we put it in a guard and throw instead
                    throw LibSessionError(
                        conf,
                        fallbackError: .getOrConstructFailedUnexpectedly,
                        logMessage: "Unable to upsert legacy group conversation to LibSession"
                    )
                }
                
                // Assign all properties to match the updated group (if there is one)
                if let updatedName: String = legacyGroup.name {
                    userGroup.set(\.name, to: updatedName)
                }
                
                if let lastKeyPair: LastKeyPairInfo = legacyGroup.lastKeyPair {
                    userGroup.set(\.enc_pubkey, to: lastKeyPair.publicKey)
                    userGroup.set(\.enc_seckey, to: lastKeyPair.secretKey)
                    userGroup.set(\.have_enc_keys, to: true)
                }
                
                // Assign all properties to match the updated disappearing messages config (if there is one)
                if let updatedConfig: DisappearingMessageInfo = legacyGroup.disappearingMessageInfo {
                    userGroup.set(\.disappearing_timer, to: (!updatedConfig.isEnabled ? 0 :
                        updatedConfig.durationSeconds
                    ))
                }
                
                // Add/Remove the group members and admins
                let existingMembers: [String: Bool] = {
                    guard legacyGroup.groupMembers != nil || legacyGroup.groupAdmins != nil else { return [:] }
                    
                    return LibSession.memberInfo(in: userGroup)
                }()
                
                if let groupMembers: [LegacyGroupMemberInfo] = legacyGroup.groupMembers {
                    // Need to make sure we remove any admins before adding them here otherwise we will
                    // overwrite the admin permission to be a standard user permission
                    let memberIds: Set<String> = groupMembers
                        .map { $0.profileId }
                        .asSet()
                        .subtracting(legacyGroup.groupAdmins.defaulting(to: []).map { $0.profileId }.asSet())
                    let existingMemberIds: Set<String> = Array(existingMembers
                        .filter { _, isAdmin in !isAdmin }
                        .keys)
                        .asSet()
                    let membersIdsToAdd: Set<String> = memberIds.subtracting(existingMemberIds)
                    let membersIdsToRemove: Set<String> = existingMemberIds.subtracting(memberIds)
                    
                    try membersIdsToAdd.forEach { memberId in
                        var cProfileId: [CChar] = try memberId.cString(using: .utf8) ?? { throw LibSessionError.invalidCConversion }()
                        ugroups_legacy_member_add(userGroup, &cProfileId, false)
                    }
                    
                    try membersIdsToRemove.forEach { memberId in
                        var cProfileId: [CChar] = try memberId.cString(using: .utf8) ?? { throw LibSessionError.invalidCConversion }()
                        ugroups_legacy_member_remove(userGroup, &cProfileId)
                    }
                }
                
                if let groupAdmins: [LegacyGroupMemberInfo] = legacyGroup.groupAdmins {
                    let adminIds: Set<String> = groupAdmins.map { $0.profileId }.asSet()
                    let existingAdminIds: Set<String> = Array(existingMembers
                        .filter { _, isAdmin in isAdmin }
                        .keys)
                        .asSet()
                    let adminIdsToAdd: Set<String> = adminIds.subtracting(existingAdminIds)
                    let adminIdsToRemove: Set<String> = existingAdminIds.subtracting(adminIds)
                    
                    try adminIdsToAdd.forEach { adminId in
                        var cProfileId: [CChar] = try adminId.cString(using: .utf8) ?? { throw LibSessionError.invalidCConversion }()
                        ugroups_legacy_member_add(userGroup, &cProfileId, true)
                    }
                    
                    try adminIdsToRemove.forEach { adminId in
                        var cProfileId: [CChar] = try adminId.cString(using: .utf8) ?? { throw LibSessionError.invalidCConversion }()
                        ugroups_legacy_member_remove(userGroup, &cProfileId)
                    }
                }
                
                if let joinedAt: Int64 = legacyGroup.joinedAt.map({ Int64($0) }) {
                    userGroup.set(\.joined_at, to: joinedAt)
                }
                
                // Store the updated group (can't be sure if we made any changes above)
                userGroup.set(\.priority, to: (legacyGroup.priority ?? userGroup.pointee.priority))
                
                // Note: Need to free the legacy group pointer
                user_groups_set_free_legacy_group(conf, userGroup)
                try LibSessionError.throwIfNeeded(conf)
            }
    }
    
    static func upsert(
        groups: [GroupUpdateInfo],
        in config: Config?,
        using dependencies: Dependencies
    ) throws {
        guard case .userGroups(let conf) = config else { throw LibSessionError.invalidConfigObject }
        guard !groups.isEmpty else { return }
        
        try groups
            .forEach { group in
                var userGroup: ugroups_group_info = ugroups_group_info()
                var cGroupId: [CChar] = try group.groupSessionId.cString(using: .utf8) ?? { throw LibSessionError.invalidCConversion }()
                
                guard user_groups_get_or_construct_group(conf, &userGroup, &cGroupId) else {
                    /// It looks like there are some situations where this object might not get created correctly (and
                    /// will throw due to the implicit unwrapping) as a result we put it in a guard and throw instead
                    throw LibSessionError(
                        config,
                        fallbackError: .getOrConstructFailedUnexpectedly,
                        logMessage: "Unable to upsert group conversation to LibSession"
                    )
                }
                
                /// Assign the non-admin auth data (if it exists)
                if let authData: Data = group.authData {
                    userGroup.set(\.auth_data, to: authData)
                    userGroup.have_auth_data = true
                }

                /// Assign the admin key (if it exists)
                ///
                /// **Note:** We do this after assigning the `auth_data` as generally the values are mutually
                /// exclusive and if we have a `groupIdentityPrivateKey` we want that to take priority
                if let privateKey: Data = group.groupIdentityPrivateKey {
                    userGroup.set(\.secretkey, to: privateKey)
                    userGroup.have_secretkey = true
                }
                
                /// Assign the group name
                if let name: String = group.name {
                    userGroup.set(\.name, to: name)
                }

                // Store the updated group (can't be sure if we made any changes above)
                userGroup.invited = (group.invited ?? userGroup.invited)
                userGroup.joined_at = (group.joinedAt.map { Int64($0) } ?? userGroup.joined_at)
                userGroup.priority = (group.priority ?? userGroup.priority)
                user_groups_set_group(conf, &userGroup)
            }
    }
    
    static func upsert(
        communities: [CommunityInfo],
        in config: Config?
    ) throws {
        guard case .userGroups(let conf) = config else { throw LibSessionError.invalidConfigObject }
        guard !communities.isEmpty else { return }
        
        try communities
            .forEach { community in
                guard
                    var cBaseUrl: [CChar] = community.urlInfo.server.cString(using: .utf8),
                    var cRoom: [CChar] = community.urlInfo.roomToken.cString(using: .utf8)
                else {
                    SNLog("Unable to upsert community conversation to LibSession: \(LibSessionError.invalidCConversion)")
                    throw LibSessionError.invalidCConversion
                }
                
                var cPubkey: [UInt8] = Array(Data(hex: community.urlInfo.publicKey))
                var userCommunity: ugroups_community_info = ugroups_community_info()
                
                guard user_groups_get_or_construct_community(conf, &userCommunity, &cBaseUrl, &cRoom, &cPubkey) else {
                    /// It looks like there are some situations where this object might not get created correctly (and
                    /// will throw due to the implicit unwrapping) as a result we put it in a guard and throw instead
                    throw LibSessionError(
                        conf,
                        fallbackError: .getOrConstructFailedUnexpectedly,
                        logMessage: "Unable to upsert community conversation to LibSession"
                    )
                }
                
                userCommunity.priority = (community.priority ?? userCommunity.priority)
                user_groups_set_community(conf, &userCommunity)
            }
    }
    
    @discardableResult static func updatingGroups<T>(
        _ db: Database,
        _ updated: [T],
        using dependencies: Dependencies
    ) throws -> [T] {
        guard let updatedGroups: [ClosedGroup] = updated as? [ClosedGroup] else { throw StorageError.generic }
        
        // Exclude legacy groups as they aren't managed via SessionUtil
        let targetGroups: [ClosedGroup] = updatedGroups
            .filter { (try? SessionId(from: $0.id))?.prefix == .group }
        let userSessionId: SessionId = dependencies[cache: .general].sessionId
        
        // If we only updated the current user contact then no need to continue
        guard !targetGroups.isEmpty else { return updated }
        
        // Apply the changes
        try dependencies.mutate(cache: .libSession) { cache in
            try cache.performAndPushChange(db, for: .userGroups, sessionId: userSessionId) { config in
                try upsert(
                    groups: targetGroups.map { group -> GroupUpdateInfo in
                        GroupUpdateInfo(
                            groupSessionId: group.threadId,
                            groupIdentityPrivateKey: group.groupIdentityPrivateKey,
                            name: group.name,
                            authData: group.authData
                        )
                    },
                    in: config,
                    using: dependencies
                )
            }
        }
        
        return updated
    }
}

// MARK: - External Outgoing Changes

public extension LibSession {
    
    // MARK: -- Communities
    
    static func add(
        _ db: Database,
        server: String,
        rootToken: String,
        publicKey: String,
        using dependencies: Dependencies
    ) throws {
        try dependencies.mutate(cache: .libSession) { cache in
            try cache.performAndPushChange(db, for: .userGroups, sessionId: dependencies[cache: .general].sessionId) { config in
                try LibSession.upsert(
                    communities: [
                        CommunityInfo(
                            urlInfo: OpenGroupUrlInfo(
                                threadId: OpenGroup.idFor(roomToken: rootToken, server: server),
                                server: server,
                                roomToken: rootToken,
                                publicKey: publicKey
                            )
                        )
                    ],
                    in: config
                )
            }
        }
    }
    
    static func remove(
        _ db: Database,
        server: String,
        roomToken: String,
        using dependencies: Dependencies
    ) throws {
        try dependencies.mutate(cache: .libSession) { cache in
            try cache.performAndPushChange(db, for: .userGroups, sessionId: dependencies[cache: .general].sessionId) { config in
                guard case .userGroups(let conf) = config else { throw LibSessionError.invalidConfigObject }
                
                var cBaseUrl: [CChar] = try server.cString(using: .utf8) ?? { throw LibSessionError.invalidCConversion }()
                var cRoom: [CChar] = try roomToken.cString(using: .utf8) ?? { throw LibSessionError.invalidCConversion }()
                
                // Don't care if the community doesn't exist
                user_groups_erase_community(conf, &cBaseUrl, &cRoom)
            }
        }
        
        // Remove the volatile info as well
        try LibSession.remove(
            db,
            volatileCommunityInfo: [
                OpenGroupUrlInfo(
                    threadId: OpenGroup.idFor(roomToken: roomToken, server: server),
                    server: server,
                    roomToken: roomToken,
                    publicKey: ""
                )
            ],
            using: dependencies
        )
    }
    
    // MARK: -- Legacy Group Changes
    
    static func add(
        _ db: Database,
        legacyGroupSessionId: String,
        name: String,
        joinedAt: TimeInterval,
        latestKeyPairPublicKey: Data,
        latestKeyPairSecretKey: Data,
        latestKeyPairReceivedTimestamp: TimeInterval,
        disappearingConfig: DisappearingMessagesConfiguration,
        members: Set<String>,
        admins: Set<String>,
        using dependencies: Dependencies
    ) throws {
        try dependencies.mutate(cache: .libSession) { cache in
            try cache.performAndPushChange(db, for: .userGroups, sessionId: dependencies[cache: .general].sessionId) { config in
                guard case .userGroups(let conf) = config else { throw LibSessionError.invalidConfigObject }
                
                var cGroupId: [CChar] = try legacyGroupSessionId.cString(using: .utf8) ?? { throw LibSessionError.invalidCConversion }()
                let userGroup: UnsafeMutablePointer<ugroups_legacy_group_info>? = user_groups_get_legacy_group(conf, &cGroupId)
                
                // Need to make sure the group doesn't already exist (otherwise we will end up overriding the
                // content which could revert newer changes since this can be triggered from other 'NEW' messages
                // coming in from the legacy group swarm)
                guard userGroup == nil else {
                    ugroups_legacy_group_free(userGroup)
                    try LibSessionError.throwIfNeeded(conf)
                    return
                }
                
                try LibSession.upsert(
                    legacyGroups: [
                        LegacyGroupInfo(
                            id: legacyGroupSessionId,
                            name: name,
                            lastKeyPair: LastKeyPairInfo(
                                publicKey: latestKeyPairPublicKey,
                                secretKey: latestKeyPairSecretKey,
                                receivedTimestamp: latestKeyPairReceivedTimestamp
                            ),
                            disappearingMessageInfo: DisappearingMessageInfo(
                                isEnabled: disappearingConfig.isEnabled,
                                durationSeconds: Int64(floor(disappearingConfig.durationSeconds)),
                                rawType: disappearingConfig.type?.rawValue
                            ),
                            groupMembers: members
                                .map { memberId in
                                    LegacyGroupMemberInfo(
                                        profileId: memberId,
                                        rawRole: GroupMember.Role.standard.rawValue
                                    )
                                },
                            groupAdmins: admins
                                .map { memberId in
                                    LegacyGroupMemberInfo(
                                        profileId: memberId,
                                        rawRole: GroupMember.Role.admin.rawValue
                                    )
                                },
                            priority: nil,
                            joinedAt: joinedAt
                        )
                    ],
                    in: config
                )
            }
        }
    }
    
    static func update(
        _ db: Database,
        legacyGroupSessionId: String,
        name: String? = nil,
        latestKeyPair: ClosedGroupKeyPair? = nil,
        disappearingConfig: DisappearingMessagesConfiguration? = nil,
        members: Set<String>? = nil,
        admins: Set<String>? = nil,
        using dependencies: Dependencies
    ) throws {
        try dependencies.mutate(cache: .libSession) { cache in
            try cache.performAndPushChange(db, for: .userGroups, sessionId: dependencies[cache: .general].sessionId) { config in
                try LibSession.upsert(
                    legacyGroups: [
                        LegacyGroupInfo(
                            id: legacyGroupSessionId,
                            name: name,
                            lastKeyPair: latestKeyPair.map {
                                LastKeyPairInfo(
                                    publicKey: $0.publicKey,
                                    secretKey: $0.secretKey,
                                    receivedTimestamp: $0.receivedTimestamp
                                )
                            },
                            disappearingMessageInfo: disappearingConfig.map {
                                DisappearingMessageInfo(
                                    isEnabled: $0.isEnabled,
                                    durationSeconds: Int64(floor($0.durationSeconds)),
                                    rawType: $0.type?.rawValue
                                )
                            },
                            groupMembers: members?
                                .map { memberId in
                                    LegacyGroupMemberInfo(
                                        profileId: memberId,
                                        rawRole: GroupMember.Role.standard.rawValue
                                    )
                                },
                            groupAdmins: admins?
                                .map { memberId in
                                    LegacyGroupMemberInfo(
                                        profileId: memberId,
                                        rawRole: GroupMember.Role.admin.rawValue
                                    )
                                },
                            priority: nil,
                            joinedAt: nil
                        )
                    ],
                    in: config
                )
            }
        }
    }
    
    static func batchUpdate(
        _ db: Database,
        disappearingConfigs: [DisappearingMessagesConfiguration],
        using dependencies: Dependencies
    ) throws {
        try dependencies.mutate(cache: .libSession) { cache in
            try cache.performAndPushChange(db, for: .userGroups, sessionId: dependencies[cache: .general].sessionId) { config in
                try LibSession.upsert(
                    legacyGroups: disappearingConfigs.map {
                        LegacyGroupInfo(
                            id: $0.id,
                            disappearingMessageInfo: DisappearingMessageInfo(
                                isEnabled: $0.isEnabled,
                                durationSeconds: Int64(floor($0.durationSeconds)),
                                rawType: $0.type?.rawValue
                            )
                        )
                    },
                    in: config
                )
            }
        }
    }
    
    static func remove(
        _ db: Database,
        legacyGroupIds: [String],
        using dependencies: Dependencies
    ) throws {
        guard !legacyGroupIds.isEmpty else { return }
        
        try dependencies.mutate(cache: .libSession) { cache in
            try cache.performAndPushChange(db, for: .userGroups, sessionId: dependencies[cache: .general].sessionId) { config in
                guard case .userGroups(let conf) = config else { throw LibSessionError.invalidConfigObject }
                
                legacyGroupIds.forEach { legacyGroupId in
                    guard var cGroupId: [CChar] = legacyGroupId.cString(using: .utf8) else { return }
                    
                    // Don't care if the group doesn't exist
                    user_groups_erase_legacy_group(conf, &cGroupId)
                }
            }
        }
        
        // Remove the volatile info as well
        try LibSession.remove(db, volatileLegacyGroupIds: legacyGroupIds, using: dependencies)
    }
    
    // MARK: -- Group Changes
    
    static func add(
        _ db: Database,
        groupSessionId: String,
        groupIdentityPrivateKey: Data?,
        name: String?,
        authData: Data?,
        joinedAt: TimeInterval,
        invited: Bool,
        using dependencies: Dependencies
    ) throws {
        try dependencies.mutate(cache: .libSession) { cache in
            try cache.performAndPushChange(db, for: .userGroups, sessionId: dependencies[cache: .general].sessionId) { config in
                try LibSession.upsert(
                    groups: [
                        GroupUpdateInfo(
                            groupSessionId: groupSessionId,
                            groupIdentityPrivateKey: groupIdentityPrivateKey,
                            name: name,
                            authData: authData,
                            joinedAt: joinedAt,
                            invited: invited
                        )
                    ],
                    in: config,
                    using: dependencies
                )
            }
        }
    }
    
    static func update(
        _ db: Database,
        groupSessionId: String,
        groupIdentityPrivateKey: Data? = nil,
        name: String? = nil,
        authData: Data? = nil,
        invited: Bool? = nil,
        using dependencies: Dependencies
    ) throws {
        try dependencies.mutate(cache: .libSession) { cache in
            try cache.performAndPushChange(db, for: .userGroups, sessionId: dependencies[cache: .general].sessionId) { config in
                try LibSession.upsert(
                    groups: [
                        GroupUpdateInfo(
                            groupSessionId: groupSessionId,
                            groupIdentityPrivateKey: groupIdentityPrivateKey,
                            name: name,
                            authData: authData,
                            invited: invited
                        )
                    ],
                    in: config,
                    using: dependencies
                )
            }
        }
    }
    
    static func markAsKicked(
        _ db: Database,
        groupSessionIds: [String],
        using dependencies: Dependencies
    ) throws {
        guard !groupSessionIds.isEmpty else { return }
        
        try dependencies.mutate(cache: .libSession) { cache in
            try cache.markAsKicked(db, groupSessionIds: groupSessionIds, using: dependencies)
        }
    }
    
    static func wasKickedFromGroup(
        groupSessionId: SessionId,
        using dependencies: Dependencies
    ) -> Bool {
        return dependencies.mutate(cache: .libSession) { cache in
            guard
                case .userGroups(let conf) = cache.config(for: .userGroups, sessionId: dependencies[cache: .general].sessionId),
                var cGroupId: [CChar] = groupSessionId.hexString.cString(using: .utf8)
            else { return false }
            
            var userGroup: ugroups_group_info = ugroups_group_info()
            
            // If the group doesn't exist then assume the user hasn't been kicked
            guard user_groups_get_group(conf, &userGroup, &cGroupId) else { return false }
            
            return ugroups_group_is_kicked(&userGroup)
        }
    }
    
    static func groupIsDestroyed(
        groupSessionId: SessionId,
        using dependencies: Dependencies
    ) -> Bool {
        return dependencies.mutate(cache: .libSession) { cache in
            guard
                case .userGroups(let conf) = cache.config(for: .userGroups, sessionId: dependencies[cache: .general].sessionId),
                var cGroupId: [CChar] = groupSessionId.hexString.cString(using: .utf8)
            else { return false }
            
            var userGroup: ugroups_group_info = ugroups_group_info()
            
            // If the group doesn't exist then assume the user hasn't been kicked
            guard user_groups_get_group(conf, &userGroup, &cGroupId) else { return false }
            
            return ugroups_group_is_destroyed(&userGroup)
        }
    }
    
    static func remove(
        _ db: Database,
        groupSessionIds: [SessionId],
        using dependencies: Dependencies
    ) throws {
        guard !groupSessionIds.isEmpty else { return }
        
        try dependencies.mutate(cache: .libSession) { cache in
            try cache.performAndPushChange(db, for: .userGroups, sessionId: dependencies[cache: .general].sessionId) { config in
                guard case .userGroups(let conf) = config else { throw LibSessionError.invalidConfigObject }
                
                try groupSessionIds.forEach { groupSessionId in
                    var cGroupId: [CChar] = try groupSessionId.hexString.cString(using: .utf8) ?? {
                        throw LibSessionError.invalidCConversion
                    }()
                    
                    // Don't care if the group doesn't exist
                    user_groups_erase_group(conf, &cGroupId)
                }
            }
        }
        
        // Remove the volatile info as well
        try LibSession.remove(db, volatileGroupSessionIds: groupSessionIds, using: dependencies)
    }
}

// MARK: - Convenience

public extension LibSession {
    typealias ExtractedUserGroups = (
        communities: [PrioritisedData<LibSession.OpenGroupUrlInfo>],
        legacyGroups: [LibSession.LegacyGroupInfo],
        groups: [LibSession.GroupInfo]
    )
    
    static func extractUserGroups(
        from conf: UnsafeMutablePointer<config_object>?,
        using dependencies: Dependencies
    ) throws -> ExtractedUserGroups {
        var infiniteLoopGuard: Int = 0
        var communities: [PrioritisedData<LibSession.OpenGroupUrlInfo>] = []
        var legacyGroups: [LibSession.LegacyGroupInfo] = []
        var groups: [LibSession.GroupInfo] = []
        var community: ugroups_community_info = ugroups_community_info()
        var legacyGroup: ugroups_legacy_group_info = ugroups_legacy_group_info()
        var group: ugroups_group_info = ugroups_group_info()
        let groupsIterator: OpaquePointer = user_groups_iterator_new(conf)
        
        while !user_groups_iterator_done(groupsIterator) {
            try LibSession.checkLoopLimitReached(&infiniteLoopGuard, for: .userGroups)
            
            if user_groups_it_is_community(groupsIterator, &community) {
                let server: String = community.get(\.base_url)
                let roomToken: String = community.get(\.room)
                
                communities.append(
                    PrioritisedData(
                        data: LibSession.OpenGroupUrlInfo(
                            threadId: OpenGroup.idFor(roomToken: roomToken, server: server),
                            server: server,
                            roomToken: roomToken,
                            publicKey: community.getHex(\.pubkey)
                        ),
                        priority: community.priority
                    )
                )
            }
            else if user_groups_it_is_legacy_group(groupsIterator, &legacyGroup) {
                let groupId: String = legacyGroup.get(\.session_id)
                let members: [String: Bool] = LibSession.memberInfo(in: &legacyGroup)
                
                legacyGroups.append(
                    LibSession.LegacyGroupInfo(
                        id: groupId,
                        name: legacyGroup.get(\.name),
                        lastKeyPair: LibSession.LastKeyPairInfo(
                            publicKey: legacyGroup.get(\.enc_pubkey),
                            secretKey: legacyGroup.get(\.enc_seckey),
                            receivedTimestamp: (dependencies[cache: .snodeAPI].currentOffsetTimestampMs() / 1000)
                        ),
                        disappearingMessageInfo: DisappearingMessageInfo(
                            isEnabled: (legacyGroup.disappearing_timer > 0),
                            durationSeconds: legacyGroup.disappearing_timer,
                            rawType: DisappearingMessagesConfiguration.DisappearingMessageType
                                .disappearAfterSend.rawValue
                        ),
                        groupMembers: members
                            .filter { _, isAdmin in !isAdmin }
                            .map { memberId, _ in
                                LegacyGroupMemberInfo(
                                    profileId: memberId,
                                    rawRole: GroupMember.Role.standard.rawValue
                                )
                            },
                        groupAdmins: members
                            .filter { _, isAdmin in isAdmin }
                            .map { memberId, _ in
                                LegacyGroupMemberInfo(
                                    profileId: memberId,
                                    rawRole: GroupMember.Role.admin.rawValue
                                )
                            },
                        priority: legacyGroup.priority,
                        joinedAt: TimeInterval(legacyGroup.joined_at)
                    )
                )
            }
            else if user_groups_it_is_group(groupsIterator, &group) {
                groups.append(
                    LibSession.GroupInfo(
                        groupSessionId: group.get(\.id),
                        groupIdentityPrivateKey: (!group.have_secretkey ? nil : group.get(\.secretkey, nullIfEmpty: true)),
                        name: group.get(\.name),
                        authData: (!group.have_auth_data ? nil : group.get(\.auth_data, nullIfEmpty: true)),
                        priority: group.priority,
                        joinedAt: TimeInterval(group.joined_at),
                        invited: group.invited,
                        wasKickedFromGroup: ugroups_group_is_kicked(&group),
                        wasGroupDestroyed: ugroups_group_is_destroyed(&group)
                    )
                )
            }
            else {
                Log.warn(.libSession, "Ignoring unknown conversation type when iterating through volatile conversation info update")
            }
            
            user_groups_iterator_advance(groupsIterator)
        }
        user_groups_iterator_free(groupsIterator) // Need to free the iterator
        
        return (communities, legacyGroups, groups)
    }
}

// MARK: - LegacyGroupInfo

public extension LibSession {
    struct LegacyGroupInfo {
        let id: String
        let name: String?
        let lastKeyPair: LastKeyPairInfo?
        let disappearingMessageInfo: LibSession.DisappearingMessageInfo?
        let groupMembers: [LegacyGroupMemberInfo]?
        let groupAdmins: [LegacyGroupMemberInfo]?
        let priority: Int32?
        let joinedAt: TimeInterval?
        
        init(
            id: String,
            name: String? = nil,
            lastKeyPair: LastKeyPairInfo? = nil,
            disappearingMessageInfo: LibSession.DisappearingMessageInfo? = nil,
            groupMembers: [LegacyGroupMemberInfo]? = nil,
            groupAdmins: [LegacyGroupMemberInfo]? = nil,
            priority: Int32? = nil,
            joinedAt: TimeInterval? = nil
        ) {
            self.id = id
            self.name = name
            self.lastKeyPair = lastKeyPair
            self.disappearingMessageInfo = disappearingMessageInfo
            self.groupMembers = groupMembers
            self.groupAdmins = groupAdmins
            self.priority = priority
            self.joinedAt = joinedAt
        }
    }
    
    struct LastKeyPairInfo {
        let publicKey: Data
        let secretKey: Data
        let receivedTimestamp: TimeInterval
    }
    
    struct LegacyGroupMemberInfo: Hashable {
        let profileId: String
        let rawRole: Int
    }
}

// MARK: - GroupInfo

public extension LibSession {
    struct GroupInfo {
        let groupSessionId: String
        let groupIdentityPrivateKey: Data?
        let name: String
        let authData: Data?
        let priority: Int32
        let joinedAt: TimeInterval
        let invited: Bool
        let wasKickedFromGroup: Bool
        let wasGroupDestroyed: Bool
    }
    
    struct GroupUpdateInfo {
        let groupSessionId: String
        let groupIdentityPrivateKey: Data?
        let name: String?
        let authData: Data?
        let priority: Int32?
        let joinedAt: TimeInterval?
        let invited: Bool?
        let wasKickedFromGroup: Bool?
        let wasGroupDestroyed: Bool?
        
        init(
            groupSessionId: String,
            groupIdentityPrivateKey: Data? = nil,
            name: String? = nil,
            authData: Data? = nil,
            priority: Int32? = nil,
            joinedAt: TimeInterval? = nil,
            invited: Bool? = nil,
            wasKickedFromGroup: Bool? = nil,
            wasGroupDestroyed: Bool? = nil
        ) {
            self.groupSessionId = groupSessionId
            self.groupIdentityPrivateKey = groupIdentityPrivateKey
            self.name = name
            self.authData = authData
            self.priority = priority
            self.joinedAt = joinedAt
            self.invited = invited
            self.wasKickedFromGroup = wasKickedFromGroup
            self.wasGroupDestroyed = wasGroupDestroyed
        }
    }
}

// MARK: - CommunityInfo

extension LibSession {
    struct CommunityInfo {
        let urlInfo: OpenGroupUrlInfo
        let priority: Int32?
        
        init(
            urlInfo: OpenGroupUrlInfo,
            priority: Int32? = nil
        ) {
            self.urlInfo = urlInfo
            self.priority = priority
        }
    }
}

// MARK: - PrioritisedData

public struct PrioritisedData<T> {
    let data: T
    let priority: Int32
}

// MARK: - C Conformance

extension ugroups_community_info: CAccessible & CMutable {}
extension ugroups_legacy_group_info: CAccessible & CMutable {}
extension ugroups_group_info: CAccessible & CMutable {}
