// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUIKit
import SessionUtilitiesKit
import SessionSnodeKit

// MARK: - Log.Category

public extension Log.Category {
    static let messageReceiver: Log.Category = .create("MessageReceiver", defaultLevel: .info)
}

// MARK: - MessageReceiver

public enum MessageReceiver {
    private static var lastEncryptionKeyPairRequest: [String: Date] = [:]
    
    public static func parse(
        _ db: Database,
        data: Data,
        origin: Message.Origin,
        using dependencies: Dependencies
    ) throws -> ProcessedMessage {
        let userSessionId: SessionId = dependencies[cache: .general].sessionId
        var plaintext: Data
        var customProto: SNProtoContent? = nil
        var customMessage: Message? = nil
        let sender: String
        let sentTimestampMs: UInt64
        let serverHash: String?
        let openGroupServerMessageId: UInt64?
        let openGroupWhisper: Bool
        let openGroupWhisperMods: Bool
        let openGroupWhisperTo: String?
        let threadVariant: SessionThread.Variant
        let threadIdGenerator: (Message) throws -> String
        
        switch (origin.isConfigNamespace, origin) {
            // Config messages are custom-handled via 'libSession' so just return the data directly
            case (true, .swarm(let publicKey, let namespace, let serverHash, let serverTimestampMs, _)):
                return .config(
                    publicKey: publicKey,
                    namespace: namespace,
                    serverHash: serverHash,
                    serverTimestampMs: serverTimestampMs,
                    data: data
                )
                
            case (_, .community(let openGroupId, let messageSender, let timestamp, let messageServerId, let messageWhisper, let messageWhisperMods, let messageWhisperTo)):
                plaintext = data.removePadding()   // Remove the padding
                sender = messageSender
                sentTimestampMs = UInt64(floor(timestamp * 1000)) // Convert to ms for database consistency
                serverHash = nil
                openGroupServerMessageId = UInt64(messageServerId)
                openGroupWhisper = messageWhisper
                openGroupWhisperMods = messageWhisperMods
                openGroupWhisperTo = messageWhisperTo
                threadVariant = .community
                threadIdGenerator = { message in
                    // Guard against control messages in open groups
                    guard message is VisibleMessage else { throw MessageReceiverError.invalidMessage }
                    
                    return openGroupId
                }
                
            case (_, .openGroupInbox(let timestamp, let messageServerId, let serverPublicKey, let senderId, let recipientId)):
                (plaintext, sender) = try dependencies[singleton: .crypto].tryGenerate(
                    .plaintextWithSessionBlindingProtocol(
                        db,
                        ciphertext: data,
                        senderId: senderId,
                        recipientId: recipientId,
                        serverPublicKey: serverPublicKey,
                        using: dependencies
                    )
                )
                
                plaintext = plaintext.removePadding()   // Remove the padding
                sentTimestampMs = UInt64(floor(timestamp * 1000)) // Convert to ms for database consistency
                serverHash = nil
                openGroupServerMessageId = UInt64(messageServerId)
                openGroupWhisper = false
                openGroupWhisperMods = false
                openGroupWhisperTo = nil
                threadVariant = .contact
                threadIdGenerator = { _ in sender }
                
            case (_, .swarm(let publicKey, let namespace, let swarmServerHash, _, _)):
                switch namespace {
                    case .default:
                        guard
                            let envelope: SNProtoEnvelope = try? MessageWrapper.unwrap(data: data),
                            let ciphertext: Data = envelope.content
                        else {
                            Log.warn(.messageReceiver, "Failed to unwrap data for message from 'default' namespace.")
                            throw MessageReceiverError.invalidMessage
                        }
                        
                        (plaintext, sender) = try dependencies[singleton: .crypto].tryGenerate(
                            .plaintextWithSessionProtocol(
                                db,
                                ciphertext: ciphertext,
                                using: dependencies
                            )
                        )
                        plaintext = plaintext.removePadding()   // Remove the padding
                        sentTimestampMs = envelope.timestamp
                        serverHash = swarmServerHash
                        openGroupServerMessageId = nil
                        openGroupWhisper = false
                        openGroupWhisperMods = false
                        openGroupWhisperTo = nil
                        threadVariant = .contact
                        threadIdGenerator = { message in
                            Message.threadId(forMessage: message, destination: .contact(publicKey: sender), using: dependencies)
                        }
                        
                    case .groupMessages:
                        let plaintextEnvelope: Data
                        (plaintextEnvelope, sender) = try dependencies[singleton: .crypto].tryGenerate(
                            .plaintextForGroupMessage(
                                groupSessionId: SessionId(.group, hex: publicKey),
                                ciphertext: Array(data)
                            )
                        )
                        
                        guard
                            let envelope: SNProtoEnvelope = try? MessageWrapper.unwrap(
                                data: plaintextEnvelope,
                                includesWebSocketMessage: false
                            ),
                            let envelopeContent: Data = envelope.content
                        else {
                            Log.warn(.messageReceiver, "Failed to unwrap data for message from 'default' namespace.")
                            throw MessageReceiverError.invalidMessage
                        }
                        plaintext = envelopeContent // Padding already removed for updated groups
                        sentTimestampMs = envelope.timestamp
                        serverHash = swarmServerHash
                        openGroupServerMessageId = nil
                        openGroupWhisper = false
                        openGroupWhisperMods = false
                        openGroupWhisperTo = nil
                        threadVariant = .group
                        threadIdGenerator = { _ in publicKey }
                        
                    case .revokedRetrievableGroupMessages:
                        plaintext = Data()  // Requires custom decryption
                        
                        let contentProto: SNProtoContent.SNProtoContentBuilder = SNProtoContent.builder()
                        contentProto.setSigTimestamp(0)
                        customProto = try contentProto.build()
                        customMessage = LibSessionMessage(ciphertext: data)
                        sender = publicKey  // The "group" sends these messages
                        sentTimestampMs = 0
                        serverHash = swarmServerHash
                        openGroupServerMessageId = nil
                        openGroupWhisper = false
                        openGroupWhisperMods = false
                        openGroupWhisperTo = nil
                        threadVariant = .group
                        threadIdGenerator = { _ in publicKey }
                        
                    // FIXME: Remove once updated groups has been around for long enough
                    case .legacyClosedGroup:
                        guard
                            let envelope: SNProtoEnvelope = try? MessageWrapper.unwrap(data: data),
                            let ciphertext: Data = envelope.content,
                            let closedGroup: ClosedGroup = try? ClosedGroup.fetchOne(db, id: publicKey)
                        else {
                            Log.warn(.messageReceiver, "Failed to unwrap data for message from 'legacyClosedGroup' namespace.")
                            throw MessageReceiverError.invalidMessage
                        }
                        
                        guard
                            let encryptionKeyPairs: [ClosedGroupKeyPair] = try? closedGroup.keyPairs
                                .order(ClosedGroupKeyPair.Columns.receivedTimestamp.desc)
                                .fetchAll(db),
                            !encryptionKeyPairs.isEmpty
                        else { throw MessageReceiverError.noGroupKeyPair }
                        
                        // Loop through all known group key pairs in reverse order (i.e. try the latest key
                        // pair first (which'll more than likely be the one we want) but try older ones in
                        // case that didn't work)
                        func decrypt(keyPairs: [ClosedGroupKeyPair], lastError: Error? = nil) throws -> (Data, String) {
                            guard let keyPair: ClosedGroupKeyPair = keyPairs.first else {
                                throw (lastError ?? MessageReceiverError.decryptionFailed)
                            }
                            
                            do {
                                return try dependencies[singleton: .crypto].tryGenerate(
                                    .plaintextWithSessionProtocolLegacyGroup(
                                        ciphertext: ciphertext,
                                        keyPair: KeyPair(
                                            publicKey: keyPair.publicKey.bytes,
                                            secretKey: keyPair.secretKey.bytes
                                        ),
                                        using: dependencies
                                    )
                                )
                            }
                            catch {
                                return try decrypt(keyPairs: Array(keyPairs.suffix(from: 1)), lastError: error)
                            }
                        }
                        
                        (plaintext, sender) = try decrypt(keyPairs: encryptionKeyPairs)
                        plaintext = plaintext.removePadding()   // Remove the padding
                        sentTimestampMs = envelope.timestamp
                        
                        /// If we weren't given a `serverHash` then compute one locally using the same logic the swarm would
                        switch swarmServerHash.isEmpty {
                            case false: serverHash = swarmServerHash
                            case true:
                                serverHash = dependencies[singleton: .crypto].generate(
                                    .messageServerHash(swarmPubkey: publicKey, namespace: namespace, data: data)
                                ).defaulting(to: "")
                        }
                        
                        openGroupServerMessageId = nil
                        openGroupWhisper = false
                        openGroupWhisperMods = false
                        openGroupWhisperTo = nil
                        threadVariant = .legacyGroup
                        threadIdGenerator = { _ in publicKey }
                        
                    case .configUserProfile, .configContacts, .configConvoInfoVolatile, .configUserGroups:
                        throw MessageReceiverError.invalidConfigMessageHandling
                        
                    case .configGroupInfo, .configGroupMembers, .configGroupKeys:
                        throw MessageReceiverError.invalidConfigMessageHandling
                        
                    case .all, .unknown:
                        Log.warn(.messageReceiver, "Couldn't process message due to invalid namespace.")
                        throw MessageReceiverError.unknownMessage
                }
        }
        
        let proto: SNProtoContent = try (customProto ?? Result(catching: { try SNProtoContent.parseData(plaintext) })
            .onFailure { Log.error(.messageReceiver, "Couldn't parse proto due to error: \($0).") }
            .successOrThrow())
        let message: Message = try (customMessage ?? Message.createMessageFrom(proto, sender: sender, using: dependencies))
        message.sender = sender
        message.serverHash = serverHash
        message.sentTimestampMs = sentTimestampMs
        message.sigTimestampMs = (proto.hasSigTimestamp ? proto.sigTimestamp : nil)
        message.receivedTimestampMs = dependencies[cache: .snodeAPI].currentOffsetTimestampMs()
        message.openGroupServerMessageId = openGroupServerMessageId
        message.openGroupWhisper = openGroupWhisper
        message.openGroupWhisperMods = openGroupWhisperMods
        message.openGroupWhisperTo = openGroupWhisperTo
        
        // Ignore disappearing message settings in communities (in case of modified clients)
        if threadVariant != .community {
            message.attachDisappearingMessagesConfiguration(from: proto)
        }
        
        // Don't process the envelope any further if the sender is blocked
        guard (try? Contact.fetchOne(db, id: sender))?.isBlocked != true || message.processWithBlockedSender else {
            throw MessageReceiverError.senderBlocked
        }
        
        // Ignore self sends if needed
        guard message.isSelfSendValid || sender != userSessionId.hexString else {
            throw MessageReceiverError.selfSend
        }
        
        // Guard against control messages in open groups
        guard !origin.isCommunity || message is VisibleMessage else {
            throw MessageReceiverError.invalidMessage
        }
        
        // Validate
        guard message.isValid(isSending: false) else {
            throw MessageReceiverError.invalidMessage
        }
        
        return .standard(
            threadId: try threadIdGenerator(message),
            threadVariant: threadVariant,
            proto: proto,
            messageInfo: try MessageReceiveJob.Details.MessageInfo(
                message: message,
                variant: try Message.Variant(from: message) ?? { throw MessageReceiverError.invalidMessage }(),
                threadVariant: threadVariant,
                serverExpirationTimestamp: origin.serverExpirationTimestamp,
                proto: proto
            )
        )
    }
    
