// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUIKit
import SessionUtilitiesKit
import SessionNetworkingKit

// MARK: - Log.Category

public extension Log.Category {
    static let messageReceiver: Log.Category = .create("MessageReceiver", defaultLevel: .info)
}

// MARK: - MessageReceiver

public enum MessageReceiver {
    private static var lastEncryptionKeyPairRequest: [String: Date] = [:]
    
    public static func parse(
        data: Data,
        origin: Message.Origin,
        using dependencies: Dependencies
    ) throws -> ProcessedMessage {
        /// Config messages are custom-handled internally within `libSession` so just return the data directly
        guard !origin.isConfigNamespace else {
            guard case .swarm(let publicKey, let namespace, let serverHash, let timestampMs, _) = origin else {
                throw MessageReceiverError.invalidConfigMessageHandling
            }
            
            return .config(
                publicKey: publicKey,
                namespace: namespace,
                serverHash: serverHash,
                serverTimestampMs: timestampMs,
                data: data,
                uniqueIdentifier: serverHash
            )
        }
        
        /// The group "revoked retrievable" namespace uses custom encryption so we need to custom handle it
        guard !origin.isRevokedRetrievableNamespace else {
            guard case .swarm(let publicKey, _, let serverHash, _, let serverExpirationTimestamp) = origin else {
                throw MessageReceiverError.invalidMessage
            }
            
            let proto: SNProtoContent = try SNProtoContent.builder().build()
            let message: LibSessionMessage = LibSessionMessage(ciphertext: data)
            message.sender = publicKey  /// The "group" sends these messages
            message.serverHash = serverHash
            
            return .standard(
                threadId: publicKey,
                threadVariant: .group,
                proto: proto,
                messageInfo: try MessageReceiveJob.Details.MessageInfo(
                    message: message,
                    variant: try Message.Variant(from: message) ?? {
                        throw MessageReceiverError.invalidMessage
                    }(),
                    threadVariant: .group,
                    serverExpirationTimestamp: serverExpirationTimestamp,
                    proto: proto
                ),
                uniqueIdentifier: serverHash
            )
        }
        
        /// For all other cases we can just decode the message
        let (proto, sender, sentTimestampMs): (SNProtoContent, String, UInt64) = try dependencies[singleton: .crypto].tryGenerate(
            .decodedMessage(
                encodedMessage: data,
                origin: origin
            )
        )
        
        let threadId: String
        let threadVariant: SessionThread.Variant
        let serverExpirationTimestamp: TimeInterval?
        let uniqueIdentifier: String
        let userSessionId: SessionId = dependencies[cache: .general].sessionId
        let message: Message = try Message.createMessageFrom(proto, sender: sender, using: dependencies)
        message.sender = sender
        message.sentTimestampMs = sentTimestampMs
        message.sigTimestampMs = (proto.hasSigTimestamp ? proto.sigTimestamp : nil)
        message.receivedTimestampMs = dependencies[cache: .snodeAPI].currentOffsetTimestampMs()
        
        /// Perform validation and assign additional message values based on the origin
        switch origin {
            case .community(let openGroupId, _, _, let messageServerId, let whisper, let whisperMods, let whisperTo):
                /// Don't allow control messages in community conversations
                guard message is VisibleMessage else {
                    throw MessageReceiverError.communitiesDoNotSupportControlMessages
                }
                
                threadId = openGroupId
                threadVariant = .community
                serverExpirationTimestamp = nil
                uniqueIdentifier = "\(messageServerId)"
                message.openGroupServerMessageId = UInt64(messageServerId)
                message.openGroupWhisper = whisper
                message.openGroupWhisperMods = whisperMods
                message.openGroupWhisperTo = whisperTo
                
            case .communityInbox(_, let messageServerId, let serverPublicKey, _, _):
                /// Don't process community inbox messages if the sender is blocked
                guard
                    dependencies.mutate(cache: .libSession, { cache in
                        !cache.isContactBlocked(contactId: sender)
                    }) ||
                    message.processWithBlockedSender
                else { throw MessageReceiverError.senderBlocked }
                
                /// Ignore self sends if needed
                guard message.isSelfSendValid || sender != userSessionId.hexString else {
                    throw MessageReceiverError.selfSend
                }
                
                threadId = sender
                threadVariant = .contact
                serverExpirationTimestamp = nil
                uniqueIdentifier = "\(messageServerId)"
                message.openGroupServerMessageId = UInt64(messageServerId)
                
            case .swarm(let publicKey, let namespace, let serverHash, _, let expirationTimestamp):
                /// Don't process 1-to-1 or group messages if the sender is blocked
                guard
                    dependencies.mutate(cache: .libSession, { cache in
                        !cache.isContactBlocked(contactId: sender)
                    }) ||
                    message.processWithBlockedSender
                else { throw MessageReceiverError.senderBlocked }
                
                /// Ignore self sends if needed
                guard message.isSelfSendValid || sender != userSessionId.hexString else {
                    throw MessageReceiverError.selfSend
                }
                
                switch namespace {
                    case .default:
                        threadId = Message.threadId(
                            forMessage: message,
                            destination: .contact(publicKey: sender),
                            using: dependencies
                        )
                        threadVariant = .contact
                        
                    case .groupMessages:
                        threadId = publicKey
                        threadVariant = .group
                        
                    default:
                        Log.warn(.messageReceiver, "Couldn't process message due to invalid namespace.")
                        throw MessageReceiverError.unknownMessage(proto)
                }
                
                serverExpirationTimestamp = expirationTimestamp
                uniqueIdentifier = serverHash
                message.serverHash = serverHash
                message.attachDisappearingMessagesConfiguration(from: proto)
        }
        
        /// Ensure the message is valid
        guard message.isValid(isSending: false) else {
            throw MessageReceiverError.invalidMessage
        }
        
        return .standard(
            threadId: threadId,
            threadVariant: threadVariant,
            proto: proto,
            messageInfo: try MessageReceiveJob.Details.MessageInfo(
                message: message,
                variant: try Message.Variant(from: message) ?? {
                    throw MessageReceiverError.invalidMessage
                }(),
                threadVariant: threadVariant,
                serverExpirationTimestamp: serverExpirationTimestamp,
                proto: proto
            ),
            uniqueIdentifier: uniqueIdentifier
        )
    }
    
