// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtil
import SessionUtilitiesKit

internal extension SessionUtil {
    // MARK: - Incoming Changes
    
    static func handleUserProfileUpdate(
        _ db: Database,
        in atomicConf: Atomic<UnsafeMutablePointer<config_object>?>,
        mergeResult: ConfResult,
        latestConfigUpdateSentTimestamp: TimeInterval
    ) throws -> ConfResult {
        typealias ProfileData = (profileName: String, profilePictureUrl: String?, profilePictureKey: Data?)
        
        guard mergeResult.needsDump else { return mergeResult }
        guard atomicConf.wrappedValue != nil else { throw SessionUtilError.nilConfigObject }
        
        let userPublicKey: String = getUserHexEncodedPublicKey(db)
        
        // Since we are doing direct memory manipulation we are using an `Atomic` type which has
        // blocking access in it's `mutate` closure
        let maybeProfileData: ProfileData? = atomicConf.mutate { conf -> ProfileData? in
            // A profile must have a name so if this is null then it's invalid and can be ignored
            guard let profileNamePtr: UnsafePointer<CChar> = user_profile_get_name(conf) else {
                return nil
            }
            
            let profileName: String = String(cString: profileNamePtr)
            let profilePic: user_profile_pic = user_profile_get_pic(conf)
            var profilePictureUrl: String? = nil
            var profilePictureKey: Data? = nil
            
            // Make sure the url and key exist before reading the memory
            if
                profilePic.keylen > 0,
                let profilePictureUrlPtr: UnsafePointer<CChar> = profilePic.url,
                let profilePictureKeyPtr: UnsafePointer<UInt8> = profilePic.key
            {
                profilePictureUrl = String(cString: profilePictureUrlPtr)
                profilePictureKey = Data(bytes: profilePictureKeyPtr, count: profilePic.keylen)
            }
            
            return (
                profileName: profileName,
                profilePictureUrl: profilePictureUrl,
                profilePictureKey: profilePictureKey
            )
        }
        
        // Only save the data in the database if it's valid
        guard let profileData: ProfileData = maybeProfileData else { return mergeResult }
        
        // Handle user profile changes
        try ProfileManager.updateProfileIfNeeded(
            db,
            publicKey: userPublicKey,
            name: profileData.profileName,
            avatarUpdate: {
                guard
                    let profilePictureUrl: String = profileData.profilePictureUrl,
                    let profileKey: Data = profileData.profilePictureKey
                else { return .remove }
                
                return .updateTo(
                    url: profilePictureUrl,
                    key: profileKey,
                    fileName: nil
                )
            }(),
            sentTimestamp: latestConfigUpdateSentTimestamp,
            calledFromConfigHandling: true
        )
        
        // Create a contact for the current user if needed (also force-approve the current user
        // in case the account got into a weird state or restored directly from a migration)
        let userContact: Contact = Contact.fetchOrCreate(db, id: userPublicKey)
        
        if !userContact.isTrusted || !userContact.isApproved || !userContact.didApproveMe {
            try userContact.save(db)
            try Contact
                .filter(id: userPublicKey)
                .updateAll( // Handling a config update so don't use `updateAllAndConfig`
                    db,
                    Contact.Columns.isTrusted.set(to: true),    // Always trust the current user
                    Contact.Columns.isApproved.set(to: true),
                    Contact.Columns.didApproveMe.set(to: true)
                )
        }
        
        return mergeResult
    }
    
    // MARK: - Outgoing Changes
    
    static func update(
        profile: Profile,
        in atomicConf: Atomic<UnsafeMutablePointer<config_object>?>
    ) throws -> ConfResult {
        guard atomicConf.wrappedValue != nil else { throw SessionUtilError.nilConfigObject }
        
        // Since we are doing direct memory manipulation we are using an `Atomic` type which has
        // blocking access in it's `mutate` closure
        return atomicConf.mutate { conf in
            // Update the name
            var updatedName: [CChar] = profile.name
                .bytes
                .map { CChar(bitPattern: $0) }
            user_profile_set_name(conf, &updatedName)
            
            // Either assign the updated profile pic, or sent a blank profile pic (to remove the current one)
            let profilePic: user_profile_pic? = {
                guard
                    let profilePictureUrl: String = profile.profilePictureUrl,
                    let profileEncryptionKey: Data = profile.profileEncryptionKey
                else { return nil }
                
                let updatedUrl: [CChar] = profilePictureUrl
                    .bytes
                    .map { CChar(bitPattern: $0) }
                let updatedKey: [UInt8] = profileEncryptionKey
                    .bytes
                
                return updatedUrl.withUnsafeBufferPointer { urlPtr in
                    updatedKey.withUnsafeBufferPointer { keyPtr in
                        user_profile_pic(
                            url: urlPtr.baseAddress,
                            key: keyPtr.baseAddress,
                            keylen: updatedKey.count
                        )
                    }
                }
            }()
            user_profile_set_pic(conf, (profilePic ?? user_profile_pic()))
            
            return ConfResult(
                needsPush: config_needs_push(conf),
                needsDump: config_needs_dump(conf)
            )
        }
    }
}
