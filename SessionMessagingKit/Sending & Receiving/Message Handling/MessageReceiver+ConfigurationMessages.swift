// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import Sodium
import SessionUIKit
import SessionUtilitiesKit

extension MessageReceiver {
    internal static func handleLegacyConfigurationMessage(
        _ db: Database,
        message: ConfigurationMessage,
        using dependencies: Dependencies
    ) throws {
        // FIXME: Remove this once `useSharedUtilForUserConfig` is permanent
        guard !SessionUtil.userConfigsEnabled(db) else {
            TopBannerController.show(warning: .outdatedUserConfig)
            return
        }
        
        let userPublicKey = getUserHexEncodedPublicKey(db)
        
        guard message.sender == userPublicKey else { return }
        
        SNLog("Configuration message received.")
        
        // Note: `message.sentTimestamp` is in ms (convert to TimeInterval before converting to
        // seconds to maintain the accuracy)
        let isInitialSync: Bool = (!UserDefaults.standard[.hasSyncedInitialConfiguration])
        let messageSentTimestamp: TimeInterval = TimeInterval((message.sentTimestamp ?? 0) / 1000)
        let lastConfigTimestamp: TimeInterval = UserDefaults.standard[.lastConfigurationSync]
            .defaulting(to: Date(timeIntervalSince1970: 0))
            .timeIntervalSince1970
        
        // Handle user profile changes
        try ProfileManager.updateProfileIfNeeded(
            db,
            publicKey: userPublicKey,
            name: message.displayName,
            avatarUpdate: {
                guard
                    let profilePictureUrl: String = message.profilePictureUrl,
                    let profileKey: Data = message.profileKey
                else { return .none }
                
                return .updateTo(
                    url: profilePictureUrl,
                    key: profileKey,
                    fileName: nil
                )
            }(),
            sentTimestamp: messageSentTimestamp,
            calledFromConfigHandling: true,
            using: dependencies
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
                    Contact.Columns.isTrusted.set(to: true),
                    Contact.Columns.isApproved.set(to: true),
                    Contact.Columns.didApproveMe.set(to: true)
                )
        }
        
