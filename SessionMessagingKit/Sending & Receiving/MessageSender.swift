// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import SessionNetworkingKit
import SessionUtilitiesKit

// MARK: - Log.Category

public extension Log.Category {
    static let messageSender: Log.Category = .create("MessageSender", defaultLevel: .info)
}

// MARK: - MessageSender

public final class MessageSender {
    private typealias SendResponse = (message: Message, serverTimestampMs: Int64?, serverExpirationMs: Int64?)
    public enum Event {
        case willSend(Message, Message.Destination, interactionId: Int64?)
        case success(Message, Message.Destination, interactionId: Int64?, serverTimestampMs: Int64?, serverExpirationMs: Int64?)
        case failure(Message, Message.Destination, interactionId: Int64?, error: MessageSenderError)
        
        var message: Message {
            switch self {
                case .willSend(let message, _, _), .success(let message, _, _, _, _),
                    .failure(let message, _, _, _):
                    return message
            }
        }
        
        var destination: Message.Destination {
            switch self {
                case .willSend(_, let destination, _), .success(_, let destination, _, _, _),
                    .failure(_, let destination, _, _):
                    return destination
            }
        }
    }
    
    // MARK: - Message Preparation
    
    public static func preparedSend(
        message: Message,
        to destination: Message.Destination,
        namespace: Network.SnodeAPI.Namespace?,
        interactionId: Int64?,
        attachments: [(attachment: Attachment, fileId: String)]?,
        authMethod: AuthenticationMethod,
        onEvent: ((Event) -> Void)?,
        using dependencies: Dependencies
    ) throws -> Network.PreparedRequest<Message> {
        // Common logic for all destinations
        let messageSendTimestampMs: Int64 = dependencies[cache: .snodeAPI].currentOffsetTimestampMs()
        let updatedMessage: Message = message
        
        // Set the message 'sentTimestamp' (Visible messages will already have their sent timestamp set)
        updatedMessage.sentTimestampMs = (
            updatedMessage.sentTimestampMs ??
            UInt64(messageSendTimestampMs)
        )
        updatedMessage.sigTimestampMs = updatedMessage.sentTimestampMs
        
        do {
            let preparedRequest: Network.PreparedRequest<SendResponse>
            
            switch destination {
                case .contact, .syncMessage, .closedGroup:
                    preparedRequest = try preparedSendToSnodeDestination(
                        message: updatedMessage,
                        to: destination,
                        namespace: namespace,
                        interactionId: interactionId,
                        attachments: attachments,
                        messageSendTimestampMs: messageSendTimestampMs,
                        authMethod: authMethod,
                        onEvent: onEvent,
                        using: dependencies
                    )
                    
                case .openGroup:
                    preparedRequest = try preparedSendToOpenGroupDestination(
                        message: updatedMessage,
                        to: destination,
                        interactionId: interactionId,
                        attachments: attachments,
                        messageSendTimestampMs: messageSendTimestampMs,
                        authMethod: authMethod,
                        onEvent: onEvent,
                        using: dependencies
                    )
                    
                case .openGroupInbox:
                    preparedRequest = try preparedSendToOpenGroupInboxDestination(
                        message: message,
                        to: destination,
                        interactionId: interactionId,
                        attachments: attachments,
                        messageSendTimestampMs: messageSendTimestampMs,
                        authMethod: authMethod,
                        onEvent: onEvent,
                        using: dependencies
                    )
            }
            
            return preparedRequest
                .handleEvents(
                    receiveOutput: { _, response in
                        onEvent?(.success(
                            response.message,
                            destination,
                            interactionId: interactionId,
                            serverTimestampMs: response.serverTimestampMs,
                            serverExpirationMs: response.serverExpirationMs
                        ))
                    },
                    receiveCompletion: { result in
                        switch result {
                            case .finished: break
                            case .failure(let error):
                                onEvent?(.failure(
                                    message,
                                    destination,
                                    interactionId: interactionId,
                                    error: .other(nil, "Couldn't send message", error)
                                ))
                        }
                    }
                )
                .map { _, response in response.message }
        }
        catch let error as MessageSenderError {
            onEvent?(.failure(message, destination, interactionId: interactionId, error: error))
            throw error
        }
    }
    
