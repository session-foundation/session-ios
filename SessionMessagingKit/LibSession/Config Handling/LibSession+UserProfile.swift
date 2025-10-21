// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtil
import SessionUtilitiesKit

// MARK: - LibSession

internal extension LibSession {
    static let columnsRelatedToUserProfile: [Profile.Columns] = [
        Profile.Columns.name,
        Profile.Columns.displayPictureUrl,
        Profile.Columns.displayPictureEncryptionKey,
        Profile.Columns.profileLastUpdated
    ]
    
    static let syncedSettings: [String] = [
        Setting.BoolKey.checkForCommunityMessageRequests.rawValue
    ]
}

// MARK: - Incoming Changes

internal extension LibSessionCacheType {
    func handleUserProfileUpdate(
        _ db: ObservingDatabase,
        in config: LibSession.Config?,
        oldState: [ObservableKey: Any]
    ) throws {
        guard configNeedsDump(config) else { return }
        guard case .userProfile(let conf) = config else {
            throw LibSessionError.invalidConfigObject(wanted: .userProfile, got: config)
        }
        
        // A profile must have a name so if this is null then it's invalid and can be ignored
        guard let profileNamePtr: UnsafePointer<CChar> = user_profile_get_name(conf) else { return }
        
        let profileName: String = String(cString: profileNamePtr)
        let displayPic: user_profile_pic = user_profile_get_pic(conf)
        let displayPictureUrl: String? = displayPic.get(\.url, nullIfEmpty: true)
        let displayPictureEncryptionKey: Data? = displayPic.get(\.key, nullIfEmpty: true)
        let profileLastUpdateTimestamp: TimeInterval = TimeInterval(user_profile_get_profile_updated(conf))
        let updatedProfile: Profile = Profile(
            id: userSessionId.hexString,
            name: profileName,
            displayPictureUrl: (oldState[.profile(userSessionId.hexString)] as? Profile)?.displayPictureUrl,
            profileLastUpdated: profileLastUpdateTimestamp
        )
        
        if let profile: Profile = oldState[.profile(userSessionId.hexString)] as? Profile {
            if profile.name != updatedProfile.name {
                db.addProfileEvent(id: updatedProfile.id, change: .name(updatedProfile.name))
            }
            
            if profile.displayPictureUrl != updatedProfile.displayPictureUrl {
                db.addProfileEvent(id: updatedProfile.id, change: .displayPictureUrl(updatedProfile.displayPictureUrl))
            }
        }
        
        // Handle user profile changes
        try Profile.updateIfNeeded(
            db,
            publicKey: userSessionId.hexString,
            displayNameUpdate: .currentUserUpdate(profileName),
            displayPictureUpdate: {
                guard
                    let displayPictureUrl: String = displayPictureUrl,
                    let displayPictureEncryptionKey: Data = displayPictureEncryptionKey
                else { return .currentUserRemove }
                
                return .currentUserUpdateTo(
                    url: displayPictureUrl,
                    key: displayPictureEncryptionKey,
                    sessionProProof: getProProof(), // TODO: double check if this is needed after Pro Proof is implemented
                    isReupload: false
                )
            }(),
            profileUpdateTimestamp: profileLastUpdateTimestamp,
            suppressUserProfileConfigUpdate: true,
            using: dependencies
        )
        
        // Kick off a job to download the display picture
        if
            let url: String = displayPictureUrl,
            let key: Data = displayPictureEncryptionKey
        {
            dependencies[singleton: .jobRunner].add(
                db,
                job: Job(
                    variant: .displayPictureDownload,
                    shouldBeUnique: true,
                    details: DisplayPictureDownloadJob.Details(
                        target: .profile(id: userSessionId.hexString, url: url, encryptionKey: key),
                        timestamp: profileLastUpdateTimestamp
                    )
                ),
                canStartJob: dependencies[singleton: .appContext].isMainApp
            )
        }
        
        // Extract the 'Note to Self' conversation settings
        let targetPriority: Int32 = user_profile_get_nts_priority(conf)
        let targetExpiry: Int32 = user_profile_get_nts_expiry(conf)
        let targetIsEnable: Bool = targetExpiry > 0
        let targetConfig: DisappearingMessagesConfiguration = DisappearingMessagesConfiguration(
            threadId: userSessionId.hexString,
            isEnabled: targetIsEnable,
            durationSeconds: TimeInterval(targetExpiry),
            type: targetIsEnable ? .disappearAfterSend : .unknown
        )
        
        // The 'Note to Self' conversation should always exist so all we need to do is create/update
        // it to match the desired state
        _ = try SessionThread.upsert(
            db,
            id: userSessionId.hexString,
            variant: .contact,
            values: SessionThread.TargetValues(
                shouldBeVisible: .setTo(LibSession.shouldBeVisible(priority: targetPriority)),
                pinnedPriority: .setTo(targetPriority),
                disappearingMessagesConfig: .setTo(targetConfig)
            ),
            using: dependencies
        )
        
        // Notify of settings change if needed
        let checkForCommunityMessageRequestsKey: ObservableKey = .setting(.checkForCommunityMessageRequests)
        let oldCheckForCommunityMessageRequests: Bool? = oldState[checkForCommunityMessageRequestsKey] as? Bool
        let newCheckForCommunityMessageRequests: Bool = get(.checkForCommunityMessageRequests)
        
        if
            oldCheckForCommunityMessageRequests != nil &&
            oldCheckForCommunityMessageRequests != newCheckForCommunityMessageRequests
        {
            db.addEvent(newCheckForCommunityMessageRequests, forKey: checkForCommunityMessageRequestsKey)
        }
        
        // Create a contact for the current user if needed (also force-approve the current user
        // in case the account got into a weird state or restored directly from a migration)
        let userContact: Contact = Contact.fetchOrCreate(db, id: userSessionId.hexString, using: dependencies)
        
        if !userContact.isTrusted || !userContact.isApproved || !userContact.didApproveMe {
            try userContact.upsert(db)
            try Contact
                .filter(id: userSessionId.hexString)
                .updateAllAndConfig(
                    db,
                    Contact.Columns.isTrusted.set(to: true),    // Always trust the current user
                    Contact.Columns.isApproved.set(to: true),
                    Contact.Columns.didApproveMe.set(to: true),
                    using: dependencies
                )
            
            db.addContactEvent(id: userSessionId.hexString, change: .isTrusted(true))
            db.addContactEvent(id: userSessionId.hexString, change: .isApproved(true))
            db.addContactEvent(id: userSessionId.hexString, change: .didApproveMe(true))
        }
    }
}

