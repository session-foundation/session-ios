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
            let profilePictureUrl: String? = String(libSessionVal: profilePic.url, nullIfEmpty: true)
            
            // Make sure the url and key exists before reading the memory
            return (
                profileName: profileName,
                profilePictureUrl: profilePictureUrl,
                profilePictureKey: (profilePictureUrl == nil ? nil :
                    Data(
                        libSessionVal: profilePic.url,
                        count: ProfileManager.avatarAES256KeyByteLength
                    )
                )
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
            var updatedName: [CChar] = profile.name.cArray
            user_profile_set_name(conf, &updatedName)
            
            // Either assign the updated profile pic, or sent a blank profile pic (to remove the current one)
            var profilePic: user_profile_pic = user_profile_pic()
            profilePic.url = profile.profilePictureUrl.toLibSession()
            profilePic.key = profile.profileEncryptionKey.toLibSession()
            user_profile_set_pic(conf, profilePic)
            
            return ConfResult(
                needsPush: config_needs_push(conf),
                needsDump: config_needs_dump(conf)
            )
        }
    }
}
