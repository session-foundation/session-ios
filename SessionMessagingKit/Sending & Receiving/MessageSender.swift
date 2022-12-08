// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import SessionSnodeKit
import SessionUtilitiesKit
import Sodium

public final class MessageSender {
    // MARK: - Message Preparation
    
    public struct PreparedSendData {
        let shouldSend: Bool
        
        let message: Message?
        let destination: Message.Destination?
        let interactionId: Int64?
        let isSyncMessage: Bool?
        let totalAttachmentsUploaded: Int
        
        let snodeMessage: SnodeMessage?
        let plaintext: Data?
        let ciphertext: Data?
        
        private init(
            shouldSend: Bool,
            message: Message?,
            destination: Message.Destination?,
            interactionId: Int64?,
            isSyncMessage: Bool?,
            totalAttachmentsUploaded: Int = 0,
            snodeMessage: SnodeMessage?,
            plaintext: Data?,
            ciphertext: Data?
        ) {
            self.shouldSend = shouldSend
            
            self.message = message
            self.destination = destination
            self.interactionId = interactionId
            self.isSyncMessage = isSyncMessage
            self.totalAttachmentsUploaded = totalAttachmentsUploaded
            
            self.snodeMessage = snodeMessage
            self.plaintext = plaintext
            self.ciphertext = ciphertext
        }
        
        // The default constructor creats an instance that doesn't actually send a message
        fileprivate init() {
            self.shouldSend = false
            
            self.message = nil
            self.destination = nil
            self.interactionId = nil
            self.isSyncMessage = nil
            self.totalAttachmentsUploaded = 0
            
            self.snodeMessage = nil
            self.plaintext = nil
            self.ciphertext = nil
        }
        
        /// This should be used to send a message to one-to-one or closed group conversations
        fileprivate init(
            message: Message,
            destination: Message.Destination,
            interactionId: Int64?,
            isSyncMessage: Bool?,
            snodeMessage: SnodeMessage
        ) {
            self.shouldSend = true
            
            self.message = message
            self.destination = destination
            self.interactionId = interactionId
            self.isSyncMessage = isSyncMessage
            self.totalAttachmentsUploaded = 0
            
            self.snodeMessage = snodeMessage
            self.plaintext = nil
            self.ciphertext = nil
        }
        
        /// This should be used to send a message to open group conversations
        fileprivate init(
            message: Message,
            destination: Message.Destination,
            interactionId: Int64?,
            plaintext: Data
        ) {
            self.shouldSend = true
            
            self.message = message
            self.destination = destination
            self.interactionId = interactionId
            self.isSyncMessage = false
            self.totalAttachmentsUploaded = 0
            
            self.snodeMessage = nil
            self.plaintext = plaintext
            self.ciphertext = nil
        }
        
        /// This should be used to send a message to an open group inbox
        fileprivate init(
            message: Message,
            destination: Message.Destination,
            interactionId: Int64?,
            ciphertext: Data
        ) {
            self.shouldSend = true
            
            self.message = message
            self.destination = destination
            self.interactionId = interactionId
            self.isSyncMessage = false
            self.totalAttachmentsUploaded = 0
            
            self.snodeMessage = nil
            self.plaintext = nil
            self.ciphertext = ciphertext
        }
        
        // MARK: - Mutation
        
        internal func with(fileIds: [String]) -> PreparedSendData {
            return PreparedSendData(
                shouldSend: shouldSend,
                message: message,
                destination: destination?.with(fileIds: fileIds),
                interactionId: interactionId,
                isSyncMessage: isSyncMessage,
                totalAttachmentsUploaded: fileIds.count,
                snodeMessage: snodeMessage,
                plaintext: plaintext,
                ciphertext: ciphertext
            )
        }
    }
    
