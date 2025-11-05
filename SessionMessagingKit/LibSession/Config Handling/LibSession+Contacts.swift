// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtil
import SessionUtilitiesKit

// MARK: - Size Restrictions

public extension LibSession {
    static var sizeMaxNameBytes: Int { CONTACT_MAX_NAME_LENGTH }
    static var sizeMaxNicknameBytes: Int { CONTACT_MAX_NAME_LENGTH }
    static var sizeMaxProfileUrlBytes: Int { PROFILE_PIC_MAX_URL_LENGTH }
}

// MARK: - Contacts Handling

internal extension LibSession {
    static let columnsRelatedToContacts: [ColumnExpression] = [
        Contact.Columns.isApproved,
        Contact.Columns.isBlocked,
        Contact.Columns.didApproveMe,
        Profile.Columns.name,
        Profile.Columns.nickname,
        Profile.Columns.displayPictureUrl,
        Profile.Columns.displayPictureEncryptionKey,
        Profile.Columns.profileLastUpdated,
        DisappearingMessagesConfiguration.Columns.isEnabled,
        DisappearingMessagesConfiguration.Columns.type,
        DisappearingMessagesConfiguration.Columns.durationSeconds
    ]
}

// MARK: - Incoming Changes

internal extension LibSessionCacheType {
    func handleContactsUpdate(
        _ db: ObservingDatabase,
        in config: LibSession.Config?,
        oldState: [ObservableKey: Any]
    ) throws {
        guard configNeedsDump(config) else { return }
        guard case .contacts(let conf) = config else {
            throw LibSessionError.invalidConfigObject(wanted: .contacts, got: config)
        }
        
        // The current users contact data is handled separately so exclude it if it's present (as that's
        // actually a bug)
        let targetContactData: [String: ContactData] = try LibSession.extractContacts(
            from: conf,
            using: dependencies
        ).filter { $0.key != userSessionId.hexString }
        
        // Since we don't sync 100% of the data stored against the contact and profile objects we
        // need to only update the data we do have to ensure we don't overwrite anything that doesn't
        // get synced
        try targetContactData
            .forEach { sessionId, data in
                // Note: We only update the contact and profile records if the data has actually changed
                // in order to avoid triggering UI updates for every thread on the home screen (the DB
                // observation system can't differ between update calls which do and don't change anything)
                try Profile.updateIfNeeded(
                    db,
                    publicKey: sessionId,
                    displayNameUpdate: .contactUpdate(data.profile.name),
                    displayPictureUpdate: {
                        guard
                            let displayPictureUrl: String = data.profile.displayPictureUrl,
                            let displayPictureEncryptionKey: Data = data.profile.displayPictureEncryptionKey
                        else { return .currentUserRemove }
                        
                        return .contactUpdateTo(
                            url: displayPictureUrl,
                            key: displayPictureEncryptionKey
                        )
                    }(),
                    nicknameUpdate: .set(to: data.profile.nickname),
                    profileUpdateTimestamp: data.profile.profileLastUpdated,
                    cacheSource: .database,
                    using: dependencies
                )
                
                /// Since message requests have no reverse, we should only handle setting `isApproved`
                /// and `didApproveMe` to `true`. This may prevent some weird edge cases where a config message
                /// swapping `isApproved` and `didApproveMe` to `false`
                let contact: Contact = Contact.fetchOrCreate(db, id: sessionId, using: dependencies)
                
                if
                    (contact.isApproved != data.contact.isApproved) ||
                    (contact.isBlocked != data.contact.isBlocked) ||
                    (contact.didApproveMe != data.contact.didApproveMe)
                {
                    db.addEvent(contact, forKey: .contact(contact.id))
                    try contact.upsert(db)
                    try Contact
                        .filter(id: sessionId)
                        .updateAllAndConfig(
                            db,
                            [
                                (!data.contact.isApproved || contact.isApproved == data.contact.isApproved ? nil :
                                    Contact.Columns.isApproved.set(to: true)
                                ),
                                (contact.isBlocked == data.contact.isBlocked ? nil :
                                    Contact.Columns.isBlocked.set(to: data.contact.isBlocked)
                                ),
                                (!data.contact.didApproveMe || contact.didApproveMe == data.contact.didApproveMe ? nil :
                                    Contact.Columns.didApproveMe.set(to: true)
                                )
                            ].compactMap { $0 },
                            using: dependencies
                        )
                    
                    if contact.isApproved != data.contact.isApproved {
                        db.addContactEvent(id: contact.id, change: .isApproved(data.contact.isApproved))
                        db.addEvent(contact.id, forKey: .messageRequestAccepted)
                    }
                    
                    if contact.didApproveMe != data.contact.didApproveMe {
                        db.addContactEvent(id: contact.id, change: .didApproveMe(data.contact.didApproveMe))
                    }
                    
                    if contact.isBlocked != data.contact.isBlocked {
                        db.addContactEvent(id: contact.id, change: .isBlocked(data.contact.isBlocked))
                    }
                }
                
                /// If the contact's `hidden` flag doesn't match the visibility of their conversation then create/delete the
                /// associated contact conversation accordingly
                let threadExists: Bool = ((try? SessionThread.exists(db, id: sessionId)) ?? false)
                
                if !LibSession.shouldBeVisible(priority: data.priority) && threadExists {
                    /// If we are hiding the conversation then kick the user from it if it's currently open then delete the thread
                    LibSession.kickFromConversationUIIfNeeded(removedThreadIds: [sessionId], using: dependencies)
                    
                    try SessionThread.deleteOrLeave(
                        db,
                        type: .deleteContactConversationAndMarkHidden,
                        threadId: sessionId,
                        threadVariant: .contact,
                        using: dependencies
                    )
                }
                else if LibSession.shouldBeVisible(priority: data.priority) {
                    /// If the thread should be visible then we should create/update it to match the desired state
                    let localConfig: DisappearingMessagesConfiguration = try DisappearingMessagesConfiguration
                        .fetchOne(db, id: sessionId)
                        .defaulting(to: DisappearingMessagesConfiguration.defaultWith(sessionId))
                    let disappearingMessagesConfigChanged: Bool = (
                        data.config.isValidV2Config() &&
                        data.config != localConfig
                    )
                    
                    _ = try SessionThread.upsert(
                        db,
                        id: sessionId,
                        variant: .contact,
                        values: SessionThread.TargetValues(
                            creationDateTimestamp: .setTo(data.created),
                            shouldBeVisible: .setTo(LibSession.shouldBeVisible(priority: data.priority)),
                            pinnedPriority: .setTo(data.priority),
                            disappearingMessagesConfig: (disappearingMessagesConfigChanged ?
                                .setTo(data.config) :
                                .useExisting
                            )
                        ),
                        using: dependencies
                    )
                }
            }
        
        /// Delete any contact/thread records which aren't in the config message
        let syncedContactIds: [String] = targetContactData
            .map { $0.key }
            .appending(userSessionId.hexString)
        let contactIdsToRemove: [String] = try Contact
            .filter(!syncedContactIds.contains(Contact.Columns.id))
            .select(.id)
            .asRequest(of: String.self)
            .fetchAll(db)
        let threadIdsToRemove: [String] = try SessionThread
            .filter(!syncedContactIds.contains(SessionThread.Columns.id))
            .filter(SessionThread.Columns.variant == SessionThread.Variant.contact)
            .filter(
                /// Only want to include include standard contact conversations (not blinded conversations)
                SessionThread.Columns.id > SessionId.Prefix.standard.rawValue &&
                SessionThread.Columns.id < SessionId.Prefix.standard.endOfRangeString
            )
            .select(.id)
            .asRequest(of: String.self)
            .fetchAll(db)
        
        /// When the user opens a brand new conversation this creates a "draft conversation" which has a hidden thread but no
        /// contact record, when we receive a contact update this "draft conversation" would be included in the
        /// `threadIdsToRemove` which would result in the user getting kicked from the screen and the thread removed, we
        /// want to avoid this (as it's essentially a bug) so find any conversations in this state and remove them from the list that
        /// will be pruned
        let threadT: TypedTableAlias<SessionThread> = TypedTableAlias()
        let contactT: TypedTableAlias<Contact> = TypedTableAlias()
        let draftConversationIds: [String] = try SQLRequest<String>("""
            SELECT \(threadT[.id])
            FROM \(SessionThread.self)
            LEFT JOIN \(Contact.self) ON \(contactT[.id]) = \(threadT[.id])
            WHERE (
                \(SQL("\(threadT[.id]) IN \(threadIdsToRemove)")) AND
                \(contactT[.id]) IS NULL
            )
        """).fetchAll(db)
        
        /// Consolidate the ids which should be removed
        let combinedIds: [String] = contactIdsToRemove
            .appending(contentsOf: threadIdsToRemove)
            .filter { !draftConversationIds.contains($0) }
        
        if !combinedIds.isEmpty {
            LibSession.kickFromConversationUIIfNeeded(removedThreadIds: combinedIds, using: dependencies)
            
            try Contact
                .filter(ids: combinedIds)
                .deleteAll(db)
            
            // Also need to remove any 'nickname' values since they are associated to contact data
            try Profile
                .filter(ids: combinedIds)
                .updateAllAndConfig(
                    db,
                    Profile.Columns.nickname.set(to: nil),
                    using: dependencies
                )
            
            // Delete the one-to-one conversations associated to the contact
            try SessionThread.deleteOrLeave(
                db,
                type: .deleteContactConversationAndContact,
                threadIds: combinedIds,
                threadVariant: .contact,
                using: dependencies
            )
            
            try LibSession.remove(
                db,
                volatileContactIds: combinedIds
                    .filter {
                        (try? SessionId.Prefix(from: $0)) != .blinded15 &&
                        (try? SessionId.Prefix(from: $0)) != .blinded25
                    },
                using: dependencies
            )
        }
    }
}

