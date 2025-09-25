// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionNetworkingKit
import SessionUtilitiesKit

extension MessageReceiver {
    public typealias InsertedInteractionInfo = (
        threadId: String,
        threadVariant: SessionThread.Variant,
        interactionId: Int64,
        interactionVariant: Interaction.Variant?,
        wasRead: Bool,
        numPreviousInteractionsForMessageRequest: Int
    )
    
    internal static func handleVisibleMessage(
        _ db: ObservingDatabase,
        threadId: String,
        threadVariant: SessionThread.Variant,
        message: VisibleMessage,
        serverExpirationTimestamp: TimeInterval?,
        associatedWithProto proto: SNProtoContent,
        suppressNotifications: Bool,
        using dependencies: Dependencies
    ) throws -> InsertedInteractionInfo {
        guard let sender: String = message.sender, let dataMessage = proto.dataMessage else {
            throw MessageReceiverError.invalidMessage
        }
        
        // Note: `message.sentTimestamp` is in ms (convert to TimeInterval before converting to
        // seconds to maintain the accuracy)
        let messageSentTimestampMs: UInt64 = message.sentTimestampMs ?? 0
        let messageSentTimestamp: TimeInterval = TimeInterval(Double(messageSentTimestampMs) / 1000)
        let isMainAppActive: Bool = dependencies[defaults: .appGroup, key: .isMainAppActive]
        
        // Update profile if needed (want to do this regardless of whether the message exists or
        // not to ensure the profile info gets sync between a users devices at every chance)
        if let profile = message.profile {
            try Profile.updateIfNeeded(
                db,
                publicKey: sender,
                displayNameUpdate: .contactUpdate(profile.displayName),
                displayPictureUpdate: .from(profile, fallback: .contactRemove, using: dependencies),
                blocksCommunityMessageRequests: profile.blocksCommunityMessageRequests,
                profileUpdateTimestamp: profile.updateTimestampSeconds,
                using: dependencies
            )
        }
        
        switch threadVariant {
            case .contact: break // Always continue
            
            case .community:
                // Only process visible messages for communities if they have an existing thread
                guard (try? SessionThread.exists(db, id: threadId)) == true else {
                    throw MessageReceiverError.noThread
                }
                        
            case .legacyGroup, .group:
                // Only process visible messages for groups if they have a ClosedGroup record
                guard (try? ClosedGroup.exists(db, id: threadId)) == true else {
                    throw MessageReceiverError.noThread
                }
        }
        
        // Store the message variant so we can run variant-specific behaviours
        let userSessionId: SessionId = dependencies[cache: .general].sessionId
        let thread: SessionThread = try SessionThread.upsert(
            db,
            id: threadId,
            variant: threadVariant,
            values: SessionThread.TargetValues(
                creationDateTimestamp: .useExistingOrSetTo(messageSentTimestamp),
                shouldBeVisible: .useExisting
            ),
            using: dependencies
        )
        let openGroupUrlInfo: LibSession.OpenGroupUrlInfo? = {
            guard threadVariant == .community else { return nil }
            
            return try? LibSession.OpenGroupUrlInfo.fetchOne(db, id: threadId)
        }()
        let variant: Interaction.Variant = try {
            guard
                let senderSessionId: SessionId = try? SessionId(from: sender),
                let openGroupUrlInfo: LibSession.OpenGroupUrlInfo = openGroupUrlInfo
            else {
                return (sender == userSessionId.hexString ?
                    .standardOutgoing :
                    .standardIncoming
                )
            }

            // Need to check if the blinded id matches for open groups
            switch senderSessionId.prefix {
                case .blinded15, .blinded25:
                    guard
                        dependencies[singleton: .crypto].verify(
                            .sessionId(
                                userSessionId.hexString,
                                matchesBlindedId: sender,
                                serverPublicKey: openGroupUrlInfo.publicKey
                            )
                        )
                    else { return .standardIncoming }
                    
                    return .standardOutgoing
                    
                case .standard, .unblinded:
                    return (sender == userSessionId.hexString ?
                        .standardOutgoing :
                        .standardIncoming
                    )
                    
                case .group, .versionBlinded07:
                    Log.info(.messageReceiver, "Ignoring message with invalid sender.")
                    throw MessageReceiverError.invalidSender
            }
        }()
        let generateCurrentUserSessionIds: () -> Set<String> = {
            guard threadVariant == .community else { return [userSessionId.hexString] }
            
            let openGroupCapabilityInfo = try? LibSession.OpenGroupCapabilityInfo
                .fetchOne(db, id: threadId)
            
            return Set([
                userSessionId,
                SessionThread.getCurrentUserBlindedSessionId(
                    threadId: threadId,
                    threadVariant: threadVariant,
                    blindingPrefix: .blinded15,
                    openGroupCapabilityInfo: openGroupCapabilityInfo,
                    using: dependencies
                ),
                SessionThread.getCurrentUserBlindedSessionId(
                    threadId: threadId,
                    threadVariant: threadVariant,
                    blindingPrefix: .blinded25,
                    openGroupCapabilityInfo: openGroupCapabilityInfo,
                    using: dependencies
                )
            ].compactMap { $0 }.map { $0.hexString })
        }
        
        // Handle emoji reacts first (otherwise it's essentially an invalid message)
        if let interactionId: Int64 = try handleEmojiReactIfNeeded(
            db,
            thread: thread,
            message: message,
            associatedWithProto: proto,
            sender: sender,
            messageSentTimestamp: messageSentTimestamp,
            openGroupUrlInfo: openGroupUrlInfo,
            currentUserSessionIds: generateCurrentUserSessionIds(),
            suppressNotifications: suppressNotifications,
            using: dependencies
        ) {
            return (threadId, threadVariant, interactionId, nil, true, 0)
        }
        // Try to insert the interaction
        //
        // Note: There are now a number of unique constraints on the database which
        // prevent the ability to insert duplicate interactions at a database level
        // so we don't need to check for the existance of a message beforehand anymore
        let interaction: Interaction

        // Auto-mark sent messages or messages older than the 'lastReadTimestampMs' as read
        let wasRead: Bool = (
            variant == .standardOutgoing ||
            dependencies.mutate(cache: .libSession) { cache in
                cache.timestampAlreadyRead(
                    threadId: thread.id,
                    threadVariant: thread.variant,
                    timestampMs: Int64(messageSentTimestamp * 1000),
                    openGroupUrlInfo: openGroupUrlInfo
                )
            }
        )
        let messageExpirationInfo: Message.MessageExpirationInfo = Message.getMessageExpirationInfo(
            threadVariant: thread.variant,
            wasRead: wasRead,
            serverExpirationTimestamp: serverExpirationTimestamp,
            expiresInSeconds: message.expiresInSeconds,
            expiresStartedAtMs: message.expiresStartedAtMs,
            using: dependencies
        )
        do {
            let isProMessage: Bool = dependencies.mutate(cache: .libSession, { $0.validateProProof(for: message) })
            let processedMessageBody: String? = Self.truncateMessageTextIfNeeded(
                message.text,
                isProMessage: isProMessage,
                dependencies: dependencies
            )
            
            interaction = try Interaction(
                serverHash: message.serverHash, // Keep track of server hash
                threadId: thread.id,
                threadVariant: thread.variant,
                authorId: sender,
                variant: variant,
                body: processedMessageBody,
                timestampMs: Int64(messageSentTimestamp * 1000),
                wasRead: wasRead,
                hasMention: Interaction.isUserMentioned(
                    db,
                    threadId: thread.id,
                    body: processedMessageBody,
                    quoteAuthorId: dataMessage.quote?.author,
                    using: dependencies
                ),
                expiresInSeconds: messageExpirationInfo.expiresInSeconds,
                expiresStartedAtMs: messageExpirationInfo.expiresStartedAtMs,
                // OpenGroupInvitations are stored as LinkPreview's in the database
                linkPreviewUrl: (message.linkPreview?.url ?? message.openGroupInvitation?.url),
                // Keep track of the open group server message ID ↔ message ID relationship
                openGroupServerMessageId: message.openGroupServerMessageId.map { Int64($0) },
                openGroupWhisper: message.openGroupWhisper,
                openGroupWhisperMods: message.openGroupWhisperMods,
                openGroupWhisperTo: message.openGroupWhisperTo,
                // If we received an outgoing message then we can assume the interaction has already
                // been sent, otherwise we should just use whatever the default state is
                state: (variant == .standardOutgoing ? .sent : nil),
                isProMessage: isProMessage,
                using: dependencies
            ).inserted(db)
        }
        catch {
            switch error {
                case DatabaseError.SQLITE_CONSTRAINT_UNIQUE:
                    guard
                        variant == .standardOutgoing,
                        let existingInteractionId: Int64 = try? thread.interactions
                            .select(.id)
                            .filter(Interaction.Columns.timestampMs == (messageSentTimestamp * 1000))
                            .filter(Interaction.Columns.variant == variant)
                            .filter(Interaction.Columns.authorId == sender)
                            .asRequest(of: Int64.self)
                            .fetchOne(db)
                    else { break }
                    
                    // If we receive an outgoing message that already exists in the database
                    // then we still need to update the recipient and read states for the
                    // message (even if we don't need to do anything else)
                    try updateRecipientAndReadStatesForOutgoingInteraction(
                        db,
                        thread: thread,
                        interactionId: existingInteractionId,
                        messageSentTimestamp: messageSentTimestamp,
                        variant: variant,
                        syncTarget: message.syncTarget,
                        using: dependencies
                    )
                    
                    Message.getExpirationForOutgoingDisappearingMessages(
                        db,
                        threadId: threadId,
                        threadVariant: threadVariant,
                        variant: variant,
                        serverHash: message.serverHash,
                        expireInSeconds: message.expiresInSeconds,
                        using: dependencies
                    )
                    
                default: break
            }
            
            throw error
        }
        
        guard let interactionId: Int64 = interaction.id else { throw StorageError.failedToSave }
        
        // Update and recipient and read states as needed
        try updateRecipientAndReadStatesForOutgoingInteraction(
            db,
            thread: thread,
            interactionId: interactionId,
            messageSentTimestamp: messageSentTimestamp,
            variant: variant,
            syncTarget: message.syncTarget,
            using: dependencies
        )
        
        if messageExpirationInfo.shouldUpdateExpiry {
            Message.updateExpiryForDisappearAfterReadMessages(
                db,
                threadId: threadId,
                threadVariant: threadVariant,
                serverHash: message.serverHash,
                expiresInSeconds: message.expiresInSeconds,
                expiresStartedAtMs: message.expiresStartedAtMs,
                using: dependencies
            )
        }
        
        Message.getExpirationForOutgoingDisappearingMessages(
            db,
            threadId: threadId,
            threadVariant: threadVariant,
            variant: variant,
            serverHash: message.serverHash,
            expireInSeconds: message.expiresInSeconds,
            using: dependencies
        )
        
        // Parse & persist attachments
        let attachments: [Attachment] = try dataMessage.attachments
            .compactMap { proto -> Attachment? in
                let attachment: Attachment = Attachment(proto: proto)
                
                // Attachments on received messages must have a 'downloadUrl' otherwise
                // they are invalid and we can ignore them
                return (attachment.downloadUrl != nil ? attachment : nil)
            }
            .enumerated()
            .map { index, attachment in
                let savedAttachment: Attachment = try attachment.upserted(db)
                
                // Link the attachment to the interaction and add to the id lookup
                try InteractionAttachment(
                    albumIndex: index,
                    interactionId: interactionId,
                    attachmentId: savedAttachment.id
                ).insert(db)
                
                return savedAttachment
            }
        
        message.attachmentIds = attachments.map { $0.id }
        
        // Persist quote if needed
        try? Quote(
            proto: dataMessage,
            interactionId: interactionId,
            thread: thread
        )?.insert(db)
        
        // Parse link preview if needed
        let linkPreview: LinkPreview? = try? LinkPreview(
            db,
            proto: dataMessage,
            sentTimestampMs: (messageSentTimestamp * 1000)
        )?.upserted(db)
        
        // Open group invitations are stored as LinkPreview values so create one if needed
        if
            let openGroupInvitationUrl: String = message.openGroupInvitation?.url,
            let openGroupInvitationName: String = message.openGroupInvitation?.name
        {
            try LinkPreview(
                url: openGroupInvitationUrl,
                timestamp: LinkPreview.timestampFor(sentTimestampMs: (messageSentTimestamp * 1000)),
                variant: .openGroupInvitation,
                title: openGroupInvitationName,
                using: dependencies
            ).upsert(db)
        }
        
        // Start attachment downloads if needed (ie. trusted contact or group thread)
        // FIXME: Replace this to check the `autoDownloadAttachments` flag we are adding to threads
        let isContactTrusted: Bool = ((try? Contact.fetchOne(db, id: sender))?.isTrusted ?? false)

        if isContactTrusted || thread.variant != .contact {
            attachments
                .map { $0.id }
                .appending(linkPreview?.attachmentId)
                .forEach { attachmentId in
                    dependencies[singleton: .jobRunner].add(
                        db,
                        job: Job(
                            variant: .attachmentDownload,
                            threadId: thread.id,
                            interactionId: interactionId,
                            details: AttachmentDownloadJob.Details(
                                attachmentId: attachmentId
                            )
                        ),
                        canStartJob: isMainAppActive
                    )
                }
        }
        
        // Cancel any typing indicators if needed
        if isMainAppActive {
            Task {
                await dependencies[singleton: .typingIndicators].didStopTyping(
                    threadId: thread.id,
                    direction: .incoming
                )
            }
        }
        
        // Update the contact's approval status of the current user if needed (if we are getting messages from
        // them outside of a group then we can assume they have approved the current user)
        //
        // Note: This is to resolve a rare edge-case where a conversation was started with a user on an old
        // version of the app and their message request approval state was set via a migration rather than
        // by using the approval process
        switch thread.variant {
            case .contact:
                try MessageReceiver.updateContactApprovalStatusIfNeeded(
                    db,
                    senderSessionId: sender,
                    threadId: thread.id,
                    using: dependencies
                )
                
            case .group:
                try MessageReceiver.updateMemberApprovalStatusIfNeeded(
                    db,
                    senderSessionId: sender,
                    groupSessionIdHexString: thread.id,
                    profile: nil,   // Don't update the profile in this case
                    using: dependencies
                )
                
            default: break
        }
        
        // Notify the user if needed
        guard
            !suppressNotifications &&
            variant == .standardIncoming &&
            !interaction.wasRead
        else { return (threadId, threadVariant, interactionId, variant, interaction.wasRead, 0) }
        
        let isMessageRequest: Bool = dependencies.mutate(cache: .libSession) { cache in
            cache.isMessageRequest(
                threadId: threadId,
                threadVariant: threadVariant
            )
        }
        let numPreviousInteractionsForMessageRequest: Int = {
            guard isMessageRequest else { return 0 }
            
            switch interaction.serverHash {
                case .some(let serverHash):
                    return (try? Interaction
                        .filter(Interaction.Columns.threadId == threadId)
                        .filter(Interaction.Columns.serverHash != serverHash)
                        .fetchCount(db))
                        .defaulting(to: 0)

                case .none:
                    return (try? Interaction
                        .filter(Interaction.Columns.threadId == threadId)
                        .filter(Interaction.Columns.timestampMs != interaction.timestampMs)
                        .fetchCount(db))
                        .defaulting(to: 0)
            }
        }()
        
        try? dependencies[singleton: .notificationsManager].notifyUser(
            cat: .messageReceiver,
            message: message,
            threadId: threadId,
            threadVariant: threadVariant,
            interactionIdentifier: (interaction.serverHash ?? "\(interactionId)"),
            interactionVariant: interaction.variant,
            attachmentDescriptionInfo: attachments.map { $0.descriptionInfo },
            openGroupUrlInfo: openGroupUrlInfo,
            applicationState: (isMainAppActive ? .active : .background),
            extensionBaseUnreadCount: nil,
            currentUserSessionIds: generateCurrentUserSessionIds(),
            displayNameRetriever: { sessionId, _ in
                Profile.displayNameNoFallback(
                    db,
                    id: sessionId,
                    threadVariant: threadVariant
                )
            },
            groupNameRetriever: { threadId, threadVariant in
                switch threadVariant {
                    case .group:
                        let groupId: SessionId = SessionId(.group, hex: threadId)
                        return dependencies.mutate(cache: .libSession) { cache in
                            cache.groupName(groupSessionId: groupId)
                        }
                        
                    case .community:
                        return try? OpenGroup
                            .select(.name)
                            .filter(id: threadId)
                            .asRequest(of: String.self)
                            .fetchOne(db)
                        
                    default: return nil
                }
            },
            shouldShowForMessageRequest: {
                // We only want to show a notification for the first interaction in the thread
                return (numPreviousInteractionsForMessageRequest == 0)
            }
        )
        
        return (
            threadId,
            threadVariant,
            interactionId,
            variant,
            interaction.wasRead,
            numPreviousInteractionsForMessageRequest
        )
    }
    
