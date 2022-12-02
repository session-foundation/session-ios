// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtil
import SessionUtilitiesKit

internal extension SessionUtil {
    static func handleUserProfileUpdate(
        _ db: Database,
        in target: Target,
        needsDump: Bool,
        latestConfigUpdateSentTimestamp: TimeInterval
    ) throws {
        typealias ProfileData = (profileName: String, profilePictureUrl: String?, profilePictureKey: Data?)
        
        guard needsDump else { return }
        guard target.conf.wrappedValue != nil else { throw SessionUtilError.nilConfigObject }
        
        let userPublicKey: String = getUserHexEncodedPublicKey(db)
        
        // Since we are doing direct memory manipulation we are using an `Atomic` type which has
        // blocking access in it's `mutate` closure
        let maybeProfileData: ProfileData? = target.conf.mutate { conf -> ProfileData? in
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
                let profilePictureKeyPtr: UnsafePointer<CChar> = profilePic.key
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
        guard let profileData: ProfileData = maybeProfileData else { return }
        
        // Profile (also force-approve the current user in case the account got into a weird state or
        // restored directly from a migration)
        try MessageReceiver.updateProfileIfNeeded(
            db,
            publicKey: userPublicKey,
            name: profileData.profileName,
            profilePictureUrl: profileData.profilePictureUrl,
            profileKey: profileData.profilePictureKey,
            sentTimestamp: latestConfigUpdateSentTimestamp
        )
        try Contact(id: userPublicKey)
            .with(
                isApproved: true,
                didApproveMe: true
            )
            .save(db)
    }
    
    @discardableResult static func update(
        profile: Profile,
        in target: Target
    ) throws -> ConfResult {
        guard target.conf.wrappedValue != nil else { throw SessionUtilError.nilConfigObject }
        
        // Since we are doing direct memory manipulation we are using an `Atomic` type which has
        // blocking access in it's `mutate` closure
        return target.conf.mutate { conf in
            // Update the name
            user_profile_set_name(conf, profile.name)
            
            let profilePic: user_profile_pic? = profile.profilePictureUrl?
                .bytes
                .map { CChar(bitPattern: $0) }
                .withUnsafeBufferPointer { profileUrlPtr in
                    let profileKey: [CChar]? = profile.profileEncryptionKey?
                        .bytes
                        .map { CChar(bitPattern: $0) }
                    
                    return profileKey?.withUnsafeBufferPointer { profileKeyPtr in
                        user_profile_pic(
                            url: profileUrlPtr.baseAddress,
                            key: profileKeyPtr.baseAddress,
                            keylen: (profileKey?.count ?? 0)
                        )
                    }
                }
            
            if let profilePic: user_profile_pic = profilePic {
                user_profile_set_pic(conf, profilePic)
            }
            
            return (
                needsPush: config_needs_push(conf),
                needsDump: config_needs_dump(conf)
            )
        }
    }
}
