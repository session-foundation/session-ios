// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtil
import SessionUtilitiesKit

internal extension SessionUtil {
    static let columnsRelatedToUserProfile: [Profile.Columns] = [
        Profile.Columns.name,
        Profile.Columns.profilePictureUrl,
        Profile.Columns.profileEncryptionKey
    ]
    
    // MARK: - Incoming Changes
    
    static func handleUserProfileUpdate(
        _ db: Database,
        in conf: UnsafeMutablePointer<config_object>?,
        mergeNeedsDump: Bool,
        latestConfigSentTimestampMs: Int64,
        using dependencies: Dependencies = Dependencies()
    ) throws {
        typealias ProfileData = (profileName: String, profilePictureUrl: String?, profilePictureKey: Data?)
        
        guard mergeNeedsDump else { return }
        guard conf != nil else { throw SessionUtilError.nilConfigObject }
        
        // A profile must have a name so if this is null then it's invalid and can be ignored
        guard let profileNamePtr: UnsafePointer<CChar> = user_profile_get_name(conf) else { return }
        
        let userPublicKey: String = getUserHexEncodedPublicKey(db)
        let profileName: String = String(cString: profileNamePtr)
        let profilePic: user_profile_pic = user_profile_get_pic(conf)
        let profilePictureUrl: String? = String(libSessionVal: profilePic.url, nullIfEmpty: true)
        
        // Handle user profile changes
        try ProfileManager.updateProfileIfNeeded(
            db,
            publicKey: userPublicKey,
            name: profileName,
            avatarUpdate: {
                guard let profilePictureUrl: String = profilePictureUrl else { return .remove }
                
                return .updateTo(
                    url: profilePictureUrl,
                    key: Data(
                        libSessionVal: profilePic.key,
                        count: ProfileManager.avatarAES256KeyByteLength
                    ),
                    fileName: nil
                )
            }(),
            sentTimestamp: (TimeInterval(latestConfigSentTimestampMs) / 1000),
            calledFromConfigHandling: true,
            using: dependencies
        )
        
        // Update the 'Note to Self' visibility and priority
        let threadInfo: PriorityVisibilityInfo? = try? SessionThread
            .filter(id: userPublicKey)
            .select(.id, .variant, .pinnedPriority, .shouldBeVisible)
            .asRequest(of: PriorityVisibilityInfo.self)
            .fetchOne(db)
        let targetPriority: Int32 = user_profile_get_nts_priority(conf)
        
        // Create the 'Note to Self' thread if it doesn't exist
        if let threadInfo: PriorityVisibilityInfo = threadInfo {
            let threadChanges: [ConfigColumnAssignment] = [
                ((threadInfo.shouldBeVisible == SessionUtil.shouldBeVisible(priority: targetPriority)) ? nil :
                    SessionThread.Columns.shouldBeVisible.set(to: SessionUtil.shouldBeVisible(priority: targetPriority))
                ),
                (threadInfo.pinnedPriority == targetPriority ? nil :
                    SessionThread.Columns.pinnedPriority.set(to: targetPriority)
                )
            ].compactMap { $0 }
            
            if !threadChanges.isEmpty {
                try SessionThread
                    .filter(id: userPublicKey)
                    .updateAll( // Handling a config update so don't use `updateAllAndConfig`
                        db,
                        threadChanges
                    )
            }
        }
        else {
            try SessionThread
                .fetchOrCreate(
                    db,
                    id: userPublicKey,
                    variant: .contact,
                    shouldBeVisible: SessionUtil.shouldBeVisible(priority: targetPriority)
                )
            
            try SessionThread
                .filter(id: userPublicKey)
                .updateAll( // Handling a config update so don't use `updateAllAndConfig`
                    db,
                    SessionThread.Columns.pinnedPriority.set(to: targetPriority)
                )
            
            // If the 'Note to Self' conversation is hidden then we should trigger the proper
            // `deleteOrLeave` behaviour (for 'Note to Self' this will leave the conversation
            // but remove the associated interactions)
            if !SessionUtil.shouldBeVisible(priority: targetPriority) {
                try SessionThread
                    .deleteOrLeave(
                        db,
                        threadId: userPublicKey,
                        threadVariant: .contact,
                        groupLeaveType: .forced,
                        calledFromConfigHandling: true
                    )
            }
        }
        
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
    }
    
    // MARK: - Outgoing Changes
    
    static func update(
        profile: Profile,
        in conf: UnsafeMutablePointer<config_object>?
    ) throws {
        guard conf != nil else { throw SessionUtilError.nilConfigObject }
        
        // Update the name
        var updatedName: [CChar] = profile.name.cArray.nullTerminated()
        user_profile_set_name(conf, &updatedName)
        
        // Either assign the updated profile pic, or sent a blank profile pic (to remove the current one)
        var profilePic: user_profile_pic = user_profile_pic()
        profilePic.url = profile.profilePictureUrl.toLibSession()
        profilePic.key = profile.profileEncryptionKey.toLibSession()
        user_profile_set_pic(conf, profilePic)
    }
    
    static func updateNoteToSelf(
        priority: Int32,
        in conf: UnsafeMutablePointer<config_object>?
    ) throws {
        guard conf != nil else { throw SessionUtilError.nilConfigObject }
        
        user_profile_set_nts_priority(conf, priority)
    }
}