    public static func preparedSendData(
        _ db: Database,
        message: Message,
        to destination: Message.Destination,
        interactionId: Int64?,
        using dependencies: SMKDependencies = SMKDependencies()
    ) throws -> PreparedSendData {
        // Common logic for all destinations
        let userPublicKey: String = getUserHexEncodedPublicKey(db, dependencies: dependencies)
        let messageSendTimestamp: Int64 = Int64(floor(Date().timeIntervalSince1970 * 1000))
        let updatedMessage: Message = message
        
        // Set the message 'sentTimestamp' (Visible messages will already have their sent timestamp set)
        updatedMessage.sentTimestamp = (
            updatedMessage.sentTimestamp ??
            UInt64(messageSendTimestamp)
        )
        
        switch destination {
            case .contact, .closedGroup:
                return try prepareSendToSnodeDestination(
                    db,
                    message: updatedMessage,
                    to: destination,
                    interactionId: interactionId,
                    userPublicKey: userPublicKey,
                    messageSendTimestamp: messageSendTimestamp,
                    using: dependencies
                )

            case .openGroup:
                return try prepareSendToOpenGroupDestination(
                    db,
                    message: updatedMessage,
                    to: destination,
                    interactionId: interactionId,
                    messageSendTimestamp: messageSendTimestamp,
                    using: dependencies
                )
                
            case .openGroupInbox:
                return try prepareSendToOpenGroupInboxDestination(
                    db,
                    message: message,
                    to: destination,
                    interactionId: interactionId,
                    userPublicKey: userPublicKey,
                    messageSendTimestamp: messageSendTimestamp,
                    using: dependencies
                )
        }
    }
    