    // MARK: - Handling
    
    public static func handle(
        _ db: Database,
        threadId: String,
        threadVariant: SessionThread.Variant,
        message: Message,
        serverExpirationTimestamp: TimeInterval?,
        associatedWithProto proto: SNProtoContent,
        using dependencies: Dependencies
    ) throws {
        // Check if the message requires an existing conversation (if it does and the conversation isn't in
        // the config then the message will be dropped)
        guard
            !Message.requiresExistingConversation(message: message, threadVariant: threadVariant) ||
            LibSession.conversationInConfig(
                db,
                threadId: threadId,
                threadVariant: threadVariant,
                visibleOnly: false,
                using: dependencies
            )
        else { throw MessageReceiverError.requiredThreadNotInConfig }
        
        // Throw if the message is outdated and shouldn't be processed
        try throwIfMessageOutdated(
            db,
            message: message,
            threadId: threadId,
            threadVariant: threadVariant,
            using: dependencies
        )
        
        MessageReceiver.updateContactDisappearingMessagesVersionIfNeeded(
            db,
            messageVariant: .init(from: message),
            contactId: message.sender,
            version: ((!proto.hasExpirationType && !proto.hasExpirationTimer) ?
                .legacyDisappearingMessages :
                .newDisappearingMessages
            ),
            using: dependencies
        )
        
        switch message {
            case let message as ReadReceipt:
                try MessageReceiver.handleReadReceipt(
                    db,
                    message: message,
                    serverExpirationTimestamp: serverExpirationTimestamp
                )
                
            case let message as TypingIndicator:
                try MessageReceiver.handleTypingIndicator(
                    db,
                    threadId: threadId,
                    threadVariant: threadVariant,
                    message: message,
                    using: dependencies
                )
                
            case let message as ClosedGroupControlMessage:
                try MessageReceiver.handleLegacyClosedGroupControlMessage(
                    db,
                    threadId: threadId,
                    threadVariant: threadVariant,
                    message: message,
                    using: dependencies
                )
                
            case is GroupUpdateInviteMessage, is GroupUpdateInfoChangeMessage,
                is GroupUpdateMemberChangeMessage, is GroupUpdatePromoteMessage, is GroupUpdateMemberLeftMessage,
                is GroupUpdateMemberLeftNotificationMessage, is GroupUpdateInviteResponseMessage,
                is GroupUpdateDeleteMemberContentMessage:
                try MessageReceiver.handleGroupUpdateMessage(
                    db,
                    threadId: threadId,
                    threadVariant: threadVariant,
                    message: message,
                    serverExpirationTimestamp: serverExpirationTimestamp,
                    using: dependencies
                )
                
            case let message as DataExtractionNotification:
                try MessageReceiver.handleDataExtractionNotification(
                    db,
                    threadId: threadId,
                    threadVariant: threadVariant,
                    message: message,
                    serverExpirationTimestamp: serverExpirationTimestamp,
                    using: dependencies
                )
                
            case let message as ExpirationTimerUpdate:
                try MessageReceiver.handleExpirationTimerUpdate(
                    db,
                    threadId: threadId,
                    threadVariant: threadVariant,
                    message: message,
                    serverExpirationTimestamp: serverExpirationTimestamp,
                    proto: proto,
                    using: dependencies
                )
                
            case let message as UnsendRequest:
                try MessageReceiver.handleUnsendRequest(
                    db,
                    threadId: threadId,
                    threadVariant: threadVariant,
                    message: message,
                    using: dependencies
                )
                
            case let message as CallMessage:
                try MessageReceiver.handleCallMessage(
                    db,
                    threadId: threadId,
                    threadVariant: threadVariant,
                    message: message,
                    using: dependencies
                )
                
            case let message as MessageRequestResponse:
                try MessageReceiver.handleMessageRequestResponse(
                    db,
                    message: message,
                    using: dependencies
                )
                
            case let message as VisibleMessage:
                try MessageReceiver.handleVisibleMessage(
                    db,
                    threadId: threadId,
                    threadVariant: threadVariant,
                    message: message,
                    serverExpirationTimestamp: serverExpirationTimestamp,
                    associatedWithProto: proto,
                    using: dependencies
                )
            
            case let message as LibSessionMessage:
                try MessageReceiver.handleLibSessionMessage(
                    db,
                    threadId: threadId,
                    threadVariant: threadVariant,
                    message: message,
                    using: dependencies
                )
            
            default: throw MessageReceiverError.unknownMessage
        }
        
        // Perform any required post-handling logic
        try MessageReceiver.postHandleMessage(
            db,
            threadId: threadId,
            threadVariant: threadVariant,
            message: message,
            using: dependencies
        )
    }
    