    private static func handleEmojiReactIfNeeded(
        _ db: ObservingDatabase,
        thread: SessionThread,
        message: VisibleMessage,
        associatedWithProto proto: SNProtoContent,
        sender: String,
        messageSentTimestamp: TimeInterval,
        openGroupUrlInfo: LibSession.OpenGroupUrlInfo?,
        currentUserSessionIds: Set<String>,
        suppressNotifications: Bool,
        using dependencies: Dependencies
    ) throws -> Int64? {
        guard
            let vmReaction: VisibleMessage.VMReaction = message.reaction,
            proto.dataMessage?.reaction != nil
        else { return nil }
        
        // Since we have database access here make sure the original message for this reaction exists
        // before handling it or showing a notification
        let maybeInteractionId: Int64? = try? Interaction
            .select(.id)
            .filter(Interaction.Columns.threadId == thread.id)
            .filter(Interaction.Columns.timestampMs == vmReaction.timestamp)
            .filter(Interaction.Columns.authorId == vmReaction.publicKey)
            .filter(Interaction.Columns.variant != Interaction.Variant.standardIncomingDeleted)
            .filter(Interaction.Columns.state != Interaction.State.deleted)
            .asRequest(of: Int64.self)
            .fetchOne(db)
        
        guard let interactionId: Int64 = maybeInteractionId else {
            throw StorageError.objectNotFound
        }
        
        let sortId = Reaction.getSortId(
            db,
            interactionId: interactionId,
            emoji: vmReaction.emoji
        )
        
        switch vmReaction.kind {
            case .react:
                // Determine whether the app is active based on the prefs rather than the UIApplication state to avoid
                // requiring main-thread execution
                let isMainAppActive: Bool = dependencies[defaults: .appGroup, key: .isMainAppActive]
                let timestampMs: Int64 = Int64(messageSentTimestamp * 1000)
                let userSessionId: SessionId = dependencies[cache: .general].sessionId
                _ = try Reaction(
                    interactionId: interactionId,
                    serverHash: message.serverHash,
                    timestampMs: timestampMs,
                    authorId: sender,
                    emoji: vmReaction.emoji,
                    count: 1,
                    sortId: sortId
                ).inserted(db)
                let timestampAlreadyRead: Bool = dependencies.mutate(cache: .libSession) { cache in
                    cache.timestampAlreadyRead(
                        threadId: thread.id,
                        threadVariant: thread.variant,
                        timestampMs: timestampMs,
                        openGroupUrlInfo: openGroupUrlInfo
                    )
                }
                
                // Don't notify if the reaction was added before the lastest read timestamp for
                // the conversation or the reaction is for the sender's own message
                if
                    !suppressNotifications &&
                    sender != userSessionId.hexString &&
                    !timestampAlreadyRead &&
                    vmReaction.publicKey != sender
                {
                    try? dependencies[singleton: .notificationsManager].notifyUser(
                        cat: .messageReceiver,
                        message: message,
                        threadId: thread.id,
                        threadVariant: thread.variant,
                        interactionIdentifier: (message.serverHash ?? "\(interactionId)"),
                        interactionVariant: .standardIncoming,
                        attachmentDescriptionInfo: nil,
                        openGroupUrlInfo: openGroupUrlInfo,
                        applicationState: (isMainAppActive ? .active : .background),
                        extensionBaseUnreadCount: nil,
                        currentUserSessionIds: currentUserSessionIds,
                        displayNameRetriever: { sessionId, _ in
                            Profile.displayNameNoFallback(
                                db,
                                id: sessionId,
                                threadVariant: thread.variant
                            )
                        },
                        groupNameRetriever: { threadId, threadVariant in
                            switch threadVariant {
                                case .group:
                                    let groupId: SessionId = SessionId(.group, hex: threadId)
                                    return dependencies.mutate(cache: .libSession) { cache in
                                        cache.groupName(groupSessionId: groupId)
                                    }
                                    
                                case .community:
                                    return try? OpenGroup
                                        .select(.name)
                                        .filter(id: threadId)
                                        .asRequest(of: String.self)
                                        .fetchOne(db)
                                    
                                default: return nil
                            }
                        },
                        shouldShowForMessageRequest: { false }
                    )
                }
                
            case .remove:
                try Reaction
                    .filter(Reaction.Columns.interactionId == interactionId)
                    .filter(Reaction.Columns.authorId == sender)
                    .filter(Reaction.Columns.emoji == vmReaction.emoji)
                    .deleteAll(db)
        }
        
        return interactionId
    }
    
