// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtil
import SessionUtilitiesKit

internal extension SessionUtil {
    // MARK: - Incoming Changes
    
    static func handleContactsUpdate(
        _ db: Database,
        in atomicConf: Atomic<UnsafeMutablePointer<config_object>?>,
        needsDump: Bool
    ) throws {
        typealias ContactData = [String: (contact: Contact, profile: Profile)]
        
        guard needsDump else { return }
        guard atomicConf.wrappedValue != nil else { throw SessionUtilError.nilConfigObject }
        
        // Since we are doing direct memory manipulation we are using an `Atomic` type which has
        // blocking access in it's `mutate` closure
        let contactData: ContactData = atomicConf.mutate { conf -> ContactData in
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
                let profileResult: Profile = Profile(
                    id: contactId,
                    name: (contact.name.map { String(cString: $0) } ?? ""),
                    nickname: contact.nickname.map { String(cString: $0) },
                    profilePictureUrl: contact.profile_pic.url.map { String(cString: $0) },
                    profileEncryptionKey: (contact.profile_pic.key != nil && contact.profile_pic.keylen > 0 ?
                        Data(bytes: contact.profile_pic.key, count: contact.profile_pic.keylen) :
                        nil
                    )
                )
                
                contactData[contactId] = (contactResult, profileResult)
                contacts_iterator_advance(contactIterator)
            }
            contacts_iterator_free(contactIterator) // Need to free the iterator
            
            return contactData
        }
        
