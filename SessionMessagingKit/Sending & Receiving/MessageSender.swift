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
    public typealias SendResponse = (message: Message, serverTimestampMs: Int64?, serverExpirationMs: Int64?)
    public enum Event {
        case willSend(Message, Message.Destination, interactionId: Int64?)
        case success(Message, Message.Destination, interactionId: Int64?, serverTimestampMs: Int64?, serverExpirationMs: Int64?)
        case failure(Message, Message.Destination, interactionId: Int64?, error: MessageError)
        
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
    
    public struct MessageToSend {
        public let message: Message
        public let destination: Message.Destination
        public let namespace: Network.StorageServer.Namespace?
        public let interactionId: Int64?
        public let attachments: [(attachment: Attachment, fileId: String)]?
        public let authMethod: AuthenticationMethod
        public let onEvent: ((Event) -> Void)?
    }
    
    // MARK: - Message Sending
    
    @discardableResult public static func send(
        message: Message,
        to destination: Message.Destination,
        namespace: Network.StorageServer.Namespace?,
        interactionId: Int64?,
        attachments: [(attachment: Attachment, fileId: String)]?,
        authMethod: AuthenticationMethod,
        onEvent: ((Event) -> Void)?,
        using dependencies: Dependencies
    ) async throws -> Message {
        var updatedMessage: Message = message
        let request: Network.PreparedRequest<SendResponse> = try preparedSend(
            message: &updatedMessage,
            to: destination,
            namespace: namespace,
            interactionId: interactionId,
            attachments: attachments,
            authMethod: authMethod,
            using: dependencies
        )
        onEvent?(.willSend(updatedMessage, destination, interactionId: interactionId))
        
        let result: Result<SendResponse, Error> = await Result(catching: {
            try await request.send(using: dependencies)
        })
        triggerResultEvents(
            result,
            message: updatedMessage,
            destination: destination,
            interactionId: interactionId,
            onEvent: onEvent
        )
        
        return try result.get().message
    }
    
    @discardableResult public static func sendBatch(
        _ messages: [MessageToSend],
        sequenceRequests: Bool = false,
        requireAllResponses: Bool = false,
        swarmPublicKey: String,
        using dependencies: Dependencies
    ) async throws -> [Message] {
        let preparedInfo: [(request: Network.PreparedRequest<SendResponse>, updatedMessage: Message)] = try messages.map {
            var updatedMessage: Message = $0.message
            let request = try preparedSend(
                message: &updatedMessage,
                to: $0.destination,
                namespace: $0.namespace,
                interactionId: $0.interactionId,
                attachments: $0.attachments,
                authMethod: $0.authMethod,
                using: dependencies
            )
            $0.onEvent?(.willSend(updatedMessage, $0.destination, interactionId: $0.interactionId))
            
            return (request, updatedMessage)
        }
        
        let batchRequest: Network.PreparedRequest<Network.BatchResponse> = try (sequenceRequests ?
            Network.StorageServer.preparedSequence(
                requests: preparedInfo.map { $0.request },
                requireAllBatchResponses: requireAllResponses,
                swarmPublicKey: swarmPublicKey,
                using: dependencies
            ) :
            Network.StorageServer.preparedBatch(
                requests: preparedInfo.map { $0.request },
                requireAllBatchResponses: requireAllResponses,
                swarmPublicKey: swarmPublicKey,
                using: dependencies
            )
        )

        do {
            let batchResponse: Network.BatchResponse = try await batchRequest.send(using: dependencies)
            var result: [Message] = []
            result.reserveCapacity(preparedInfo.count)
            
            /// Fire events for each message and add to the result
            for ((messageInfo, requestInfo), subResponse) in zip(zip(messages, preparedInfo), batchResponse) {
                guard
                    let typedSubResponse: Network.BatchSubResponse<SendResponse> = subResponse as? Network.BatchSubResponse<SendResponse>,
                    !typedSubResponse.failedToParseBody,
                    let subSendResponse: SendResponse = typedSubResponse.body
                else { throw NetworkError.invalidResponse }
                
                triggerResultEvents(
                    .success(subSendResponse),
                    message: requestInfo.updatedMessage,
                    destination: messageInfo.destination,
                    interactionId: messageInfo.interactionId,
                    onEvent: messageInfo.onEvent
                )
                
                result.append(subSendResponse.message)
            }
            
            return result
        } catch {
            for (messageInfo, requestInfo) in zip(messages, preparedInfo) {
                triggerResultEvents(
                    .failure(error),
                    message: requestInfo.updatedMessage,
                    destination: messageInfo.destination,
                    interactionId: messageInfo.interactionId,
                    onEvent: messageInfo.onEvent
                )
            }
            throw error
        }
    }
    
    private static func triggerResultEvents(
        _ result: Result<SendResponse, Error>,
        message: Message,
        destination: Message.Destination,
        interactionId: Int64?,
        onEvent: ((Event) -> Void)?
    ) {
        switch result {
            case .success(let response):
                onEvent?(.success(
                    response.message,
                    destination,
                    interactionId: interactionId,
                    serverTimestampMs: response.serverTimestampMs,
                    serverExpirationMs: response.serverExpirationMs
                ))
                
            case .failure(let error):
                onEvent?(.failure(
                    message,
                    destination,
                    interactionId: interactionId,
                    error: .sendFailure(nil, "Couldn't send message", error)
                ))
        }
    }
    
    // MARK: - Message Preparation
    
    public static func preparedSend(
        message: inout Message,
        to destination: Message.Destination,
        namespace: Network.StorageServer.Namespace?,
        interactionId: Int64?,
        attachments: [(attachment: Attachment, fileId: String)]?,
        authMethod: AuthenticationMethod,
        using dependencies: Dependencies
    ) throws -> Network.PreparedRequest<SendResponse> {
        // Common logic for all destinations
        let messageSendTimestampMs: Int64 = dependencies.networkOffsetTimestampMs()
        
        // Set the message 'sentTimestamp' (Visible messages will already have their sent timestamp set)
        message.sentTimestampMs = (
            message.sentTimestampMs ??
            UInt64(messageSendTimestampMs)
        )
        message.sigTimestampMs = message.sentTimestampMs
        
        let request: Network.PreparedRequest<SendResponse>
        
        switch destination {
            case .contact, .syncMessage, .group:
                request = try preparedSendToSnodeDestination(
                    message: &message,
                    to: destination,
                    namespace: namespace,
                    interactionId: interactionId,
                    attachments: attachments,
                    messageSendTimestampMs: messageSendTimestampMs,
                    authMethod: authMethod,
                    using: dependencies
                )
                
            case .community:
                request = try preparedSendToCommunityDestination(
                    message: &message,
                    to: destination,
                    interactionId: interactionId,
                    attachments: attachments,
                    messageSendTimestampMs: messageSendTimestampMs,
                    authMethod: authMethod,
                    using: dependencies
                )
                
            case .communityInbox:
                request = try preparedSendToCommunityInboxDestination(
                    message: &message,
                    to: destination,
                    interactionId: interactionId,
                    attachments: attachments,
                    messageSendTimestampMs: messageSendTimestampMs,
                    authMethod: authMethod,
                    using: dependencies
                )
        }
        
        /// After a successful send we want to schedule a sync message if needed
        let finalMessage: Message = message
        
        return request.withPostSendAction {
            Task(priority: .userInitiated) {
                try? await MessageSender.scheduleSyncMessageIfNeeded(
                    message: finalMessage,
                    destination: destination,
                    threadId: Message.threadId(
                        forMessage: finalMessage,
                        destination: destination,
                        using: dependencies
                    ),
                    interactionId: interactionId,
                    using: dependencies
                )
            }
        }
    }
    
    private static func preparedSendToSnodeDestination(
        message: inout Message,
        to destination: Message.Destination,
        namespace: Network.StorageServer.Namespace?,
        interactionId: Int64?,
        attachments: [(attachment: Attachment, fileId: String)]?,
        messageSendTimestampMs: Int64,
        authMethod: AuthenticationMethod,
        using dependencies: Dependencies
    ) throws -> Network.PreparedRequest<SendResponse> {
        guard let namespace: Network.StorageServer.Namespace = namespace else {
            throw MessageError.missingRequiredField("namespace")
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
                    .map { profile in VisibleMessage.VMProfile(profile: profile) }
        }
        
        // Convert and prepare the data for sending
        let swarmPublicKey: String = {
            switch destination {
                case .contact(let publicKey): return publicKey
                case .syncMessage: return userSessionId.hexString
                case .group(let publicKey): return publicKey
                case .community, .communityInbox: preconditionFailure()
            }
        }()
        let request: Network.StorageServer.SendMessageRequest = Network.StorageServer.SendMessageRequest(
            recipient: swarmPublicKey,
            namespace: namespace,
            data: try MessageSender.encodeMessageForSending(
                namespace: namespace,
                destination: destination,
                message: message,
                attachments: attachments,
                using: dependencies
            ),
            ttl: Message.getSpecifiedTTL(message: message, destination: destination, using: dependencies),
            /// **Note:** This timestamp is for the request being sent rather than when the message was created so it should always
            /// be the current offset timestamp (otherwise the storage server could reject the request for the clock being too far out)
            timestampMs: dependencies.networkOffsetTimestampMs(),
            authMethod: authMethod
        )
        
        let finalMessage: Message = message
        
        return try Network.StorageServer
            .preparedSendMessage(
                request: request,
                using: dependencies
            )
            .map { _, response in
                let expirationTimestampMs: Int64 = (dependencies.networkOffsetTimestampMs() + Network.StorageServer.Message.defaultExpirationMs)
                let updatedMessage: Message = finalMessage
                updatedMessage.serverHash = response.hash
                
                return (updatedMessage, nil, expirationTimestampMs)
            }
    }
    
    private static func preparedSendToCommunityDestination(
        message: inout Message,
        to destination: Message.Destination,
        interactionId: Int64?,
        attachments: [(attachment: Attachment, fileId: String)]?,
        messageSendTimestampMs: Int64,
        authMethod: AuthenticationMethod,
        using dependencies: Dependencies
    ) throws -> Network.PreparedRequest<SendResponse> {
        // Note: It's possible to send a message and then delete the open group you sent the message to
        // which would go into this case, so rather than handling it as an invalid state we just want to
        // error in a non-retryable way
        guard
            let message: VisibleMessage = message as? VisibleMessage,
            case .community(let server, let publicKey, let hasCapabilities, let supportsBlinding, _) = authMethod.info,
            case .community(let roomToken, let destinationServer, let whisperTo, let whisperMods) = destination,
            server == destinationServer,
            let userEdKeyPair: KeyPair = dependencies[singleton: .crypto].generate(
                .ed25519KeyPair(seed: dependencies[cache: .general].ed25519Seed)
            )
        else { throw MessageError.invalidMessage("Configuration doesn't meet requirements to send to a community") }
        
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
            else { throw MessageError.requiredSignatureMissing }
            
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
                    profile: profile,
                    blocksCommunityMessageRequests: !checkForCommunityMessageRequests
                )
            }

        guard !(message.profile?.displayName ?? "").isEmpty else { throw MessageError.invalidSender }
        
        let plaintext: Data = try MessageSender.encodeMessageForSending(
            namespace: .default,
            destination: destination,
            message: message,
            attachments: attachments,
            using: dependencies
        )
        
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
    
    private static func preparedSendToCommunityInboxDestination(
        message: inout Message,
        to destination: Message.Destination,
        interactionId: Int64?,
        attachments: [(attachment: Attachment, fileId: String)]?,
        messageSendTimestampMs: Int64,
        authMethod: AuthenticationMethod,
        using dependencies: Dependencies
    ) throws -> Network.PreparedRequest<SendResponse> {
        /// The `communityInbox` destination does not support attachments
        guard
            (attachments ?? []).isEmpty,
            case .communityInbox(_, _, let recipientBlindedPublicKey) = destination
        else { throw MessageError.invalidMessage("Configuration doesn't meet requirements to send to community inbox") }
        
        let userSessionId: SessionId = dependencies[cache: .general].sessionId
        message.sender = userSessionId.hexString
        
        // Attach the user's profile if needed
        switch (message as? MessageWithProfile) {
            case .some(var messageWithProfile):
                messageWithProfile.profile = dependencies
                    .mutate(cache: .libSession) { $0.profile(contactId: userSessionId.hexString) }
                    .map { profile in VisibleMessage.VMProfile(profile: profile) }
            
            default: break
        }
        let ciphertext: Data = try MessageSender.encodeMessageForSending(
            namespace: .default,
            destination: destination,
            message: message,
            attachments: nil,
            using: dependencies
        )
        
        let finalMessage: Message = message
        
        return try Network.SOGS
            .preparedSend(
                ciphertext: ciphertext,
                toInboxFor: recipientBlindedPublicKey,
                authMethod: authMethod,
                using: dependencies
            )
            .map { _, response in
                let updatedMessage: Message = finalMessage
                updatedMessage.openGroupServerMessageId = UInt64(response.id)
                updatedMessage.sentTimestampMs = UInt64(floor(response.posted * 1000))
                
                return (updatedMessage, Int64(floor(response.posted * 1000)), Int64(floor(response.expires * 1000)))
            }
    }
    
    // MARK: - Message Wrapping
    
    public static func encodeMessageForSending(
        namespace: Network.StorageServer.Namespace,
        destination: Message.Destination,
        message: Message,
        attachments: [(attachment: Attachment, fileId: String)]?,
        using dependencies: Dependencies
    ) throws -> Data {
        /// Check the message itself is valid
        try message.validateMessage(isSending: true)
        
        guard let sentTimestampMs: UInt64 = message.sentTimestampMs else {
            throw MessageError.missingRequiredField("sentTimestampMs")
        }

        /// Messages sent to `revokedRetrievableGroupMessages` should be sent directly instead of via the `MessageSender`
        guard namespace != .revokedRetrievableGroupMessages else {
            throw MessageError.invalidMessage("Attempted to send to namespace \(namespace) via the wrong pipeline")
        }
        
        /// Add Session Pro data if needed
        let finalMessage: Message = dependencies[singleton: .sessionProManager].attachProInfoIfNeeded(message: message)
        
        /// Add attachments if needed and convert to serialised proto data
        guard
            let plaintext: Data = try? finalMessage.toProto()?
                .addingAttachmentsIfNeeded(finalMessage, attachments?.map { $0.attachment })?
                .serializedData()
        else { throw MessageError.protoConversionFailed }
        
        return try dependencies[singleton: .crypto].tryGenerate(
            .encodedMessage(
                plaintext: Array(plaintext),
                proMessageFeatures: (finalMessage.proMessageFeatures ?? .none),
                proProfileFeatures: (finalMessage.proProfileFeatures ?? .none),
                destination: destination,
                sentTimestampMs: sentTimestampMs
            )
        )
    }
}
