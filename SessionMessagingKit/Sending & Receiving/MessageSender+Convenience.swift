// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import SessionNetworkingKit
import SessionUtilitiesKit

extension MessageSender {
    // MARK: - Durable
    
    public static func send(
        _ db: ObservingDatabase,
        interaction: Interaction,
        threadId: String,
        threadVariant: SessionThread.Variant,
        isSyncMessage: Bool = false,
        using dependencies: Dependencies
    ) throws {
        // Only 'VisibleMessage' types can be sent via this method
        guard interaction.variant == .standardOutgoing else { throw MessageSenderError.invalidMessage }
        guard let interactionId: Int64 = interaction.id else { throw StorageError.objectNotSaved }
        
        send(
            db,
            message: VisibleMessage.from(
                db,
                interaction: interaction,
                proProof: dependencies.mutate(cache: .libSession, { $0.getProProof() })
            ),
            threadId: threadId,
            interactionId: interactionId,
            to: try Message.Destination.from(db, threadId: threadId, threadVariant: threadVariant),
            isSyncMessage: isSyncMessage,
            using: dependencies
        )
    }
    
    public static func send(
        _ db: ObservingDatabase,
        message: Message,
        interactionId: Int64?,
        threadId: String,
        threadVariant: SessionThread.Variant,
        after blockingJob: Job? = nil,
        isSyncMessage: Bool = false,
        using dependencies: Dependencies
    ) throws {
        send(
            db,
            message: message,
            threadId: threadId,
            interactionId: interactionId,
            to: try Message.Destination.from(db, threadId: threadId, threadVariant: threadVariant),
            isSyncMessage: isSyncMessage,
            using: dependencies
        )
    }
    
    public static func send(
        _ db: ObservingDatabase,
        message: Message,
        threadId: String?,
        interactionId: Int64?,
        to destination: Message.Destination,
        isSyncMessage: Bool = false,
        using dependencies: Dependencies
    ) {
        // If it's a sync message then we need to make some slight tweaks before sending so use the proper
        // sync message sending process instead of the standard process
        guard !isSyncMessage else {
            scheduleSyncMessageIfNeeded(
                db,
                message: message,
                destination: destination,
                threadId: threadId,
                interactionId: interactionId,
                using: dependencies
            )
            return
        }
        
        dependencies[singleton: .jobRunner].add(
            db,
            job: Job(
                variant: .messageSend,
                threadId: threadId,
                interactionId: interactionId,
                details: MessageSendJob.Details(
                    destination: destination,
                    message: message
                )
            ),
            canStartJob: true
        )
    }
}

// MARK: - Success & Failure Handling

extension MessageSender {
    public static func standardEventHandling(using dependencies: Dependencies) -> ((Event) -> Void) {
        return { event in
            let threadId: String = Message.threadId(
                forMessage: event.message,
                destination: event.destination,
                using: dependencies
            )
            
            dependencies[singleton: .storage].writeAsync { db in
                switch event {
                    case .willSend(let message, let destination, let interactionId):
                        handleMessageWillSend(
                            db,
                            threadId: threadId,
                            message: message,
                            destination: destination,
                            interactionId: interactionId,
                            using: dependencies
                        )
                    
                    case .success(let message, let destination, let interactionId, let serverTimestampMs, let serverExpirationMs):
                        try handleSuccessfulMessageSend(
                            db,
                            threadId: threadId,
                            message: message,
                            to: destination,
                            interactionId: interactionId,
                            serverTimestampMs: serverTimestampMs,
                            serverExpirationTimestampMs: serverExpirationMs,
                            using: dependencies
                        )
                        
                    case .failure(let message, let destination, let interactionId, let error):
                        let threadId: String = Message.threadId(forMessage: message, destination: destination, using: dependencies)
                        
                        handleFailedMessageSend(
                            db,
                            threadId: threadId,
                            message: message,
                            destination: destination,
                            error: error,
                            interactionId: interactionId,
                            using: dependencies
                        )
                }
            }
        }
    }
    
    internal static func handleMessageWillSend(
        _ db: ObservingDatabase,
        threadId: String,
        message: Message,
        destination: Message.Destination,
        interactionId: Int64?,
        using dependencies: Dependencies
    ) {
        // If the message was a reaction then we don't want to do anything to the original
        // interaction (which the 'interactionId' is pointing to
        guard (message as? VisibleMessage)?.reaction == nil else { return }
        
        // Mark messages as "sending"/"syncing" if needed (this is for retries)
        switch destination {
            case .syncMessage:
                _ = try? Interaction
                    .filter(id: interactionId)
                    .filter(Interaction.Columns.state == Interaction.State.failedToSync)
                    .updateAll(db, Interaction.Columns.state.set(to: Interaction.State.syncing))
                db.addMessageEvent(id: interactionId, threadId: threadId, type: .updated(.state(.syncing)))
                
            default:
                _ = try? Interaction
                    .filter(id: interactionId)
                    .filter(Interaction.Columns.state == Interaction.State.failed)
                    .updateAll(db, Interaction.Columns.state.set(to: Interaction.State.sending))
                db.addMessageEvent(id: interactionId, threadId: threadId, type: .updated(.state(.sending)))
        }
    }
    