// MARK: - Outgoing Changes

public extension LibSession {
    static func upsert(
        contactData: [ContactUpdateInfo],
        in config: Config?,
        using dependencies: Dependencies
    ) throws {
        guard case .contacts(let conf) = config else {
            throw LibSessionError.invalidConfigObject(wanted: .contacts, got: config)
        }
        
        // The current users contact data doesn't need to sync so exclude it, we also don't want to sync
        // blinded message requests so exclude those as well
        let userSessionId: SessionId = dependencies[cache: .general].sessionId
        let targetContacts: [ContactUpdateInfo] = contactData
            .filter {
                $0.id != userSessionId.hexString &&
                (try? SessionId(from: $0.id))?.prefix == .standard
            }
        
        // If we only updated the current user contact then no need to continue
        guard !targetContacts.isEmpty else { return }        
        
        // Update the name
        try targetContacts
            .forEach { info in
                var contact: contacts_contact = contacts_contact()
                guard
                    var sessionId: [CChar] = info.id.cString(using: .utf8),
                    contacts_get_or_construct(conf, &contact, &sessionId)
                else {
                    /// It looks like there are some situations where this object might not get created correctly (and
                    /// will throw due to the implicit unwrapping) as a result we put it in a guard and throw instead
                    throw LibSessionError(
                        conf,
                        fallbackError: .getOrConstructFailedUnexpectedly,
                        logMessage: "Unable to upsert contact to LibSession"
                    )
                }
                
                /// Update the profile data (if there is one - users we have sent a message request to may not have profile info
                /// in certain situations)
                if let updatedName: String = info.name {
                    let oldAvatarUrl: String? = contact.get(\.profile_pic.url)
                    let oldAvatarKey: Data? = contact.get(\.profile_pic.key)
                    
                    contact.set(\.name, to: updatedName)
                    contact.set(\.nickname, to: info.nickname)
                    contact.set(\.profile_pic.url, to: info.displayPictureUrl)
                    contact.set(\.profile_pic.key, to: info.displayPictureEncryptionKey)
                    if let profileLastUpdated = info.profileLastUpdated {
                        contact.set(\.profile_updated, to: profileLastUpdated)
                    }
                    
                    if let profileLastUpdated: Int64 = info.profileLastUpdated {
                        contact.set(\.profile_updated, to: profileLastUpdated)
                    }
                    
                    // Attempts retrieval of the profile picture (will schedule a download if
                    // needed via a throttled subscription on another thread to prevent blocking)
                    //
                    // Note: Only trigger the avatar download if we are in the main app (don't
                    // want the extensions to trigger this as it can clog up their networking)
                    if
                        let updatedProfile: Profile = info.profile,
                        dependencies[singleton: .appContext].isMainApp && (
                            oldAvatarUrl != (info.displayPictureUrl ?? "") ||
                            oldAvatarKey != (info.displayPictureEncryptionKey ?? Data())
                        )
                    {
                        dependencies[singleton: .displayPictureManager].scheduleDownload(
                            for: .user(updatedProfile)
                        )
                    }
                    
                    // Store the updated contact (needs to happen before variables go out of scope)
                    contacts_set(conf, &contact)
                    try LibSessionError.throwIfNeeded(conf)
                }
                
                /// Assign all properties to match the updated disappearing messages configuration (if there is one)
                if
                    let disappearingInfo: LibSession.DisappearingMessageInfo = info.disappearingMessagesInfo,
                    let exp_mode: CONVO_EXPIRATION_MODE = disappearingInfo.type?.toLibSession()
                {
                    contact.exp_mode = exp_mode
                    contact.exp_seconds = Int32(disappearingInfo.durationSeconds)
                }
                
                /// If we were given a `created` timestamp then set it to the min between the current setting and the value (as
                /// long as the current setting isn't `0`)
                if let created: Int64 = info.created.map({ Int64(floor($0)) }) {
                    contact.created = (contact.created > 0 ? min(contact.created, created) : created)
                }
                
                /// Only support approving (not un-approving) a contact
                contact.approved = (!contact.approved ?
                    (info.isApproved ?? contact.approved) :
                    contact.approved
                )
                contact.approved_me = (!contact.approved_me ?
                    (info.didApproveMe ?? contact.approved_me) :
                    contact.approved_me
                )
                
                /// Store the updated contact (can't be sure if we made any changes above)
                contact.blocked = (info.isBlocked ?? contact.blocked)
                contact.priority = (info.priority ?? contact.priority)
                contacts_set(conf, &contact)
                try LibSessionError.throwIfNeeded(conf)
            }
    }
}

