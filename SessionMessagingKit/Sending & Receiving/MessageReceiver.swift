// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import Sodium
import SessionUtilitiesKit
import SessionSnodeKit

public enum MessageReceiver {
    private static var lastEncryptionKeyPairRequest: [String: Date] = [:]
    
    public static func parse(
        _ db: Database,
        envelope: SNProtoEnvelope,
        serverExpirationTimestamp: TimeInterval?,
        openGroupId: String?,
        openGroupMessageServerId: Int64?,
        openGroupServerPublicKey: String?,
        isOutgoing: Bool? = nil,
        otherBlindedPublicKey: String? = nil,
        dependencies: SMKDependencies = SMKDependencies()
    ) throws -> (Message, SNProtoContent, String, SessionThread.Variant) {
        let userPublicKey: String = getUserHexEncodedPublicKey(db, dependencies: dependencies)
        let isOpenGroupMessage: Bool = (openGroupId != nil)
        
        // Decrypt the contents
        guard let ciphertext = envelope.content else { throw MessageReceiverError.noData }
        
        var plaintext: Data
        var sender: String
        var groupPublicKey: String? = nil
        
        if isOpenGroupMessage {
            (plaintext, sender) = (envelope.content!, envelope.source!)
        }
        else {
            switch envelope.type {
                case .sessionMessage:
                    // Default to 'standard' as the old code didn't seem to require an `envelope.source`
                    switch (SessionId.Prefix(from: envelope.source) ?? .standard) {
                        case .standard, .unblinded:
                            guard let userX25519KeyPair: KeyPair = Identity.fetchUserKeyPair(db) else {
                                throw MessageReceiverError.noUserX25519KeyPair
                            }
                            
                            (plaintext, sender) = try decryptWithSessionProtocol(ciphertext: ciphertext, using: userX25519KeyPair)
                            
                        case .blinded:
                            guard let otherBlindedPublicKey: String = otherBlindedPublicKey else {
                                throw MessageReceiverError.noData
                            }
                            guard let openGroupServerPublicKey: String = openGroupServerPublicKey else {
                                throw MessageReceiverError.invalidGroupPublicKey
                            }
                            guard let userEd25519KeyPair: KeyPair = Identity.fetchUserEd25519KeyPair(db) else {
                                throw MessageReceiverError.noUserED25519KeyPair
                            }
                            
                            (plaintext, sender) = try decryptWithSessionBlindingProtocol(
                                data: ciphertext,
                                isOutgoing: (isOutgoing == true),
                                otherBlindedPublicKey: otherBlindedPublicKey,
                                with: openGroupServerPublicKey,
                                userEd25519KeyPair: userEd25519KeyPair,
                                using: dependencies
                            )
                    }
                    
                case .closedGroupMessage:
                    guard
                        let hexEncodedGroupPublicKey = envelope.source,
                        let closedGroup: ClosedGroup = try? ClosedGroup.fetchOne(db, id: hexEncodedGroupPublicKey)
                    else {
                        throw MessageReceiverError.invalidGroupPublicKey
                    }
                    guard
                        let encryptionKeyPairs: [ClosedGroupKeyPair] = try? closedGroup.keyPairs
                            .order(ClosedGroupKeyPair.Columns.receivedTimestamp.desc)
                            .fetchAll(db),
                        !encryptionKeyPairs.isEmpty
                    else {
                        throw MessageReceiverError.noGroupKeyPair
                    }
                    
                    // Loop through all known group key pairs in reverse order (i.e. try the latest key
                    // pair first (which'll more than likely be the one we want) but try older ones in
                    // case that didn't work)
                    func decrypt(keyPairs: [ClosedGroupKeyPair], lastError: Error? = nil) throws -> (Data, String) {
                        guard let keyPair: ClosedGroupKeyPair = keyPairs.first else {
                            throw (lastError ?? MessageReceiverError.decryptionFailed)
                        }
                        
                        do {
                            return try decryptWithSessionProtocol(
                                ciphertext: ciphertext,
                                using: KeyPair(
                                    publicKey: keyPair.publicKey.bytes,
                                    secretKey: keyPair.secretKey.bytes
                                )
                            )
                        }
                        catch {
                            return try decrypt(keyPairs: Array(keyPairs.suffix(from: 1)), lastError: error)
                        }
                    }
                    
                    groupPublicKey = hexEncodedGroupPublicKey
                    (plaintext, sender) = try decrypt(keyPairs: encryptionKeyPairs)
                
                default: throw MessageReceiverError.unknownEnvelopeType
            }
        }
        
        // Don't process the envelope any further if the sender is blocked
        guard (try? Contact.fetchOne(db, id: sender))?.isBlocked != true else {
            throw MessageReceiverError.senderBlocked
        }
        
        // Parse the proto
        let proto: SNProtoContent
        
        do {
            proto = try SNProtoContent.parseData(plaintext.removePadding())
        }
        catch {
            SNLog("Couldn't parse proto due to error: \(error).")
            throw error
        }
        
        // Parse the message
        guard let message: Message = Message.createMessageFrom(proto, sender: sender) else {
            throw MessageReceiverError.unknownMessage
        }
        
        // Ignore self sends if needed
        guard message.isSelfSendValid || sender != userPublicKey else {
            throw MessageReceiverError.selfSend
        }
        
        // Guard against control messages in open groups
        guard !isOpenGroupMessage || message is VisibleMessage else {
            throw MessageReceiverError.invalidMessage
        }
        
        // Finish parsing
        message.sender = sender
        message.recipient = userPublicKey
        message.sentTimestamp = envelope.timestamp
        message.receivedTimestamp = UInt64(SnodeAPI.currentOffsetTimestampMs())
        message.openGroupServerMessageId = openGroupMessageServerId.map { UInt64($0) }
        
        // Validate
        var isValid: Bool = message.isValid
        if message is VisibleMessage && !isValid && proto.dataMessage?.attachments.isEmpty == false {
            isValid = true
        }
        
        guard isValid else {
            throw MessageReceiverError.invalidMessage
        }
        
        // Extract the proper threadId for the message
        let (threadId, threadVariant): (String, SessionThread.Variant) = {
            if let groupPublicKey: String = groupPublicKey { return (groupPublicKey, .legacyGroup) }
            if let openGroupId: String = openGroupId { return (openGroupId, .community) }
            
            switch message {
                case let message as VisibleMessage: return ((message.syncTarget ?? sender), .contact)
                case let message as ExpirationTimerUpdate: return ((message.syncTarget ?? sender), .contact)
                default: return (sender, .contact)
            }
        }()
        
        return (message, proto, threadId, threadVariant)
    }
    
