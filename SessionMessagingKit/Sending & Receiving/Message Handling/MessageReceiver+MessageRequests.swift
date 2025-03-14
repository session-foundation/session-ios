// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import Combine
import GRDB
import SessionUtilitiesKit
import SessionSnodeKit

extension MessageReceiver {
    internal static func handleMessageRequestResponse(
        _ db: Database,
        message: MessageRequestResponse,
        using dependencies: Dependencies
    ) throws {
        let userSessionId = dependencies[cache: .general].sessionId
        var blindedContactIds: [String] = []
        
        // Ignore messages which were sent from the current user
        guard
            message.sender != userSessionId.hexString,
            let senderId: String = message.sender
        else { throw MessageReceiverError.invalidMessage }
        
        // Update profile if needed (want to do this regardless of whether the message exists or
        // not to ensure the profile info gets sync between a users devices at every chance)
        if let profile = message.profile {
            let messageSentTimestamp: TimeInterval = TimeInterval(Double(message.sentTimestampMs ?? 0) / 1000)
            
            try Profile.updateIfNeeded(
                db,
                publicKey: senderId,
                displayNameUpdate: .contactUpdate(profile.displayName),
                displayPictureUpdate: {
                    guard
                        let profilePictureUrl: String = profile.profilePictureUrl,
                        let profileKey: Data = profile.profileKey
                    else { return .none }
                    
                    return .contactUpdateTo(
                        url: profilePictureUrl,
                        key: profileKey,
                        fileName: nil
                    )
                }(),
                sentTimestamp: messageSentTimestamp,
                using: dependencies
            )
        }
        
        // Need to handle a `MessageRequestResponse` sent to a blinded thread (ie. check if the sender matches
        // the blinded ids of any threads)
        let blindedThreadIds: Set<String> = (try? SessionThread
            .select(.id)
            .filter(SessionThread.Columns.variant == SessionThread.Variant.contact)
            .filter(
                (
                    SessionThread.Columns.id > SessionId.Prefix.blinded15.rawValue &&
                    SessionThread.Columns.id < SessionId.Prefix.blinded15.endOfRangeString
                ) ||
                (
                    SessionThread.Columns.id > SessionId.Prefix.blinded25.rawValue &&
                    SessionThread.Columns.id < SessionId.Prefix.blinded25.endOfRangeString
                )
            )
            .asRequest(of: String.self)
            .fetchSet(db))
            .defaulting(to: [])
        let pendingBlindedIdLookups: [BlindedIdLookup] = (try? BlindedIdLookup
            .filter(blindedThreadIds.contains(BlindedIdLookup.Columns.blindedId))
            .fetchAll(db))
            .defaulting(to: [])
        let earliestCreationTimestamp: TimeInterval = (try? SessionThread
            .filter(blindedThreadIds.contains(SessionThread.Columns.id))
            .select(max(SessionThread.Columns.creationDateTimestamp))
            .fetchOne(db))
            .defaulting(to: (dependencies[cache: .snodeAPI].currentOffsetTimestampMs() / 1000))
        
        // Prep the unblinded thread
        let unblindedThread: SessionThread = try SessionThread.upsert(
            db,
            id: senderId,
            variant: .contact,
            values: SessionThread.TargetValues(
                creationDateTimestamp: .setTo(earliestCreationTimestamp),
                shouldBeVisible: .useExisting
            ),
            using: dependencies
        )
        
        // Loop through all blinded threads and extract any interactions relating to the user accepting
        // the message request
        try pendingBlindedIdLookups.forEach { blindedIdLookup in
            // If the sessionId matches the blindedId then this thread needs to be converted to an
            // un-blinded thread
            guard
                dependencies[singleton: .crypto].verify(
                    .sessionId(
                        senderId,
                        matchesBlindedId: blindedIdLookup.blindedId,
                        serverPublicKey: blindedIdLookup.openGroupPublicKey
                    )
                )
            else { return }
            
            // Update the lookup
            try blindedIdLookup
                .with(sessionId: senderId)
                .upserted(db)
            
            // Add the `blindedId` to an array so we can remove them at the end of processing
            blindedContactIds.append(blindedIdLookup.blindedId)
            
            // Update all interactions to be on the new thread
            // Note: Pending `MessageSendJobs` _shouldn't_ be an issue as even if they are sent after the
            // un-blinding of a thread, the logic when handling the sent messages should automatically
            // assign them to the correct thread
            try Interaction
                .filter(Interaction.Columns.threadId == blindedIdLookup.blindedId)
                .updateAll(db, Interaction.Columns.threadId.set(to: unblindedThread.id))
            
            _ = try SessionThread
                .deleteOrLeave(
                    db,
                    type: .deleteContactConversationAndContact, // Blinded contact isn't synced anyway
                    threadId: blindedIdLookup.blindedId,
                    threadVariant: .contact,
                    using: dependencies
                )
        }
        
        // Update the `didApproveMe` state of the sender
        try updateContactApprovalStatusIfNeeded(
            db,
            senderSessionId: senderId,
            threadId: nil,
            using: dependencies
        )
        
        // If there were blinded contacts which have now been resolved to this contact then we should remove
        // the blinded contact and we also need to assume that the 'sender' is a newly created contact and
        // hence need to update it's `isApproved` state
        if !blindedContactIds.isEmpty {
            _ = try? Contact
                .filter(ids: blindedContactIds)
                .deleteAll(db)
            
            try updateContactApprovalStatusIfNeeded(
                db,
                senderSessionId: userSessionId.hexString,
                threadId: unblindedThread.id,
                using: dependencies
            )
        }
        
        // Notify the user of their approval (Note: This will always appear in the un-blinded thread)
        //
        // Note: We want to do this last as it'll mean the un-blinded thread gets updated and the
        // contact approval status will have been updated at this point (which will mean the
        // `isMessageRequest` will return correctly after this is saved)
        _ = try Interaction(
            serverHash: message.serverHash,
            threadId: unblindedThread.id,
            threadVariant: unblindedThread.variant,
            authorId: senderId,
            variant: .infoMessageRequestAccepted,
            timestampMs: (
                message.sentTimestampMs.map { Int64($0) } ??
                dependencies[cache: .snodeAPI].currentOffsetTimestampMs()
            ),
            using: dependencies
        ).inserted(db)
    }
    