// MARK: - Outgoing Changes

internal extension LibSession {
    private struct ThreadInfo: Decodable, FetchableRecord {
        let id: String
        let creationDateTimestamp: TimeInterval
    }
    
    static func updatingContacts<T>(
        _ db: ObservingDatabase,
        _ updated: [T],
        using dependencies: Dependencies
    ) throws -> [T] {
        guard let updatedContacts: [Contact] = updated as? [Contact] else { throw StorageError.generic }
        
        // The current users contact data doesn't need to sync so exclude it, we also don't want to sync
        // blinded message requests so exclude those as well
        let userSessionId: SessionId = dependencies[cache: .general].sessionId
        let targetContacts: [Contact] = updatedContacts
            .filter {
                $0.id != userSessionId.hexString &&
                (try? SessionId(from: $0.id))?.prefix == .standard
            }
        
        // If we only updated the current user contact then no need to continue
        guard !targetContacts.isEmpty else { return updated }
        
        try dependencies.mutate(cache: .libSession) { cache in
            try cache.performAndPushChange(db, for: .contacts, sessionId: userSessionId) { config in
                guard case .contacts(let conf) = config else {
                    throw LibSessionError.invalidConfigObject(wanted: .contacts, got: config)
                }
                
                // When inserting new contacts (or contacts with invalid profile data) we want
                // to add any valid profile information we have so identify if any of the updated
                // contacts are new/invalid, and if so, fetch any profile data we have for them
                let newContactIds: [String] = targetContacts
                    .compactMap { contactData -> String? in
                        var contact: contacts_contact = contacts_contact()
                        
                        guard
                            var cContactId: [CChar] = contactData.id.cString(using: .utf8),
                            contacts_get(conf, &contact, &cContactId),
                            contact.get(\.name, nullIfEmpty: true) != nil
                        else {
                            LibSessionError.clear(conf)
                            return contactData.id
                        }
                        
                        return nil
                    }
                let newProfiles: [String: Profile] = try Profile
                    .fetchAll(db, ids: newContactIds)
                    .reduce(into: [:]) { result, next in result[next.id] = next }
                let newCreatedTimestamps: [String: TimeInterval] = try SessionThread
                    .select(.id, .creationDateTimestamp)
                    .filter(ids: newContactIds)
                    .asRequest(of: ThreadInfo.self)
                    .fetchAll(db)
                    .reduce(into: [:]) { result, next in result[next.id] = next.creationDateTimestamp }
                
                // Upsert the updated contact data
                try LibSession
                    .upsert(
                        contactData: targetContacts
                            .map { contact in
                                ContactUpdateInfo(
                                    id: contact.id,
                                    contact: contact,
                                    profile: newProfiles[contact.id],
                                    created: newCreatedTimestamps[contact.id]
                                )
                            },
                        in: config,
                        using: dependencies
                    )
            }
        }
        
        return updated
    }
    
