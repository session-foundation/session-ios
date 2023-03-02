// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtil
import SessionUtilitiesKit

internal extension SessionUtil {
    static let columnsRelatedToContacts: [ColumnExpression] = [
        Contact.Columns.isApproved,
        Contact.Columns.isBlocked,
        Contact.Columns.didApproveMe,
        Profile.Columns.name,
        Profile.Columns.nickname,
        Profile.Columns.profilePictureUrl,
        Profile.Columns.profileEncryptionKey
    ]
    
    // MARK: - Incoming Changes
    
    static func handleContactsUpdate(
        _ db: Database,
        in conf: UnsafeMutablePointer<config_object>?,
        mergeNeedsDump: Bool
    ) throws {
        typealias ContactData = [
            String: (
                contact: Contact,
                profile: Profile,
                isHiddenConversation: Bool
            )
        ]
        
        guard mergeNeedsDump else { return }
        guard conf != nil else { throw SessionUtilError.nilConfigObject }
        
        var contactData: ContactData = [:]
        var contact: contacts_contact = contacts_contact()
        let contactIterator: UnsafeMutablePointer<contacts_iterator> = contacts_iterator_new(conf)
        
        while !contacts_iterator_done(contactIterator, &contact) {
            let contactId: String = String(cString: withUnsafeBytes(of: contact.session_id) { [UInt8]($0) }
                .map { CChar($0) }
                .nullTerminated()
            )
            let contactResult: Contact = Contact(
                id: contactId,
                isApproved: contact.approved,
                isBlocked: contact.blocked,
                didApproveMe: contact.approved_me
            )
            let profilePictureUrl: String? = String(libSessionVal: contact.profile_pic.url, nullIfEmpty: true)
            let profileResult: Profile = Profile(
                id: contactId,
                name: String(libSessionVal: contact.name),
                nickname: String(libSessionVal: contact.nickname, nullIfEmpty: true),
                profilePictureUrl: profilePictureUrl,
                profileEncryptionKey: (profilePictureUrl == nil ? nil :
                    Data(
                        libSessionVal: contact.profile_pic.key,
                        count: ProfileManager.avatarAES256KeyByteLength
                    )
                )
            )
            
            contactData[contactId] = (
                contactResult,
                profileResult,
                contact.hidden
            )
            contacts_iterator_advance(contactIterator)
        }
        contacts_iterator_free(contactIterator) // Need to free the iterator
        
        // The current users contact data is handled separately so exclude it if it's present (as that's
        // actually a bug)
        let userPublicKey: String = getUserHexEncodedPublicKey(db)
        let targetContactData: ContactData = contactData.filter { $0.key != userPublicKey }
        
        // If we only updated the current user contact then no need to continue
        guard !targetContactData.isEmpty else { return }
        
        // Since we don't sync 100% of the data stored against the contact and profile objects we
        // need to only update the data we do have to ensure we don't overwrite anything that doesn't
        // get synced
        try targetContactData
            .forEach { sessionId, data in
                // Note: We only update the contact and profile records if the data has actually changed
                // in order to avoid triggering UI updates for every thread on the home screen (the DB
                // observation system can't differ between update calls which do and don't change anything)
                let contact: Contact = Contact.fetchOrCreate(db, id: sessionId)
                let profile: Profile = Profile.fetchOrCreate(db, id: sessionId)
                
                if
                    (!data.profile.name.isEmpty && profile.name != data.profile.name) ||
                    profile.nickname != data.profile.nickname ||
                    profile.profilePictureUrl != data.profile.profilePictureUrl ||
                    profile.profileEncryptionKey != data.profile.profileEncryptionKey
                {
                    try profile.save(db)
                    try Profile
                        .filter(id: sessionId)
                        .updateAll( // Handling a config update so don't use `updateAllAndConfig`
                            db,
                            [
                                (data.profile.name.isEmpty || profile.name == data.profile.name ? nil :
                                    Profile.Columns.name.set(to: data.profile.name)
                                ),
                                (profile.nickname == data.profile.nickname ? nil :
                                    Profile.Columns.nickname.set(to: data.profile.nickname)
                                ),
                                (profile.profilePictureUrl != data.profile.profilePictureUrl ? nil :
                                    Profile.Columns.profilePictureUrl.set(to: data.profile.profilePictureUrl)
                                ),
                                (profile.profileEncryptionKey != data.profile.profileEncryptionKey ? nil :
                                    Profile.Columns.profileEncryptionKey.set(to: data.profile.profileEncryptionKey)
                                )
                            ].compactMap { $0 }
                        )
                }
                
                /// Since message requests have no reverse, we should only handle setting `isApproved`
                /// and `didApproveMe` to `true`. This may prevent some weird edge cases where a config message
                /// swapping `isApproved` and `didApproveMe` to `false`
                if
                    (contact.isApproved != data.contact.isApproved) ||
                    (contact.isBlocked != data.contact.isBlocked) ||
                    (contact.didApproveMe != data.contact.didApproveMe)
                {
                    try contact.save(db)
                    try Contact
                        .filter(id: sessionId)
                        .updateAll( // Handling a config update so don't use `updateAllAndConfig`
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
                            ].compactMap { $0 }
                        )
                }
                
                /// If the contact's `hidden` flag doesn't match the visibility of their conversation then create/delete the
                /// associated contact conversation accordingly
                let threadExists: Bool = try SessionThread.exists(db, id: contact.id)
                let threadIsVisible: Bool = try SessionThread
                    .filter(id: contact.id)
                    .select(.shouldBeVisible)
                    .asRequest(of: Bool.self)
                    .fetchOne(db)
                    .defaulting(to: false)
                
                switch (data.isHiddenConversation, threadExists, threadIsVisible) {
                    case (true, true, _):
                        try SessionThread
                            .filter(id: contact.id)
                            .deleteAll(db)
                        
                    case (false, false, _):
                        try SessionThread(
                            id: contact.id,
                            variant: .contact,
                            shouldBeVisible: true
                        ).save(db)
                        
                    case (false, true, false):
                        try SessionThread
                            .filter(id: contact.id)
                            .updateAll( // Handling a config update so don't use `updateAllAndConfig`
                                db,
                                SessionThread.Columns.shouldBeVisible.set(to: !data.isHiddenConversation)
                            )
                        
                    default: break
                }
            }
    }
    
    // MARK: - Outgoing Changes
    
    static func upsert(
        contactData: [SyncedContactInfo],
        in conf: UnsafeMutablePointer<config_object>?
    ) throws {
        guard conf != nil else { throw SessionUtilError.nilConfigObject }
        
        // The current users contact data doesn't need to sync so exclude it
        let userPublicKey: String = getUserHexEncodedPublicKey()
        let targetContacts: [SyncedContactInfo] = contactData
            .filter { $0.id != userPublicKey }
        
        // If we only updated the current user contact then no need to continue
        guard !targetContacts.isEmpty else { return }        
        
        // Update the name
        targetContacts
            .forEach { info in
                var sessionId: [CChar] = info.id.cArray
                var contact: contacts_contact = contacts_contact()
                guard contacts_get_or_construct(conf, &contact, &sessionId) else {
                    SNLog("Unable to upsert contact from Config Message")
                    return
                }
                
                // Assign all properties to match the updated contact (if there is one)
                if let updatedContact: Contact = info.contact {
                    contact.approved = updatedContact.isApproved
                    contact.approved_me = updatedContact.didApproveMe
                    contact.blocked = updatedContact.isBlocked
                    
                    // Store the updated contact (needs to happen before variables go out of scope)
                    contacts_set(conf, &contact)
                }
                
                // Update the profile data (if there is one - users we have sent a message request to may
                // not have profile info in certain situations)
                if let updatedProfile: Profile = info.profile {
                    let oldAvatarUrl: String? = String(libSessionVal: contact.profile_pic.url)
                    let oldAvatarKey: Data? = Data(
                        libSessionVal: contact.profile_pic.key,
                        count: ProfileManager.avatarAES256KeyByteLength
                    )
                    
                    contact.name = updatedProfile.name.toLibSession()
                    contact.nickname = updatedProfile.nickname.toLibSession()
                    contact.profile_pic.url = updatedProfile.profilePictureUrl.toLibSession()
                    contact.profile_pic.key = updatedProfile.profileEncryptionKey.toLibSession()
                    
                    // Download the profile picture if needed (this can be triggered within
                    // database reads/writes so dispatch the download to a separate queue to
                    // prevent blocking)
                    if oldAvatarUrl != updatedProfile.profilePictureUrl || oldAvatarKey != updatedProfile.profileEncryptionKey {
                        DispatchQueue.global(qos: .background).async {
                            ProfileManager.downloadAvatar(for: updatedProfile)
                        }
                    }
                    
                    // Store the updated contact (needs to happen before variables go out of scope)
                    contacts_set(conf, &contact)
                }
                
                // Store the updated contact (can't be sure if we made any changes above)
                contact.hidden = (info.hidden ?? contact.hidden)
                contact.priority = (info.priority ?? contact.priority)
                contacts_set(conf, &contact)
            }
    }
}

