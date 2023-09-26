// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import SessionSnodeKit
import SessionUtilitiesKit
import Sodium

public final class MessageSender {
    // MARK: - Message Preparation
    
    public static func preparedSend(
        _ db: Database,
        message: Message,
        to destination: Message.Destination,
        namespace: SnodeAPI.Namespace?,
        interactionId: Int64?,
        fileIds: [String],
        isSyncMessage: Bool = false,
        using dependencies: Dependencies = Dependencies()
    ) throws -> HTTP.PreparedRequest<Void> {
        // Common logic for all destinations
        let currentUserPublicKey: String = getUserHexEncodedPublicKey(db, using: dependencies)
        let messageSendTimestamp: Int64 = SnodeAPI.currentOffsetTimestampMs(using: dependencies)
        let updatedMessage: Message = message
        
        // Set the message 'sentTimestamp' (Visible messages will already have their sent timestamp set)
        updatedMessage.sentTimestamp = (
            updatedMessage.sentTimestamp ??
            UInt64(messageSendTimestamp)
        )
        
        do {
            switch destination {
                case .contact, .closedGroup:
                    return try preparedSendToSnodeDestination(
                        db,
                        message: updatedMessage,
                        to: destination,
                        namespace: namespace,
                        interactionId: interactionId,
                        fileIds: fileIds,
                        userPublicKey: currentUserPublicKey,
                        messageSendTimestamp: messageSendTimestamp,
                        isSyncMessage: isSyncMessage,
                        using: dependencies
                    )
                    .map { _, _ in () }
                    
                case .openGroup:
                    return try preparedSendToOpenGroupDestination(
                        db,
                        message: updatedMessage,
                        to: destination,
                        interactionId: interactionId,
                        fileIds: fileIds,
                        messageSendTimestamp: messageSendTimestamp,
                        using: dependencies
                    )
                    
                case .openGroupInbox:
                    return try preparedSendToOpenGroupInboxDestination(
                        db,
                        message: message,
                        to: destination,
                        interactionId: interactionId,
                        fileIds: fileIds,
                        userPublicKey: currentUserPublicKey,
                        messageSendTimestamp: messageSendTimestamp,
                        using: dependencies
                    )
            }
        }
        catch let error as MessageSenderError {
            throw MessageSender.handleFailedMessageSend(
                db,
                message: message,
                with: error,
                interactionId: interactionId,
                isSyncMessage: isSyncMessage,
                using: dependencies
            )
        }
    }
    
