// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import PromiseKit
import SessionSnodeKit
import SessionUtilitiesKit
import Sodium

public final class MessageSender {
    // MARK: - Preparation
    
    public static func prep(
        _ db: Database,
        signalAttachments: [SignalAttachment],
        for interactionId: Int64
    ) throws {
        try signalAttachments.enumerated().forEach { index, signalAttachment in
            let maybeAttachment: Attachment? = Attachment(
                variant: (signalAttachment.isVoiceMessage ?
                    .voiceMessage :
                    .standard
                ),
                contentType: signalAttachment.mimeType,
                dataSource: signalAttachment.dataSource,
                sourceFilename: signalAttachment.sourceFilename,
                caption: signalAttachment.captionText
            )
            
            guard let attachment: Attachment = maybeAttachment else { return }
            
            let interactionAttachment: InteractionAttachment = InteractionAttachment(
                albumIndex: index,
                interactionId: interactionId,
                attachmentId: attachment.id
            )
            
            try attachment.insert(db)
            try interactionAttachment.insert(db)
        }
    }

    // MARK: - Convenience
    
    public static func sendImmediate(
        _ db: Database,
        message: Message,
        to destination: Message.Destination,
        interactionId: Int64?,
        isSyncMessage: Bool
    ) throws -> Promise<Void> {
        switch destination {
            case .contact, .closedGroup:
                return try sendToSnodeDestination(db, message: message, to: destination, interactionId: interactionId, isSyncMessage: isSyncMessage)

            case .openGroup:
                return sendToOpenGroupDestination(db, message: message, to: destination, interactionId: interactionId)
                
            case .openGroupInbox:
                return sendToOpenGroupInboxDestination(db, message: message, to: destination, interactionId: interactionId)
        }
    }

    // MARK: One-on-One Chats & Closed Groups
    