    // MARK: - Handling
    
    public static func handle(
        _ db: ObservingDatabase,
        threadId: String,
        threadVariant: SessionThread.Variant,
        message: Message,
        serverExpirationTimestamp: TimeInterval?,
        associatedWithProto proto: SNProtoContent,
        suppressNotifications: Bool,
        using dependencies: Dependencies
    ) throws -> InsertedInteractionInfo? {
        /// Throw if the message is outdated and shouldn't be processed (this is based on pretty flaky logic which checks if the config
        /// has been updated since the message was sent - this should be reworked to be less edge-case prone in the future)
        try throwIfMessageOutdated(
            message: message,
            threadId: threadId,
            threadVariant: threadVariant,
            openGroupUrlInfo: (threadVariant != .community ? nil :
                try? LibSession.OpenGroupUrlInfo.fetchOne(db, id: threadId)
            ),
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
        
        let interactionInfo: InsertedInteractionInfo?
        switch message {
            case let message as ReadReceipt:
                interactionInfo = nil
                try MessageReceiver.handleReadReceipt(
                    db,
                    message: message,
                    serverExpirationTimestamp: serverExpirationTimestamp,
                    using: dependencies
                )
                
            case let message as TypingIndicator:
                interactionInfo = nil
                try MessageReceiver.handleTypingIndicator(
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
                interactionInfo = try MessageReceiver.handleGroupUpdateMessage(
                    db,
                    threadId: threadId,
                    threadVariant: threadVariant,
                    message: message,
                    serverExpirationTimestamp: serverExpirationTimestamp,
                    suppressNotifications: suppressNotifications,
                    using: dependencies
                )
                
            case let message as DataExtractionNotification:
                interactionInfo = try MessageReceiver.handleDataExtractionNotification(
                    db,
                    threadId: threadId,
                    threadVariant: threadVariant,
                    message: message,
                    serverExpirationTimestamp: serverExpirationTimestamp,
                    using: dependencies
                )
                
            case let message as ExpirationTimerUpdate:
                interactionInfo = try MessageReceiver.handleExpirationTimerUpdate(
                    db,
                    threadId: threadId,
                    threadVariant: threadVariant,
                    message: message,
                    serverExpirationTimestamp: serverExpirationTimestamp,
                    proto: proto,
                    using: dependencies
                )
                
            case let message as UnsendRequest:
                interactionInfo = nil
                try MessageReceiver.handleUnsendRequest(
                    db,
                    threadId: threadId,
                    threadVariant: threadVariant,
                    message: message,
                    using: dependencies
                )
                
            case let message as CallMessage:
                interactionInfo = try MessageReceiver.handleCallMessage(
                    db,
                    threadId: threadId,
                    threadVariant: threadVariant,
                    message: message,
                    suppressNotifications: suppressNotifications,
                    using: dependencies
                )
                
            case let message as MessageRequestResponse:
                interactionInfo = try MessageReceiver.handleMessageRequestResponse(
                    db,
                    message: message,
                    using: dependencies
                )
                
            case let message as VisibleMessage:
                interactionInfo = try MessageReceiver.handleVisibleMessage(
                    db,
                    threadId: threadId,
                    threadVariant: threadVariant,
                    message: message,
                    serverExpirationTimestamp: serverExpirationTimestamp,
                    associatedWithProto: proto,
                    suppressNotifications: suppressNotifications,
                    using: dependencies
                )
            
            case let message as LibSessionMessage:
                interactionInfo = nil
                try MessageReceiver.handleLibSessionMessage(
                    db,
                    threadId: threadId,
                    threadVariant: threadVariant,
                    message: message,
                    using: dependencies
                )
            
            default: throw MessageReceiverError.unknownMessage(proto)
        }
        
        // Perform any required post-handling logic
        try MessageReceiver.postHandleMessage(
            db,
            threadId: threadId,
            threadVariant: threadVariant,
            message: message,
            insertedInteractionInfo: interactionInfo,
            using: dependencies
        )
        
        return interactionInfo
    }
    
    public static func postHandleMessage(
        _ db: ObservingDatabase,
        threadId: String,
        threadVariant: SessionThread.Variant,
        message: Message,
        insertedInteractionInfo: InsertedInteractionInfo?,
        using dependencies: Dependencies
    ) throws {
        // When handling any message type which has related UI we want to make sure the thread becomes
        // visible (the only other spot this flag gets set is when sending messages)
        let shouldBecomeVisible: Bool = {
            switch message {
                case is ReadReceipt: return false
                case is TypingIndicator: return false
                case is UnsendRequest: return false
                case is CallMessage: return (threadId != dependencies[cache: .general].sessionId.hexString)
                    
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
            db.afterCommit(dedupeId: "PostInsertDisappearingMessagesJob") {  // stringlint:ignore
                dependencies[singleton: .storage].writeAsync { db in
                    dependencies[singleton: .jobRunner].upsert(
                        db,
                        job: DisappearingMessagesJob.updateNextRunIfNeeded(db, using: dependencies),
                        canStartJob: true
                    )
                }
            }
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
        
        try SessionThread.updateVisibility(
            db,
            threadId: threadId,
            isVisible: true,
            additionalChanges: [SessionThread.Columns.isDraft.set(to: false)],
            using: dependencies
        )
    }
    
    public static func handleOpenGroupReactions(
        _ db: ObservingDatabase,
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
        message: Message,
        threadId: String,
        threadVariant: SessionThread.Variant,
        openGroupUrlInfo: LibSession.OpenGroupUrlInfo?,
        using dependencies: Dependencies
    ) throws {
        // TODO: [Database Relocation] Need the "deleted_contacts" logic to handle the 'throwIfMessageOutdated' case
        // TODO: [Database Relocation] Need a way to detect _when_ the NTS conversation was hidden (so an old message won't re-show it)
        switch (threadVariant, message) {
            case (_, is ReadReceipt): return /// No visible artifact created so better to keep for more reliable read states
            case (_, is UnsendRequest): return /// We should always process the removal of messages just in case
            
            /// These group update messages update the group state so should be processed even if they were old
            case (.group, is GroupUpdateInviteResponseMessage): return
            case (.group, is GroupUpdateDeleteMemberContentMessage): return
            case (.group, is GroupUpdateMemberLeftMessage): return
                
            /// A `LibSessionMessage` may not contain a timestamp and may contain custom instructions regardless of the
            /// state of the group so we should always process it (it should contain it's own versioning which can be used to determine
            /// if it's old)
            case (.group, is LibSessionMessage): return
            
            /// No special logic for these, just make sure that either the conversation is already visible, or we are allowed to
            /// make a config change
            case (.contact, _), (.community, _), (.legacyGroup, _): break
                
            /// If the destination is a group then ensure:
            /// • We have credentials
            /// • The group hasn't been destroyed
            /// • The user wasn't kicked from the group
            /// • The message wasn't sent before all messages/attachments were deleted
            case (.group, _):
                let messageSentTimestamp: TimeInterval = TimeInterval((message.sentTimestampMs ?? 0) / 1000)
                let groupSessionId: SessionId = SessionId(.group, hex: threadId)
                
                /// Ensure the group is able to receive messages
                try dependencies.mutate(cache: .libSession) { cache in
                    guard
                        cache.hasCredentials(groupSessionId: groupSessionId),
                        !cache.groupIsDestroyed(groupSessionId: groupSessionId),
                        !cache.wasKickedFromGroup(groupSessionId: groupSessionId)
                    else { throw MessageReceiverError.outdatedMessage }
                    
                    return
                }
                
                /// Ensure the message shouldn't have been deleted
                try dependencies.mutate(cache: .libSession) { cache in
                    let deleteBefore: TimeInterval = (cache.groupDeleteBefore(groupSessionId: groupSessionId) ?? 0)
                    let deleteAttachmentsBefore: TimeInterval = (cache.groupDeleteAttachmentsBefore(groupSessionId: groupSessionId) ?? 0)
                    
                    guard
                        (
                            deleteBefore == 0 ||
                            messageSentTimestamp > deleteBefore
                        ) && (
                            deleteAttachmentsBefore == 0 ||
                            (message as? VisibleMessage)?.dataMessageHasAttachments == false ||
                            messageSentTimestamp > deleteAttachmentsBefore
                        )
                    else { throw MessageReceiverError.outdatedMessage }
                    
                    return
                }
        }
        
        /// If the conversation is not visible in the config and the message was sent before the last config update (minus a buffer period)
        /// then we can assume that the user has hidden/deleted the conversation and it shouldn't be reshown by this (old) message
        try dependencies.mutate(cache: .libSession) { cache in
            let conversationInConfig: Bool? = cache.conversationInConfig(
                threadId: threadId,
                threadVariant: threadVariant,
                visibleOnly: true,
                openGroupUrlInfo: openGroupUrlInfo
            )
            let canPerformConfigChange: Bool? = cache.canPerformChange(
                threadId: threadId,
                threadVariant: threadVariant,
                changeTimestampMs: message.sentTimestampMs
                    .map { Int64($0) }
                    .defaulting(to: dependencies[cache: .snodeAPI].currentOffsetTimestampMs())
            )
            
            switch (conversationInConfig, canPerformConfigChange) {
                case (false, false): throw MessageReceiverError.outdatedMessage
                default: break
            }
        }
        
        /// If we made it here then the message is not outdated
    }
    
    /// Notify any observers of newly received messages
    public static func prepareNotificationsForInsertedInteractions(
        _ db: ObservingDatabase,
        insertedInteractionInfo: InsertedInteractionInfo?,
        isMessageRequest: Bool,
        using dependencies: Dependencies
    ) {
        guard let info: InsertedInteractionInfo = insertedInteractionInfo else { return }
        
        /// This allows observing for an event where a message request receives an unread message
        if isMessageRequest && !info.wasRead {
            db.addEvent(
                MessageEvent(id: info.interactionId, threadId: info.threadId, change: nil),
                forKey: .messageRequestUnreadMessageReceived
            )
        }
        
        /// Need to re-show the message requests section if we received a new message request
        if isMessageRequest && info.numPreviousInteractionsForMessageRequest == 0 {
            dependencies.set(db, .hasHiddenMessageRequests, false)
        }
    }
}