    internal static func preparedSendToSnodeDestination(
        _ db: Database,
        message: Message,
        to destination: Message.Destination,
        namespace: SnodeAPI.Namespace?,
        interactionId: Int64?,
        fileIds: [String],
        userPublicKey: String,
        messageSendTimestamp: Int64,
        isSyncMessage: Bool = false,
        using dependencies: Dependencies
    ) throws -> HTTP.PreparedRequest<SendMessagesResponse> {
        guard let namespace: SnodeAPI.Namespace = namespace else { throw MessageSenderError.invalidMessage }
        
        /// Set the sender/recipient info (needed to be valid)
        ///
        /// **Note:** The `sentTimestamp` will differ from the `messageSendTimestamp` as it's the time the user originally
        /// sent the message whereas the `messageSendTimestamp` is the time it will be uploaded to the swarm
        let sentTimestamp: UInt64 = (message.sentTimestamp ?? UInt64(messageSendTimestamp))
        let recipient: String = {
            switch destination {
                case .contact(let publicKey): return publicKey
                case .closedGroup(let groupPublicKey): return groupPublicKey
                case .openGroup, .openGroupInbox: preconditionFailure()
            }
        }()
        message.sender = userPublicKey
        message.recipient = recipient
        message.sentTimestamp = sentTimestamp
        
        // Ensure the message is valid
        try MessageSender.ensureValidMessage(message, destination: destination, fileIds: fileIds)
        
        // Attach the user's profile if needed (no need to do so for 'Note to Self' or sync
        // messages as they will be managed by the user config handling
        let isSelfSend: Bool = (recipient == userPublicKey)

        if !isSelfSend, !isSyncMessage, var messageWithProfile: MessageWithProfile = message as? MessageWithProfile {
            let profile: Profile = Profile.fetchOrCreateCurrentUser(db)
            
            if let profileKey: Data = profile.profileEncryptionKey, let profilePictureUrl: String = profile.profilePictureUrl {
                messageWithProfile.profile = VisibleMessage.VMProfile(
                    displayName: profile.name,
                    profileKey: profileKey,
                    profilePictureUrl: profilePictureUrl
                )
            }
            else {
                messageWithProfile.profile = VisibleMessage.VMProfile(displayName: profile.name)
            }
        }
        
        // Perform any pre-send actions
        handleMessageWillSend(db, message: message, interactionId: interactionId, isSyncMessage: isSyncMessage)
        
        // Convert it to protobuf
        let threadId: String = Message.threadId(forMessage: message, destination: destination)
        
        guard let proto = message.toProto(db, threadId: threadId) else {
            throw MessageSenderError.protoConversionFailed
        }
        
        // Serialize the protobuf
        let plaintext: Data = try Result(proto.serializedData())
            .map { serialisedData -> Data in
                switch destination {
                    case .closedGroup(let key) where SessionId.Prefix(from: key) == .group: return serialisedData
                    default: return serialisedData.paddedMessageBody()
                }
            }
            .mapError { MessageSenderError.other("Couldn't serialize proto", $0) }
            .successOrThrow()
        let base64EncodedData: String = try {
            switch (destination, namespace) {
                // Standard one-to-one messages
                case (.contact(let publicKey), .default):
                    let ciphertext: Data = try encryptWithSessionProtocol(
                        db,
                        plaintext: plaintext,
                        for: publicKey,
                        using: dependencies
                    )
                    
                    return try Result(
                        MessageWrapper.wrap(
                            type: .sessionMessage,
                            timestamp: sentTimestamp,
                            senderPublicKey: "",
                            base64EncodedContent: ciphertext.base64EncodedString()
                        )
                    )
                    .mapError { MessageSenderError.other("Couldn't wrap message", $0) }
                    .successOrThrow()
                    .base64EncodedString()
                    
                // Updated group messages should be wrapped _before_ encrypting
                case (.closedGroup(let groupPublicKey), .groupMessages) where SessionId.Prefix(from: groupPublicKey) == .group:
                    return try SessionUtil
                        .encrypt(
                            message: try Result(
                                MessageWrapper.wrap(
                                    type: .closedGroupMessage,
                                    timestamp: sentTimestamp,
                                    senderPublicKey: groupPublicKey,
                                    base64EncodedContent: plaintext.base64EncodedString(),
                                    wrapInWebSocketMessage: false
                                )
                            )
                            .mapError { MessageSenderError.other("Couldn't wrap message", $0) }
                            .successOrThrow(),
                            groupIdentityPublicKey: groupPublicKey,
                            using: dependencies
                        )
                        .base64EncodedString()
                    
                // Config messages should be sent directly rather than via this method
                case (.contact, _): throw MessageSenderError.invalidConfigMessageHandling
                case (.closedGroup(let groupPublicKey), _) where SessionId.Prefix(from: groupPublicKey) == .group:
                    throw MessageSenderError.invalidConfigMessageHandling
                    
                // Legacy groups used a `05` prefix
                case (.closedGroup(let groupPublicKey), _):
                    guard let encryptionKeyPair: ClosedGroupKeyPair = try? ClosedGroupKeyPair.fetchLatestKeyPair(db, threadId: groupPublicKey) else {
                        throw MessageSenderError.noKeyPair
                    }
                    
                    let ciphertext: Data = try encryptWithSessionProtocol(
                        db,
                        plaintext: plaintext,
                        for: SessionId(.standard, publicKey: encryptionKeyPair.publicKey.bytes).hexString,
                        using: dependencies
                    )
                    
                    return try Result(
                        MessageWrapper.wrap(
                            type: .closedGroupMessage,
                            timestamp: sentTimestamp,
                            senderPublicKey: groupPublicKey,
                            base64EncodedContent: ciphertext.base64EncodedString()
                        )
                    )
                    .mapError { MessageSenderError.other("Couldn't wrap message", $0) }
                    .successOrThrow()
                    .base64EncodedString()
                    
                case (.openGroup, _), (.openGroupInbox, _): preconditionFailure()
            }
        }()
        
        // Send the result
        let snodeMessage = SnodeMessage(
            recipient: recipient,
            data: base64EncodedData,
            ttl: MessageSender
                .getSpecifiedTTL(db, threadId: threadId, message: message, isSyncMessage: isSyncMessage)
                .defaulting(to: message.ttl),
            timestampMs: UInt64(messageSendTimestamp)
        )
        
        return try SnodeAPI
            .preparedSendMessage(
                db,
                message: snodeMessage,
                in: namespace,
                authInfo: try SnodeAPI.AuthenticationInfo(db, threadId: threadId, using: dependencies),
                using: dependencies
            )
            .handleEvents(
                receiveOutput: { _, response in
                    let updatedMessage: Message = message
                    updatedMessage.serverHash = response.hash
                    
                    let job: Job? = Job(
                        variant: .notifyPushServer,
                        behaviour: .runOnce,
                        details: NotifyPushServerJob.Details(message: snodeMessage)
                    )
                    let shouldNotify: Bool = {
                        // New groups only run via the updated push server so don't notify
                        switch destination {
                            case .closedGroup(let key) where SessionId.Prefix(from: key) == .group:
                                return false
                            default: break
                        }
                        
                        switch updatedMessage {
                            case is VisibleMessage, is UnsendRequest: return !isSyncMessage
                            case let callMessage as CallMessage:
                                // Note: Other 'CallMessage' types are too big to send as push notifications
                                // so only send the 'preOffer' message as a notification
                                switch callMessage.kind {
                                    case .preOffer: return true
                                    default: return false
                                }

                            default: return false
                        }
                    }()
                    
                    // Save the updated message info and send a PN if needed
                    dependencies[singleton: .storage].write(using: dependencies) { db -> Void in
                        try MessageSender.handleSuccessfulMessageSend(
                            db,
                            message: updatedMessage,
                            to: destination,
                            interactionId: interactionId,
                            serverTimestampMs: nil,   // No server timestamp in snode messages
                            isSyncMessage: isSyncMessage,
                            using: dependencies
                        )

                        guard shouldNotify else { return }

                        dependencies[singleton: .jobRunner].add(
                            db,
                            job: job,
                            canStartJob: true,
                            using: dependencies
                        )
                    }
                    
                    // If we should send a push notification and are sending from the background then
                    // we want to send it on this thread
                    guard
                        let job: Job = job,
                        shouldNotify &&
                        !dependencies[defaults: .appGroup, key: .isMainAppActive]
                    else { return }
                    
                    NotifyPushServerJob.run(
                        job,
                        queue: .main,
                        success: { _, _, _ in },
                        failure: { _, _, _, _ in },
                        deferred: { _, _ in },
                        using: dependencies
                    )
                },
                receiveCompletion: { result in
                    switch result {
                        case .finished: break
                        case .failure(let error):
                            dependencies[singleton: .storage].read(using: dependencies) { db in
                                MessageSender.handleFailedMessageSend(
                                    db,
                                    message: message,
                                    with: .other("Couldn't send message", error),
                                    interactionId: interactionId,
                                    isSyncMessage: isSyncMessage,
                                    using: dependencies
                                )
                            }
                    }
                }
            )
    }
    