// MARK: - External Outgoing Changes

public extension SessionUtil {
    static func hide(_ db: Database, contactIds: [String]) throws {
        try SessionUtil.performAndPushChange(
            db,
            for: .contacts,
            publicKey: getUserHexEncodedPublicKey(db)
        ) { conf in
            // Mark the contacts as hidden
            try SessionUtil.upsert(
                contactData: contactIds
                    .map { SyncedContactInfo(id: $0, hidden: true) },
                in: conf
            )
        }
    }
}

// MARK: - Convenience

internal extension SessionUtil {
    static func updatingContacts<T>(_ db: Database, _ updated: [T]) throws -> [T] {
        guard let updatedContacts: [Contact] = updated as? [Contact] else { throw StorageError.generic }
        
        // The current users contact data doesn't need to sync so exclude it
        let userPublicKey: String = getUserHexEncodedPublicKey(db)
        let targetContacts: [Contact] = updatedContacts.filter { $0.id != userPublicKey }
        
        // If we only updated the current user contact then no need to continue
        guard !targetContacts.isEmpty else { return updated }
        
        do {
            try SessionUtil.performAndPushChange(
                db,
                for: .contacts,
                publicKey: userPublicKey
            ) { conf in
                // When inserting new contacts (or contacts with invalid profile data) we want
                // to add any valid profile information we have so identify if any of the updated
                // contacts are new/invalid, and if so, fetch any profile data we have for them
                let newContactIds: [String] = targetContacts
                    .compactMap { contactData -> String? in
                        var cContactId: [CChar] = contactData.id.cArray
                        var contact: contacts_contact = contacts_contact()
                        
                        guard
                            contacts_get(conf, &contact, &cContactId),
                            String(libSessionVal: contact.name, nullIfEmpty: true) != nil
                        else { return contactData.id }
                        
                        return nil
                    }
                let newProfiles: [String: Profile] = try Profile
                    .fetchAll(db, ids: newContactIds)
                    .reduce(into: [:]) { result, next in result[next.id] = next }
                
                // Upsert the updated contact data
                try SessionUtil
                    .upsert(
                        contactData: targetContacts
                            .map { contact in
                                SyncedContactInfo(
                                    id: contact.id,
                                    contact: contact,
                                    profile: newProfiles[contact.id]
                                )
                            },
                        in: conf
                    )
            }
        }
        catch {
            SNLog("[libSession-util] Failed to dump updated data")
        }
        
        return updated
    }
    