    private static func handleSuccessfulMessageSend(
        _ db: ObservingDatabase,
        threadId: String,
        message: Message,
        to destination: Message.Destination,
        interactionId: Int64?,
        serverTimestampMs: Int64? = nil,
        serverExpirationTimestampMs: Int64? = nil,
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
            let maybeInteraction: Interaction? = try interaction(db, for: message, interactionId: interactionId)
            
            // Get the visible message if possible
            if var interaction: Interaction = maybeInteraction {
                // Only store the server hash of a sync message if the message is self send valid
                switch (message.isSelfSendValid, destination) {
                    case (false, .syncMessage):
                        try interaction.with(state: .sent).update(db)
                    
                    case (true, .syncMessage), (_, .contact), (_, .closedGroup), (_, .openGroup), (_, .openGroupInbox):
                        // The timestamp to use for scheduling message deletion. This is generated
                        // when the message is successfully sent to ensure the deletion timer starts
                        // from the correct time.
                        var scheduledTimestampForDeletion: Double? {
                            guard interaction.isExpiringMessage else { return nil }
                            let sentTimestampMs: Double = dependencies[cache: .storageServer].currentOffsetTimestampMs()
                            return sentTimestampMs
                        }
                    
                        // Update the interaction so we have the correct `expiresStartedAtMs` value
                        interaction = interaction.with(
                            serverHash: message.serverHash,
                            // Track the open group server message ID and update server timestamp (use server
                            // timestamp for open group messages otherwise the quote messages may not be able
                            // to be found by the timestamp on other devices
                            timestampMs: (message.openGroupServerMessageId == nil ?
                                nil :
                                serverTimestampMs.map { Int64($0) }
                            ),
                            expiresStartedAtMs: scheduledTimestampForDeletion, // Updates the expiresStartedAtMs value when message is marked as sent
                            openGroupServerMessageId: message.openGroupServerMessageId.map { Int64($0) },
                            state: .sent
                        )
                        try interaction.update(db)
                        
                        if interaction.isExpiringMessage {
                            // Start disappearing messages job after a message is successfully sent.
                            // For DAR and DAS outgoing messages, the expiration start time are the
                            // same as message sentTimestamp. So do this once, DAR and DAS messages
                            // should all be covered.
                            dependencies[singleton: .jobRunner].upsert(
                                db,
                                job: DisappearingMessagesJob.updateNextRunIfNeeded(
                                    db,
                                    interaction: interaction,
                                    startedAtMs: Double(interaction.timestampMs),
                                    using: dependencies
                                ),
                                canStartJob: true
                            )
                        
                            if
                                case .syncMessage = destination,
                                let startedAtMs: Double = scheduledTimestampForDeletion,
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
                                    canStartJob: true
                                )
                            }
                        }
                    }
            }
        }
        
        // Notify of the state change
        db.addMessageEvent(id: interactionId, threadId: threadId, type: .updated(.state(.sent)))
        
        // Insert a `MessageDeduplication` record so we don't handle this message when it's received
        // in the next poll
        try MessageDeduplication.insert(
            db,
            threadId: threadId,
            threadVariant: destination.threadVariant,
            uniqueIdentifier: {
                if let serverHash: String = message.serverHash { return serverHash }
                if let openGroupServerMessageId: UInt64 = message.openGroupServerMessageId {
                    return "\(openGroupServerMessageId)"
                }
                
                let variantString: String = Message.Variant(from: message)
                    .map { "\($0)" }
                    .defaulting(to: "Unknown Variant")  // stringlint:ignore
                Log.warn(.messageSender, "Unable to store deduplication unique identifier for outgoing message of type: \(variantString).")
                return nil
            }(),
            message: message,
            serverExpirationTimestamp: serverExpirationTimestampMs.map { (TimeInterval($0) / 1000) },
            ignoreDedupeFiles: false,
            using: dependencies
        )

        // Sync the message if needed
        scheduleSyncMessageIfNeeded(
            db,
            message: message,
            destination: destination,
            threadId: threadId,
            interactionId: interactionId,
            using: dependencies
        )
    }

    @discardableResult internal static func handleFailedMessageSend(
        _ db: ObservingDatabase,
        threadId: String,
        message: Message,
        destination: Message.Destination?,
        error: MessageSenderError,
        interactionId: Int64?,
        using dependencies: Dependencies
    ) -> Error {
        // Log a message for any 'other' errors
        switch error {
            case .other(let cat, let description, let error):
                Log.error([.messageSender, cat].compactMap { $0 }, "\(description) due to error: \(error).")
            default: break
        }
        
        // Only 'VisibleMessage' messages can show a status so don't bother updating
        // the other cases (if the VisibleMessage was a reaction then we also don't
        // want to do anything as the `interactionId` points to the original message
        // which has it's own status)
        switch message {
            case let message as VisibleMessage where message.reaction != nil: return error
            case is VisibleMessage: break
            default: return error
        }
        
        /// Check if we need to mark any "sending" recipients as "failed" and update their errors
        switch destination {
            case .syncMessage:
                _ = try? Interaction
                    .filter(id: interactionId)
                    .filter(
                        Interaction.Columns.state == Interaction.State.syncing ||
                        Interaction.Columns.state == Interaction.State.sent
                    )
                    .updateAll(
                        db,
                        Interaction.Columns.state.set(to: Interaction.State.failedToSync),
                        Interaction.Columns.mostRecentFailureText.set(to: "\(error)")
                    )
                db.addMessageEvent(id: interactionId, threadId: threadId, type: .updated(.state(.failedToSync)))
                
            default:
                _ = try? Interaction
                    .filter(id: interactionId)
                    .filter(Interaction.Columns.state == Interaction.State.sending)
                    .updateAll(
                        db,
                        Interaction.Columns.state.set(to: Interaction.State.failed),
                        Interaction.Columns.mostRecentFailureText.set(to: "\(error)")
                    )
                db.addMessageEvent(id: interactionId, threadId: threadId, type: .updated(.state(.failed)))
        }
        
        return error
    }
    
    private static func interaction(_ db: ObservingDatabase, for message: Message, interactionId: Int64?) throws -> Interaction? {
        if let interactionId: Int64 = interactionId {
            return try Interaction.fetchOne(db, id: interactionId)
        }
        
        if let sentTimestampMs: Double = message.sentTimestampMs.map({ Double($0) }) {
            return try Interaction
                .filter(Interaction.Columns.timestampMs == sentTimestampMs)
                .fetchOne(db)
        }
        
        return nil
    }
    
    private static func scheduleSyncMessageIfNeeded(
        _ db: ObservingDatabase,
        message: Message,
        destination: Message.Destination,
        threadId: String?,
        interactionId: Int64?,
        using dependencies: Dependencies
    ) {
        // Sync the message if it's not a sync message, wasn't already sent to the current user and
        // it's a message type which should be synced
        let userSessionId = dependencies[cache: .general].sessionId
        
        if
            case .contact(let publicKey) = destination,
            publicKey != userSessionId.hexString,
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
                        destination: .syncMessage(originalRecipientPublicKey: publicKey),
                        message: message
                    )
                ),
                canStartJob: true
            )
        }
    }
}

