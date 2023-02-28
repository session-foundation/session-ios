// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import Sodium
import SessionUtil
import SessionUtilitiesKit
import SessionSnodeKit
// TODO: Expose 'GROUP_NAME_MAX_LENGTH', 'COMMUNITY_URL_MAX_LENGTH' & 'COMMUNITY_ROOM_MAX_LENGTH'
internal extension SessionUtil {
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
        var legacyGroups: [PrioritisedData<LegacyGroupInfo>] = []
        var groups: [PrioritisedData<String>] = []
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
                
                legacyGroups.append(
                    PrioritisedData(
                        data: LegacyGroupInfo(
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
                                    // TODO: double check the 'isEnabled' flag
                                    isEnabled: (legacyGroup.disappearing_timer > 0),
                                    durationSeconds: (legacyGroup.disappearing_timer == 0 ? nil :
                                        TimeInterval(legacyGroup.disappearing_timer)
                                    )
                                ),
                            groupMembers: [], //[GroupMember] // TODO: This
                            hidden: legacyGroup.hidden
                        ),
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
        guard !communities.isEmpty || !legacyGroups.isEmpty || !groups.isEmpty else { return }
        
        // Extract all community/legacyGroup/group thread priorities
        let existingThreadPriorities: [String: PriorityInfo] = (try? SessionThread
            .select(.id, .variant, .pinnedPriority)
            .filter(
                [
                    SessionThread.Variant.community,
                    SessionThread.Variant.legacyGroup,
                    SessionThread.Variant.group
                ].contains(SessionThread.Columns.variant)
            )
            .asRequest(of: PriorityInfo.self)
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
            if existingThreadPriorities[community.data.threadId]?.pinnedPriority != community.priority {
                _ = try? SessionThread
                    .filter(id: community.data.threadId)
                    .updateAll( // Handling a config update so don't use `updateAllAndConfig`
                        db,
                        SessionThread.Columns.pinnedPriority.set(to: community.priority)
                    )
            }
        }
        
        // Remove any communities which are no longer in the config
        let communityIdsToRemove: Set<String> = Set(existingThreadPriorities
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
        
        let existingLegacyGroupIds: Set<String> = Set(existingThreadPriorities
            .filter { $0.value.variant == .legacyGroup }
            .keys)
        
        try legacyGroups.forEach { group in
            guard
                let name: String = group.data.name,
                let lastKeyPair: ClosedGroupKeyPair = group.data.lastKeyPair,
                let members: [GroupMember] = group.data.groupMembers
            else { return }
            
            if !existingLegacyGroupIds.contains(group.data.id) {
                // Add a new group if it doesn't already exist
                try MessageReceiver.handleNewClosedGroup(
                    db,
                    groupPublicKey: group.data.id,
                    name: name,
                    encryptionKeyPair: Box.KeyPair(
                        publicKey: lastKeyPair.publicKey.bytes,
                        secretKey: lastKeyPair.secretKey.bytes
                    ),
                    members: members
                        .filter { $0.role == .standard }
                        .map { $0.profileId },
                    admins: members
                        .filter { $0.role == .admin }
                        .map { $0.profileId },
                    expirationTimer: UInt32(group.data.disappearingConfig?.durationSeconds ?? 0),
                    messageSentTimestamp: UInt64(latestConfigUpdateSentTimestamp * 1000)
                )
            }
            else {
                // Otherwise update the existing group
                _ = try? ClosedGroup
                    .filter(id: group.data.id)
                    .updateAll( // Handling a config update so don't use `updateAllAndConfig`
                        db,
                        ClosedGroup.Columns.name.set(to: name)
                    )
                
                // Update the lastKey
                let keyPairExists: Bool = ClosedGroupKeyPair
                    .filter(
                        ClosedGroupKeyPair.Columns.threadId == lastKeyPair.threadId &&
                        ClosedGroupKeyPair.Columns.publicKey == lastKeyPair.publicKey &&
                        ClosedGroupKeyPair.Columns.secretKey == lastKeyPair.secretKey
                    )
                    .isNotEmpty(db)
                
                if !keyPairExists {
                    try lastKeyPair.insert(db)
                }
                
                // Update the disappearing messages timer
                _ = try DisappearingMessagesConfiguration
                    .fetchOne(db, id: group.data.id)
                    .defaulting(to: DisappearingMessagesConfiguration.defaultWith(group.data.id))
                    .with(
                        // TODO: double check the 'isEnabled' flag
                        isEnabled: (group.data.disappearingConfig?.isEnabled == true),
                        durationSeconds: group.data.disappearingConfig?.durationSeconds
                    )
                    .saved(db)
                
                // Update the members
                // TODO: This
                // TODO: Going to need to decide whether we want to update the 'GroupMember' records in the database based on this config message changing
//                let members: [String]
//                let admins: [String]
            }
            
            // TODO: 'hidden' flag - just toggle the 'shouldBeVisible' flag? Delete messages as well???
            
            
            // Set the priority if it's changed
            if existingThreadPriorities[group.data.id]?.pinnedPriority != group.priority {
                _ = try? SessionThread
                    .filter(id: group.data.id)
                    .updateAll( // Handling a config update so don't use `updateAllAndConfig`
                        db,
                        SessionThread.Columns.pinnedPriority.set(to: group.priority)
                    )
            }
        }
        
        // Remove any legacy groups which are no longer in the config
        let legacyGroupIdsToRemove: Set<String> = existingLegacyGroupIds
            .subtracting(legacyGroups.map { $0.data.id })
        
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

    // MARK: - Outgoing Changes
    
    static func upsert(
        legacyGroups: [LegacyGroupInfo],
        in conf: UnsafeMutablePointer<config_object>?
    ) throws -> ConfResult {
        guard conf != nil else { throw SessionUtilError.nilConfigObject }
        guard !legacyGroups.isEmpty else { return ConfResult(needsPush: false, needsDump: false) }

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
                    user_groups_set_legacy_group(conf, &userGroup)
                }
                
                if let lastKeyPair: ClosedGroupKeyPair = legacyGroup.lastKeyPair {
                    userGroup.pointee.enc_pubkey = lastKeyPair.publicKey.toLibSession()
                    userGroup.pointee.enc_seckey = lastKeyPair.secretKey.toLibSession()
                    
                    // Store the updated group (needs to happen before variables go out of scope)
                    user_groups_set_legacy_group(conf, &userGroup)
                }
                
                // Assign all properties to match the updated disappearing messages config (if there is one)
                if let updatedConfig: DisappearingMessagesConfiguration = legacyGroup.disappearingConfig {
                    // TODO: double check the 'isEnabled' flag
                    userGroup.pointee.disappearing_timer = (!updatedConfig.isEnabled ? 0 :
                        Int64(floor(updatedConfig.durationSeconds))
                    )
                }
                
                // TODO: Need to add members/admins

                // Store the updated group (can't be sure if we made any changes above)
                userGroup.pointee.hidden = (legacyGroup.hidden ?? userGroup.pointee.hidden)
                userGroup.pointee.priority = (legacyGroup.priority ?? userGroup.pointee.priority)
                
                // Note: Need to free the legacy group pointer
                user_groups_set_free_legacy_group(conf, userGroup)
            }

        return ConfResult(
            needsPush: config_needs_push(conf),
            needsDump: config_needs_dump(conf)
        )
    }

