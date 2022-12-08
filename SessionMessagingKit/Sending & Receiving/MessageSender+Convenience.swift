// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import SessionUtilitiesKit

extension MessageSender {
    
    // MARK: - Durable
    
    public static func send(_ db: Database, interaction: Interaction, in thread: SessionThread) throws {
        // Only 'VisibleMessage' types can be sent via this method
        guard interaction.variant == .standardOutgoing else { throw MessageSenderError.invalidMessage }
        guard let interactionId: Int64 = interaction.id else { throw StorageError.objectNotSaved }
        
        send(
            db,
            message: VisibleMessage.from(db, interaction: interaction),
            threadId: thread.id,
            interactionId: interactionId,
            to: try Message.Destination.from(db, thread: thread)
        )
    }
    
    public static func send(_ db: Database, message: Message, interactionId: Int64?, in thread: SessionThread) throws {
        send(
            db,
            message: message,
            threadId: thread.id,
            interactionId: interactionId,
            to: try Message.Destination.from(db, thread: thread)
        )
    }
    
    public static func send(_ db: Database, message: Message, threadId: String?, interactionId: Int64?, to destination: Message.Destination) {
        JobRunner.add(
            db,
            job: Job(
                variant: .messageSend,
                threadId: threadId,
                interactionId: interactionId,
                details: MessageSendJob.Details(
                    destination: destination,
                    message: message
                )
            )
        )
    }

    // MARK: - Non-Durable
    
    public static func preparedSendData(
        _ db: Database,
        interaction: Interaction,
        in thread: SessionThread
    ) throws -> PreparedSendData {
        // Only 'VisibleMessage' types can be sent via this method
        guard interaction.variant == .standardOutgoing else { throw MessageSenderError.invalidMessage }
        guard let interactionId: Int64 = interaction.id else { throw StorageError.objectNotSaved }
        
        return try MessageSender.preparedSendData(
            db,
            message: VisibleMessage.from(db, interaction: interaction),
            to: try Message.Destination.from(db, thread: thread),
            interactionId: interactionId
        )
    }
    
    public static func performUploadsIfNeeded(
        preparedSendData: PreparedSendData
    ) -> AnyPublisher<PreparedSendData, Error> {
        // We need an interactionId in order for a message to have uploads
        guard let interactionId: Int64 = preparedSendData.interactionId else {
            return Just(preparedSendData)
                .setFailureType(to: Error.self)
                .eraseToAnyPublisher()
        }
        
        // Ensure we have the rest of the required data
        guard let destination: Message.Destination = preparedSendData.destination else {
            return Fail<PreparedSendData, Error>(error: MessageSenderError.invalidMessage)
                .eraseToAnyPublisher()
        }
        
        let threadId: String = {
            switch destination {
                case .contact(let publicKey, _): return publicKey
                case .closedGroup(let groupPublicKey, _): return groupPublicKey
                case .openGroup(let roomToken, let server, _, _, _):
                    return OpenGroup.idFor(roomToken: roomToken, server: server)
                    
                case .openGroupInbox(_, _, let blindedPublicKey): return blindedPublicKey
            }
        }()
        
        return Storage.shared
            .readPublisherFlatMap { db -> AnyPublisher<(attachments: [Attachment], openGroup: OpenGroup?), Error> in
                let attachmentStateInfo: [Attachment.StateInfo] = (try? Attachment
                    .stateInfo(interactionId: interactionId, state: .uploading)
                    .fetchAll(db))
                    .defaulting(to: [])
                
                // If there is no attachment data then just return early
                guard !attachmentStateInfo.isEmpty else {
                    return Just(([], nil))
                        .setFailureType(to: Error.self)
                        .eraseToAnyPublisher()
                }
                
                // Otherwise fetch the open group (if there is one)
                return Just((
                    (try? Attachment
                        .filter(ids: attachmentStateInfo.map { $0.attachmentId })
                        .fetchAll(db))
                        .defaulting(to: []),
                    try? OpenGroup.fetchOne(db, id: threadId)
                ))
                .setFailureType(to: Error.self)
                .eraseToAnyPublisher()
            }
            .flatMap { attachments, openGroup -> AnyPublisher<[String?], Error> in
                guard !attachments.isEmpty else {
                    return Just<[String?]>([])
                        .setFailureType(to: Error.self)
                        .eraseToAnyPublisher()
                }
                
                return Publishers
                    .MergeMany(
                        attachments
                            .map { attachment -> AnyPublisher<String?, Error> in
                                attachment
                                    .upload(
                                        to: (
                                            openGroup.map { Attachment.Destination.openGroup($0) } ??
                                            .fileServer
                                        ),
                                        queue: DispatchQueue.global(qos: .userInitiated)
                                    )
                            }
                    )
                    .collect()
                    .eraseToAnyPublisher()
            }
            .map { results -> PreparedSendData in
                // Once the attachments are processed then update the PreparedSendData with
                // the fileIds associated to the message
                let fileIds: [String] = results.compactMap { result -> String? in result }
                
                return preparedSendData.with(fileIds: fileIds)
            }
            .eraseToAnyPublisher()
    }
    