    private static func preparedSendToOpenGroupDestination(
        _ db: Database,
        message: Message,
        to destination: Message.Destination,
        interactionId: Int64?,
        fileIds: [String],
        messageSendTimestamp: Int64,
        using dependencies: Dependencies
    ) throws -> HTTP.PreparedRequest<Void> {
        // Note: It's possible to send a message and then delete the open group you sent the message to
        // which would go into this case, so rather than handling it as an invalid state we just want to
        // error in a non-retryable way
        guard
            let message: VisibleMessage = message as? VisibleMessage,
            case .openGroup(let roomToken, let server, let whisperTo, let whisperMods, _) = destination,
            let openGroup: OpenGroup = try? OpenGroup.fetchOne(
                db,
                id: OpenGroup.idFor(roomToken: roomToken, server: server)
            ),
            let userEdKeyPair: KeyPair = Identity.fetchUserEd25519KeyPair(db, using: dependencies)
        else { throw MessageSenderError.invalidMessage }
        
        // Set the sender/recipient info (needed to be valid)
        let threadId: String = OpenGroup.idFor(roomToken: roomToken, server: server)
        message.recipient = [
            server,
            roomToken,
            whisperTo,
            (whisperMods ? "mods" : nil)
        ]
        .compactMap { $0 }
        .joined(separator: ".")
        message.sender = try {
            let capabilities: [Capability.Variant] = (try? Capability
                .select(.variant)
                .filter(Capability.Columns.openGroupServer == server)
                .filter(Capability.Columns.isMissing == false)
                .asRequest(of: Capability.Variant.self)
                .fetchAll(db))
                .defaulting(to: [])
            
            // If the server doesn't support blinding then go with an unblinded id
            guard capabilities.isEmpty || capabilities.contains(.blind) else {
                return SessionId(.unblinded, publicKey: userEdKeyPair.publicKey).hexString
            }
            guard
                let blindedKeyPair: KeyPair = dependencies[singleton: .crypto].generate(
                    .blindedKeyPair(serverPublicKey: openGroup.publicKey, edKeyPair: userEdKeyPair, using: dependencies)
                )
            else { throw MessageSenderError.signingFailed }
            
            return SessionId(.blinded15, publicKey: blindedKeyPair.publicKey).hexString
        }()
        
        // Ensure the message is valid
        try MessageSender.ensureValidMessage(message, destination: destination, fileIds: fileIds)
        
        // Attach the user's profile
        message.profile = VisibleMessage.VMProfile(
            profile: Profile.fetchOrCreateCurrentUser(db),
            blocksCommunityMessageRequests: !db[.checkForCommunityMessageRequests]
        )

        guard !(message.profile?.displayName ?? "").isEmpty else { throw MessageSenderError.noUsername }
        
        // Perform any pre-send actions
        handleMessageWillSend(db, message: message, interactionId: interactionId)
        
        // Convert it to protobuf
        guard let proto = message.toProto(db, threadId: threadId) else {
            throw MessageSenderError.protoConversionFailed
        }
        
        // Serialize the protobuf
        let plaintext: Data
        
        do { plaintext = try proto.serializedData().paddedMessageBody() }
        catch { throw MessageSenderError.other("Couldn't serialize proto", error) }
        
        return try OpenGroupAPI
            .preparedSend(
                db,
                plaintext: plaintext,
                to: roomToken,
                on: server,
                whisperTo: whisperTo,
                whisperMods: whisperMods,
                fileIds: fileIds
            )
            .handleEvents(
                receiveOutput: { _, response in
                    let serverTimestampMs: UInt64? = response.posted.map { UInt64(floor($0 * 1000)) }
                    let updatedMessage: Message = message
                    updatedMessage.openGroupServerMessageId = UInt64(response.id)
                    
                    dependencies[singleton: .storage].write(using: dependencies) { db in
                        // The `posted` value is in seconds but we sent it in ms so need that for de-duping
                        try MessageSender.handleSuccessfulMessageSend(
                            db,
                            message: updatedMessage,
                            to: destination,
                            interactionId: interactionId,
                            serverTimestampMs: serverTimestampMs,
                            isSyncMessage: false,   // No sync messages in open groups
                            using: dependencies
                        )
                    }
                },
                receiveCompletion: { result in
                    switch result {
                        case .finished: break
                        case .failure(let error):
                            dependencies[singleton: .storage].read(using: dependencies) { db in
                                MessageSender.handleFailedMessageSend(
                                    db,
                                    message: message,
                                    with: .other("Couldn't send message", error),
                                    interactionId: interactionId,
                                    isSyncMessage: false,   // No sync messages in open groups
                                    using: dependencies
                                )
                            }
                    }
                }
            )
            .map { _, _ in () }
    }
    