// MARK: - Outgoing Changes

internal extension LibSession {
    static func updateNoteToSelf(
        priority: Int32? = nil,
        disappearingMessagesConfig: DisappearingMessagesConfiguration? = nil,
        in config: Config?
    ) throws {
        guard case .userProfile(let conf) = config else {
            throw LibSessionError.invalidConfigObject(wanted: .userProfile, got: config)
        }
        
        if let priority: Int32 = priority {
            user_profile_set_nts_priority(conf, priority)
        }
        
        if let config: DisappearingMessagesConfiguration = disappearingMessagesConfig {
            user_profile_set_nts_expiry(conf, Int32(config.durationSeconds))
        }
    }
    
    static func updateSettings(
        checkForCommunityMessageRequests: Bool? = nil,
        in config: Config?
    ) throws {
        guard case .userProfile(let conf) = config else {
            throw LibSessionError.invalidConfigObject(wanted: .userProfile, got: config)
        }
        
        if let blindedMessageRequests: Bool = checkForCommunityMessageRequests {
            user_profile_set_blinded_msgreqs(conf, (blindedMessageRequests ? 1 : 0))
        }
    }
}

// MARK: - External Outgoing Changes

public extension LibSession {
    static func updateNoteToSelf(
        _ db: ObservingDatabase,
        priority: Int32? = nil,
        disappearingMessagesConfig: DisappearingMessagesConfiguration? = nil,
        using dependencies: Dependencies
    ) throws {
        try dependencies.mutate(cache: .libSession) { cache in
            try cache.performAndPushChange(db, for: .userProfile, sessionId: dependencies[cache: .general].sessionId) { config in
                try LibSession.updateNoteToSelf(
                    priority: priority,
                    disappearingMessagesConfig: disappearingMessagesConfig,
                    in: config
                )
            }
        }
    }
}