    private static func updateRecipientAndReadStatesForOutgoingInteraction(
        _ db: ObservingDatabase,
        thread: SessionThread,
        interactionId: Int64,
        messageSentTimestamp: TimeInterval,
        variant: Interaction.Variant,
        syncTarget: String?,
        using dependencies: Dependencies
    ) throws {
        guard variant == .standardOutgoing else { return }
        
        // Immediately update any existing outgoing message 'State' records to be 'sent' (can
        // also remove the failure text as it's redundant if the message is in the sent state)
        if (try? Interaction.select(.state).filter(id: interactionId).asRequest(of: Interaction.State.self).fetchOne(db)) != .sent {
            _ = try? Interaction
                .filter(id: interactionId)
                .updateAll(
                    db,
                    Interaction.Columns.state.set(to: Interaction.State.sent),
                    Interaction.Columns.mostRecentFailureText.set(to: nil)
                )
            db.addMessageEvent(id: interactionId, threadId: thread.id, type: .updated(.state(.sent)))
        }
        
        // For outgoing messages mark all older interactions as read (the user should have seen
        // them if they send a message - also avoids a situation where the user has "phantom"
        // unread messages that they need to scroll back to before they become marked as read)
        try Interaction.markAsRead(
            db,
            interactionId: interactionId,
            threadId: thread.id,
            threadVariant: thread.variant,
            includingOlder: true,
            trySendReadReceipt: false,
            using: dependencies
        )
        
        // Process any PendingReadReceipt values
        let maybePendingReadReceipt: PendingReadReceipt? = try PendingReadReceipt
            .filter(PendingReadReceipt.Columns.threadId == thread.id)
            .filter(PendingReadReceipt.Columns.interactionTimestampMs == Int64(messageSentTimestamp * 1000))
            .fetchOne(db)
        
        if let pendingReadReceipt: PendingReadReceipt = maybePendingReadReceipt {
            try Interaction.markAsRecipientRead(
                db,
                threadId: thread.id,
                timestampMsValues: [pendingReadReceipt.interactionTimestampMs],
                readTimestampMs: pendingReadReceipt.readTimestampMs,
                using: dependencies
            )
            
            _ = try pendingReadReceipt.delete(db)
        }
    }
    