    static func upsert(
        communities: [(info: OpenGroupUrlInfo, priority: Int32?)],
        in conf: UnsafeMutablePointer<config_object>?
    ) throws -> ConfResult {
        guard conf != nil else { throw SessionUtilError.nilConfigObject }
        guard !communities.isEmpty else { return ConfResult.init(needsPush: false, needsDump: false) }

        communities
            .forEach { info, priority in
                var cBaseUrl: [CChar] = info.server.cArray
                var cRoom: [CChar] = info.roomToken.cArray
                var cPubkey: [UInt8] = Data(hex: info.publicKey).cArray
                var userCommunity: ugroups_community_info = ugroups_community_info()
                
                guard user_groups_get_or_construct_community(conf, &userCommunity, &cBaseUrl, &cRoom, &cPubkey) else {
                    SNLog("Unable to upsert community conversation to Config Message")
                    return
                }
                
                userCommunity.priority = (priority ?? userCommunity.priority)
                user_groups_set_community(conf, &userCommunity)
            }

        return ConfResult(
            needsPush: config_needs_push(conf),
            needsDump: config_needs_dump(conf)
        )
    }
    
    // MARK: -- Communities
    
    static func add(
        _ db: Database,
        server: String,
        rootToken: String,
        publicKey: String
    ) throws {
        let userPublicKey: String = getUserHexEncodedPublicKey(db)
        
        // Since we are doing direct memory manipulation we are using an `Atomic` type which has
        // blocking access in it's `mutate` closure
        let needsPush: Bool = try SessionUtil
            .config(
                for: .userGroups,
                publicKey: userPublicKey
            )
            .mutate { conf in
                guard conf != nil else { throw SessionUtilError.nilConfigObject }
                
                let result: ConfResult = try SessionUtil.upsert(
                    communities: [
                        (
                            OpenGroupUrlInfo(
                                threadId: OpenGroup.idFor(roomToken: rootToken, server: server),
                                server: server,
                                roomToken: rootToken,
                                publicKey: publicKey
                            ),
                            nil
                        )
                    ],
                    in: conf
                )
                
                // If we don't need to dump the data the we can finish early
                guard result.needsDump else { return result.needsPush }
                
                try SessionUtil.createDump(
                    conf: conf,
                    for: .userGroups,
                    publicKey: userPublicKey
                )?.save(db)
                
                return result.needsPush
            }
        
        // Make sure we need a push before scheduling one
        guard needsPush else { return }
        
        db.afterNextTransactionNestedOnce(dedupeId: SessionUtil.syncDedupeId(userPublicKey)) { db in
            ConfigurationSyncJob.enqueue(db, publicKey: userPublicKey)
        }
    }
    