    static func updatingProfiles<T>(_ db: Database, _ updated: [T]) throws -> [T] {
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
        
        // Get the user public key (updating their profile is handled separately
        let userPublicKey: String = getUserHexEncodedPublicKey(db)
        let targetProfiles: [Profile] = updatedProfiles
            .filter {
                $0.id != userPublicKey &&
                existingContactIds.contains($0.id)
            }
        
        do {
            // Update the user profile first (if needed)
            if let updatedUserProfile: Profile = updatedProfiles.first(where: { $0.id == userPublicKey }) {
                try SessionUtil.performAndPushChange(
                    db,
                    for: .userProfile,
                    publicKey: userPublicKey
                ) { conf in
                    try SessionUtil.update(
                        profile: updatedUserProfile,
                        in: conf
                    )
                }
            }
            
            try SessionUtil.performAndPushChange(
                db,
                for: .contacts,
                publicKey: userPublicKey
            ) { conf in
                try SessionUtil
                    .upsert(
                        contactData: targetProfiles
                            .map { SyncedContactInfo(id: $0.id, profile: $0) },
                        in: conf
                    )
            }
        }
        catch {
            SNLog("[libSession-util] Failed to dump updated data")
        }
        
        return updated
    }
}

// MARK: - SyncedContactInfo

extension SessionUtil {
    struct SyncedContactInfo {
        let id: String
        let contact: Contact?
        let profile: Profile?
        let priority: Int32?
        let hidden: Bool?
        
        init(
            id: String,
            contact: Contact? = nil,
            profile: Profile? = nil,
            priority: Int32? = nil,
            hidden: Bool? = nil
        ) {
            self.id = id
            self.contact = contact
            self.profile = profile
            self.priority = priority
            self.hidden = hidden
        }
    }
}