    public static func postHandleMessage(
        _ db: Database,
        threadId: String,
        threadVariant: SessionThread.Variant,
        message: Message,
        using dependencies: Dependencies
    ) throws {
        // When handling any message type which has related UI we want to make sure the thread becomes
        // visible (the only other spot this flag gets set is when sending messages)
        let shouldBecomeVisible: Bool = {
            switch message {
                case is ReadReceipt: return true
                case is TypingIndicator: return true
                case is UnsendRequest: return true
                case is CallMessage: return (threadId != dependencies[cache: .general].sessionId.hexString)
                    
                case let message as ClosedGroupControlMessage:
                    // Only re-show a legacy group conversation if we are going to add a control text message
                    switch message.kind {
                        case .new, .encryptionKeyPair, .encryptionKeyPairRequest: return false
                        default: return true
                    }
                    
                /// These are sent to the one-to-one conversation so they shouldn't make that visible
                case is GroupUpdateInviteMessage, is GroupUpdatePromoteMessage:
                    return false
                    
                /// These are sent to the group conversation but we have logic so you can only ever "leave" a group, you can't "hide" it
                /// so that it re-appears when a new message is received so the thread shouldn't become visible for any of them
                case is GroupUpdateInfoChangeMessage, is GroupUpdateMemberChangeMessage,
                    is GroupUpdateMemberLeftMessage, is GroupUpdateMemberLeftNotificationMessage,
                    is GroupUpdateInviteResponseMessage, is GroupUpdateDeleteMemberContentMessage:
                    return false
            
                /// Currently this is just for handling the `groupKicked` message which is sent to a group so the same rules as above apply
                case is LibSessionMessage: return false
                    
                default: return true
            }
        }()
        
        // Start the disappearing messages timer if needed
        // For disappear after send, this is necessary so the message will disappear even if it is not read
        if threadVariant != .community {
            db.afterNextTransactionNestedOnce(
                dedupeId: "PostInsertDisappearingMessagesJob",  // stringlint:ignore
                using: dependencies,
                onCommit: { db in
                    dependencies[singleton: .jobRunner].upsert(
                        db,
                        job: DisappearingMessagesJob.updateNextRunIfNeeded(db, using: dependencies),
                        canStartJob: true
                    )
                }
            )
        }
        
        // Only check the current visibility state if we should become visible for this message type
        guard shouldBecomeVisible else { return }
        
        // Only update the `shouldBeVisible` flag if the thread is currently not visible
        // as we don't want to trigger a config update if not needed
        let isCurrentlyVisible: Bool = try SessionThread
            .filter(id: threadId)
            .select(.shouldBeVisible)
            .asRequest(of: Bool.self)
            .fetchOne(db)
            .defaulting(to: false)

        guard !isCurrentlyVisible else { return }
        
        try SessionThread
            .filter(id: threadId)
            .updateAllAndConfig(
                db,
                SessionThread.Columns.shouldBeVisible.set(to: true),
                SessionThread.Columns.pinnedPriority.set(to: LibSession.visiblePriority),
                SessionThread.Columns.isDraft.set(to: false),
                using: dependencies
            )
    }
    