    static func remove(_ db: Database, server: String, roomToken: String) throws {
        let userPublicKey: String = getUserHexEncodedPublicKey(db)
        
        // Since we are doing direct memory manipulation we are using an `Atomic` type which has
        // blocking access in it's `mutate` closure
        let needsPush: Bool = try SessionUtil
            .config(
                for: .userGroups,
                publicKey: userPublicKey
            )
            .mutate { conf in
                guard conf != nil else { throw SessionUtilError.nilConfigObject }
                
                var cBaseUrl: [CChar] = server.cArray
                var cRoom: [CChar] = roomToken.cArray
                
                // Don't care if the community doesn't exist
                user_groups_erase_community(conf, &cBaseUrl, &cRoom)
                
                let needsPush: Bool = config_needs_push(conf)
                
                // If we don't need to dump the data the we can finish early
                guard config_needs_dump(conf) else { return needsPush }
                
                try SessionUtil.createDump(
                    conf: conf,
                    for: .userGroups,
                    publicKey: userPublicKey
                )?.save(db)
                
                return needsPush
            }
        
        // Make sure we need a push before scheduling one
        guard needsPush else { return }
        
        db.afterNextTransactionNestedOnce(dedupeId: SessionUtil.syncDedupeId(userPublicKey)) { db in
            ConfigurationSyncJob.enqueue(db, publicKey: userPublicKey)
        }
    }
    
    // MARK: -- Legacy Group Changes
    
