// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import Sodium
import SessionUtil
import SessionUtilitiesKit
import SessionSnodeKit

// MARK: - Size Restrictions

public extension SessionUtil {
    static var libSessionMaxGroupNameByteLength: Int { GROUP_NAME_MAX_LENGTH }
    static var libSessionMaxGroupBaseUrlByteLength: Int { COMMUNITY_BASE_URL_MAX_LENGTH }
    static var libSessionMaxGroupFullUrlByteLength: Int { COMMUNITY_FULL_URL_MAX_LENGTH }
    static var libSessionMaxCommunityRoomByteLength: Int { COMMUNITY_ROOM_MAX_LENGTH }
}

// MARK: - UserGroups Handling

internal extension SessionUtil {
    static let columnsRelatedToUserGroups: [ColumnExpression] = [
        ClosedGroup.Columns.name
    ]
    
    // MARK: - Incoming Changes
    
    static func handleGroupsUpdate(
        _ db: Database,
        in conf: UnsafeMutablePointer<config_object>?,
        mergeNeedsDump: Bool,
        latestConfigUpdateSentTimestamp: TimeInterval
    ) throws {
        guard mergeNeedsDump else { return }
        guard conf != nil else { throw SessionUtilError.nilConfigObject }
        
        var communities: [PrioritisedData<OpenGroupUrlInfo>] = []
        var legacyGroups: [LegacyGroupInfo] = []
        var community: ugroups_community_info = ugroups_community_info()
        var legacyGroup: ugroups_legacy_group_info = ugroups_legacy_group_info()
        let groupsIterator: OpaquePointer = user_groups_iterator_new(conf)
        
        while !user_groups_iterator_done(groupsIterator) {
            if user_groups_it_is_community(groupsIterator, &community) {
                let server: String = String(libSessionVal: community.base_url)
                let roomToken: String = String(libSessionVal: community.room)
                
                communities.append(
                    PrioritisedData(
                        data: OpenGroupUrlInfo(
                            threadId: OpenGroup.idFor(roomToken: roomToken, server: server),
                            server: server,
                            roomToken: roomToken,
                            publicKey: Data(
                                libSessionVal: community.pubkey,
                                count: OpenGroup.pubkeyByteLength
                            ).toHexString()
                        ),
                        priority: community.priority
                    )
                )
            }
            else if user_groups_it_is_legacy_group(groupsIterator, &legacyGroup) {
                let groupId: String = String(libSessionVal: legacyGroup.session_id)
                let members: [String: Bool] = SessionUtil.memberInfo(in: &legacyGroup)
                
                legacyGroups.append(
                    LegacyGroupInfo(
                        id: groupId,
                        name: String(libSessionVal: legacyGroup.name),
                        lastKeyPair: ClosedGroupKeyPair(
                            threadId: groupId,
                            publicKey: Data(
                                libSessionVal: legacyGroup.enc_pubkey,
                                count: ClosedGroup.pubkeyByteLength
                            ),
                            secretKey: Data(
                                libSessionVal: legacyGroup.enc_seckey,
                                count: ClosedGroup.secretKeyByteLength
                            ),
                            receivedTimestamp: (TimeInterval(SnodeAPI.currentOffsetTimestampMs()) / 1000)
                        ),
                        disappearingConfig: DisappearingMessagesConfiguration
                            .defaultWith(groupId)
                            .with(
                                isEnabled: (legacyGroup.disappearing_timer > 0),
                                durationSeconds: TimeInterval(legacyGroup.disappearing_timer)
                            ),
                        groupMembers: members
                            .filter { _, isAdmin in !isAdmin }
                            .map { memberId, admin in
                                GroupMember(
                                    groupId: groupId,
                                    profileId: memberId,
                                    role: .standard,
                                    isHidden: false
                                )
                            },
                        groupAdmins: members
                            .filter { _, isAdmin in isAdmin }
                            .map { memberId, admin in
                                GroupMember(
                                    groupId: groupId,
                                    profileId: memberId,
                                    role: .admin,
                                    isHidden: false
                                )
                            },
                        priority: legacyGroup.priority
                    )
                )
            }
            else {
                SNLog("Ignoring unknown conversation type when iterating through volatile conversation info update")
            }
            
            user_groups_iterator_advance(groupsIterator)
        }
        user_groups_iterator_free(groupsIterator) // Need to free the iterator
        
        // If we don't have any conversations then no need to continue
        guard !communities.isEmpty || !legacyGroups.isEmpty else { return }
        
        // Extract all community/legacyGroup/group thread priorities
        let existingThreadInfo: [String: PriorityVisibilityInfo] = (try? SessionThread
            .select(.id, .variant, .pinnedPriority, .shouldBeVisible)
            .filter(
                [
                    SessionThread.Variant.community,
                    SessionThread.Variant.legacyGroup,
                    SessionThread.Variant.group
                ].contains(SessionThread.Columns.variant)
            )
            .asRequest(of: PriorityVisibilityInfo.self)
            .fetchAll(db))
            .defaulting(to: [])
            .reduce(into: [:]) { result, next in result[next.id] = next }
        
        // MARK: -- Handle Community Changes
        
        // Add any new communities (via the OpenGroupManager)
        communities.forEach { community in
            OpenGroupManager.shared
                .add(
                    db,
                    roomToken: community.data.roomToken,
                    server: community.data.server,
                    publicKey: community.data.publicKey,
                    calledFromConfigHandling: true
                )
                .sinkUntilComplete()
            
            // Set the priority if it's changed (new communities will have already been inserted at
            // this stage)
            if existingThreadInfo[community.data.threadId]?.pinnedPriority != community.priority {
                _ = try? SessionThread
                    .filter(id: community.data.threadId)
                    .updateAll( // Handling a config update so don't use `updateAllAndConfig`
                        db,
                        SessionThread.Columns.pinnedPriority.set(to: community.priority)
                    )
            }
        }
        
        // Remove any communities which are no longer in the config
        let communityIdsToRemove: Set<String> = Set(existingThreadInfo
            .filter { $0.value.variant == .community }
            .keys)
            .subtracting(communities.map { $0.data.threadId })
        
        communityIdsToRemove.forEach { threadId in
            OpenGroupManager.shared.delete(
                db,
                openGroupId: threadId,
                calledFromConfigHandling: true
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
        
        try legacyGroups.forEach { group in
            guard
                let name: String = group.name,
                let lastKeyPair: ClosedGroupKeyPair = group.lastKeyPair,
                let members: [GroupMember] = group.groupMembers,
                let updatedAdmins: [GroupMember] = group.groupAdmins
            else { return }
            
            if !existingLegacyGroupIds.contains(group.id) {
                // Add a new group if it doesn't already exist
                try MessageReceiver.handleNewClosedGroup(
                    db,
                    groupPublicKey: group.id,
                    name: name,
                    encryptionKeyPair: KeyPair(
                        publicKey: lastKeyPair.publicKey.bytes,
                        secretKey: lastKeyPair.secretKey.bytes
                    ),
                    members: members
                        .appending(contentsOf: updatedAdmins)  // Admins should also have 'standard' member entries
                        .map { $0.profileId },
                    admins: updatedAdmins.map { $0.profileId },
                    expirationTimer: UInt32(group.disappearingConfig?.durationSeconds ?? 0),
                    messageSentTimestamp: UInt64(latestConfigUpdateSentTimestamp * 1000),
                    calledFromConfigHandling: true
                )
            }
            else {
                // Otherwise update the existing group
                if existingLegacyGroups[group.id]?.name != name {
                    _ = try? ClosedGroup
                        .filter(id: group.id)
                        .updateAll( // Handling a config update so don't use `updateAllAndConfig`
                            db,
                            ClosedGroup.Columns.name.set(to: name)
                        )
                }
                
                // Add the lastKey if it doesn't already exist
                let keyPairExists: Bool = ClosedGroupKeyPair
                    .filter(ClosedGroupKeyPair.Columns.threadKeyPairHash == lastKeyPair.threadKeyPairHash)
                    .isNotEmpty(db)
                
                if !keyPairExists {
                    try lastKeyPair.insert(db)
                }
                
                // Update the disappearing messages timer
                _ = try DisappearingMessagesConfiguration
                    .fetchOne(db, id: group.id)
                    .defaulting(to: DisappearingMessagesConfiguration.defaultWith(group.id))
                    .with(
                        isEnabled: (group.disappearingConfig?.isEnabled == true),
                        durationSeconds: group.disappearingConfig?.durationSeconds
                    )
                    .saved(db)
                
                // Update the members
                let updatedMembers: [GroupMember] = members
                    .appending(
                        contentsOf: updatedAdmins.map { admin in
                            GroupMember(
                                groupId: admin.groupId,
                                profileId: admin.profileId,
                                role: .standard,
                                isHidden: false
                            )
                        }
                    )
                
                if
                    let existingMembers: [GroupMember] = existingLegacyGroupMembers[group.id]?
                        .filter({ $0.role == .standard || $0.role == .zombie }),
                    existingMembers != updatedMembers
                {
                    // Add in any new members and remove any removed members
                    try updatedMembers.forEach { try $0.save(db) }
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
                    let existingAdmins: [GroupMember] = existingLegacyGroupMembers[group.id]?
                        .filter({ $0.role == .admin }),
                    existingAdmins != updatedAdmins
                {
                    // Add in any new admins and remove any removed admins
                    try updatedAdmins.forEach { try $0.save(db) }
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
                    .updateAll( // Handling a config update so don't use `updateAllAndConfig`
                        db,
                        SessionThread.Columns.pinnedPriority.set(to: group.priority)
                    )
            }
        }
        
        // Remove any legacy groups which are no longer in the config
        let legacyGroupIdsToRemove: Set<String> = existingLegacyGroupIds
            .subtracting(legacyGroups.map { $0.id })
        
        if !legacyGroupIdsToRemove.isEmpty {
            try ClosedGroup.removeKeysAndUnsubscribe(
                db,
                threadIds: Array(legacyGroupIdsToRemove),
                removeGroupData: true,
                calledFromConfigHandling: true
            )
        }
        
        // MARK: -- Handle Group Changes
        // TODO: Add this
    }
    
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
        in conf: UnsafeMutablePointer<config_object>?
    ) throws {
        guard conf != nil else { throw SessionUtilError.nilConfigObject }
        guard !legacyGroups.isEmpty else { return }
        
        // Since we are doing direct memory manipulation we are using an `Atomic` type which has
        // blocking access in it's `mutate` closure
        legacyGroups
            .forEach { legacyGroup in
                var cGroupId: [CChar] = legacyGroup.id.cArray
                let userGroup: UnsafeMutablePointer<ugroups_legacy_group_info> = user_groups_get_or_construct_legacy_group(conf, &cGroupId)
                
                // Assign all properties to match the updated group (if there is one)
                if let updatedName: String = legacyGroup.name {
                    userGroup.pointee.name = updatedName.toLibSession()
                    
                    // Store the updated group (needs to happen before variables go out of scope)
                    user_groups_set_legacy_group(conf, userGroup)
                }
                
                if let lastKeyPair: ClosedGroupKeyPair = legacyGroup.lastKeyPair {
                    userGroup.pointee.enc_pubkey = lastKeyPair.publicKey.toLibSession()
                    userGroup.pointee.enc_seckey = lastKeyPair.secretKey.toLibSession()
                    userGroup.pointee.have_enc_keys = true
                    
                    // Store the updated group (needs to happen before variables go out of scope)
                    user_groups_set_legacy_group(conf, userGroup)
                }
                
                // Assign all properties to match the updated disappearing messages config (if there is one)
                if let updatedConfig: DisappearingMessagesConfiguration = legacyGroup.disappearingConfig {
                    userGroup.pointee.disappearing_timer = (!updatedConfig.isEnabled ? 0 :
                        Int64(floor(updatedConfig.durationSeconds))
                    )
                    
                    user_groups_set_legacy_group(conf, userGroup)
                }
                
                // Add/Remove the group members and admins
                let existingMembers: [String: Bool] = {
                    guard legacyGroup.groupMembers != nil || legacyGroup.groupAdmins != nil else { return [:] }
                    
                    return SessionUtil.memberInfo(in: userGroup)
                }()
                
                if let groupMembers: [GroupMember] = legacyGroup.groupMembers {
                    let memberIds: Set<String> = groupMembers.map { $0.profileId }.asSet()
                    let existingMemberIds: Set<String> = Array(existingMembers
                        .filter { _, isAdmin in !isAdmin }
                        .keys)
                        .asSet()
                    let membersIdsToAdd: Set<String> = memberIds.subtracting(existingMemberIds)
                    let membersIdsToRemove: Set<String> = existingMemberIds.subtracting(memberIds)
                    
                    membersIdsToAdd.forEach { memberId in
                        var cProfileId: [CChar] = memberId.cArray
                        ugroups_legacy_member_add(userGroup, &cProfileId, false)
                    }
                    
                    membersIdsToRemove.forEach { memberId in
                        var cProfileId: [CChar] = memberId.cArray
                        ugroups_legacy_member_remove(userGroup, &cProfileId)
                    }
                }
                
                if let groupAdmins: [GroupMember] = legacyGroup.groupAdmins {
                    let adminIds: Set<String> = groupAdmins.map { $0.profileId }.asSet()
                    let existingAdminIds: Set<String> = Array(existingMembers
                        .filter { _, isAdmin in isAdmin }
                        .keys)
                        .asSet()
                    let adminIdsToAdd: Set<String> = adminIds.subtracting(existingAdminIds)
                    let adminIdsToRemove: Set<String> = existingAdminIds.subtracting(adminIds)
                    
                    adminIdsToAdd.forEach { adminId in
                        var cProfileId: [CChar] = adminId.cArray
                        ugroups_legacy_member_add(userGroup, &cProfileId, true)
                    }
                    
                    adminIdsToRemove.forEach { adminId in
                        var cProfileId: [CChar] = adminId.cArray
                        ugroups_legacy_member_remove(userGroup, &cProfileId)
                    }
                }
                
                // Store the updated group (can't be sure if we made any changes above)
                userGroup.pointee.priority = (legacyGroup.priority ?? userGroup.pointee.priority)
                
                // Note: Need to free the legacy group pointer
                user_groups_set_free_legacy_group(conf, userGroup)
            }
    }
    
    static func upsert(
        communities: [CommunityInfo],
        in conf: UnsafeMutablePointer<config_object>?
    ) throws {
        guard conf != nil else { throw SessionUtilError.nilConfigObject }
        guard !communities.isEmpty else { return }
        
        communities
            .forEach { community in
                var cBaseUrl: [CChar] = community.urlInfo.server.cArray
                var cRoom: [CChar] = community.urlInfo.roomToken.cArray
                var cPubkey: [UInt8] = Data(hex: community.urlInfo.publicKey).cArray
                var userCommunity: ugroups_community_info = ugroups_community_info()
                
                guard user_groups_get_or_construct_community(conf, &userCommunity, &cBaseUrl, &cRoom, &cPubkey) else {
                    SNLog("Unable to upsert community conversation to Config Message")
                    return
                }
                
                userCommunity.priority = (community.priority ?? userCommunity.priority)
                user_groups_set_community(conf, &userCommunity)
            }
    }
}

// MARK: - External Outgoing Changes

public extension SessionUtil {
    
    // MARK: -- Communities
    
    static func add(
        _ db: Database,
        server: String,
        rootToken: String,
        publicKey: String
    ) throws {
        try SessionUtil.performAndPushChange(
            db,
            for: .userGroups,
            publicKey: getUserHexEncodedPublicKey(db)
        ) { conf in
            try SessionUtil.upsert(
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
                in: conf
            )
        }
    }
    
    static func remove(_ db: Database, server: String, roomToken: String) throws {
        try SessionUtil.performAndPushChange(
            db,
            for: .userGroups,
            publicKey: getUserHexEncodedPublicKey(db)
        ) { conf in
            var cBaseUrl: [CChar] = server.cArray
            var cRoom: [CChar] = roomToken.cArray
            
            // Don't care if the community doesn't exist
            user_groups_erase_community(conf, &cBaseUrl, &cRoom)
        }
        
        // Remove the volatile info as well
        try SessionUtil.remove(
            db,
            volatileCommunityInfo: [
                OpenGroupUrlInfo(
                    threadId: OpenGroup.idFor(roomToken: roomToken, server: server),
                    server: server,
                    roomToken: roomToken,
                    publicKey: ""
                )
            ]
        )
    }
    
    // MARK: -- Legacy Group Changes
    
    static func add(
        _ db: Database,
        groupPublicKey: String,
        name: String,
        latestKeyPairPublicKey: Data,
        latestKeyPairSecretKey: Data,
        latestKeyPairReceivedTimestamp: TimeInterval,
        disappearingConfig: DisappearingMessagesConfiguration,
        members: Set<String>,
        admins: Set<String>
    ) throws {
        try SessionUtil.performAndPushChange(
            db,
            for: .userGroups,
            publicKey: getUserHexEncodedPublicKey(db)
        ) { conf in
            try SessionUtil.upsert(
                legacyGroups: [
                    LegacyGroupInfo(
                        id: groupPublicKey,
                        name: name,
                        lastKeyPair: ClosedGroupKeyPair(
                            threadId: groupPublicKey,
                            publicKey: latestKeyPairPublicKey,
                            secretKey: latestKeyPairSecretKey,
                            receivedTimestamp: latestKeyPairReceivedTimestamp
                        ),
                        disappearingConfig: disappearingConfig,
                        groupMembers: members
                            .map { memberId in
                                GroupMember(
                                    groupId: groupPublicKey,
                                    profileId: memberId,
                                    role: .standard,
                                    isHidden: false
                                )
                            },
                        groupAdmins: admins
                            .map { memberId in
                                GroupMember(
                                    groupId: groupPublicKey,
                                    profileId: memberId,
                                    role: .admin,
                                    isHidden: false
                                )
                            }
                    )
                ],
                in: conf
            )
        }
    }
    
    static func update(
        _ db: Database,
        groupPublicKey: String,
        name: String? = nil,
        latestKeyPair: ClosedGroupKeyPair? = nil,
        disappearingConfig: DisappearingMessagesConfiguration? = nil,
        members: Set<String>? = nil,
        admins: Set<String>? = nil
    ) throws {
        try SessionUtil.performAndPushChange(
            db,
            for: .userGroups,
            publicKey: getUserHexEncodedPublicKey(db)
        ) { conf in
            try SessionUtil.upsert(
                legacyGroups: [
                    LegacyGroupInfo(
                        id: groupPublicKey,
                        name: name,
                        lastKeyPair: latestKeyPair,
                        disappearingConfig: disappearingConfig,
                        groupMembers: members?
                            .map { memberId in
                                GroupMember(
                                    groupId: groupPublicKey,
                                    profileId: memberId,
                                    role: .standard,
                                    isHidden: false
                                )
                            },
                        groupAdmins: admins?
                            .map { memberId in
                                GroupMember(
                                    groupId: groupPublicKey,
                                    profileId: memberId,
                                    role: .admin,
                                    isHidden: false
                                )
                            }
                    )
                ],
                in: conf
            )
        }
    }
    
    static func remove(_ db: Database, legacyGroupIds: [String]) throws {
        guard !legacyGroupIds.isEmpty else { return }
        
        try SessionUtil.performAndPushChange(
            db,
            for: .userGroups,
            publicKey: getUserHexEncodedPublicKey(db)
        ) { conf in
            legacyGroupIds.forEach { threadId in
                var cGroupId: [CChar] = threadId.cArray
                
                // Don't care if the group doesn't exist
                user_groups_erase_legacy_group(conf, &cGroupId)
            }
        }
        
        // Remove the volatile info as well
        try SessionUtil.remove(db, volatileLegacyGroupIds: legacyGroupIds)
    }
    
    // MARK: -- Group Changes
    
    static func remove(_ db: Database, groupIds: [String]) throws {
        guard !groupIds.isEmpty else { return }
    }
}

// MARK: - LegacyGroupInfo

extension SessionUtil {
    struct LegacyGroupInfo: Decodable, FetchableRecord, ColumnExpressible {
        typealias Columns = CodingKeys
        enum CodingKeys: String, CodingKey, ColumnExpression, CaseIterable {
            case threadId
            case name
            case lastKeyPair
            case disappearingConfig
            case groupMembers
            case groupAdmins
            case priority
        }
        
        var id: String { threadId }
        
        let threadId: String
        let name: String?
        let lastKeyPair: ClosedGroupKeyPair?
        let disappearingConfig: DisappearingMessagesConfiguration?
        let groupMembers: [GroupMember]?
        let groupAdmins: [GroupMember]?
        let priority: Int32?
        
        init(
            id: String,
            name: String? = nil,
            lastKeyPair: ClosedGroupKeyPair? = nil,
            disappearingConfig: DisappearingMessagesConfiguration? = nil,
            groupMembers: [GroupMember]? = nil,
            groupAdmins: [GroupMember]? = nil,
            priority: Int32? = nil
        ) {
            self.threadId = id
            self.name = name
            self.lastKeyPair = lastKeyPair
            self.disappearingConfig = disappearingConfig
            self.groupMembers = groupMembers
            self.groupAdmins = groupAdmins
            self.priority = priority
        }
        
        static func fetchAll(_ db: Database) throws -> [LegacyGroupInfo] {
            return try ClosedGroup
                .filter(ClosedGroup.Columns.threadId.like("\(SessionId.Prefix.standard.rawValue)%"))
                .including(
                    required: ClosedGroup.keyPairs
                        .order(ClosedGroupKeyPair.Columns.receivedTimestamp.desc)
                        .forKey(Columns.lastKeyPair.name)
                )
                .including(
                    all: ClosedGroup.members
                        .filter([GroupMember.Role.standard, GroupMember.Role.zombie]
                            .contains(GroupMember.Columns.role))
                        .forKey(Columns.groupMembers.name)
                )
                .including(
                    all: ClosedGroup.members
                        .filter(GroupMember.Columns.role == GroupMember.Role.admin)
                        .forKey(Columns.groupAdmins.name)
                )
                .joining(
                    optional: ClosedGroup.thread
                        .including(
                            optional: SessionThread.disappearingMessagesConfiguration
                                .forKey(Columns.disappearingConfig.name)
                        )
                )
                .asRequest(of: LegacyGroupInfo.self)
                .fetchAll(db)
        }
    }
    
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
    
    fileprivate struct GroupThreadData {
        let communities: [PrioritisedData<SessionUtil.OpenGroupUrlInfo>]
        let legacyGroups: [PrioritisedData<LegacyGroupInfo>]
        let groups: [PrioritisedData<String>]
    }
    
    fileprivate struct PrioritisedData<T> {
        let data: T
        let priority: Int32
    }
}
