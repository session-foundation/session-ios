// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import GRDB
import SessionUIKit
import SessionSnodeKit
import SessionUtil
import SessionUtilitiesKit

// MARK: - Convenience

internal extension SessionUtil {
    static func createGroup(
        _ db: Database,
        name: String,
        displayPictureUrl: String?,
        displayPictureFilename: String?,
        displayPictureEncryptionKey: Data?,
        members: [(id: String, profile: Profile?)],
        admins: [(id: String, profile: Profile?)],
        using dependencies: Dependencies
    ) throws -> (identityKeyPair: KeyPair, group: ClosedGroup, members: [GroupMember]) {
        guard
            let groupIdentityKeyPair: KeyPair = dependencies[singleton: .crypto].generate(.ed25519KeyPair()),
            let userED25519KeyPair: KeyPair = Identity.fetchUserEd25519KeyPair(db, using: dependencies)
        else { throw MessageSenderError.noKeyPair }
        
        // There will probably be custom init functions, will need a way to save the conf into
        // the in-memory state after init though
        var secretKey: [UInt8] = userED25519KeyPair.secretKey
        var groupIdentityPublicKey: [UInt8] = groupIdentityKeyPair.publicKey
        var groupIdentityPrivateKey: [UInt8] = groupIdentityKeyPair.secretKey
        let groupId: SessionId = SessionId(.group, publicKey: groupIdentityKeyPair.publicKey)
        let creationTimestamp: TimeInterval = TimeInterval(
            SnodeAPI.currentOffsetTimestampMs(using: dependencies) / 1000
        )
        let currentUserPublicKey: String = getUserHexEncodedPublicKey(db, using: dependencies)
        let currentUserProfile: Profile? = Profile.fetchOrCreateCurrentUser(db, using: dependencies)
        
        // Create the new config objects
        var groupKeysConf: UnsafeMutablePointer<config_group_keys>? = nil
        var groupInfoConf: UnsafeMutablePointer<config_object>? = nil
        var groupMembersConf: UnsafeMutablePointer<config_object>? = nil
        var error: [CChar] = [CChar](repeating: 0, count: 256)
        try groups_info_init(
            &groupInfoConf,
            &groupIdentityPublicKey,
            &groupIdentityPrivateKey,
            nil,
            0,
            &error
        ).orThrow(error: error)
        try groups_members_init(
            &groupMembersConf,
            &groupIdentityPublicKey,
            &groupIdentityPrivateKey,
            nil,
            0,
            &error
        ).orThrow(error: error)
        try groups_keys_init(
            &groupKeysConf,
            &secretKey,
            &groupIdentityPublicKey,
            &groupIdentityPrivateKey,
            groupInfoConf,
            groupMembersConf,
            nil,
            0,
            &error
        ).orThrow(error: error)
        
        guard
            let keysConf: UnsafeMutablePointer<config_group_keys> = groupKeysConf,
            let infoConf: UnsafeMutablePointer<config_object> = groupInfoConf,
            let membersConf: UnsafeMutablePointer<config_object> = groupMembersConf
        else {
            SNLog("[SessionUtil Error] Group config objects were null")
            throw SessionUtilError.unableToCreateConfigObject
        }
        
        // Set the initial values in the confs
        var groupName: [CChar] = name.cArray.nullTerminated()
        groups_info_set_name(groupInfoConf, &groupName)
        groups_info_set_created(groupInfoConf, Int64(floor(creationTimestamp)))
        
        if
            let displayPictureUrl: String = displayPictureUrl,
            let displayPictureEncryptionKey: Data = displayPictureEncryptionKey
        {
            var displayPic: user_profile_pic = user_profile_pic()
            displayPic.url = displayPictureUrl.toLibSession()
            displayPic.key = displayPictureEncryptionKey.toLibSession()
            groups_info_set_pic(groupInfoConf, displayPic)
        }
        
        // Store the members/admins in the group (reduce to ensure we don't accidentally insert duplicates)
        let finalMembers: [String: (profile: Profile?, isAdmin: Bool)] = members
            .map { ($0.id, $0.profile, false) }
            .appending(contentsOf: admins.map { ($0.id, $0.profile, true) })
            .appending((currentUserPublicKey, currentUserProfile, true))
            .reduce(into: [:]) { result, next in result[next.0] = (profile: next.1, isAdmin: next.2)}
        
        try finalMembers.forEach { memberId, info in
            var profilePic: user_profile_pic = user_profile_pic()
            
            if
                let picUrl: String = info.profile?.profilePictureUrl,
                let picKey: Data = info.profile?.profileEncryptionKey
            {
                profilePic.url = picUrl.toLibSession()
                profilePic.key = picKey.toLibSession()
            }

            try CExceptionHelper.performSafely {
                var member: config_group_member = config_group_member(
                    session_id: memberId.toLibSession(),
                    name: (info.profile?.name ?? "").toLibSession(),
                    profile_pic: profilePic,
                    admin: info.isAdmin,
                    invited: 0,
                    promoted: 0
                )
                
                groups_members_set(membersConf, &member)
            }
        }
        // Load them into memory
        let groupState: [ConfigDump.Variant: Config] = [
            .groupKeys: .groupKeys(keysConf, info: infoConf, members: membersConf),
            .groupInfo: .object(infoConf),
            .groupMembers: .object(membersConf),
        ]
        dependencies.mutate(cache: .sessionUtil) { cache in
            groupState.forEach { variant, config in
                cache.setConfig(for: variant, publicKey: groupId.hexString, to: config)
            }
        }
        
        // Create and save dumps for the configs
        try groupState.forEach { variant, config in
            try SessionUtil.createDump(
                config: config,
                for: variant,
                publicKey: groupId.hexString,
                timestampMs: Int64(floor(creationTimestamp * 1000))
            )?.save(db)
        }
        
        // Add the new group to the USER_GROUPS config message
        try SessionUtil.add(
            db,
            groupIdentityPublicKey: groupId.hexString,
            groupIdentityPrivateKey: Data(groupIdentityPrivateKey),
            name: name,
            tag: nil,
            subkey: nil,
            joinedAt: Int64(floor(creationTimestamp)),
            using: dependencies
        )
        
        return (
            groupIdentityKeyPair,
            ClosedGroup(
                threadId: groupId.hexString,
                name: name,
                formationTimestamp: creationTimestamp,
                displayPictureUrl: displayPictureUrl,
                displayPictureFilename: displayPictureFilename,
                displayPictureEncryptionKey: displayPictureEncryptionKey,
                lastDisplayPictureUpdate: creationTimestamp,
                groupIdentityPrivateKey: Data(groupIdentityPrivateKey),
                approved: true
            ),
            finalMembers.map { memberId, info -> GroupMember in
                GroupMember(
                    groupId: groupId.hexString,
                    profileId: memberId,
                    role: (info.isAdmin ? .admin : .standard),
                    isHidden: false
                )
            }
        )
    }
    
    @discardableResult static func addGroup(
        _ db: Database,
        groupIdentityPublicKey: [UInt8],
        groupIdentityPrivateKey: Data?,
        name: String,
        tag: Data?,
        subkey: Data?,
        joinedAt: Int64,
        approved: Bool,
        using dependencies: Dependencies
    ) throws -> (group: ClosedGroup, members: [GroupMember]) {
        // TODO: This!!!
        preconditionFailure()
    }
}

private extension Int32 {
    func orThrow(error: [CChar]) throws {
        guard self != 0 else { return }
        
        SNLog("[SessionUtil Error] Unable to create group config objects: \(String(cString: error))")
        throw SessionUtilError.unableToCreateConfigObject
    }
}
