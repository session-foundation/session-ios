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
        Profile.Columns.displayPictureEncryptionKey
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
        oldState: [LibSession.ObservableKey: Any],
        serverTimestampMs: Int64
    ) throws {
        guard configNeedsDump(config) else { return }
        guard case .userProfile(let conf) = config else { throw LibSessionError.invalidConfigObject }
        
        // A profile must have a name so if this is null then it's invalid and can be ignored
        guard let profileNamePtr: UnsafePointer<CChar> = user_profile_get_name(conf) else { return }
        
        let profileName: String = String(cString: profileNamePtr)
        let displayPic: user_profile_pic = user_profile_get_pic(conf)
        let displayPictureUrl: String? = displayPic.get(\.url, nullIfEmpty: true)
        let updatedProfile: Profile = Profile(
            id: userSessionId.hexString,
            name: profileName,
            displayPictureUrl: (oldState[.profile(userSessionId.hexString)] as? Profile)?.displayPictureUrl
        )
        
        if
            let profile: Profile = oldState[.profile(userSessionId.hexString)] as? Profile,
            profile != updatedProfile
        {
            db.addChange(updatedProfile, forKey: .profile(updatedProfile.id))
        }
        
        // Handle user profile changes
        try Profile.updateIfNeeded(
            db,
            publicKey: userSessionId.hexString,
            displayNameUpdate: .currentUserUpdate(profileName),
            displayPictureUpdate: {
                guard
                    let displayPictureUrl: String = displayPictureUrl,
                    let filePath: String = try? dependencies[singleton: .displayPictureManager]
                        .path(for: displayPictureUrl)
                else { return .currentUserRemove }
                
                return .currentUserUpdateTo(
                    url: displayPictureUrl,
                    key: displayPic.get(\.key),
                    filePath: filePath
                )
            }(),
            sentTimestamp: TimeInterval(Double(serverTimestampMs) / 1000),
            using: dependencies
        )
        
        // Update the 'Note to Self' visibility and priority
        let threadInfo: LibSession.PriorityVisibilityInfo? = try? SessionThread
            .filter(id: userSessionId.hexString)
            .select(.id, .variant, .pinnedPriority, .shouldBeVisible)
            .asRequest(of: LibSession.PriorityVisibilityInfo.self)
            .fetchOne(db)
        let targetPriority: Int32 = user_profile_get_nts_priority(conf)
        
        // Create the 'Note to Self' thread if it doesn't exist
        if let threadInfo: LibSession.PriorityVisibilityInfo = threadInfo {
            let threadChanges: [ConfigColumnAssignment] = [
                ((threadInfo.shouldBeVisible == LibSession.shouldBeVisible(priority: targetPriority)) ? nil :
                    SessionThread.Columns.shouldBeVisible.set(to: LibSession.shouldBeVisible(priority: targetPriority))
                ),
                (threadInfo.pinnedPriority == targetPriority ? nil :
                    SessionThread.Columns.pinnedPriority.set(to: targetPriority)
                )
            ].compactMap { $0 }
            
            if !threadChanges.isEmpty {
                try SessionThread
                    .filter(id: userSessionId.hexString)
                    .updateAllAndConfig(
                        db,
                        threadChanges,
                        using: dependencies
                    )
            }
        }
        else {
            // If the 'Note to Self' conversation is hidden then we should trigger the proper
            // `deleteOrLeave` behaviour
            if !LibSession.shouldBeVisible(priority: targetPriority) {
                try SessionThread.deleteOrLeave(
                    db,
                    type: .hideContactConversation,
                    threadId: userSessionId.hexString,
                    threadVariant: .contact,
                    using: dependencies
                )
            }
            else {
                try SessionThread.upsert(
                    db,
                    id: userSessionId.hexString,
                    variant: .contact,
                    values: SessionThread.TargetValues(
                        shouldBeVisible: .setTo(LibSession.shouldBeVisible(priority: targetPriority)),
                        pinnedPriority: .setTo(targetPriority)
                    ),
                    using: dependencies
                )
            }
        }
        
        // Update the 'Note to Self' disappearing messages configuration
        let targetExpiry: Int32 = user_profile_get_nts_expiry(conf)
        let targetIsEnable: Bool = targetExpiry > 0
        let targetConfig: DisappearingMessagesConfiguration = DisappearingMessagesConfiguration(
            threadId: userSessionId.hexString,
            isEnabled: targetIsEnable,
            durationSeconds: TimeInterval(targetExpiry),
            type: targetIsEnable ? .disappearAfterSend : .unknown
        )
        let localConfig: DisappearingMessagesConfiguration = try DisappearingMessagesConfiguration
            .fetchOne(db, id: userSessionId.hexString)
            .defaulting(to: DisappearingMessagesConfiguration.defaultWith(userSessionId.hexString))
        
        if targetConfig != localConfig {
            try targetConfig
                .saved(db)
                .clearUnrelatedControlMessages(
                    db,
                    threadVariant: .contact,
                    using: dependencies
                )
        }
        
        // Notify of settings change if needed
        let checkForCommunityMessageRequestsKey: LibSession.ObservableKey = .setting(Setting.BoolKey.checkForCommunityMessageRequests)
        let oldCheckForCommunityMessageRequests: Bool? = oldState[checkForCommunityMessageRequestsKey] as? Bool
        let newCheckForCommunityMessageRequests: Bool = get(.checkForCommunityMessageRequests)
        
        if
            oldCheckForCommunityMessageRequests != nil &&
            oldCheckForCommunityMessageRequests != newCheckForCommunityMessageRequests
        {
            db.addChange(newCheckForCommunityMessageRequests, forKey: checkForCommunityMessageRequestsKey)
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
        guard case .userProfile(let conf) = config else { throw LibSessionError.invalidConfigObject }
        
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
        guard case .userProfile(let conf) = config else { throw LibSessionError.invalidConfigObject }
        
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
    
    @discardableResult func updateProfile(
        displayName: String,
        displayPictureUrl: String?,
        displayPictureEncryptionKey: Data?
    ) throws -> Profile? {
        guard case .userProfile(let conf) = config(for: .userProfile, sessionId: userSessionId) else {
            throw LibSessionError.invalidConfigObject
        }
        
        // Get the old values to determine if something changed
        let oldName: String? = user_profile_get_name(conf).map { String(cString: $0) }
        let oldDisplayPic: user_profile_pic = user_profile_get_pic(conf)
        let oldDisplayPictureUrl: String? = oldDisplayPic.get(\.url, nullIfEmpty: true)
        
        // Update the name
        var cUpdatedName: [CChar] = try displayName.cString(using: .utf8) ?? {
            throw LibSessionError.invalidCConversion
        }()
        user_profile_set_name(conf, &cUpdatedName)
        try LibSessionError.throwIfNeeded(conf)
        
        // Either assign the updated profile pic, or sent a blank profile pic (to remove the current one)
        var profilePic: user_profile_pic = user_profile_pic()
        profilePic.set(\.url, to: displayPictureUrl)
        profilePic.set(\.key, to: displayPictureEncryptionKey)
        user_profile_set_pic(conf, profilePic)
        try LibSessionError.throwIfNeeded(conf)
        
        /// Add a pending observation to notify any observers of the change once it's committed
        if displayName != oldName || displayPictureUrl != oldDisplayPictureUrl {
            return Profile(
                id: userSessionId.hexString,
                name: displayName,
                displayPictureUrl: displayPictureUrl
            )
        }
        
        return nil
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