    // MARK: - Handling
    
    public static func handle(
        _ db: Database,
        threadId: String,
        threadVariant: SessionThread.Variant,
        message: Message,
        serverExpirationTimestamp: TimeInterval?,
        associatedWithProto proto: SNProtoContent,
        dependencies: SMKDependencies = SMKDependencies()
    ) throws {
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
                    message: message
                )
                
            case let message as ClosedGroupControlMessage:
                try MessageReceiver.handleClosedGroupControlMessage(
                    db,
                    threadId: threadId,
                    threadVariant: threadVariant,
                    message: message
                )
                
            case let message as DataExtractionNotification:
                try MessageReceiver.handleDataExtractionNotification(
                    db,
                    threadId: threadId,
                    threadVariant: threadVariant,
                    message: message
                )
                
            case let message as ExpirationTimerUpdate:
                try MessageReceiver.handleExpirationTimerUpdate(
                    db,
                    threadId: threadId,
                    threadVariant: threadVariant,
                    message: message
                )
                
            case let message as ConfigurationMessage:
                try MessageReceiver.handleLegacyConfigurationMessage(db, message: message)
                
            case let message as UnsendRequest:
                try MessageReceiver.handleUnsendRequest(
                    db,
                    threadId: threadId,
                    threadVariant: threadVariant,
                    message: message
                )
                
            case let message as CallMessage:
                try MessageReceiver.handleCallMessage(
                    db,
                    threadId: threadId,
                    threadVariant: threadVariant,
                    message: message
                )
                
            case let message as MessageRequestResponse:
                try MessageReceiver.handleMessageRequestResponse(
                    db,
                    message: message,
                    dependencies: dependencies
                )
                
            case let message as VisibleMessage:
                try MessageReceiver.handleVisibleMessage(
                    db,
                    threadId: threadId,
                    threadVariant: threadVariant,
                    message: message,
                    associatedWithProto: proto
                )
                
            // SharedConfigMessages should be handled by the 'SharedUtil' instead of this
            case is SharedConfigMessage: throw MessageReceiverError.invalidSharedConfigMessageHandling
                
            default: fatalError()
        }
        
        // Perform any required post-handling logic
        try MessageReceiver.postHandleMessage(db, threadId: threadId, message: message)
    }
    
    public static func postHandleMessage(
        _ db: Database,
        threadId: String,
        message: Message
    ) throws {
        // When handling any non-typing indicator message we want to make sure the thread becomes
        // visible (the only other spot this flag gets set is when sending messages)
        switch message {
            case is TypingIndicator: break
                
            default:
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
                        SessionThread.Columns.shouldBeVisible.set(to: true)
                    )
        }
    }
    
    public static func handleOpenGroupReactions(
        _ db: Database,
        threadId: String,
        openGroupMessageServerId: Int64,
        openGroupReactions: [Reaction]
    ) throws {
        guard let interactionId: Int64 = try? Interaction
            .select(.id)
            .filter(Interaction.Columns.threadId == threadId)
            .filter(Interaction.Columns.openGroupServerMessageId == openGroupMessageServerId)
            .asRequest(of: Int64.self)
            .fetchOne(db)
        else {
            throw MessageReceiverError.invalidMessage
        }
        
        _ = try Reaction
            .filter(Reaction.Columns.interactionId == interactionId)
            .deleteAll(db)
        
        for reaction in openGroupReactions {
            try reaction.with(interactionId: interactionId).insert(db)
        }
    }
}