    internal static func sendToSnodeDestination(
        _ db: Database,
        message: Message,
        to destination: Message.Destination,
        interactionId: Int64?,
        isSyncMessage: Bool = false
    ) throws -> Promise<Void> {
        let (promise, seal) = Promise<Void>.pending()
        let currentUserPublicKey: String = getUserHexEncodedPublicKey(db)
        let messageSendTimestamp: Int64 = SnodeAPI.currentOffsetTimestampMs()
        
        // Set the timestamp, sender and recipient
        message.sentTimestamp = (
            message.sentTimestamp ??     // Visible messages will already have their sent timestamp set
            UInt64(messageSendTimestamp)
        )
        message.sender = currentUserPublicKey
        message.recipient = {
            switch destination {
                case .contact(let publicKey): return publicKey
                case .closedGroup(let groupPublicKey): return groupPublicKey
                case .openGroup, .openGroupInbox: preconditionFailure()
            }
        }()
        
        // Set the failure handler (need it here already for precondition failure handling)
        func handleFailure(_ db: Database, with error: MessageSenderError) {
            MessageSender.handleFailedMessageSend(db, message: message, with: error, interactionId: interactionId, isSyncMessage: isSyncMessage)
            seal.reject(error)
        }
        
        // Validate the message
        guard message.isValid else {
            handleFailure(db, with: .invalidMessage)
            return promise
        }
        
        // Attach the user's profile if needed
        if !isSyncMessage, var messageWithProfile: MessageWithProfile = message as? MessageWithProfile {
            let profile: Profile = Profile.fetchOrCreateCurrentUser(db)
            
            if let profileKey: Data = profile.profileEncryptionKey?.keyData, let profilePictureUrl: String = profile.profilePictureUrl {
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
        guard let proto = message.toProto(db) else {
            handleFailure(db, with: .protoConversionFailed)
            return promise
        }
        
        // Serialize the protobuf
        let plaintext: Data
        
        do {
            plaintext = try proto.serializedData().paddedMessageBody()
        }
        catch {
            SNLog("Couldn't serialize proto due to error: \(error).")
            handleFailure(db, with: .other(error))
            return promise
        }
        
        // Encrypt the serialized protobuf
        let ciphertext: Data
        do {
            switch destination {
                case .contact(let publicKey):
                    ciphertext = try encryptWithSessionProtocol(plaintext, for: publicKey)
                    
                case .closedGroup(let groupPublicKey):
                    guard let encryptionKeyPair: ClosedGroupKeyPair = try? ClosedGroupKeyPair.fetchLatestKeyPair(db, threadId: groupPublicKey) else {
                        throw MessageSenderError.noKeyPair
                    }
                    
                    ciphertext = try encryptWithSessionProtocol(
                        plaintext,
                        for: SessionId(.standard, publicKey: encryptionKeyPair.publicKey.bytes).hexString
                    )
                    
                case .openGroup, .openGroupInbox: preconditionFailure()
            }
        }
        catch {
            SNLog("Couldn't encrypt message for destination: \(destination) due to error: \(error).")
            handleFailure(db, with: .other(error))
            return promise
        }
        
        // Wrap the result
        let kind: SNProtoEnvelope.SNProtoEnvelopeType
        let senderPublicKey: String
        
        switch destination {
            case .contact:
                kind = .sessionMessage
                senderPublicKey = ""
                
            case .closedGroup(let groupPublicKey):
                kind = .closedGroupMessage
                senderPublicKey = groupPublicKey
            
            case .openGroup, .openGroupInbox: preconditionFailure()
        }
        
        let wrappedMessage: Data
        do {
            wrappedMessage = try MessageWrapper.wrap(type: kind, timestamp: message.sentTimestamp!,
                senderPublicKey: senderPublicKey, base64EncodedContent: ciphertext.base64EncodedString())
        }
        catch {
            SNLog("Couldn't wrap message due to error: \(error).")
            handleFailure(db, with: .other(error))
            return promise
        }
        
        // Send the result
        let base64EncodedData = wrappedMessage.base64EncodedString()

        let snodeMessage = SnodeMessage(
            recipient: message.recipient!,
            data: base64EncodedData,
            ttl: message.ttl,
            timestampMs: UInt64(messageSendTimestamp)
        )
        
        SnodeAPI
            .sendMessage(
                snodeMessage,
                isClosedGroupMessage: (kind == .closedGroupMessage),
                isConfigMessage: (message is ConfigurationMessage)
            )
            .done(on: DispatchQueue.global(qos: .default)) { promises in
                let promiseCount = promises.count
                var isSuccess = false
                var errorCount = 0

                promises.forEach {
                    let _ = $0.done(on: DispatchQueue.global(qos: .default)) { responseData in
                        guard !isSuccess else { return } // Succeed as soon as the first promise succeeds
                        isSuccess = true

                        Storage.shared.write { db in
                            let responseJson: JSON? = try? JSONSerialization.jsonObject(with: responseData, options: [ .fragmentsAllowed ]) as? JSON
                            message.serverHash = (responseJson?["hash"] as? String)
                            
                            try MessageSender.handleSuccessfulMessageSend(
                                db,
                                message: message,
                                to: destination,
                                interactionId: interactionId,
                                isSyncMessage: isSyncMessage
                            )
                            
                            let shouldNotify: Bool = {
                                // Don't send a notification when sending messages in 'Note to Self'
                                guard message.recipient != currentUserPublicKey else { return false }
                                
                                switch message {
                                    case is VisibleMessage, is UnsendRequest: return !isSyncMessage
                                    case let callMessage as CallMessage:
                                        switch callMessage.kind {
                                            case .preOffer: return true
                                            default: return false
                                        }
                                        
                                    default: return false
                                }
                            }()
                            
                            /*
                            if let closedGroupControlMessage = message as? ClosedGroupControlMessage, case .new = closedGroupControlMessage.kind {
                                shouldNotify = true
                            }
                             */
                            guard shouldNotify else {
                                seal.fulfill(())
                                return
                            }
                            
                            let job: Job? = Job(
                                variant: .notifyPushServer,
                                behaviour: .runOnce,
                                details: NotifyPushServerJob.Details(message: snodeMessage)
                            )
                            let isMainAppActive: Bool = (UserDefaults.sharedLokiProject?[.isMainAppActive])
                                .defaulting(to: false)
                            
                            if isMainAppActive {
                                JobRunner.add(db, job: job)
                                seal.fulfill(())
                            }
                            else if let job: Job = job {
                                NotifyPushServerJob.run(
                                    job,
                                    queue: DispatchQueue.global(qos: .default),
                                    success: { _, _ in seal.fulfill(()) },
                                    failure: { _, _, _ in
                                        // Always fulfill because the notify PN server job isn't critical.
                                        seal.fulfill(())
                                    },
                                    deferred: { _ in
                                        // Always fulfill because the notify PN server job isn't critical.
                                        seal.fulfill(())
                                    }
                                )
                            }
                            else {
                                // Always fulfill because the notify PN server job isn't critical.
                                seal.fulfill(())
                            }
                        }
                    }
                    $0.catch(on: DispatchQueue.global(qos: .default)) { error in
                        errorCount += 1
                        guard errorCount == promiseCount else { return } // Only error out if all promises failed
                        
                        Storage.shared.read { db in
                            handleFailure(db, with: .other(error))
                        }
                    }
                }
            }
            .catch(on: DispatchQueue.global(qos: .default)) { error in
                SNLog("Couldn't send message due to error: \(error).")
                
                Storage.shared.read { db in
                    handleFailure(db, with: .other(error))
                }
            }
        
        return promise
    }

    // MARK: Open Groups
    
    internal static func sendToOpenGroupDestination(
        _ db: Database,
        message: Message,
        to destination: Message.Destination,
        interactionId: Int64?,
        dependencies: SMKDependencies = SMKDependencies()
    ) -> Promise<Void> {
        let (promise, seal) = Promise<Void>.pending()
        
        // Set the timestamp, sender and recipient
        if message.sentTimestamp == nil { // Visible messages will already have their sent timestamp set
            message.sentTimestamp = UInt64(SnodeAPI.currentOffsetTimestampMs())
        }
        
        switch destination {
            case .contact, .closedGroup, .openGroupInbox: preconditionFailure()
            case .openGroup(let roomToken, let server, let whisperTo, let whisperMods, _):
                message.recipient = [
                    server,
                    roomToken,
                    whisperTo,
                    (whisperMods ? "mods" : nil)
                ]
                .compactMap { $0 }
                .joined(separator: ".")
        }
        
        // Note: It's possible to send a message and then delete the open group you sent the message to
        // which would go into this case, so rather than handling it as an invalid state we just want to
        // error in a non-retryable way
        guard
            case .openGroup(let roomToken, let server, let whisperTo, let whisperMods, let fileIds) = destination
        else {
            seal.reject(MessageSenderError.invalidMessage)
            return promise
        }
        
        // Set the failure handler (need it here already for precondition failure handling)
        func handleFailure(_ db: Database, with error: MessageSenderError) {
            MessageSender.handleFailedMessageSend(db, message: message, with: error, interactionId: interactionId)
            seal.reject(error)
        }
        
        // Validate the message
        guard let message = message as? VisibleMessage else {
            #if DEBUG
            preconditionFailure()
            #else
            handleFailure(db, with: MessageSenderError.invalidMessage)
            return promise
            #endif
        }
        guard message.isValid else {
            handleFailure(db, with: .invalidMessage)
            return promise
        }
        
        // Attach the user's profile
        message.profile = VisibleMessage.VMProfile(
            profile: Profile.fetchOrCreateCurrentUser()
        )

        if (message.profile?.displayName ?? "").isEmpty {
            handleFailure(db, with: .noUsername)
            return promise
        }
        
        // Perform any pre-send actions
        handleMessageWillSend(db, message: message, interactionId: interactionId)
        
        // Convert it to protobuf
        guard let proto = message.toProto(db) else {
            handleFailure(db, with: .protoConversionFailed)
            return promise
        }
        
        // Serialize the protobuf
        let plaintext: Data
        
        do {
            plaintext = try proto.serializedData().paddedMessageBody()
        }
        catch {
            SNLog("Couldn't serialize proto due to error: \(error).")
            handleFailure(db, with: .other(error))
            return promise
        }
        
        // Send the result
        OpenGroupAPI
            .send(
                db,
                plaintext: plaintext,
                to: roomToken,
                on: server,
                whisperTo: whisperTo,
                whisperMods: whisperMods,
                fileIds: fileIds,
                using: dependencies
            )
            .done(on: DispatchQueue.global(qos: .default)) { responseInfo, data in
                message.openGroupServerMessageId = UInt64(data.id)
                let serverTimestampMs: UInt64? = data.posted.map { UInt64(floor($0 * 1000)) }
                
                dependencies.storage.write { db in
                    // The `posted` value is in seconds but we sent it in ms so need that for de-duping
                    try MessageSender.handleSuccessfulMessageSend(
                        db,
                        message: message,
                        to: destination,
                        interactionId: interactionId,
                        serverTimestampMs: serverTimestampMs
                    )
                    seal.fulfill(())
                }
            }
            .catch(on: DispatchQueue.global(qos: .default)) { error in
                dependencies.storage.read { db in
                    handleFailure(db, with: .other(error))
                }
            }
        
        return promise
    }

    internal static func sendToOpenGroupInboxDestination(
        _ db: Database,
        message: Message,
        to destination: Message.Destination,
        interactionId: Int64?,
        dependencies: SMKDependencies = SMKDependencies()
    ) -> Promise<Void> {
        let (promise, seal) = Promise<Void>.pending()
        
        guard case .openGroupInbox(let server, let openGroupPublicKey, let recipientBlindedPublicKey) = destination else {
            preconditionFailure()
        }
        
        // Set the timestamp, sender and recipient
        if message.sentTimestamp == nil { // Visible messages will already have their sent timestamp set
            message.sentTimestamp = UInt64(SnodeAPI.currentOffsetTimestampMs())
        }
        
        message.recipient = recipientBlindedPublicKey
        
        // Set the failure handler (need it here already for precondition failure handling)
        func handleFailure(_ db: Database, with error: MessageSenderError) {
            MessageSender.handleFailedMessageSend(db, message: message, with: error, interactionId: interactionId)
            seal.reject(error)
        }
        
        // Attach the user's profile if needed
        if let message: VisibleMessage = message as? VisibleMessage {
            let profile: Profile = Profile.fetchOrCreateCurrentUser(db)
            
            if let profileKey: Data = profile.profileEncryptionKey?.keyData, let profilePictureUrl: String = profile.profilePictureUrl {
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
        guard let proto = message.toProto(db) else {
            handleFailure(db, with: .protoConversionFailed)
            return promise
        }
        
        // Serialize the protobuf
        let plaintext: Data
        
        do {
            plaintext = try proto.serializedData().paddedMessageBody()
        }
        catch {
            SNLog("Couldn't serialize proto due to error: \(error).")
            handleFailure(db, with: .other(error))
            return promise
        }
        
        // Encrypt the serialized protobuf
        let ciphertext: Data
        
        do {
            ciphertext = try encryptWithSessionBlindingProtocol(
                plaintext,
                for: recipientBlindedPublicKey,
                openGroupPublicKey: openGroupPublicKey,
                using: dependencies
            )
        }
        catch {
            SNLog("Couldn't encrypt message for destination: \(destination) due to error: \(error).")
            handleFailure(db, with: .other(error))
            return promise
        }
        
        // Send the result
        OpenGroupAPI
            .send(
                db,
                ciphertext: ciphertext,
                toInboxFor: recipientBlindedPublicKey,
                on: server,
                using: dependencies
            )
            .done(on: DispatchQueue.global(qos: .default)) { responseInfo, data in
                message.openGroupServerMessageId = UInt64(data.id)
                
                dependencies.storage.write { transaction in
                    try MessageSender.handleSuccessfulMessageSend(
                        db,
                        message: message,
                        to: destination,
                        interactionId: interactionId
                    )
                    seal.fulfill(())
                }
            }
            .catch(on: DispatchQueue.global(qos: .default)) { error in
                dependencies.storage.read { db in
                    handleFailure(db, with: .other(error))
                }
            }
        
        return promise
    }

    // MARK: Success & Failure Handling
    
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
        serverTimestampMs: UInt64? = nil,
        isSyncMessage: Bool = false
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
                // When the sync message is successfully sent, the hash value of this TSOutgoingMessage
                // will be replaced by the hash value of the sync message. Since the hash value of the
                // real message has no use when we delete a message. It is OK to let it be.
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
                
                // Mark the message as sent
                try interaction.recipientStates
                    .filter(RecipientState.Columns.state != RecipientState.State.sent)
                    .updateAll(db, RecipientState.Columns.state.set(to: RecipientState.State.sent))
                
                // Start the disappearing messages timer if needed
                JobRunner.upsert(
                    db,
                    job: DisappearingMessagesJob.updateNextRunIfNeeded(
                        db,
                        interaction: interaction,
                        startedAtMs: TimeInterval(SnodeAPI.currentOffsetTimestampMs())
                    )
                )
            }
        }
        
        let threadId: String = {
            switch destination {
                case .contact(let publicKey): return publicKey
                case .closedGroup(let groupPublicKey): return groupPublicKey
                case .openGroup(let roomToken, let server, _, _, _):
                    return OpenGroup.idFor(roomToken: roomToken, server: server)
                
                case .openGroupInbox(_, _, let blindedPublicKey): return blindedPublicKey
            }
        }()
        
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
            isAlreadySyncMessage: isSyncMessage
        )
    }