    private static func preparedSendToSnodeDestination(
        message: Message,
        to destination: Message.Destination,
        namespace: Network.SnodeAPI.Namespace?,
        interactionId: Int64?,
        attachments: [(attachment: Attachment, fileId: String)]?,
        messageSendTimestampMs: Int64,
        authMethod: AuthenticationMethod,
        onEvent: ((Event) -> Void)?,
        using dependencies: Dependencies
    ) throws -> Network.PreparedRequest<SendResponse> {
        guard let namespace: Network.SnodeAPI.Namespace = namespace else {
            throw MessageSenderError.invalidMessage
        }
        
        /// Set the sender/recipient info (needed to be valid)
        ///
        /// **Note:** The `sentTimestamp` will differ from the `messageSendTimestampMs` as it's the time the user originally
        /// sent the message whereas the `messageSendTimestamp` is the time it will be uploaded to the swarm
        let userSessionId: SessionId = dependencies[cache: .general].sessionId
        let sentTimestampMs: UInt64 = (message.sentTimestampMs ?? UInt64(messageSendTimestampMs))
        message.sender = userSessionId.hexString
        message.sentTimestampMs = sentTimestampMs
        message.sigTimestampMs = sentTimestampMs
        
        // Attach the user's profile if needed (no need to do so for 'Note to Self' or sync
        // messages as they will be managed by the user config handling
        switch (destination, message as? MessageWithProfile) {
            case (.syncMessage, _), (_, .none): break
            case (.contact(let publicKey), _) where publicKey == userSessionId.hexString: break
            case (_, .some(var messageWithProfile)):
                messageWithProfile.profile = dependencies
                    .mutate(cache: .libSession) { $0.profile(contactId: userSessionId.hexString) }
                    .map { profile in
                        VisibleMessage.VMProfile(
                            displayName: profile.name,
                            profileKey: profile.displayPictureEncryptionKey,
                            profilePictureUrl: profile.displayPictureUrl,
                            updateTimestampMs: profile.profileLastUpdated.map { UInt64($0) }
                        )
                    }
        }
        
        // Convert and prepare the data for sending
        let swarmPublicKey: String = {
            switch destination {
                case .contact(let publicKey): return publicKey
                case .syncMessage: return userSessionId.hexString
                case .closedGroup(let groupPublicKey): return groupPublicKey
                case .openGroup, .openGroupInbox: preconditionFailure()
            }
        }()
        let snodeMessage = SnodeMessage(
            recipient: swarmPublicKey,
            data: try MessageSender.encodeMessageForSending(
                namespace: namespace,
                destination: destination,
                message: message,
                attachments: attachments,
                authMethod: authMethod,
                using: dependencies
            ),
            ttl: Message.getSpecifiedTTL(message: message, destination: destination, using: dependencies),
            timestampMs: UInt64(messageSendTimestampMs)
        )
        
        // Perform any pre-send actions
        onEvent?(.willSend(message, destination, interactionId: interactionId))
        
        return try Network.SnodeAPI
            .preparedSendMessage(
                message: snodeMessage,
                in: namespace,
                authMethod: authMethod,
                using: dependencies
            )
            .map { _, response in
                let expirationTimestampMs: Int64 = (dependencies[cache: .snodeAPI].currentOffsetTimestampMs() + SnodeReceivedMessage.defaultExpirationMs)
                let updatedMessage: Message = message
                updatedMessage.serverHash = response.hash
                
                return (updatedMessage, nil, expirationTimestampMs)
            }
    }
    