    /// This method requires the `db` value to be passed in because if it's called within a `writeAsync` completion block
    /// it will throw a "re-entrant" fatal error when attempting to write again
    public static func syncConfiguration(
        _ db: Database,
        forceSyncNow: Bool = true
    ) throws -> AnyPublisher<Void, Error> {
        // If we don't have a userKeyPair yet then there is no need to sync the configuration
        // as the user doesn't exist yet (this will get triggered on the first launch of a
        // fresh install due to the migrations getting run)
        guard
            Identity.userExists(db),
            let ed25519SecretKey: [UInt8] = Identity.fetchUserEd25519KeyPair(db)?.secretKey
        else {
            return Fail(error: StorageError.generic)
                .eraseToAnyPublisher()
        }
        
        let publicKey: String = getUserHexEncodedPublicKey(db)
        let legacyDestination: Message.Destination = Message.Destination.contact(
            publicKey: publicKey,
            namespace: .default
        )
        let legacyConfigurationMessage = try ConfigurationMessage.getCurrent(db)
        let userConfigMessageChanges: [SharedConfigMessage] = SessionUtil.getChanges(
            ed25519SecretKey: ed25519SecretKey
        )
        let destination: Message.Destination = Message.Destination.contact(
            publicKey: publicKey,
            namespace: .userProfileConfig
        )
        
        guard forceSyncNow else {
            JobRunner.add(
                db,
                job: Job(
                    variant: .messageSend,
                    threadId: publicKey,
                    details: MessageSendJob.Details(
                        destination: legacyDestination,
                        message: legacyConfigurationMessage
                    )
                )
            )
            
            return Just(())
                .setFailureType(to: Error.self)
                .eraseToAnyPublisher()
        }
        
        let sendData: PreparedSendData = try MessageSender.preparedSendData(
            db,
            message: legacyConfigurationMessage,
            to: legacyDestination,
            interactionId: nil
        )
        
        let userConfigSendData: [PreparedSendData] = try userConfigMessageChanges
            .map { message in
                try MessageSender.preparedSendData(
                    db,
                    message: message,
                    to: destination,
                    interactionId: nil
                )
            }
        
        /// We want to avoid blocking the db write thread so we dispatch the API call to a different thread
        return Just(())
            .setFailureType(to: Error.self)
            .receive(on: DispatchQueue.global(qos: .userInitiated))
            .flatMap { _ -> AnyPublisher<Void, Error> in
                Publishers
                    .MergeMany(
                        ([sendData] + userConfigSendData)
                            .map { MessageSender.sendImmediate(preparedSendData: $0) }
                    )
                    .collect()
                    .map { _ in () }
                    .eraseToAnyPublisher()
            }
            .eraseToAnyPublisher()
    }
}
