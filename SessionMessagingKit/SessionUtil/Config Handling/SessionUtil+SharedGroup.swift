// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import GRDB
import SessionUIKit
import SessionSnodeKit
import SessionUtil
import SessionUtilitiesKit

// MARK: - Convenience

internal extension SessionUtil {
    typealias CreatedGroupInfo = (
        groupSessionId: SessionId,
        identityKeyPair: KeyPair,
        groupState: [ConfigDump.Variant: Config],
        group: ClosedGroup,
        members: [GroupMember]
    )
    
    static func createGroup(
        _ db: Database,
        name: String,
        description: String?,
        displayPictureUrl: String?,
        displayPictureFilename: String?,
        displayPictureEncryptionKey: Data?,
        members: [(id: String, profile: Profile?)],
        admins: [(id: String, profile: Profile?)],
        using dependencies: Dependencies
    ) throws -> CreatedGroupInfo {
        guard
            let groupIdentityKeyPair: KeyPair = dependencies[singleton: .crypto].generate(.ed25519KeyPair()),
            let userED25519KeyPair: KeyPair = Identity.fetchUserEd25519KeyPair(db, using: dependencies)
        else { throw MessageSenderError.noKeyPair }
        
        // Prep the relevant details (reduce the members to ensure we don't accidentally insert duplicates)
        let groupSessionId: SessionId = SessionId(.group, publicKey: groupIdentityKeyPair.publicKey)
        let creationTimestamp: TimeInterval = TimeInterval(
            Double(SnodeAPI.currentOffsetTimestampMs(using: dependencies)) / 1000
        )
        let userSessionId: SessionId = getUserSessionId(db, using: dependencies)
        let currentUserProfile: Profile? = Profile.fetchOrCreateCurrentUser(db, using: dependencies)
        let initialMembers: [String: (profile: Profile?, isAdmin: Bool)] = members
            .map { ($0.id, $0.profile, false) }
            .appending(contentsOf: admins.map { ($0.id, $0.profile, true) })
            .appending((userSessionId.hexString, currentUserProfile, true))
            .reduce(into: [:]) { result, next in result[next.0] = (profile: next.1, isAdmin: next.2)}
        
        // Create the new config objects
        let groupState: [ConfigDump.Variant: Config] = try createGroupState(
            groupSessionId: groupSessionId,
            userED25519KeyPair: userED25519KeyPair,
            groupIdentityPrivateKey: Data(groupIdentityKeyPair.secretKey),
            initialMembers: initialMembers,
            shouldLoadState: false, // We manually load the state after populating the configs
            using: dependencies
        )
        
        // Extract the conf objects from the state to load in the initial data
        guard case .groupKeys(_, let groupInfoConf, _) = groupState[.groupKeys] else {
            SNLog("[SessionUtil Error] Group config objects were null")
            throw SessionUtilError.unableToCreateConfigObject
        }
        
        // Set the initial values in the confs
        var cGroupName: [CChar] = name.cArray.nullTerminated()
        groups_info_set_name(groupInfoConf, &cGroupName)
        groups_info_set_created(groupInfoConf, Int64(floor(creationTimestamp)))
        
        if let groupDescription: String = description {
            var cGroupDescription: [CChar] = groupDescription.cArray.nullTerminated()
            groups_info_set_description(groupInfoConf, &cGroupDescription)
        }
        
        if
            let displayPictureUrl: String = displayPictureUrl,
            let displayPictureEncryptionKey: Data = displayPictureEncryptionKey
        {
            var displayPic: user_profile_pic = user_profile_pic()
            displayPic.url = displayPictureUrl.toLibSession()
            displayPic.key = displayPictureEncryptionKey.toLibSession()
            groups_info_set_pic(groupInfoConf, displayPic)
        }
        
        // Now that everything has been populated correctly we can load the state into memory
        dependencies.mutate(cache: .sessionUtil) { cache in
            groupState.forEach { variant, config in
                cache.setConfig(for: variant, sessionId: groupSessionId, to: config)
            }
        }
        
        return (
            groupSessionId,
            groupIdentityKeyPair,
            groupState,
            ClosedGroup(
                threadId: groupSessionId.hexString,
                name: name,
                formationTimestamp: creationTimestamp,
                displayPictureUrl: displayPictureUrl,
                displayPictureFilename: displayPictureFilename,
                displayPictureEncryptionKey: displayPictureEncryptionKey,
                lastDisplayPictureUpdate: creationTimestamp,
                shouldPoll: true,
                groupIdentityPrivateKey: Data(groupIdentityKeyPair.secretKey),
                invited: false
            ),
            initialMembers.map { memberId, info -> GroupMember in
                GroupMember(
                    groupId: groupSessionId.hexString,
                    profileId: memberId,
                    role: (info.isAdmin ? .admin : .standard),
                    roleStatus: (memberId == userSessionId.hexString ? .accepted : .pending),
                    isHidden: false
                )
            }
        )
    }
    