// MARK: - State Access

public extension LibSession.Cache {
    var displayName: String? {
        guard
            case .userProfile(let conf) = config(for: .userProfile, sessionId: userSessionId),
            let profileNamePtr: UnsafePointer<CChar> = user_profile_get_name(conf)
        else { return nil }
        
        return String(cString: profileNamePtr)
    }
    
    func updateProfile(
        displayName: Update<String>,
        displayPictureUrl: Update<String?>,
        displayPictureEncryptionKey: Update<Data?>,
        isReuploadProfilePicture: Bool
    ) throws {
        guard let config: LibSession.Config = config(for: .userProfile, sessionId: userSessionId) else {
            throw LibSessionError.invalidConfigObject(wanted: .userProfile, got: nil)
        }
        guard case .userProfile(let conf) = config else {
            throw LibSessionError.invalidConfigObject(wanted: .userProfile, got: config)
        }
        
        // Get the old values to determine if something changed
        let oldName: String? = user_profile_get_name(conf).map { String(cString: $0) }
        let oldNameFallback: String = (oldName ?? "")
        let oldDisplayPic: user_profile_pic = user_profile_get_pic(conf)
        let oldDisplayPictureUrl: String? = oldDisplayPic.get(\.url, nullIfEmpty: true)
        let oldDisplayPictureKey: Data? = oldDisplayPic.get(\.key, nullIfEmpty: true)
        
        // Update the name
        var cUpdatedName: [CChar] = try displayName.or(oldNameFallback).cString(using: .utf8) ?? {
            throw LibSessionError.invalidCConversion
        }()
        user_profile_set_name(conf, &cUpdatedName)
        try LibSessionError.throwIfNeeded(conf)
        
        // Either assign the updated profile pic, or sent a blank profile pic (to remove the current one)
        var profilePic: user_profile_pic = user_profile_pic()
        profilePic.set(\.url, to: displayPictureUrl.or(oldDisplayPictureUrl))
        profilePic.set(\.key, to: displayPictureEncryptionKey.or(oldDisplayPictureKey))
        
        switch isReuploadProfilePicture {
            case true: user_profile_set_reupload_pic(conf, profilePic)
            case false: user_profile_set_pic(conf, profilePic)
        }
        
        try LibSessionError.throwIfNeeded(conf)
        
        /// Add a pending observation to notify any observers of the change once it's committed
        if displayName.or("") != oldName {
            addEvent(
                key: .profile(userSessionId.hexString),
                value: ProfileEvent(id: userSessionId.hexString, change: .name(displayName.or(oldNameFallback)))
            )
        }
        
        if displayPictureUrl.or(oldDisplayPictureUrl) != oldDisplayPictureUrl {
            addEvent(
                key: .profile(userSessionId.hexString),
                value: ProfileEvent(
                    id: userSessionId.hexString,
                    change: .displayPictureUrl(displayPictureUrl.or(oldDisplayPictureUrl))
                )
            )
        }
    }
}

// MARK: - ProfileInfo

public extension LibSession {
    struct ProfileInfo {
        let name: String
        let profilePictureUrl: String?
        let profileEncryptionKey: Data?
    }
}

// MARK: - C Conformance

extension user_profile_pic: CAccessible & CMutable {}