    public static func handleOpenGroupReactions(
        _ db: Database,
        threadId: String,
        openGroupMessageServerId: Int64,
        openGroupReactions: [Reaction]
    ) throws {
        struct Info: Decodable, FetchableRecord {
            let id: Int64
            let variant: Interaction.Variant
        }
        
        guard let interactionInfo: Info = try? Interaction
            .select(.id, .variant)
            .filter(Interaction.Columns.threadId == threadId)
            .filter(Interaction.Columns.openGroupServerMessageId == openGroupMessageServerId)
            .asRequest(of: Info.self)
            .fetchOne(db)
        else { throw MessageReceiverError.invalidMessage }
        
        // If the user locally deleted the message then we don't want to process reactions for it
        guard !interactionInfo.variant.isDeletedMessage else { return }
        
        _ = try Reaction
            .filter(Reaction.Columns.interactionId == interactionInfo.id)
            .deleteAll(db)
        
        for reaction in openGroupReactions {
            try reaction.with(interactionId: interactionInfo.id).insert(db)
        }
    }
    
    public static func throwIfMessageOutdated(
        _ db: Database,
        message: Message,
        threadId: String,
        threadVariant: SessionThread.Variant,
        using dependencies: Dependencies
    ) throws {
        let userSessionId: SessionId = dependencies[cache: .general].sessionId
        
        switch message {
            case is ReadReceipt: return // No visible artifact created so better to keep for more reliable read states
            case is UnsendRequest: return // We should always process the removal of messages just in case
            default: break
        }
        
        // If the destination is a group conversation that has been destroyed then the message is outdated
        guard
            threadVariant != .group ||
            !LibSession.groupIsDestroyed(
                groupSessionId: SessionId(.group, hex: threadId),
                using: dependencies
            )
        else { throw MessageReceiverError.outdatedMessage }
        
        // Determine if it's a group conversation that received a deletion instruction after this
        // message was sent (if so then it's outdated)
        let deletionInstructionSentAfterThisMessage: Bool = {
            guard threadVariant == .group else { return false }
            
            // These group update messages update the group state so should be processed even
            // if they were old
            switch message {
                case is GroupUpdateInviteResponseMessage: return false
                case is GroupUpdateDeleteMemberContentMessage: return false
                case is GroupUpdateMemberLeftMessage: return false
                default: break
            }
            
            // Note: 'sentTimestamp' is in milliseconds so convert it
            let messageSentTimestamp: TimeInterval = TimeInterval((message.sentTimestampMs ?? 0) / 1000)
            let deletionInfo: (deleteBefore: TimeInterval, deleteAttachmentsBefore: TimeInterval) = dependencies.mutate(cache: .libSession) { cache in
                let config: LibSession.Config? = cache.config(for: .groupInfo, sessionId: SessionId(.group, hex: threadId))
                
                return (
                    ((try? LibSession.groupDeleteBefore(in: config)) ?? 0),
                    ((try? LibSession.groupAttachmentDeleteBefore(in: config)) ?? 0)
                )
            }
            
            return (
                deletionInfo.deleteBefore > messageSentTimestamp || (
                    (message as? VisibleMessage)?.dataMessageHasAttachments == true &&
                    deletionInfo.deleteAttachmentsBefore > messageSentTimestamp
                )
            )
        }()
        
        guard !deletionInstructionSentAfterThisMessage else { throw MessageReceiverError.outdatedMessage }
        
        // If the conversation is not visible in the config and the message was sent before the last config
        // update (minus a buffer period) then we can assume that the user has hidden/deleted the conversation
        // and it shouldn't be reshown by this (old) message
        let conversationVisibleInConfig: Bool = LibSession.conversationInConfig(
            db,
            threadId: threadId,
            threadVariant: threadVariant,
            visibleOnly: true,
            using: dependencies
        )
        let canPerformChange: Bool = LibSession.canPerformChange(
            db,
            threadId: threadId,
            targetConfig: {
                switch threadVariant {
                    case .contact: return (threadId == userSessionId.hexString ? .userProfile : .contacts)
                    default: return .userGroups
                }
            }(),
            changeTimestampMs: message.sentTimestampMs
                .map { Int64($0) }
                .defaulting(to: dependencies[cache: .snodeAPI].currentOffsetTimestampMs()),
            using: dependencies
        )
        
        switch (conversationVisibleInConfig, canPerformChange) {
            case (false, false): throw MessageReceiverError.outdatedMessage
            default: break  // Message not outdated
        }
    }
}