    static func add(
        _ db: Database,
        groupPublicKey: String,
        name: String,
        latestKeyPairPublicKey: Data,
        latestKeyPairSecretKey: Data,
        latestKeyPairReceivedTimestamp: TimeInterval,
        members: Set<String>,
        admins: Set<String>
    ) throws {
        let userPublicKey: String = getUserHexEncodedPublicKey(db)
        
        // Since we are doing direct memory manipulation we are using an `Atomic` type which has
        // blocking access in it's `mutate` closure
        let needsPush: Bool = try SessionUtil
            .config(
                for: .userGroups,
                publicKey: userPublicKey
            )
            .mutate { conf in
                guard conf != nil else { throw SessionUtilError.nilConfigObject }
                
                let result: ConfResult = try SessionUtil.upsert(
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
                            groupMembers: members
                                .map { memberId in
                                    GroupMember(
                                        groupId: groupPublicKey,
                                        profileId: memberId,
                                        role: .standard,
                                        isHidden: false
                                    )
                                }
                                .appending(
                                    contentsOf: admins
                                        .map { memberId in
                                            GroupMember(
                                                groupId: groupPublicKey,
                                                profileId: memberId,
                                                role: .admin,
                                                isHidden: false
                                            )
                                        }
                                )
                        )
                    ],
                    in: conf
                )
                
                // If we don't need to dump the data the we can finish early
                guard result.needsDump else { return result.needsPush }
                
                try SessionUtil.createDump(
                    conf: conf,
                    for: .userGroups,
                    publicKey: userPublicKey
                )?.save(db)
                
                return result.needsPush
            }
        
        // Make sure we need a push before scheduling one
        guard needsPush else { return }
        
        db.afterNextTransactionNestedOnce(dedupeId: SessionUtil.syncDedupeId(userPublicKey)) { db in
            ConfigurationSyncJob.enqueue(db, publicKey: userPublicKey)
        }
    }
    
    static func hide(_ db: Database, legacyGroupIds: [String]) throws {
    }
    
    static func remove(_ db: Database, legacyGroupIds: [String]) throws {
        let userPublicKey: String = getUserHexEncodedPublicKey(db)
        
        // Since we are doing direct memory manipulation we are using an `Atomic` type which has
        // blocking access in it's `mutate` closure
        let needsPush: Bool = try SessionUtil
            .config(
                for: .userGroups,
                publicKey: userPublicKey
            )
            .mutate { conf in
                guard conf != nil else { throw SessionUtilError.nilConfigObject }
                
                legacyGroupIds.forEach { threadId in
                    var cGroupId: [CChar] = threadId.cArray
                    
                    // Don't care if the group doesn't exist
                    user_groups_erase_legacy_group(conf, &cGroupId)
                }
                
                let needsPush: Bool = config_needs_push(conf)
                
                // If we don't need to dump the data the we can finish early
                guard config_needs_dump(conf) else { return needsPush }
                
                try SessionUtil.createDump(
                    conf: conf,
                    for: .userGroups,
                    publicKey: userPublicKey
                )?.save(db)
                
                return needsPush
            }
        
        // Make sure we need a push before scheduling one
        guard needsPush else { return }
        
        db.afterNextTransactionNestedOnce(dedupeId: SessionUtil.syncDedupeId(userPublicKey)) { db in
            ConfigurationSyncJob.enqueue(db, publicKey: userPublicKey)
        }
    }
    
    // MARK: -- Group Changes
    
    static func hide(_ db: Database, groupIds: [String]) throws {
    }
    
    static func remove(_ db: Database, groupIds: [String]) throws {
    }
}

        }
        
        return updated
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
            case hidden
            case priority
        }
        
        var id: String { threadId }
        
        let threadId: String
        let name: String?
        let lastKeyPair: ClosedGroupKeyPair?
        let disappearingConfig: DisappearingMessagesConfiguration?
        let groupMembers: [GroupMember]?
        let hidden: Bool?
        let priority: Int32?
        
        init(
            id: String,
            name: String? = nil,
            lastKeyPair: ClosedGroupKeyPair? = nil,
            disappearingConfig: DisappearingMessagesConfiguration? = nil,
            groupMembers: [GroupMember]? = nil,
            hidden: Bool? = nil,
            priority: Int32? = nil
        ) {
            self.threadId = id
            self.name = name
            self.lastKeyPair = lastKeyPair
            self.disappearingConfig = disappearingConfig
            self.groupMembers = groupMembers
            self.hidden = hidden
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
                .including(all: ClosedGroup.members)
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