    static func removeGroupStateIfNeeded(
        _ db: Database,
        groupSessionId: SessionId,
        using dependencies: Dependencies
    ) {
        dependencies.mutate(cache: .sessionUtil) { cache in
            cache.setConfig(for: .groupKeys, sessionId: groupSessionId, to: nil)
            cache.setConfig(for: .groupInfo, sessionId: groupSessionId, to: nil)
            cache.setConfig(for: .groupMembers, sessionId: groupSessionId, to: nil)
        }
        
        _ = try? ConfigDump
            .filter(ConfigDump.Columns.sessionId == groupSessionId.hexString)
            .deleteAll(db)
    }
    
    static func saveCreatedGroup(
        _ db: Database,
        group: ClosedGroup,
        groupState: [ConfigDump.Variant: Config],
        using dependencies: Dependencies
    ) throws {
        // Create and save dumps for the configs
        try groupState.forEach { variant, config in
            try SessionUtil.createDump(
                config: config,
                for: variant,
                sessionId: SessionId(.group, hex: group.id),
                timestampMs: Int64(floor(group.formationTimestamp * 1000))
            )?.upsert(db)
        }
        
        // Add the new group to the USER_GROUPS config message
        try SessionUtil.add(
            db,
            groupSessionId: group.id,
            groupIdentityPrivateKey: group.groupIdentityPrivateKey,
            name: group.name,
            authData: group.authData,
            joinedAt: group.formationTimestamp,
            invited: (group.invited == true),
            using: dependencies
        )
    }
    