    private static func preparedSendToOpenGroupDestination(
        message: Message,
        to destination: Message.Destination,
        interactionId: Int64?,
        attachments: [(attachment: Attachment, fileId: String)]?,
        messageSendTimestampMs: Int64,
        authMethod: AuthenticationMethod,
        onEvent: ((Event) -> Void)?,
        using dependencies: Dependencies
    ) throws -> Network.PreparedRequest<SendResponse> {
        // Note: It's possible to send a message and then delete the open group you sent the message to
        // which would go into this case, so rather than handling it as an invalid state we just want to
        // error in a non-retryable way
        guard
            let message: VisibleMessage = message as? VisibleMessage,
            case .community(let server, let publicKey, let hasCapabilities, let supportsBlinding, _) = authMethod.info,
            case .openGroup(let roomToken, let destinationServer, let whisperTo, let whisperMods) = destination,
            server == destinationServer,
            let userEdKeyPair: KeyPair = dependencies[singleton: .crypto].generate(
                .ed25519KeyPair(seed: dependencies[cache: .general].ed25519Seed)
            )
        else { throw MessageSenderError.invalidMessage }
        
        // Set the sender/recipient info (needed to be valid)
        let userSessionId: SessionId = dependencies[cache: .general].sessionId
        message.sender = try {
            // If the server doesn't support blinding then go with an unblinded id
            guard !hasCapabilities || supportsBlinding else {
                return SessionId(.unblinded, publicKey: userEdKeyPair.publicKey).hexString
            }
            guard
                let blinded15KeyPair: KeyPair = dependencies[singleton: .crypto].generate(
                    .blinded15KeyPair(
                        serverPublicKey: publicKey,
                        ed25519SecretKey: userEdKeyPair.secretKey
                    )
                )
            else { throw MessageSenderError.signingFailed }
            
            return SessionId(.blinded15, publicKey: blinded15KeyPair.publicKey).hexString
        }()
        message.profile = dependencies
            .mutate(cache: .libSession) { cache in
                cache.profile(contactId: userSessionId.hexString).map {
                    ($0, cache.get(.checkForCommunityMessageRequests))
                }
            }
            .map { profile, checkForCommunityMessageRequests in
                VisibleMessage.VMProfile(
                    displayName: profile.name,
                    profileKey: profile.displayPictureEncryptionKey,
                    profilePictureUrl: profile.displayPictureUrl,
                    updateTimestampMs: profile.profileLastUpdated.map { UInt64($0) },
                    blocksCommunityMessageRequests: !checkForCommunityMessageRequests
                )
            }

        guard !(message.profile?.displayName ?? "").isEmpty else { throw MessageSenderError.noUsername }
        
        let plaintext: Data = try MessageSender.encodeMessageForSending(
            namespace: .default,
            destination: destination,
            message: message,
            attachments: attachments,
            authMethod: authMethod,
            using: dependencies
        )
        
        // Perform any pre-send actions
        onEvent?(.willSend(message, destination, interactionId: interactionId))
        
        return try Network.SOGS
            .preparedSend(
                plaintext: plaintext,
                roomToken: roomToken,
                whisperTo: whisperTo,
                whisperMods: whisperMods,
                fileIds: attachments?.map { $0.fileId },
                authMethod: authMethod,
                using: dependencies
            )
            .map { _, response in
                let updatedMessage: Message = message
                updatedMessage.openGroupServerMessageId = UInt64(response.id)
                updatedMessage.sentTimestampMs = response.posted.map { UInt64(floor($0 * 1000)) }
                
                return (updatedMessage, response.posted.map { Int64(floor($0 * 1000)) }, nil)
            }
    }
    
    private static func preparedSendToOpenGroupInboxDestination(
        message: Message,
        to destination: Message.Destination,
        interactionId: Int64?,
        attachments: [(attachment: Attachment, fileId: String)]?,
        messageSendTimestampMs: Int64,
        authMethod: AuthenticationMethod,
        onEvent: ((Event) -> Void)?,
        using dependencies: Dependencies
    ) throws -> Network.PreparedRequest<SendResponse> {
        // The `openGroupInbox` destination does not support attachments
        guard
            (attachments ?? []).isEmpty,
            case .openGroupInbox(_, _, let recipientBlindedPublicKey) = destination
        else { throw MessageSenderError.invalidMessage }
        
        let userSessionId: SessionId = dependencies[cache: .general].sessionId
        message.sender = userSessionId.hexString
        
        // Attach the user's profile if needed
        switch (message as? MessageWithProfile) {
            case .some(var messageWithProfile):
                messageWithProfile.profile = dependencies
                    .mutate(cache: .libSession) { $0.profile(contactId: userSessionId.hexString) }
                    .map { profile in
                        VisibleMessage.VMProfile(
                            displayName: profile.name,
                            profileKey: profile.displayPictureEncryptionKey,
                            profilePictureUrl: profile.displayPictureUrl,
                            updateTimestampMs: profile.profileLastUpdated.map { UInt64($0) }
                        )
                    }
            
            default: break
        }
        let ciphertext: Data = try MessageSender.encodeMessageForSending(
            namespace: .default,
            destination: destination,
            message: message,
            attachments: nil,
            authMethod: authMethod,
            using: dependencies
        )
        
        // Perform any pre-send actions
        onEvent?(.willSend(message, destination, interactionId: interactionId))
        
        return try Network.SOGS
            .preparedSend(
                ciphertext: ciphertext,
                toInboxFor: recipientBlindedPublicKey,
                authMethod: authMethod,
                using: dependencies
            )
            .map { _, response in
                let updatedMessage: Message = message
                updatedMessage.openGroupServerMessageId = UInt64(response.id)
                updatedMessage.sentTimestampMs = UInt64(floor(response.posted * 1000))
                
                return (updatedMessage, Int64(floor(response.posted * 1000)), Int64(floor(response.expires * 1000)))
            }
    }
    
    // MARK: - Message Wrapping
    