    internal static func updateContactApprovalStatusIfNeeded(
        _ db: Database,
        senderSessionId: String,
        threadId: String?,
        using dependencies: Dependencies
    ) throws {
        let userSessionId: SessionId = dependencies[cache: .general].sessionId
        
        // If the sender of the message was the current user
        if senderSessionId == userSessionId.hexString {
            // Retrieve the contact for the thread the message was sent to (excluding 'NoteToSelf'
            // threads) and if the contact isn't flagged as approved then do so
            guard
                let threadId: String = threadId,
                let thread: SessionThread = try? SessionThread.fetchOne(db, id: threadId),
                !thread.isNoteToSelf(db, using: dependencies)
            else { return }
            
            // Sending a message to someone flags them as approved so create the contact record if
            // it doesn't exist
            let contact: Contact = Contact.fetchOrCreate(db, id: threadId, using: dependencies)
            
            guard !contact.isApproved else { return }
            
            try? contact.upsert(db)
            _ = try? Contact
                .filter(id: threadId)
                .updateAllAndConfig(
                    db,
                    Contact.Columns.isApproved.set(to: true),
                    using: dependencies
                )
        }
        else {
            // The message was sent to the current user so flag their 'didApproveMe' as true (can't send a message to
            // someone without approving them)
            let contact: Contact = Contact.fetchOrCreate(db, id: senderSessionId, using: dependencies)
            
            guard !contact.didApproveMe else { return }

            try? contact.upsert(db)
            _ = try? Contact
                .filter(id: senderSessionId)
                .updateAllAndConfig(
                    db,
                    Contact.Columns.didApproveMe.set(to: true),
                    using: dependencies
                )
        }
    }
}