    static func updatingProfiles<T>(
        _ db: ObservingDatabase,
        _ updated: [T],
        using dependencies: Dependencies
    ) throws -> [T] {
        guard let updatedProfiles: [Profile] = updated as? [Profile] else { throw StorageError.generic }
        
        // We should only sync profiles which are associated to contact data to avoid including profiles
        // for random people in community conversations so filter out any profiles which don't have an
        // associated contact
        let existingContactIds: [String] = (try? Contact
            .filter(ids: updatedProfiles.map { $0.id })
            .select(.id)
            .asRequest(of: String.self)
            .fetchAll(db))
            .defaulting(to: [])
        
        // If none of the profiles are associated with existing contacts then ignore the changes (no need
        // to do a config sync)
        guard !existingContactIds.isEmpty else { return updated }
        
        // Get the user public key (updating their profile is handled separately)
        let userSessionId: SessionId = dependencies[cache: .general].sessionId
        let targetProfiles: [Profile] = updatedProfiles
            .filter {
                $0.id != userSessionId.hexString &&
                (try? SessionId(from: $0.id))?.prefix == .standard &&
                existingContactIds.contains($0.id)
            }
        
        try dependencies.mutate(cache: .libSession) { cache in
            try cache.performAndPushChange(db, for: .contacts, sessionId: userSessionId) { config in
                try LibSession
                    .upsert(
                        contactData: targetProfiles
                            .map { ContactUpdateInfo(id: $0.id, profile: $0) },
                        in: config,
                        using: dependencies
                    )
            }
        }
        
        return updated
    }
    