    private static func preparedSendToOpenGroupInboxDestination(
        _ db: Database,
        message: Message,
        to destination: Message.Destination,
        interactionId: Int64?,
        fileIds: [String],
        userPublicKey: String,
        messageSendTimestamp: Int64,
        using dependencies: Dependencies
    ) throws -> HTTP.PreparedRequest<Void> {
        // The `openGroupInbox` destination does not support attachments
        guard
            fileIds.isEmpty,
            case .openGroupInbox(let server, let openGroupPublicKey, let recipientBlindedPublicKey) = destination
        else { throw MessageSenderError.invalidMessage }
        
        message.sender = userPublicKey
        message.recipient = recipientBlindedPublicKey
        
        // Attach the user's profile if needed
        if let message: VisibleMessage = message as? VisibleMessage {
            let profile: Profile = Profile.fetchOrCreateCurrentUser(db)
            
            if let profileKey: Data = profile.profileEncryptionKey, let profilePictureUrl: String = profile.profilePictureUrl {
                message.profile = VisibleMessage.VMProfile(
                    displayName: profile.name,
                    profileKey: profileKey,
                    profilePictureUrl: profilePictureUrl
                )
            }
            else {
                message.profile = VisibleMessage.VMProfile(displayName: profile.name)
            }
        }
        
        // Perform any pre-send actions
        handleMessageWillSend(db, message: message, interactionId: interactionId)
        
        // Convert it to protobuf
        guard let proto = message.toProto(db, threadId: recipientBlindedPublicKey) else {
            throw MessageSenderError.protoConversionFailed
        }
        
        // Serialize the protobuf
        let plaintext: Data
        
        do { plaintext = try proto.serializedData().paddedMessageBody() }
        catch { throw MessageSenderError.other("Couldn't serialize proto", error) }
        
        // Encrypt the serialized protobuf
        let ciphertext: Data
        
        do {
            ciphertext = try encryptWithSessionBlindingProtocol(
                db,
                plaintext: plaintext,
                for: recipientBlindedPublicKey,
                openGroupPublicKey: openGroupPublicKey,
                using: dependencies
            )
        }
        catch { throw MessageSenderError.other("Couldn't encrypt message for destination: \(destination)", error) }
        
        return try OpenGroupAPI
            .preparedSend(
                db,
                ciphertext: ciphertext,
                toInboxFor: recipientBlindedPublicKey,
                on: server,
                using: dependencies
            )
            .handleEvents(
                receiveOutput: { _, response in
                    let updatedMessage: Message = message
                    updatedMessage.openGroupServerMessageId = UInt64(response.id)
                    
                    dependencies[singleton: .storage].write(using: dependencies) { db in
                        // The `posted` value is in seconds but we sent it in ms so need that for de-duping
                        try MessageSender.handleSuccessfulMessageSend(
                            db,
                            message: updatedMessage,
                            to: destination,
                            interactionId: interactionId,
                            serverTimestampMs: UInt64(floor(response.posted * 1000)),
                            isSyncMessage: false,   // No sync messages in open groups
                            using: dependencies
                        )
                    }
                },
                receiveCompletion: { result in
                    switch result {
                        case .finished: break
                        case .failure(let error):
                            dependencies[singleton: .storage].read(using: dependencies) { db in
                                MessageSender.handleFailedMessageSend(
                                    db,
                                    message: message,
                                    with: .other("Couldn't send message", error),
                                    interactionId: interactionId,
                                    isSyncMessage: false,   // No sync messages in open groups
                                    using: dependencies
                                )
                            }
                    }
                }
            )
            .map { _, _ in () }
    }