    public static func handleFailedMessageSend(
        _ db: Database,
        message: Message,
        with error: MessageSenderError,
        interactionId: Int64?,
        isSyncMessage: Bool = false
    ) {
        // TODO: Revert the local database change
        // If the message was a reaction then we don't want to do anything to the original
        // interaction (which the 'interactionId' is pointing to
        guard (message as? VisibleMessage)?.reaction == nil else { return }
        
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
        
        guard !rowIds.isEmpty else { return }
        
        // Need to dispatch to a different thread to prevent a potential db re-entrancy
        // issue from occuring in some cases
        DispatchQueue.global(qos: .background).async {
            Storage.shared.write { db in
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
        isAlreadySyncMessage: Bool
    ) {
        // Sync the message if it's not a sync message, wasn't already sent to the current user and
        // it's a message type which should be synced
        let currentUserPublicKey = getUserHexEncodedPublicKey(db)
        
        if
            case .contact(let publicKey) = destination,
            !isAlreadySyncMessage,
            publicKey != currentUserPublicKey,
            Message.shouldSync(message: message)
        {
            if let message = message as? VisibleMessage { message.syncTarget = publicKey }
            if let message = message as? ExpirationTimerUpdate { message.syncTarget = publicKey }
            
            JobRunner.add(
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
                )
            )
        }
    }
}

// MARK: - Objective-C Support

// FIXME: Remove when possible

@objc(SMKMessageSender)
public class SMKMessageSender: NSObject {
    @objc(leaveClosedGroupWithPublicKey:)
    public static func objc_leave(_ groupPublicKey: String) -> AnyPromise {
        let promise = Storage.shared.writeAsync { db in
            try MessageSender.leave(db, groupPublicKey: groupPublicKey)
        }
        
        return AnyPromise.from(promise)
    }
    
    @objc(forceSyncConfigurationNow)
    public static func objc_forceSyncConfigurationNow() {
        Storage.shared.write { db in
            try MessageSender.syncConfiguration(db, forceSyncNow: true).retainUntilComplete()
        }
    }
}