    @discardableResult static func updatingDisappearingConfigsOneToOne<T>(
        _ db: ObservingDatabase,
        _ updated: [T],
        using dependencies: Dependencies
    ) throws -> [T] {
        guard let updatedDisappearingConfigs: [DisappearingMessagesConfiguration] = updated as? [DisappearingMessagesConfiguration] else { throw StorageError.generic }
        
        // Filter out any disappearing config changes related to groups
        let targetUpdatedConfigs: [DisappearingMessagesConfiguration] = updatedDisappearingConfigs
            .filter { (try? SessionId.Prefix(from: $0.id)) != .group }
        
        guard !targetUpdatedConfigs.isEmpty else { return updated }
        
        // We should only sync disappearing messages configs which are associated to existing contacts
        let existingContactIds: [String] = (try? Contact
            .filter(ids: targetUpdatedConfigs.map { $0.id })
            .select(.id)
            .asRequest(of: String.self)
            .fetchAll(db))
            .defaulting(to: [])
        
        // If none of the disappearing messages configs are associated with existing contacts then ignore
        // the changes (no need to do a config sync)
        guard !existingContactIds.isEmpty else { return updated }
        
        // Get the user public key (updating note to self is handled separately)
        let userSessionId: SessionId = dependencies[cache: .general].sessionId
        let targetDisappearingConfigs: [DisappearingMessagesConfiguration] = targetUpdatedConfigs
            .filter {
                $0.id != userSessionId.hexString &&
                (try? SessionId(from: $0.id))?.prefix == .standard &&
                existingContactIds.contains($0.id)
            }
        
        // Update the note to self disappearing messages config first (if needed)
        if let updatedUserDisappearingConfig: DisappearingMessagesConfiguration = targetUpdatedConfigs.first(where: { $0.id == userSessionId.hexString }) {
            try dependencies.mutate(cache: .libSession) { cache in
                try cache.performAndPushChange(db, for: .userProfile, sessionId: userSessionId) { config in
                    try LibSession.updateNoteToSelf(
                        disappearingMessagesConfig: updatedUserDisappearingConfig,
                        in: config
                    )
                }
            }
        }
        
        try dependencies.mutate(cache: .libSession) { cache in
            try cache.performAndPushChange(db, for: .contacts, sessionId: userSessionId) { config in
                try LibSession
                    .upsert(
                        contactData: targetDisappearingConfigs
                            .map { ContactUpdateInfo(id: $0.id, disappearingMessagesConfig: $0) },
                        in: config,
                        using: dependencies
                    )
            }
        }
        
        return updated
    }
}