    public static func encodeMessageForSending(
        namespace: Network.SnodeAPI.Namespace,
        destination: Message.Destination,
        message: Message,
        attachments: [(attachment: Attachment, fileId: String)]?,
        authMethod: AuthenticationMethod,
        using dependencies: Dependencies
    ) throws -> Data {
        /// Check the message itself is valid
        guard
            message.isValid(isSending: true),
            let sentTimestampMs: UInt64 = message.sentTimestampMs
        else { throw MessageSenderError.invalidMessage }
        
        let plaintext: Data = try {
            switch (namespace, destination) {
                case (.revokedRetrievableGroupMessages, _):
                    return try BencodeEncoder(using: dependencies).encode(message)
                    
                case (_, .openGroup), (_, .openGroupInbox):
                    guard
                        let proto: SNProtoContent = try message.toProto()?
                            .addingAttachmentsIfNeeded(message, attachments?.map { $0.attachment })
                    else { throw MessageSenderError.protoConversionFailed }
                    
                    return try Result(proto.serializedData().paddedMessageBody())
                        .mapError { MessageSenderError.other(nil, "Couldn't serialize proto", $0) }
                        .successOrThrow()
                    
                default:
                    guard
                        let proto: SNProtoContent = try message.toProto()?
                            .addingAttachmentsIfNeeded(message, attachments?.map { $0.attachment })
                    else { throw MessageSenderError.protoConversionFailed }
                    
                    return try Result(proto.serializedData())
                        .map { serialisedData -> Data in
                            switch destination {
                                case .closedGroup(let groupId) where (try? SessionId.Prefix(from: groupId)) == .group:
                                    return serialisedData
                                    
                                default: return serialisedData.paddedMessageBody()
                            }
                        }
                        .mapError { MessageSenderError.other(nil, "Couldn't serialize proto", $0) }
                        .successOrThrow()
            }
        }()
        
        switch (destination, namespace) {
            /// Updated group messages should be wrapped _before_ encrypting
            case (.closedGroup(let groupId), .groupMessages) where (try? SessionId.Prefix(from: groupId)) == .group:
                let messageData: Data = try Result(
                    MessageWrapper.wrap(
                        type: .closedGroupMessage,
                        timestampMs: sentTimestampMs,
                        content: plaintext,
                        wrapInWebSocketMessage: false
                    )
                )
                .mapError { MessageSenderError.other(nil, "Couldn't wrap message", $0) }
                .successOrThrow()
                
                let ciphertext: Data = try dependencies[singleton: .crypto].tryGenerate(
                    .ciphertextForGroupMessage(
                        groupSessionId: SessionId(.group, hex: groupId),
                        message: Array(messageData)
                    )
                )
                return ciphertext
                
            /// `revokedRetrievableGroupMessages` should be sent in plaintext (their content has custom encryption)
            case (.closedGroup(let groupId), .revokedRetrievableGroupMessages) where (try? SessionId.Prefix(from: groupId)) == .group:
                return plaintext
                
            // Standard one-to-one messages and legacy groups (which used a `05` prefix)
            case (.contact, .default), (.syncMessage, _), (.closedGroup, _):
                let ciphertext: Data = try dependencies[singleton: .crypto].tryGenerate(
                    .ciphertextWithSessionProtocol(
                        plaintext: plaintext,
                        destination: destination
                    )
                )
                
                return try Result(
                    try MessageWrapper.wrap(
                        type: try {
                            switch destination {
                                case .contact, .syncMessage: return .sessionMessage
                                case .closedGroup: return .closedGroupMessage
                                default: throw MessageSenderError.invalidMessage
                            }
                        }(),
                        timestampMs: sentTimestampMs,
                        senderPublicKey: {
                            switch destination {
                                case .closedGroup: return try authMethod.swarmPublicKey // Needed for Android
                                default: return ""                     // Empty for all other cases
                            }
                        }(),
                        content: ciphertext
                    )
                )
                .mapError { MessageSenderError.other(nil, "Couldn't wrap message", $0) }
                .successOrThrow()
            
            /// Community messages should be sent in plaintext
            case (.openGroup, _): return plaintext
            
            /// Blinded community messages have their own special encryption
            case (.openGroupInbox(_, let serverPublicKey, let recipientBlindedPublicKey), _):
                return try dependencies[singleton: .crypto].generateResult(
                    .ciphertextWithSessionBlindingProtocol(
                        plaintext: plaintext,
                        recipientBlindedId: recipientBlindedPublicKey,
                        serverPublicKey: serverPublicKey
                    )
                )
                .mapError { MessageSenderError.other(nil, "Couldn't encrypt message for destination: \(destination)", $0) }
                .successOrThrow()
                
            /// Config messages should be sent directly rather than via this method
            case (.closedGroup(let groupId), _) where (try? SessionId.Prefix(from: groupId)) == .group:
                throw MessageSenderError.invalidConfigMessageHandling
                
            /// Config messages should be sent directly rather than via this method
            case (.contact, _): throw MessageSenderError.invalidConfigMessageHandling
        }
    }
}