    // MARK: - Success & Failure Handling
    
    private static func ensureValidMessage(
        _ message: Message,
        destination: Message.Destination,
        fileIds: [String]
    ) throws {
        /// Check the message itself is valid
        guard message.isValid else { throw MessageSenderError.invalidMessage }
        
        /// We now allow the creation of message data without validating it's attachments have finished uploading first, this is here to
        /// ensure we don't send a message which should have uploaded files
        ///
        /// If you see this error then you need to upload the associated attachments prior to sending the message
        if let visibleMessage: VisibleMessage = message as? VisibleMessage {
            let expectedAttachmentUploadCount: Int = (
                visibleMessage.attachmentIds.count +
                (visibleMessage.linkPreview?.attachmentId != nil ? 1 : 0) +
                (visibleMessage.quote?.attachmentId != nil ? 1 : 0)
            )
            
            guard expectedAttachmentUploadCount == fileIds.count else {
                throw MessageSenderError.attachmentsNotUploaded
            }
        }
    }
    
    public static func handleMessageWillSend(
        _ db: Database,
        message: Message,
        interactionId: Int64?,
        isSyncMessage: Bool = false
    ) {
        // If the message was a reaction then we don't want to do anything to the original
        // interaction (which the 'interactionId' is pointing to
        guard (message as? VisibleMessage)?.reaction == nil else { return }
        
        // Mark messages as "sending"/"syncing" if needed (this is for retries)
        _ = try? RecipientState
            .filter(RecipientState.Columns.interactionId == interactionId)
            .filter(isSyncMessage ?
                RecipientState.Columns.state == RecipientState.State.failedToSync :
                RecipientState.Columns.state == RecipientState.State.failed
            )
            .updateAll(
                db,
                RecipientState.Columns.state.set(to: isSyncMessage ?
                    RecipientState.State.syncing :
                    RecipientState.State.sending
                )
            )
    }
    
