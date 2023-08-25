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
        members: Set<String>,
        admins: Set<String>,
        using dependencies: Dependencies
    ) throws -> (identityKeyPair: KeyPair, group: ClosedGroup, members: [GroupMember]) {
        guard
            let groupIdentityKeyPair: KeyPair = dependencies.crypto.generate(.ed25519KeyPair()),
            let userED25519KeyPair: KeyPair = Identity.fetchUserEd25519KeyPair(db)
        else { throw MessageSenderError.noKeyPair }
        
        // There will probably be custom init functions, will need a way to save the conf into
        // the in-memory state after init though
        var secretKey: [UInt8] = userED25519KeyPair.secretKey
        var groupIdentityPublicKey: [UInt8] = groupIdentityKeyPair.publicKey
        var groupIdentityPrivateKey: [UInt8] = groupIdentityKeyPair.secretKey
        let groupIdentityPublicKeyString: String = groupIdentityKeyPair.publicKey.toHexString()
        let creationTimestamp: TimeInterval = TimeInterval(SnodeAPI.currentOffsetTimestampMs() * 1000)
        let currentUserPublicKey: String = getUserHexEncodedPublicKey(db, using: dependencies)
        
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
        
        // Set the initial values in the confs
        var groupName: [CChar] = name.cArray.nullTerminated()
        groups_info_set_name(groupInfoConf, &groupName)
        groups_info_set_created(groupInfoConf, Int64(floor(creationTimestamp)))
        
        if var displayPictureUrl: String = displayPictureUrl, var displayPictureEncryptionKey: Data = displayPictureEncryptionKey {
            var displayPic: user_profile_pic = user_profile_pic()
            displayPic.url = displayPictureUrl.toLibSession()
            displayPic.key = displayPictureEncryptionKey.toLibSession()
            groups_info_set_pic(groupInfoConf, displayPic)
        }
        
        // Create dumps for the configs
        try [.groupKeys, .groupInfo, .groupMembers].forEach { variant in
            try SessionUtil.pushChangesIfNeeded(db, for: variant, publicKey: groupIdentityPublicKeyString)
        }
        
        // Add the new group to the USER_GROUPS config message
        try SessionUtil.add(
            db,
            groupIdentityPublicKey: groupIdentityPublicKeyString,
            groupIdentityPrivateKey: Data(groupIdentityPrivateKey),
            name: name,
            tag: nil,
            subkey: nil
        )
        
        return (
            groupIdentityKeyPair,
            ClosedGroup(
                threadId: groupIdentityPublicKeyString,
                name: name,
                formationTimestamp: creationTimestamp,
                displayPictureUrl: displayPictureUrl,
                displayPictureFilename: displayPictureFilename,
                displayPictureEncryptionKey: displayPictureEncryptionKey,
                lastDisplayPictureUpdate: creationTimestamp,
                groupIdentityPrivateKey: Data(groupIdentityPrivateKey),
                approved: true
            ),
            members
                .map { memberId -> GroupMember in
                    GroupMember(
                        groupId: groupIdentityPublicKeyString,
                        profileId: memberId,
                        role: .standard,
                        isHidden: false
                    )
                }
                .appending(
                    contentsOf: admins.map { memberId -> GroupMember in
                        GroupMember(
                            groupId: groupIdentityPublicKeyString,
                            profileId: memberId,
                            role: .admin,
                            isHidden: false
                        )
                    }
                )
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

private extension Int32 {
    func orThrow(error: [CChar]) throws {
        guard self != 0 else { return }
        
        SNLog("[SessionUtil Error] Unable to create group config objects: \(String(cString: error))")
        throw SessionUtilError.unableToCreateConfigObject
    }
}