// MARK: - Database Type Conversion

public extension VisibleMessage {
    static func from(_ db: ObservingDatabase, interaction: Interaction, proProof: String? = nil) -> VisibleMessage {
        let linkPreview: LinkPreview? = try? interaction.linkPreview.fetchOne(db)
        let shouldAttachProProof: Bool = ((interaction.body ?? "").utf16.count > LibSession.CharacterLimit)
        
        let visibleMessage: VisibleMessage = VisibleMessage(
            sender: interaction.authorId,
            sentTimestampMs: UInt64(interaction.timestampMs),
            syncTarget: nil,
            text: interaction.body,
            attachmentIds: ((try? interaction.attachments.fetchAll(db)) ?? [])
                .map { $0.id },
            quote: (try? interaction.quote.fetchOne(db))
                .map { VMQuote.from(quote: $0) },
            linkPreview: linkPreview
                .map { linkPreview in
                    guard linkPreview.variant == .standard else { return nil }
                    
                    return VMLinkPreview.from(linkPreview: linkPreview)
                },
            profile: nil,   // Don't attach the profile to avoid sending a legacy version (set in MessageSender)
            openGroupInvitation: linkPreview.map { linkPreview in
                guard linkPreview.variant == .openGroupInvitation else { return nil }
                
                return VMOpenGroupInvitation.from(linkPreview: linkPreview)
            },
            reaction: nil   // Reactions are custom messages sent separately
        )
        .with(
            expiresInSeconds: interaction.expiresInSeconds,
            expiresStartedAtMs: interaction.expiresStartedAtMs
        )
        .with(proProof: (shouldAttachProProof ? proProof : nil))
        
        return visibleMessage
    }
}