    private static func handleSuccessfulMessageSend(
        _ db: Database,
        message: Message,
        to destination: Message.Destination,
        interactionId: Int64?,
        serverTimestampMs: UInt64?,
        isSyncMessage: Bool,
        using dependencies: Dependencies
    ) throws {
        // If the message was a reaction then we want to update the reaction instead of the original
        // interaction (which the 'interactionId' is pointing to
        if let visibleMessage: VisibleMessage = message as? VisibleMessage, let reaction: VisibleMessage.VMReaction = visibleMessage.reaction {
            try Reaction
                .filter(Reaction.Columns.interactionId == interactionId)
                .filter(Reaction.Columns.authorId == reaction.publicKey)
                .filter(Reaction.Columns.emoji == reaction.emoji)
                .updateAll(db, Reaction.Columns.serverHash.set(to: message.serverHash))
        }
        else {
            // Otherwise we do want to try and update the referenced interaction
            let interaction: Interaction? = try interaction(db, for: message, interactionId: interactionId)
            
            // Get the visible message if possible
            if let interaction: Interaction = interaction {
                // Only store the server hash of a sync message if the message is self send valid
                if (message.isSelfSendValid && isSyncMessage || !isSyncMessage) {
                    try interaction.with(
                        serverHash: message.serverHash,
                        // Track the open group server message ID and update server timestamp (use server
                        // timestamp for open group messages otherwise the quote messages may not be able
                        // to be found by the timestamp on other devices
                        timestampMs: (message.openGroupServerMessageId == nil ?
                            nil :
                            serverTimestampMs.map { Int64($0) }
                        ),
                        openGroupServerMessageId: message.openGroupServerMessageId.map { Int64($0) }
                    ).update(db)
                    
                    if
                        interaction.isExpiringMessage && isSyncMessage,
                        let startedAtMs: Double = interaction.expiresStartedAtMs,
                        let expiresInSeconds: TimeInterval = interaction.expiresInSeconds,
                        let serverHash: String = message.serverHash
                    {
                        let expirationTimestampMs: Int64 = Int64(startedAtMs + expiresInSeconds * 1000)
                        dependencies[singleton: .jobRunner].add(
                            db,
                            job: Job(
                                variant: .expirationUpdate,
                                behaviour: .runOnce,
                                threadId: interaction.threadId,
                                details: ExpirationUpdateJob.Details(
                                    serverHashes: [serverHash],
                                    expirationTimestampMs: expirationTimestampMs
                                )
                            ),
                            canStartJob: true,
                            using: dependencies
                        )
                    }
                }
                
                // Mark the message as sent
                try interaction.recipientStates
                    .filter(RecipientState.Columns.state != RecipientState.State.sent)
                    .updateAll(db, RecipientState.Columns.state.set(to: RecipientState.State.sent))
            }
        }
        
        // Extract the threadId from the message
        let threadId: String = Message.threadId(forMessage: message, destination: destination)
        
        // Prevent ControlMessages from being handled multiple times if not supported
        try? ControlMessageProcessRecord(
            threadId: threadId,
            message: message,
            serverExpirationTimestamp: (
                (TimeInterval(SnodeAPI.currentOffsetTimestampMs()) / 1000) +
                ControlMessageProcessRecord.defaultExpirationSeconds
            )
        )?.insert(db)

        // Sync the message if needed
        scheduleSyncMessageIfNeeded(
            db,
            message: message,
            destination: destination,
            threadId: threadId,
            interactionId: interactionId,
            isAlreadySyncMessage: isSyncMessage,
            using: dependencies
        )
    }