// MARK: - External Outgoing Changes

public extension LibSession {
    static func hide(
        _ db: ObservingDatabase,
        contactIds: [String],
        using dependencies: Dependencies
    ) throws {
        try dependencies.mutate(cache: .libSession) { cache in
            try cache.performAndPushChange(db, for: .contacts, sessionId: dependencies[cache: .general].sessionId) { config in
                // Mark the contacts as hidden
                try LibSession.upsert(
                    contactData: contactIds
                        .map {
                            ContactUpdateInfo(
                                id: $0,
                                priority: LibSession.hiddenPriority
                            )
                        },
                    in: config,
                    using: dependencies
                )
            }
        }
    }
    
    static func remove(
        _ db: ObservingDatabase,
        contactIds: [String],
        using dependencies: Dependencies
    ) throws {
        guard !contactIds.isEmpty else { return }
        
        try dependencies.mutate(cache: .libSession) { cache in
            try cache.performAndPushChange(db, for: .contacts, sessionId: dependencies[cache: .general].sessionId) { config in
                guard case .contacts(let conf) = config else {
                    throw LibSessionError.invalidConfigObject(wanted: .contacts, got: config)
                }
                
                contactIds.forEach { sessionId in
                    guard var cSessionId: [CChar] = sessionId.cString(using: .utf8) else { return }
                    
                    // Don't care if the contact doesn't exist
                    contacts_erase(conf, &cSessionId)
                }
            }
        }
    }
    