    internal static func prepareSendToSnodeDestination(
        _ db: Database,
        message: Message,
        to destination: Message.Destination,
        interactionId: Int64?,
        userPublicKey: String,
        messageSendTimestamp: Int64,
        isSyncMessage: Bool = false,
        using dependencies: SMKDependencies = SMKDependencies()
    ) throws -> PreparedSendData {
        message.sender = userPublicKey
        message.recipient = {
            switch destination {
                case .contact(let publicKey, _): return publicKey
                case .closedGroup(let groupPublicKey, _): return groupPublicKey
                case .openGroup, .openGroupInbox: preconditionFailure()
            }
        }()
        
        // Validate the message
        guard message.isValid else {
            throw MessageSender.handleFailedMessageSend(
                db,
                message: message,
                with: .invalidMessage,
                interactionId: interactionId,
                using: dependencies
            )
        }
        
        // Stop here if this is a self-send, unless we should sync the message
        let isSelfSend: Bool = (message.recipient == userPublicKey)
        
        guard
            !isSelfSend ||
            isSyncMessage ||
            Message.shouldSync(message: message)
        else {
            try MessageSender.handleSuccessfulMessageSend(db, message: message, to: destination, interactionId: interactionId, using: dependencies)
            return PreparedSendData()
        }
        
        // Attach the user's profile if needed
        if var messageWithProfile: MessageWithProfile = message as? MessageWithProfile {
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
        
        // Convert it to protobuf
        guard let proto = message.toProto(db) else {
            throw MessageSender.handleFailedMessageSend(
                db,
                message: message,
                with: .protoConversionFailed,
                interactionId: interactionId,
                using: dependencies
            )
        }
        
        // Serialize the protobuf
        let plaintext: Data
        
        do {
            plaintext = try proto.serializedData().paddedMessageBody()
        }
        catch {
            SNLog("Couldn't serialize proto due to error: \(error).")
            throw MessageSender.handleFailedMessageSend(
                db,
                message: message,
                with: .other(error),
                interactionId: interactionId,
                using: dependencies
            )
        }
        
        // Encrypt the serialized protobuf
        let ciphertext: Data
        do {
            switch destination {
                case .contact(let publicKey, _):
                    ciphertext = try encryptWithSessionProtocol(plaintext, for: publicKey)
                    
                case .closedGroup(let groupPublicKey, _):
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
            throw MessageSender.handleFailedMessageSend(
                db,
                message: message,
                with: .other(error),
                interactionId: interactionId,
                using: dependencies
            )
        }
        
        // Wrap the result
        let kind: SNProtoEnvelope.SNProtoEnvelopeType
        let senderPublicKey: String
        
        switch destination {
            case .contact:
                kind = .sessionMessage
                senderPublicKey = ""
                
            case .closedGroup(let groupPublicKey, _):
                kind = .closedGroupMessage
                senderPublicKey = groupPublicKey
            
            case .openGroup, .openGroupInbox: preconditionFailure()
        }
        
        let wrappedMessage: Data
        do {
            wrappedMessage = try MessageWrapper.wrap(
                type: kind,
                timestamp: message.sentTimestamp!,
                senderPublicKey: senderPublicKey,
                base64EncodedContent: ciphertext.base64EncodedString()
            )
        }
        catch {
            SNLog("Couldn't wrap message due to error: \(error).")
            throw MessageSender.handleFailedMessageSend(
                db,
                message: message,
                with: .other(error),
                interactionId: interactionId,
                using: dependencies
            )
        }
        
        // Send the result
        let base64EncodedData = wrappedMessage.base64EncodedString()
        
        let snodeMessage = SnodeMessage(
            recipient: message.recipient!,
            data: base64EncodedData,
            ttl: message.ttl,
            timestampMs: UInt64(messageSendTimestamp + SnodeAPI.clockOffset.wrappedValue)
        )
        
        return PreparedSendData(
            message: message,
            destination: destination,
            interactionId: interactionId,
            isSyncMessage: isSyncMessage,
            snodeMessage: snodeMessage
        )
    }
    
    internal static func prepareSendToOpenGroupDestination(
        _ db: Database,
        message: Message,
        to destination: Message.Destination,
        interactionId: Int64?,
        messageSendTimestamp: Int64,
        using dependencies: SMKDependencies = SMKDependencies()
    ) throws -> PreparedSendData {
        let threadId: String
        
        switch destination {
            case .contact, .closedGroup, .openGroupInbox: preconditionFailure()
            case .openGroup(let roomToken, let server, let whisperTo, let whisperMods, _):
                threadId = OpenGroup.idFor(roomToken: roomToken, server: server)
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
            let openGroup: OpenGroup = try? OpenGroup.fetchOne(db, id: threadId),
            let userEdKeyPair: Box.KeyPair = Identity.fetchUserEd25519KeyPair(db),
            case .openGroup(_, let server, _, _, _) = destination
        else {
            throw MessageSenderError.invalidMessage
        }
        
        message.sender = {
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
            guard let blindedKeyPair: Box.KeyPair = dependencies.sodium.blindedKeyPair(serverPublicKey: openGroup.publicKey, edKeyPair: userEdKeyPair, genericHash: dependencies.genericHash) else {
                preconditionFailure()
            }
            
            return SessionId(.blinded, publicKey: blindedKeyPair.publicKey).hexString
        }()
        
        // Validate the message
        guard
            let message = message as? VisibleMessage,
            message.isValid
        else {
            #if DEBUG
            if (message as? VisibleMessage) == nil { preconditionFailure() }
            #endif
            throw MessageSender.handleFailedMessageSend(
                db,
                message: message,
                with: .invalidMessage,
                interactionId: interactionId,
                using: dependencies
            )
        }
        
        // Attach the user's profile
        message.profile = VisibleMessage.VMProfile(
            profile: Profile.fetchOrCreateCurrentUser()
        )

        if (message.profile?.displayName ?? "").isEmpty {
            throw MessageSender.handleFailedMessageSend(
                db,
                message: message,
                with: .noUsername,
                interactionId: interactionId,
                using: dependencies
            )
        }
        
        // Convert it to protobuf
        guard let proto = message.toProto(db) else {
            throw MessageSender.handleFailedMessageSend(
                db,
                message: message,
                with: .protoConversionFailed,
                interactionId: interactionId,
                using: dependencies
            )
        }
        
        // Serialize the protobuf
        let plaintext: Data
        
        do {
            plaintext = try proto.serializedData().paddedMessageBody()
        }
        catch {
            SNLog("Couldn't serialize proto due to error: \(error).")
            throw MessageSender.handleFailedMessageSend(
                db,
                message: message,
                with: .other(error),
                interactionId: interactionId,
                using: dependencies
            )
        }
        
        return PreparedSendData(
            message: message,
            destination: destination,
            interactionId: interactionId,
            plaintext: plaintext
        )
    }
    
    internal static func prepareSendToOpenGroupInboxDestination(
        _ db: Database,
        message: Message,
        to destination: Message.Destination,
        interactionId: Int64?,
        userPublicKey: String,
        messageSendTimestamp: Int64,
        using dependencies: SMKDependencies = SMKDependencies()
    ) throws -> PreparedSendData {
        guard case .openGroupInbox(_, let openGroupPublicKey, let recipientBlindedPublicKey) = destination else {
            throw MessageSenderError.invalidMessage
        }
        
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
        
        // Convert it to protobuf
        guard let proto = message.toProto(db) else {
            throw MessageSender.handleFailedMessageSend(
                db,
                message: message,
                with: .protoConversionFailed,
                interactionId: interactionId,
                using: dependencies
            )
        }
        
        // Serialize the protobuf
        let plaintext: Data
        
        do {
            plaintext = try proto.serializedData().paddedMessageBody()
        }
        catch {
            SNLog("Couldn't serialize proto due to error: \(error).")
            throw MessageSender.handleFailedMessageSend(
                db,
                message: message,
                with: .other(error),
                interactionId: interactionId,
                using: dependencies
            )
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
            throw MessageSender.handleFailedMessageSend(
                db,
                message: message,
                with: .other(error),
                interactionId: interactionId,
                using: dependencies
            )
        }
        
        return PreparedSendData(
            message: message,
            destination: destination,
            interactionId: interactionId,
            ciphertext: ciphertext
        )
    }
    
    // MARK: - Sending
    
    public static func sendImmediate(
        preparedSendData: PreparedSendData,
        using dependencies: SMKDependencies = SMKDependencies()
    ) -> AnyPublisher<Void, Error> {
        guard preparedSendData.shouldSend else {
            return Just(())
                .setFailureType(to: Error.self)
                .eraseToAnyPublisher()
        }
        
        // We now allow the creation of message data without validating it's attachments have finished
        // uploading first, this is here to ensure we don't send a message which should have uploaded
        // files
        //
        // If you see this error then you need to call `MessageSender.performUploadsIfNeeded(preparedSendData:)`
        // before calling this function
        switch preparedSendData.message {
            case let visibleMessage as VisibleMessage:
                guard visibleMessage.attachmentIds.count == preparedSendData.totalAttachmentsUploaded else {
                    return Fail(error: MessageSenderError.attachmentsNotUploaded)
                        .eraseToAnyPublisher()
                }
                
                break
                
            default: break
        }
        
        switch preparedSendData.destination {
            case .contact, .closedGroup: return sendToSnodeDestination(data: preparedSendData, using: dependencies)
            case .openGroup: return sendToOpenGroupDestination(data: preparedSendData, using: dependencies)
            case .openGroupInbox: return sendToOpenGroupInbox(data: preparedSendData, using: dependencies)
            case .none:
                return Fail(error: MessageSenderError.invalidMessage)
                    .eraseToAnyPublisher()
        }
    }
    
    // MARK: - One-to-One
    
    private static func sendToSnodeDestination(
        data: PreparedSendData,
        using dependencies: SMKDependencies = SMKDependencies()
    ) -> AnyPublisher<Void, Error> {
        guard
            let message: Message = data.message,
            let destination: Message.Destination = data.destination,
            let isSyncMessage: Bool = data.isSyncMessage,
            let snodeMessage: SnodeMessage = data.snodeMessage
        else {
            return Fail(error: MessageSenderError.invalidMessage)
                .eraseToAnyPublisher()
        }
        
        let isMainAppActive: Bool = (UserDefaults.sharedLokiProject?[.isMainAppActive])
            .defaulting(to: false)
        var isSuccess = false
        var errorCount = 0
        
        return SnodeAPI
            .sendMessage(
                snodeMessage,
                in: destination.namespace
            )
            .subscribe(on: DispatchQueue.global(qos: .default))
            .flatMap { result, totalCount -> AnyPublisher<Bool, Error> in
                switch result {
                    case .success(let response):
                        // Don't emit if we've already succeeded
                        guard !isSuccess else {
                            return Just(false)
                                .setFailureType(to: Error.self)
                                .eraseToAnyPublisher()
                        }
                        isSuccess = true

                        let updatedMessage: Message = message
                        updatedMessage.serverHash = response.1.hash

                        let job: Job? = Job(
                            variant: .notifyPushServer,
                            behaviour: .runOnce,
                            details: NotifyPushServerJob.Details(message: snodeMessage)
                        )
                        let shouldNotify: Bool = {
                            switch updatedMessage {
                                case is VisibleMessage, is UnsendRequest: return !isSyncMessage
                                case let callMessage as CallMessage:
                                    switch callMessage.kind {
                                        case .preOffer: return true
                                        default: return false
                                    }

                                default: return false
                            }
                        }()

                        return dependencies.storage
                            .writePublisher { db -> Void in
                                try MessageSender.handleSuccessfulMessageSend(
                                    db,
                                    message: updatedMessage,
                                    to: destination,
                                    interactionId: data.interactionId,
                                    isSyncMessage: isSyncMessage,
                                    using: dependencies
                                )

                                guard shouldNotify && isMainAppActive else { return () }

                                JobRunner.add(db, job: job)
                                return ()
                            }
                            .flatMap { _ -> AnyPublisher<Bool, Error> in
                                guard shouldNotify && !isMainAppActive else {
                                    return Just(true)
                                        .setFailureType(to: Error.self)
                                        .eraseToAnyPublisher()
                                }
                                guard let job: Job = job else {
                                    return Just(true)
                                        .setFailureType(to: Error.self)
                                        .eraseToAnyPublisher()
                                }

                                return Future<Bool, Error> { resolver in
                                    NotifyPushServerJob.run(
                                        job,
                                        queue: DispatchQueue.global(qos: .default),
                                        success: { _, _ in resolver(Result.success(true)) },
                                        failure: { _, _, _ in
                                            // Always fulfill because the notify PN server job isn't critical.
                                            resolver(Result.success(true))
                                        },
                                        deferred: { _ in
                                            // Always fulfill because the notify PN server job isn't critical.
                                            resolver(Result.success(true))
                                        }
                                    )
                                }
                                .eraseToAnyPublisher()
                            }
                            .eraseToAnyPublisher()

                    case .failure(let error):
                        errorCount += 1

                        // Only process the error if all promises failed
                        guard errorCount == totalCount else {
                            return Just(false)
                                .setFailureType(to: Error.self)
                                .eraseToAnyPublisher()
                        }

                        return Fail(error: error)
                            .eraseToAnyPublisher()
                }
            }
            .filter { $0 }
            .handleEvents(
                receiveCompletion: { result in
                    switch result {
                        case .finished: break
                        case .failure(let error):
                            SNLog("Couldn't send message due to error: \(error).")

                            dependencies.storage.read { db in
                                MessageSender.handleFailedMessageSend(
                                    db,
                                    message: message,
                                    with: .other(error),
                                    interactionId: data.interactionId,
                                    using: dependencies
                                )
                            }
                    }
                }
            )
            .map { _ in () }
            .eraseToAnyPublisher()
    }
    
    // MARK: - Open Groups
    
    private static func sendToOpenGroupDestination(
        data: PreparedSendData,
        using dependencies: SMKDependencies = SMKDependencies()
    ) -> AnyPublisher<Void, Error> {
        guard
            let message: Message = data.message,
            let destination: Message.Destination = data.destination,
            case .openGroup(let roomToken, let server, let whisperTo, let whisperMods, let fileIds) = destination,
            let plaintext: Data = data.plaintext
        else {
            return Fail(error: MessageSenderError.invalidMessage)
                .eraseToAnyPublisher()
        }
        
        // Send the result
        return dependencies.storage
            .readPublisherFlatMap { db in
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
            }
            .subscribe(on: DispatchQueue.global(qos: .default))
            .flatMap { (responseInfo, responseData) -> AnyPublisher<Void, Error> in
                let serverTimestampMs: UInt64? = responseData.posted.map { UInt64(floor($0 * 1000)) }
                let updatedMessage: Message = message
                updatedMessage.openGroupServerMessageId = UInt64(responseData.id)
                
                return dependencies.storage.writePublisher { db in
                    // The `posted` value is in seconds but we sent it in ms so need that for de-duping
                    try MessageSender.handleSuccessfulMessageSend(
                        db,
                        message: updatedMessage,
                        to: destination,
                        interactionId: data.interactionId,
                        serverTimestampMs: serverTimestampMs,
                        using: dependencies
                    )
                    
                    return ()
                }
            }
            .handleEvents(
                receiveCompletion: { result in
                    switch result {
                        case .finished: break
                        case .failure(let error):
                            dependencies.storage.read { db in
                                MessageSender.handleFailedMessageSend(
                                    db,
                                    message: message,
                                    with: .other(error),
                                    interactionId: data.interactionId,
                                    using: dependencies
                                )
                            }
                    }
                }
            )
            .eraseToAnyPublisher()
    }
    
    private static func sendToOpenGroupInbox(
        data: PreparedSendData,
        using dependencies: SMKDependencies = SMKDependencies()
    ) -> AnyPublisher<Void, Error> {
        guard
            let message: Message = data.message,
            let destination: Message.Destination = data.destination,
            case .openGroupInbox(let server, _, let recipientBlindedPublicKey) = destination,
            let ciphertext: Data = data.ciphertext
        else {
            return Fail(error: MessageSenderError.invalidMessage)
                .eraseToAnyPublisher()
        }
        
        // Send the result
        return dependencies.storage
            .readPublisherFlatMap { db in
                return OpenGroupAPI
                    .send(
                        db,
                        ciphertext: ciphertext,
                        toInboxFor: recipientBlindedPublicKey,
                        on: server,
                        using: dependencies
                    )
            }
            .subscribe(on: DispatchQueue.global(qos: .default))
            .flatMap { (responseInfo, responseData) -> AnyPublisher<Void, Error> in
                let updatedMessage: Message = message
                updatedMessage.openGroupServerMessageId = UInt64(responseData.id)
                
                return dependencies.storage.writePublisher { db in
                    // The `posted` value is in seconds but we sent it in ms so need that for de-duping
                    try MessageSender.handleSuccessfulMessageSend(
                        db,
                        message: updatedMessage,
                        to: destination,
                        interactionId: data.interactionId,
                        serverTimestampMs: UInt64(floor(responseData.posted * 1000)),
                        using: dependencies
                    )

                    return ()
                }
            }
            .handleEvents(
                receiveCompletion: { result in
                    switch result {
                        case .finished: break
                        case .failure(let error):
                            dependencies.storage.read { db in
                                MessageSender.handleFailedMessageSend(
                                    db,
                                    message: message,
                                    with: .other(error),
                                    interactionId: data.interactionId,
                                    using: dependencies
                                )
                            }
                    }
                }
            )
            .eraseToAnyPublisher()
    }

    // MARK: Success & Failure Handling
    
    private static func handleSuccessfulMessageSend(
        _ db: Database,
        message: Message,
        to destination: Message.Destination,
        interactionId: Int64?,
        serverTimestampMs: UInt64? = nil,
        isSyncMessage: Bool = false,
        using dependencies: SMKDependencies = SMKDependencies()
    ) throws {
        // If the message was a reaction then we want to update the reaction instead of the original
        // interaciton (which the 'interactionId' is pointing to
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
                    .updateAll(db, RecipientState.Columns.state.set(to: RecipientState.State.sent))
                
                // Start the disappearing messages timer if needed
                JobRunner.upsert(
                    db,
                    job: DisappearingMessagesJob.updateNextRunIfNeeded(
                        db,
                        interaction: interaction,
                        startedAtMs: (Date().timeIntervalSince1970 * 1000)
                    )
                )
            }
        }
        
        // Prevent ControlMessages from being handled multiple times if not supported
        try? ControlMessageProcessRecord(
            threadId: {
                switch destination {
                    case .contact(let publicKey, _): return publicKey
                    case .closedGroup(let groupPublicKey, _): return groupPublicKey
                    case .openGroup(let roomToken, let server, _, _, _):
                        return OpenGroup.idFor(roomToken: roomToken, server: server)
                    
                    case .openGroupInbox(_, _, let blindedPublicKey): return blindedPublicKey
                }
            }(),
            message: message,
            serverExpirationTimestamp: (Date().timeIntervalSince1970 + ControlMessageProcessRecord.defaultExpirationSeconds)
        )?.insert(db)
        
        // Sync the message if:
        // • it's a visible message or an expiration timer update
        // • the destination was a contact
        // • we didn't sync it already
        let userPublicKey = getUserHexEncodedPublicKey(db)
        if case .contact(let publicKey, let namespace) = destination, !isSyncMessage {
            if let message = message as? VisibleMessage { message.syncTarget = publicKey }
            if let message = message as? ExpirationTimerUpdate { message.syncTarget = publicKey }
            
            MessageSender
                .sendToSnodeDestination(
                    data: try prepareSendToSnodeDestination(
                        db,
                        message: message,
                        to: .contact(publicKey: userPublicKey, namespace: namespace),
                        interactionId: interactionId,
                        userPublicKey: userPublicKey,
                        messageSendTimestamp: Int64(floor(Date().timeIntervalSince1970 * 1000)),
                        isSyncMessage: true
                    ),
                    using: dependencies
                )
                .sinkUntilComplete()
        }
    }

    @discardableResult private static func handleFailedMessageSend(
        _ db: Database,
        message: Message,
        with error: MessageSenderError,
        interactionId: Int64?,
        using dependencies: SMKDependencies = SMKDependencies()
    ) -> Error {
        // TODO: Revert the local database change
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
            .filter(RecipientState.Columns.state == RecipientState.State.sending)
            .asRequest(of: Int64.self)
            .fetchAll(db))
            .defaulting(to: [])
        
        guard !rowIds.isEmpty else { return error }
        
        // Need to dispatch to a different thread to prevent a potential db re-entrancy
        // issue from occuring in some cases
        DispatchQueue.global(qos: .background).async {
            dependencies.storage.write { db in
                try RecipientState
                    .filter(rowIds.contains(Column.rowID))
                    .updateAll(
                        db,
                        RecipientState.Columns.state.set(to: RecipientState.State.failed),
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
}
