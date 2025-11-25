// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtil
import SessionNetworkingKit
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
                    type: .config
                )
            }(),
            proUpdate: {
                guard
                    let proConfig: SessionPro.ProConfig = self.proConfig,
                    proConfig.rotatingPrivateKey.count >= 32,
                    let rotatingKeyPair: KeyPair = try? dependencies[singleton: .crypto].tryGenerate(
                        .ed25519KeyPair(seed: proConfig.rotatingPrivateKey.prefix(upTo: 32))
                    )
                else { return .none }
                
                let features: SessionPro.Features = SessionPro.Features(user_profile_get_pro_features(conf))
                let status: SessionPro.DecodedStatus = dependencies[singleton: .sessionProManager].proStatus(
                    for: proConfig.proProof,
                    verifyPubkey: rotatingKeyPair.publicKey,
                    atTimestampMs: dependencies[cache: .snodeAPI].currentOffsetTimestampMs()
                )
                
                return .currentUserUpdate(
                    SessionPro.DecodedProForMessage(
                        status: status,
                        proProof: proConfig.proProof,
                        features: features
                    )
                )
            }(),
            profileUpdateTimestamp: profileLastUpdateTimestamp,
            cacheSource: .value((oldState[.profile(userSessionId.hexString)] as? Profile), fallback: .database),
            suppressUserProfileConfigUpdate: true,
            currentUserSessionIds: [userSessionId.hexString],
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
        
        // Update the SessionProManager with these changes
        db.afterCommit { [sessionProManager = dependencies[singleton: .sessionProManager]] in
            Task { await sessionProManager.updateWithLatestFromUserConfig() }
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
    
    var proConfig: SessionPro.ProConfig? {
        var cProConfig: pro_pro_config = pro_pro_config()
        
        guard
            case .userProfile(let conf) = config(for: .userProfile, sessionId: userSessionId),
            user_profile_get_pro_config(conf, &cProConfig)
        else { return nil }
        
        return SessionPro.ProConfig(cProConfig)
    }
    
    var proAccessExpiryTimestampMs: UInt64 {
        guard case .userProfile(let conf) = config(for: .userProfile, sessionId: userSessionId) else { return 0 }
        
        return user_profile_get_pro_access_expiry_ms(conf)
    }
    
    /// This function should not be called outside of the `Profile.updateIfNeeded` function to avoid duplicating changes and events,
    /// as a result this function doesn't emit profile change events itself (use `Profile.updateLocal` instead)
    func updateProfile(
        displayName: Update<String>,
        displayPictureUrl: Update<String?>,
        displayPictureEncryptionKey: Update<Data?>,
        proFeatures: Update<SessionPro.Features>,
        isReuploadProfilePicture: Bool
    ) throws {
        guard let config: LibSession.Config = config(for: .userProfile, sessionId: userSessionId) else {
            throw LibSessionError.invalidConfigObject(wanted: .userProfile, got: nil)
        }
        guard case .userProfile(let conf) = config else {
            throw LibSessionError.invalidConfigObject(wanted: .userProfile, got: config)
        }
        
        /// Get the old values to determine if something changed
        let oldName: String? = user_profile_get_name(conf).map { String(cString: $0) }
        let oldNameFallback: String = (oldName ?? "")
        let oldDisplayPic: user_profile_pic = user_profile_get_pic(conf)
        let oldDisplayPictureUrl: String? = oldDisplayPic.get(\.url, nullIfEmpty: true)
        let oldDisplayPictureKey: Data? = oldDisplayPic.get(\.key, nullIfEmpty: true)
        let oldProFeatures: SessionPro.Features = SessionPro.Features(user_profile_get_pro_features(conf))
        
        /// Either assign the updated profile pic, or sent a blank profile pic (to remove the current one)
        ///
        /// **Note:** We **MUST** update the profile picture first because doing so will result in any subsequent profile changes
        /// which impact the `profile_updated` timestamp being routed to the "reupload" storage instead of the "standard"
        /// storage - if we don't do this first then the "standard" timestamp will also get updated which can result in both timestamps
        /// matching (in which case the "standard" profile wins and the re-uploaded content would be ignored)
        if displayPictureUrl.or(oldDisplayPictureUrl) != oldDisplayPictureUrl {
            var profilePic: user_profile_pic = user_profile_pic()
            profilePic.set(\.url, to: displayPictureUrl.or(oldDisplayPictureUrl))
            profilePic.set(\.key, to: displayPictureEncryptionKey.or(oldDisplayPictureKey))
            
            switch isReuploadProfilePicture {
                case true: user_profile_set_reupload_pic(conf, profilePic)
                case false: user_profile_set_pic(conf, profilePic)
            }
            
            try LibSessionError.throwIfNeeded(conf)
        }
        
        /// Update the name
        ///
        /// **Note:** Setting the name (even if it hasn't changed) currently results in a timestamp change so only do this if it was
        /// changed (this will be fixed in `libSession v1.5.8`)
        if displayName.or("") != oldName {
            var cUpdatedName: [CChar] = try displayName.or(oldNameFallback).cString(using: .utf8) ?? {
                throw LibSessionError.invalidCConversion
            }()
            user_profile_set_name(conf, &cUpdatedName)
            try LibSessionError.throwIfNeeded(conf)
        }
        
        /// Update the pro features
        ///
        /// **Note:** Setting the name (even if it hasn't changed) currently results in a timestamp change so only do this if it was
        /// changed (this will be fixed in `libSession v1.5.8`)
        if proFeatures.or(.none) != oldProFeatures {
            user_profile_set_pro_badge(conf, proFeatures.or(.none).contains(.proBadge))
            user_profile_set_animated_avatar(conf, proFeatures.or(.none).contains(.animatedAvatar))
        }
    }
    
    func updateProConfig(proConfig: SessionPro.ProConfig) {
        guard case .userProfile(let conf) = config(for: .userProfile, sessionId: userSessionId) else { return }
        
        var cProConfig: pro_pro_config = proConfig.libSessionValue
        user_profile_set_pro_config(conf, &cProConfig)
    }
    
    func removeProConfig() {
        guard case .userProfile(let conf) = config(for: .userProfile, sessionId: userSessionId) else { return }
        
        user_profile_remove_pro_config(conf)
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