        // The current users contact data is handled separately so exclude it if it's present (as that's
        // actually a bug)
        let userPublicKey: String = getUserHexEncodedPublicKey()
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
                                (!data.contact.isApproved ? nil :
                                    Contact.Columns.isApproved.set(to: true)
                                ),
                                Contact.Columns.isBlocked.set(to: data.contact.isBlocked),
                                (!data.contact.didApproveMe ? nil :
                                    Contact.Columns.didApproveMe.set(to: true)
                                )
                            ].compactMap { $0 }
                        )
                }
            }
    }
    
    // MARK: - Outgoing Changes
    
    static func upsert(
        contactData: [(id: String, contact: Contact?, profile: Profile?)],
        in atomicConf: Atomic<UnsafeMutablePointer<config_object>?>
    ) throws -> ConfResult {
        guard atomicConf.wrappedValue != nil else { throw SessionUtilError.nilConfigObject }
        
        // The current users contact data doesn't need to sync so exclude it
        let userPublicKey: String = getUserHexEncodedPublicKey()
        let targetContacts: [(id: String, contact: Contact?, profile: Profile?)] = contactData
            .filter { $0.id != userPublicKey }
        
        // If we only updated the current user contact then no need to continue
        guard !targetContacts.isEmpty else { return ConfResult(needsPush: false, needsDump: false) }
        
        // Since we are doing direct memory manipulation we are using an `Atomic` type which has
        // blocking access in it's `mutate` closure
        return atomicConf.mutate { conf in
            // Update the name
            targetContacts
                .forEach { (id, maybeContact, maybeProfile) in
                    var sessionId: [CChar] = id
                        .bytes
                        .map { CChar(bitPattern: $0) }
                    var contact: contacts_contact = contacts_contact()
                    guard contacts_get_or_create(conf, &contact, &sessionId) else {
                        SNLog("Unable to upsert contact from Config Message")
                        return
                    }
                    
                    // Assign all properties to match the updated contact (if there is one)
                    if let updatedContact: Contact = maybeContact {
                        contact.approved = updatedContact.isApproved
                        contact.approved_me = updatedContact.didApproveMe
                        contact.blocked = updatedContact.isBlocked
                    }
                    
                    // Update the profile data (if there is one)
                    if let updatedProfile: Profile = maybeProfile {
                        /// Users we have sent a message request to may not have profile info in certain situations
                        ///
                        /// Note: We **MUST** store these in local variables rather than access them directly or they won't
                        /// exist in memory long enough to actually be assigned in the C type
                        let updatedName: [CChar]? = (updatedProfile.name.isEmpty ?
                            nil :
                            updatedProfile.name
                                .bytes
                                .map { CChar(bitPattern: $0) }
                        )
                        let updatedNickname: [CChar]? = updatedProfile.nickname?
                            .bytes
                            .map { CChar(bitPattern: $0) }
                        let updatedAvatarUrl: [CChar]? = updatedProfile.profilePictureUrl?
                            .bytes
                            .map { CChar(bitPattern: $0) }
                        let updatedAvatarKey: [UInt8]? = updatedProfile.profileEncryptionKey?
                            .bytes
                        let oldAvatarUrl: String? = contact.profile_pic.url.map { String(cString: $0) }
                        let oldAvatarKey: Data? = (contact.profile_pic.key != nil && contact.profile_pic.keylen > 0 ?
                            Data(bytes: contact.profile_pic.key, count: contact.profile_pic.keylen) :
                            nil
                        )
                        updatedName?.withUnsafeBufferPointer { contact.name = $0.baseAddress }
                        (updatedNickname == nil ?
                            contact.nickname = nil :
                            updatedNickname?.withUnsafeBufferPointer { contact.nickname = $0.baseAddress }
                        )
                        (updatedAvatarUrl == nil ?
                            contact.profile_pic.url = nil :
                            updatedAvatarUrl?.withUnsafeBufferPointer {
                                contact.profile_pic.url = $0.baseAddress
                            }
                        )
                        (updatedAvatarKey == nil ?
                            contact.profile_pic.key = nil :
                            updatedAvatarKey?.withUnsafeBufferPointer {
                                contact.profile_pic.key = $0.baseAddress
                            }
                        )
                        contact.profile_pic.keylen = (updatedAvatarKey?.count ?? 0)
                        
                        // Download the profile picture if needed
                        if oldAvatarUrl != updatedProfile.profilePictureUrl || oldAvatarKey != updatedProfile.profileEncryptionKey {
                            ProfileManager.downloadAvatar(for: updatedProfile)
                        }
                    }
                    
                    // Store the updated contact
                    contacts_set(conf, &contact)
                }
            
            return ConfResult(
                needsPush: config_needs_push(conf),
                needsDump: config_needs_dump(conf)
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
        
        db.afterNextTransaction { db in
            do {
                let atomicConf: Atomic<UnsafeMutablePointer<config_object>?> = SessionUtil.config(
                    for: .contacts,
                    publicKey: userPublicKey
                )
                let result: ConfResult = try SessionUtil
                    .upsert(
                        contactData: targetContacts.map { (id: $0.id, contact: $0, profile: nil) },
                        in: atomicConf
                    )
                
                // If we don't need to dump the data the we can finish early
                guard result.needsDump else { return }
                
                try SessionUtil.saveState(
                    db,
                    keepingExistingMessageHashes: true,
                    configDump: try atomicConf.mutate { conf in
                        try SessionUtil.createDump(
                            conf: conf,
                            for: .contacts,
                            publicKey: userPublicKey,
                            messageHashes: nil
                        )
                    }
                )
            }
            catch {
                SNLog("[libSession-util] Failed to dump updated data")
            }
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
        
        db.afterNextTransaction { db in
            do {
                // Update the user profile first (if needed)
                if let updatedUserProfile: Profile = updatedProfiles.first(where: { $0.id == userPublicKey }) {
                    let atomicConf: Atomic<UnsafeMutablePointer<config_object>?> = SessionUtil.config(
                        for: .userProfile,
                        publicKey: userPublicKey
                    )
                    let result: ConfResult = try SessionUtil.update(
                        profile: updatedUserProfile,
                        in: atomicConf
                    )
                    
                    if result.needsDump {
                        try SessionUtil.saveState(
                            db,
                            keepingExistingMessageHashes: true,
                            configDump: try atomicConf.mutate { conf in
                                try SessionUtil.createDump(
                                    conf: conf,
                                    for: .userProfile,
                                    publicKey: userPublicKey,
                                    messageHashes: nil
                                )
                            }
                        )
                    }
                }
                
                // Then update other contacts
                let atomicConf: Atomic<UnsafeMutablePointer<config_object>?> = SessionUtil.config(
                    for: .contacts,
                    publicKey: userPublicKey
                )
                let result: ConfResult = try SessionUtil
                    .upsert(
                        contactData: updatedProfiles
                            .filter { $0.id != userPublicKey }
                            .map { (id: $0.id, contact: nil, profile: $0) },
                        in: atomicConf
                    )
                
                // If we don't need to dump the data the we can finish early
                guard result.needsDump else { return }
                
                try SessionUtil.saveState(
                    db,
                    keepingExistingMessageHashes: true,
                    configDump: try atomicConf.mutate { conf in
                        try SessionUtil.createDump(
                            conf: conf,
                            for: .contacts,
                            publicKey: userPublicKey,
                            messageHashes: nil
                        )
                    }
                )
            }
            catch {
                SNLog("[libSession-util] Failed to dump updated data")
            }
        }
        
        return updated
    }
}