        if isInitialSync || messageSentTimestamp > lastConfigTimestamp {
            if isInitialSync {
                UserDefaults.standard[.hasSyncedInitialConfiguration] = true
                NotificationCenter.default.post(name: .initialConfigurationMessageReceived, object: nil)
            }
            
            UserDefaults.standard[.lastConfigurationSync] = Date(timeIntervalSince1970: messageSentTimestamp)
            
            // Contacts
            try message.contacts.forEach { contactInfo in
                guard let sessionId: String = contactInfo.publicKey else { return }
                
                // If the contact is a blinded contact then only add them if they haven't already been
                // unblinded
                if SessionId.Prefix(from: sessionId) == .blinded15 || SessionId.Prefix(from: sessionId) == .blinded25 {
                    let hasUnblindedContact: Bool = BlindedIdLookup
                        .filter(BlindedIdLookup.Columns.blindedId == sessionId)
                        .filter(BlindedIdLookup.Columns.sessionId != nil)
                        .isNotEmpty(db)
                    
                    if hasUnblindedContact {
                        return
                    }
                }
                
                // Note: We only update the contact and profile records if the data has actually changed
                // in order to avoid triggering UI updates for every thread on the home screen
                let contact: Contact = Contact.fetchOrCreate(db, id: sessionId)
                let profile: Profile = Profile.fetchOrCreate(db, id: sessionId)
                
                if
                    profile.name != contactInfo.displayName ||
                    profile.profilePictureUrl != contactInfo.profilePictureUrl ||
                    profile.profileEncryptionKey != contactInfo.profileKey
                {
                    try profile.save(db)
                    try Profile
                        .filter(id: sessionId)
                        .updateAll( // Handling a config update so don't use `updateAllAndConfig`
                            db,
                            [
                                Profile.Columns.name.set(to: contactInfo.displayName),
                                (contactInfo.profilePictureUrl == nil ? nil :
                                    Profile.Columns.profilePictureUrl.set(to: contactInfo.profilePictureUrl)
                                ),
                                (contactInfo.profileKey == nil ? nil :
                                    Profile.Columns.profileEncryptionKey.set(to: contactInfo.profileKey)
                                )
                            ].compactMap { $0 }
                        )
                }
                
                /// We only update these values if the proto actually has values for them (this is to prevent an
                /// edge case where an old client could override the values with default values since they aren't included)
                ///
                /// **Note:** Since message requests have no reverse, we should only handle setting `isApproved`
                /// and `didApproveMe` to `true`. This may prevent some weird edge cases where a config message
                /// swapping `isApproved` and `didApproveMe` to `false`
                if
                    (contactInfo.hasIsApproved && (contact.isApproved != contactInfo.isApproved)) ||
                    (contactInfo.hasIsBlocked && (contact.isBlocked != contactInfo.isBlocked)) ||
                    (contactInfo.hasDidApproveMe && (contact.didApproveMe != contactInfo.didApproveMe))
                {
                    try contact.save(db)
                    try Contact
                        .filter(id: sessionId)
                        .updateAll( // Handling a config update so don't use `updateAllAndConfig`
                            db,
                            [
                                (!contactInfo.hasIsApproved || !contactInfo.isApproved ? nil :
                                    Contact.Columns.isApproved.set(to: true)
                                ),
                                (!contactInfo.hasIsBlocked ? nil :
                                    Contact.Columns.isBlocked.set(to: contactInfo.isBlocked)
                                ),
                                (!contactInfo.hasDidApproveMe || !contactInfo.didApproveMe ? nil :
                                    Contact.Columns.didApproveMe.set(to: contactInfo.didApproveMe)
                                )
                            ].compactMap { $0 }
                        )
                }
                
                // If the contact is blocked
                if contactInfo.hasIsBlocked && contactInfo.isBlocked {
                    // If this message changed them to the blocked state and there is an existing thread
                    // associated with them that is a message request thread then delete it (assume
                    // that the current user had deleted that message request)
                    if
                        contactInfo.isBlocked != contact.isBlocked, // 'contact.isBlocked' will be the old value
                        let thread: SessionThread = try? SessionThread.fetchOne(db, id: sessionId),
                        thread.isMessageRequest(db)
                    {
                        _ = try thread.delete(db)
                    }
                }
            }
            
            // Closed groups
            //
            // Note: Only want to add these for initial sync to avoid re-adding closed groups the user
            // intentionally left (any closed groups joined since the first processed sync message should
            // get added via the 'handleNewClosedGroup' method anyway as they will have come through in the
            // past two weeks)
            if isInitialSync {
                let existingClosedGroupsIds: [String] = (try? SessionThread
                    .filter(SessionThread.Columns.variant == SessionThread.Variant.legacyGroup)
                    .fetchAll(db))
                    .defaulting(to: [])
                    .map { $0.id }
                
                try message.closedGroups.forEach { closedGroup in
                    guard !existingClosedGroupsIds.contains(closedGroup.publicKey) else { return }
                    
                    let keyPair: KeyPair = KeyPair(
                        publicKey: closedGroup.encryptionKeyPublicKey.bytes,
                        secretKey: closedGroup.encryptionKeySecretKey.bytes
                    )
                    
                    try MessageReceiver.handleNewClosedGroup(
                        db,
                        groupPublicKey: closedGroup.publicKey,
                        name: closedGroup.name,
                        encryptionKeyPair: keyPair,
                        members: [String](closedGroup.members),
                        admins: [String](closedGroup.admins),
                        expirationTimer: closedGroup.expirationTimer,
                        formationTimestampMs: message.sentTimestamp!,
                        calledFromConfigHandling: false, // Legacy config isn't an issue
                        using: dependencies
                    )
                }
            }
            
            // Open groups
            for openGroupURL in message.openGroups {
                if let (room, server, publicKey) = SessionUtil.parseCommunity(url: openGroupURL) {
                    let successfullyAddedGroup: Bool = OpenGroupManager.shared
                        .add(
                            db,
                            roomToken: room,
                            server: server,
                            publicKey: publicKey,
                            calledFromConfigHandling: true
                        )
                    
                    if successfullyAddedGroup {
                        db.afterNextTransactionNested { _ in
                            OpenGroupManager.shared.performInitialRequestsAfterAdd(
                                successfullyAddedGroup: successfullyAddedGroup,
                                roomToken: room,
                                server: server,
                                publicKey: publicKey,
                                calledFromConfigHandling: false
                            )
                            .subscribe(on: OpenGroupAPI.workQueue)
                            .sinkUntilComplete()
                        }
                    }
                }
            }
        }
    }
}