    @discardableResult static func createGroupState(
        groupSessionId: SessionId,
        userED25519KeyPair: KeyPair,
        groupIdentityPrivateKey: Data?,
        initialMembers: [String: (profile: Profile?, isAdmin: Bool)] = [:],
        shouldLoadState: Bool,
        using dependencies: Dependencies
    ) throws -> [ConfigDump.Variant: Config] {
        var secretKey: [UInt8] = userED25519KeyPair.secretKey
        var groupIdentityPublicKey: [UInt8] = groupSessionId.publicKey
        
        // Create the new config objects
        var groupKeysConf: UnsafeMutablePointer<config_group_keys>? = nil
        var groupInfoConf: UnsafeMutablePointer<config_object>? = nil
        var groupMembersConf: UnsafeMutablePointer<config_object>? = nil
        var error: [CChar] = [CChar](repeating: 0, count: 256)
        
        func loading(
            members: [String: (profile: Profile?, isAdmin: Bool)],
            into membersConf: UnsafeMutablePointer<config_object>?
        ) throws {
            guard !members.isEmpty else { return }
            
            try members.forEach { memberId, info in
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
                        promoted: 0,
                        supplement: false
                    )
                    
                    groups_members_set(membersConf, &member)
                }
            }
        }
        
        // It looks like C doesn't deal will passing pointers to null variables well so we need
        // to explicitly pass 'nil' for the admin key in this case
        switch groupIdentityPrivateKey {
            case .some(let privateKeyData):
                var groupIdentityPrivateKey: [UInt8] = Array(privateKeyData)
                
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
                try loading(members: initialMembers, into: groupMembersConf)
                
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
                
            case .none:
                try groups_info_init(
                    &groupInfoConf,
                    &groupIdentityPublicKey,
                    nil,
                    nil,
                    0,
                    &error
                ).orThrow(error: error)
                try groups_members_init(
                    &groupMembersConf,
                    &groupIdentityPublicKey,
                    nil,
                    nil,
                    0,
                    &error
                ).orThrow(error: error)
                try loading(members: initialMembers, into: groupMembersConf)
                
                try groups_keys_init(
                    &groupKeysConf,
                    &secretKey,
                    &groupIdentityPublicKey,
                    nil,
                    groupInfoConf,
                    groupMembersConf,
                    nil,
                    0,
                    &error
                ).orThrow(error: error)
        }
        
        guard
            let keysConf: UnsafeMutablePointer<config_group_keys> = groupKeysConf,
            let infoConf: UnsafeMutablePointer<config_object> = groupInfoConf,
            let membersConf: UnsafeMutablePointer<config_object> = groupMembersConf
        else {
            SNLog("[SessionUtil Error] Group config objects were null")
            throw SessionUtilError.unableToCreateConfigObject
        }
        
        // Define the config state map and load it into memory
        let groupState: [ConfigDump.Variant: Config] = [
            .groupKeys: .groupKeys(keysConf, info: infoConf, members: membersConf),
            .groupInfo: .object(infoConf),
            .groupMembers: .object(membersConf),
        ]
        
        // Only load the state if specified (during initial group creation we want to
        // load the state after populating the different configs incase invalid data
        // was provided)
        if shouldLoadState {
            dependencies.mutate(cache: .sessionUtil) { cache in
                groupState.forEach { variant, config in
                    cache.setConfig(for: variant, sessionId: groupSessionId, to: config)
                }
            }
        }
        
        return groupState
    }
    
    
    static func encrypt(
        message: Data,
        groupSessionId: SessionId,
        using dependencies: Dependencies
    ) throws -> Data {
        return try dependencies[cache: .sessionUtil]
            .config(for: .groupKeys, sessionId: groupSessionId)
            .wrappedValue
            .map { config in
                guard case .groupKeys(let conf, _, _) = config else { throw SessionUtilError.invalidConfigObject }
                
                var maybeCiphertext: UnsafeMutablePointer<UInt8>? = nil
                var ciphertextLen: Int = 0
                groups_keys_encrypt_message(
                    conf,
                    Array(message),
                    message.count,
                    &maybeCiphertext,
                    &ciphertextLen
                )
                
                guard
                    ciphertextLen > 0,
                    let ciphertext: Data = maybeCiphertext
                        .map({ Data(bytes: $0, count: ciphertextLen) })
                else { throw MessageSenderError.encryptionFailed }
                
                return ciphertext
            } ?? { throw MessageSenderError.encryptionFailed }()
    }
    
    static func decrypt(
        ciphertext: Data,
        groupSessionId: SessionId,
        using dependencies: Dependencies
    ) throws -> (plaintext: Data, sender: String) {
        return try dependencies[cache: .sessionUtil]
            .config(for: .groupKeys, sessionId: groupSessionId)
            .wrappedValue
            .map { config -> (Data, String) in
                guard case .groupKeys(let conf, _, _) = config else { throw SessionUtilError.invalidConfigObject }
                
                var ciphertext: [UInt8] = Array(ciphertext)
                var cSessionId: [CChar] = [CChar](repeating: 0, count: 67)
                var maybePlaintext: UnsafeMutablePointer<UInt8>? = nil
                var plaintextLen: Int = 0
                let didDecrypt: Bool = groups_keys_decrypt_message(
                    conf,
                    &ciphertext,
                    ciphertext.count,
                    &cSessionId,
                    &maybePlaintext,
                    &plaintextLen
                )
                
                // If we got a reported failure then just stop here
                guard didDecrypt else { throw MessageReceiverError.decryptionFailed }
                
                // We need to manually free 'maybePlaintext' upon a successful decryption
                defer { maybePlaintext?.deallocate() }
                
                guard
                    plaintextLen > 0,
                    let plaintext: Data = maybePlaintext
                        .map({ Data(bytes: $0, count: plaintextLen) })
                else { throw MessageReceiverError.decryptionFailed }
                
                return (plaintext, String(cString: cSessionId))
            } ?? { throw MessageReceiverError.decryptionFailed }()
    }
}

private extension Int32 {
    func orThrow(error: [CChar]) throws {
        guard self != 0 else { return }
        
        SNLog("[SessionUtil Error] Unable to create group config objects: \(String(cString: error))")
        throw SessionUtilError.unableToCreateConfigObject
    }
}