    static func update(
        _ db: ObservingDatabase,
        sessionId: String,
        disappearingMessagesConfig: DisappearingMessagesConfiguration,
        using dependencies: Dependencies
    ) throws {
        let userSessionId: SessionId = dependencies[cache: .general].sessionId
        
        switch sessionId {
            case userSessionId.hexString:
                try dependencies.mutate(cache: .libSession) { cache in
                    try cache.performAndPushChange(db, for: .userProfile, sessionId: userSessionId) { config in
                        try LibSession.updateNoteToSelf(
                            disappearingMessagesConfig: disappearingMessagesConfig,
                            in: config
                        )
                    }
                }
                
            default:
                try dependencies.mutate(cache: .libSession) { cache in
                    try cache.performAndPushChange(db, for: .contacts, sessionId: userSessionId) { config in
                        try LibSession
                            .upsert(
                                contactData: [
                                    ContactUpdateInfo(
                                        id: sessionId,
                                        disappearingMessagesConfig: disappearingMessagesConfig
                                    )
                                ],
                                in: config,
                                using: dependencies
                            )
                    }
                }
        }
    }
}

// MARK: - State Access

public extension LibSession.Cache {
    func isContactBlocked(contactId: String) -> Bool {
        guard
            case .contacts(let conf) = config(for: .contacts, sessionId: userSessionId),
            var cContactId: [CChar] = contactId.cString(using: .utf8)
        else { return false }
        
        var contact: contacts_contact = contacts_contact()
        
        guard contacts_get(conf, &contact, &cContactId) else {
            LibSessionError.clear(conf)
            return false
        }
        
        return contact.blocked
    }
    
    func isContactApproved(contactId: String) -> Bool {
        guard
            case .contacts(let conf) = config(for: .contacts, sessionId: userSessionId),
            var cContactId: [CChar] = contactId.cString(using: .utf8)
        else { return false }
        
        var contact: contacts_contact = contacts_contact()
        
        guard contacts_get(conf, &contact, &cContactId) else {
            LibSessionError.clear(conf)
            return false
        }
        
        return contact.approved
    }
}

// MARK: - ContactUpdateInfo

extension LibSession {
    public struct ContactUpdateInfo {
        let id: String
        let isTrusted: Bool?
        let isApproved: Bool?
        let isBlocked: Bool?
        let didApproveMe: Bool?
        
        let name: String?
        let nickname: String?
        let displayPictureUrl: String?
        let displayPictureEncryptionKey: Data?
        let profileLastUpdated: Int64?
        
        let disappearingMessagesInfo: DisappearingMessageInfo?
        let priority: Int32?
        let created: TimeInterval?
        
        fileprivate var profile: Profile? {
            guard let name: String = name else { return nil }
            
            return Profile(
                id: id,
                name: name,
                nickname: nickname,
                displayPictureUrl: displayPictureUrl,
                displayPictureEncryptionKey: displayPictureEncryptionKey
            )
        }
        
        public init(
            id: String,
            contact: Contact? = nil,
            profile: Profile? = nil,
            disappearingMessagesConfig: DisappearingMessagesConfiguration? = nil,
            priority: Int32? = nil,
            created: TimeInterval? = nil
        ) {
            self.init(
                id: id,
                isTrusted: contact?.isTrusted,
                isApproved: contact?.isApproved,
                isBlocked: contact?.isBlocked,
                didApproveMe: contact?.didApproveMe,
                name: profile?.name,
                nickname: profile?.nickname,
                displayPictureUrl: profile?.displayPictureUrl,
                displayPictureEncryptionKey: profile?.displayPictureEncryptionKey,
                profileLastUpdated: profile?.profileLastUpdated.map { Int64($0) },
                disappearingMessagesInfo: disappearingMessagesConfig.map {
                    DisappearingMessageInfo(
                        isEnabled: $0.isEnabled,
                        durationSeconds: Int64($0.durationSeconds),
                        rawType: $0.type?.rawValue
                    )
                },
                priority: priority,
                created: created
            )
        }
        