    private static func truncateMessageTextIfNeeded(
        _ text: String?,
        isProMessage: Bool,
        dependencies: Dependencies
    ) -> String? {
        guard let text = text else { return nil }
        
        let utf16View = text.utf16
        // TODO: Remove after Session Pro is enabled
        let isSessionProEnabled: Bool = (dependencies.hasSet(feature: .sessionProEnabled) && dependencies[feature: .sessionProEnabled])
        let offset: Int = (isSessionProEnabled && !isProMessage) ?
            LibSession.CharacterLimit :
            LibSession.ProCharacterLimit
        
        guard utf16View.count > offset else { return text }
        
        // Get the index at the maxUnits position in UTF16
        let endUTF16Index = utf16View.index(utf16View.startIndex, offsetBy: offset)
        
        // Try converting that UTF16 index back to a String.Index
        if let endIndex = String.Index(endUTF16Index, within: text) {
            return String(text[..<endIndex])
        } else {
            // Fallback: safely step back until there is a valid boundary
            var adjustedIndex = endUTF16Index
            while adjustedIndex > utf16View.startIndex {
                adjustedIndex = utf16View.index(before: adjustedIndex)
                if let validIndex = String.Index(adjustedIndex, within: text) {
                    return String(text[..<validIndex])
                }
            }
            return text // If all else fails, return original string
        }
    }
}