    @discardableResult internal static func handleFailedMessageSend(
        _ db: Database,
        message: Message,
        with error: MessageSenderError,
        interactionId: Int64?,
        isSyncMessage: Bool,
        using dependencies: Dependencies
    ) -> Error {
        // Log a message for any 'other' errors
        switch error {
            case .other(let description, let error): SNLog("\(description) due to error: \(error).")
            default: break
        }
        
        // If the message was a reaction then we don't want to do anything to the original
        // interaciton (which the 'interactionId' is pointing to
        guard (message as? VisibleMessage)?.reaction == nil else { return error }
        
        // Check if we need to mark any "sending" recipients as "failed"
        //
        // Note: The 'db' could be either read-only or writeable so we determine
        // if a change is required, and if so dispatch to a separate queue for the
        // actual write
        let rowIds: [Int64] = (try? RecipientState
            .select(Column.rowID)
            .filter(RecipientState.Columns.interactionId == interactionId)
            .filter(!isSyncMessage ?
                RecipientState.Columns.state == RecipientState.State.sending : (
                    RecipientState.Columns.state == RecipientState.State.syncing ||
                    RecipientState.Columns.state == RecipientState.State.sent
                )
            )
            .asRequest(of: Int64.self)
            .fetchAll(db))
            .defaulting(to: [])
        
        guard !rowIds.isEmpty else { return error }
        
        // Need to dispatch to a different thread to prevent a potential db re-entrancy
        // issue from occuring in some cases
        DispatchQueue.global(qos: .background).async(using: dependencies) {
            dependencies[singleton: .storage].write { db in
                try RecipientState
                    .filter(rowIds.contains(Column.rowID))
                    .updateAll(
                        db,
                        RecipientState.Columns.state.set(
                            to: (isSyncMessage ? RecipientState.State.failedToSync : RecipientState.State.failed)
                        ),
                        RecipientState.Columns.mostRecentFailureText.set(to: error.localizedDescription)
                    )
            }
        }
        
        return error
    }
    
    // MARK: - Convenience
    
    private static func interaction(_ db: Database, for message: Message, interactionId: Int64?) throws -> Interaction? {
        if let interactionId: Int64 = interactionId {
            return try Interaction.fetchOne(db, id: interactionId)
        }
        
        if let sentTimestamp: Double = message.sentTimestamp.map({ Double($0) }) {
            return try Interaction
                .filter(Interaction.Columns.timestampMs == sentTimestamp)
                .fetchOne(db)
        }
        
        return nil
    }
    
    public static func scheduleSyncMessageIfNeeded(
        _ db: Database,
        message: Message,
        destination: Message.Destination,
        threadId: String?,
        interactionId: Int64?,
        isAlreadySyncMessage: Bool,
        using dependencies: Dependencies
    ) {
        // Sync the message if it's not a sync message, wasn't already sent to the current user and
        // it's a message type which should be synced
        let currentUserPublicKey = getUserHexEncodedPublicKey(db, using: dependencies)
        
        if
            case .contact(let publicKey) = destination,
            !isAlreadySyncMessage,
            publicKey != currentUserPublicKey,
            Message.shouldSync(message: message)
        {
            if let message = message as? VisibleMessage { message.syncTarget = publicKey }
            if let message = message as? ExpirationTimerUpdate { message.syncTarget = publicKey }
            
            dependencies[singleton: .jobRunner].add(
                db,
                job: Job(
                    variant: .messageSend,
                    threadId: threadId,
                    interactionId: interactionId,
                    details: MessageSendJob.Details(
                        destination: .contact(publicKey: currentUserPublicKey),
                        message: message,
                        isSyncMessage: true
                    )
                ),
                canStartJob: true,
                using: dependencies
            )
        }
    }
}