        init(
            id: String,
            isTrusted: Bool? = nil,
            isApproved: Bool? = nil,
            isBlocked: Bool? = nil,
            didApproveMe: Bool? = nil,
            name: String? = nil,
            nickname: String? = nil,
            displayPictureUrl: String? = nil,
            displayPictureEncryptionKey: Data? = nil,
            profileLastUpdated: Int64? = nil,
            disappearingMessagesInfo: DisappearingMessageInfo? = nil,
            priority: Int32? = nil,
            created: TimeInterval? = nil
        ) {
            self.id = id
            self.isTrusted = isTrusted
            self.isApproved = isApproved
            self.isBlocked = isBlocked
            self.didApproveMe = didApproveMe
            self.name = name
            self.nickname = nickname
            self.displayPictureUrl = displayPictureUrl
            self.displayPictureEncryptionKey = displayPictureEncryptionKey
            self.profileLastUpdated = profileLastUpdated
            self.disappearingMessagesInfo = disappearingMessagesInfo
            self.priority = priority
            self.created = created
        }
    }
    
    struct DisappearingMessageInfo {
        let isEnabled: Bool
        let durationSeconds: Int64
        let rawType: Int?
        
        var type: DisappearingMessagesConfiguration.DisappearingMessageType? {
            rawType.map { DisappearingMessagesConfiguration.DisappearingMessageType(rawValue: $0) }
        }
        
        func generateConfig(for threadId: String) -> DisappearingMessagesConfiguration {
            DisappearingMessagesConfiguration(
                threadId: threadId,
                isEnabled: isEnabled,
                durationSeconds: TimeInterval(durationSeconds),
                type: rawType.map { DisappearingMessagesConfiguration.DisappearingMessageType(rawValue: $0) }
            )
        }
    }
}

// MARK: - ContactData

internal struct ContactData {
    internal let contact: Contact
    internal let profile: Profile
    internal let config: DisappearingMessagesConfiguration
    internal let priority: Int32
    internal let created: TimeInterval
}

// MARK: - Convenience

internal extension LibSession {
    static func extractContacts(
        from conf: UnsafeMutablePointer<config_object>?,
        using dependencies: Dependencies
    ) throws -> [String: ContactData] {
        var infiniteLoopGuard: Int = 0
        var result: [String: ContactData] = [:]
        var contact: contacts_contact = contacts_contact()
        let contactIterator: UnsafeMutablePointer<contacts_iterator> = contacts_iterator_new(conf)
        let userSessionId: SessionId = dependencies[cache: .general].sessionId
        
        while !contacts_iterator_done(contactIterator, &contact) {
            try LibSession.checkLoopLimitReached(&infiniteLoopGuard, for: .contacts)
            
            let contactId: String = contact.get(\.session_id)
            let contactResult: Contact = Contact(
                id: contactId,
                isApproved: contact.approved,
                isBlocked: contact.blocked,
                didApproveMe: contact.approved_me,
                currentUserSessionId: userSessionId
            )
            let displayPictureUrl: String? = contact.get(\.profile_pic.url, nullIfEmpty: true)
            let profileResult: Profile = Profile(
                id: contactId,
                name: contact.get(\.name),
                nickname: contact.get(\.nickname, nullIfEmpty: true),
                displayPictureUrl: displayPictureUrl,
                displayPictureEncryptionKey: (displayPictureUrl == nil ? nil : contact.get(\.profile_pic.key)),
                profileLastUpdated: TimeInterval(contact.profile_updated)
            )
            let configResult: DisappearingMessagesConfiguration = DisappearingMessagesConfiguration(
                threadId: contactId,
                isEnabled: contact.exp_seconds > 0,
                durationSeconds: TimeInterval(contact.exp_seconds),
                type: DisappearingMessagesConfiguration.DisappearingMessageType(libSessionType: contact.exp_mode)
            )
            
            result[contactId] = ContactData(
                contact: contactResult,
                profile: profileResult,
                config: configResult,
                priority: contact.priority,
                created: TimeInterval(contact.created)
            )
            contacts_iterator_advance(contactIterator)
        }
        contacts_iterator_free(contactIterator) // Need to free the iterator
        
        return result
    }
}

// MARK: - C Conformance

extension contacts_contact: CAccessible & CMutable {}
