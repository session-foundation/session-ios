// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import UniformTypeIdentifiers
import GRDB
import DifferenceKit
import SessionUIKit
import SessionUtilitiesKit

public struct MessageViewModel: Sendable, Equatable, Hashable, Identifiable, Differentiable {
    public enum Gesture {
        case tap
        case doubleTap
        case longPress
    }
    
    public enum CellType: Sendable, Equatable, Hashable {
        case textOnlyMessage
        case mediaMessage
        case audio
        case voiceMessage
        case genericAttachment
        case infoMessage
        case call
        case typingIndicator
        case dateHeader
        case unreadMarker
        
        public var supportedGestures: Set<Gesture> {
            switch self {
                case .typingIndicator, .dateHeader, .unreadMarker: return []
                case .voiceMessage: return [.tap, .doubleTap, .longPress]
                case .textOnlyMessage, .mediaMessage, .audio, .genericAttachment,
                    .infoMessage, .call:
                    return [.tap, .longPress]
            }
        }
    }
    
    public var differenceIdentifier: Int64 { id }
    
    /// This value will be used to populate the Context Menu and date header (if present)
    public var dateForUI: Date { Date(timeIntervalSince1970: TimeInterval(Double(self.timestampMs) / 1000)) }
    
    /// This value will be used to populate the Message Info (if present)
    public var receivedDateForUI: Date {
        Date(timeIntervalSince1970: TimeInterval(Double(self.receivedAtTimestampMs) / 1000))
    }
    
    public var bodyTextColor: ThemeValue { MessageViewModel.bodyTextColor(isOutgoing: variant.isOutgoing) }
    
    /// This value defines what type of cell should appear and is generated based on the interaction variant
    /// and associated attachment data
    public let cellType: CellType
    
    /// This is a temporary id used before an outgoing message is persisted into the database
    public let optimisticMessageId: Int64?
    
    // Thread Data
    
    public let threadId: String
    public let threadVariant: SessionThread.Variant
    public let threadIsTrusted: Bool
    
    // Interaction Data
    
    public let id: Int64
    public let variant: Interaction.Variant
    public let serverHash: String?
    public let openGroupServerMessageId: Int64?
    public let authorId: String
    
    /// The value will be populated if the sender has a blinded id and we have resolved it to an unblinded id
    public let authorUnblindedId: String?
    public let bubbleBody: String?
    public let rawBody: String?
    public let bodyForCopying: String?
    public let timestampMs: Int64
    public let receivedAtTimestampMs: Int64
    public let expiresStartedAtMs: Double?
    public let expiresInSeconds: TimeInterval?
    public let attachments: [Attachment]
    public let reactionInfo: [ReactionInfo]
    public let profile: Profile
    public let quoteViewModel: QuoteViewModel?
    public let linkPreview: LinkPreview?
    public let linkPreviewAttachment: Attachment?
    public let proMessageFeatures: SessionPro.MessageFeatures
    public let proProfileFeatures: SessionPro.ProfileFeatures
    
    public let state: Interaction.State
    public let hasBeenReadByRecipient: Bool
    public let mostRecentFailureText: String?
    public let isSenderModeratorOrAdmin: Bool
    public let canFollowDisappearingMessagesSetting: Bool
    
    // Display Properties
    
    /// A flag indicating whether the author name should be displayed
    public let shouldShowAuthorName: Bool

    /// A flag indicating whether the profile view can be displayed
    public let canHaveProfile: Bool
    
    /// A flag indicating whether the display picture view should be displayed
    public let shouldShowDisplayPicture: Bool

    /// A flag which controls whether the date header should be displayed
    public let shouldShowDateHeader: Bool
    
    /// This value specifies whether the body contains only emoji characters
    public let containsOnlyEmoji: Bool
    
    /// This value specifies the number of emoji characters the body contains
    public let glyphCount: Int
    
    /// This value indicates the variant of the previous ViewModel item, if it's null then there is no previous item
    public let previousVariant: Interaction.Variant?
    
    /// This value indicates the position of this message within a cluser of messages
    public let positionInCluster: Position
    
    /// This value indicates whether this is the only message in a cluser of messages
    public let isOnlyMessageInCluster: Bool
    
    /// This value indicates whether this is the last message in the thread
    public let isLast: Bool
    
    /// This value indicates whether this is the last outgoing message in the thread
    public let isLastOutgoing: Bool
    
    /// This contains all sessionId values for the current user (standard and any blinded variants)
    public let currentUserSessionIds: Set<String>
    
    /// This is the mention image for the current user
    public let currentUserMentionImage: UIImage?
}

public extension MessageViewModel {
    private static let genericId: Int64 = -1
    private static let typingIndicatorId: Int64 = -2
    
    static var typingIndicator: MessageViewModel = MessageViewModel(
        cellType: .typingIndicator,
        timestampMs: 0
    )
    
    init(
        cellType: CellType,
        timestampMs: Int64,
        variant: Interaction.Variant = .standardOutgoing,
        body: String? = nil,
        quoteViewModel: QuoteViewModel? = nil,
        isLast: Bool = true
    ) {
        self.id = {
            switch cellType {
                case .typingIndicator: return MessageViewModel.typingIndicatorId
                case .dateHeader: return -timestampMs
                default: return MessageViewModel.genericId
            }
        }()
        self.cellType = cellType
        self.timestampMs = timestampMs
        self.variant = variant
        self.bubbleBody = body
        self.rawBody = body
        self.bodyForCopying = body
        self.quoteViewModel = quoteViewModel
        
        /// These values shouldn't be used for the custom types
        self.optimisticMessageId = nil
        self.threadId = "INVALID_THREAD_ID"
        self.threadVariant = .contact
        self.threadIsTrusted = false
        self.serverHash = ""
        self.openGroupServerMessageId = nil
        self.authorId = ""
        self.authorUnblindedId = nil
        self.receivedAtTimestampMs = 0
        self.expiresStartedAtMs = nil
        self.expiresInSeconds = nil
        self.attachments = []
        self.reactionInfo = []
        self.profile = Profile.with(id: "", name: "")
        self.linkPreview = nil
        self.linkPreviewAttachment = nil
        self.proMessageFeatures = .none
        self.proProfileFeatures = .none
        
        self.state = .localOnly
        self.hasBeenReadByRecipient = false
        self.mostRecentFailureText = nil
        self.isSenderModeratorOrAdmin = false
        self.canFollowDisappearingMessagesSetting = false
        
        self.shouldShowAuthorName = false
        self.canHaveProfile = false
        self.shouldShowDisplayPicture = false
        self.shouldShowDateHeader = false
        self.containsOnlyEmoji = false
        self.glyphCount = 0
        self.previousVariant = nil
        
        self.positionInCluster = .individual
        self.isOnlyMessageInCluster = true
        self.isLast = false
        self.isLastOutgoing = false
        self.currentUserSessionIds = []
        self.currentUserMentionImage = nil
    }
    
    init?(
        optimisticMessageId: Int64? = nil,
        interaction: Interaction,
        reactionInfo: [MessageViewModel.ReactionInfo]?,
        maybeUnresolvedQuotedInfo: MaybeUnresolvedQuotedInfo?,
        userSessionId: SessionId,
        threadInfo: ConversationInfoViewModel,
        dataCache: ConversationDataCache,
        previousInteraction: Interaction?,
        nextInteraction: Interaction?,
        isLast: Bool,
        isLastOutgoing: Bool,
        currentUserMentionImage: UIImage?,
        using dependencies: Dependencies
    ) {
        let targetId: Int64
        
        switch (optimisticMessageId, interaction.id) {
            case (.some(let id), _): targetId = id
            case (_, .some(let id)): targetId = id
            case (.none, .none): return nil
        }
        
        let currentUserSessionIds: Set<String> = dataCache.currentUserSessionIds(for: threadInfo.id)
        let targetProfile: Profile = {
            /// If the sender is the current user then use the proper profile from the cache (instead of a random blinded one)
            guard !currentUserSessionIds.contains(interaction.authorId) else {
                return (dataCache.profile(for: userSessionId.hexString) ?? Profile.defaultFor(userSessionId.hexString))
            }
            
            if let unblindedProfile: Profile = dataCache.unblindedId(for: interaction.authorId).map({ dataCache.profile(for: $0) }) {
                return unblindedProfile
            }
            
            return (dataCache.profile(for: interaction.authorId) ?? Profile.defaultFor(interaction.authorId))
        }()
        let contentBuilder: Interaction.ContentBuilder = Interaction.ContentBuilder(
            interaction: interaction,
            threadId: threadInfo.id,
            threadVariant: threadInfo.variant,
            dataCache: dataCache
        )
        let proMessageFeatures: SessionPro.MessageFeatures = {
            guard dependencies[feature: .sessionProEnabled] else { return .none }
            
            if dependencies[feature: .forceMessageFeatureLongMessage] {
                return interaction.proMessageFeatures.union(.largerCharacterLimit)
            }
            
            return interaction.proMessageFeatures
        }()
        let proProfileFeatures: SessionPro.ProfileFeatures = {
            guard dependencies[feature: .sessionProEnabled] else { return .none }
            
            var result: SessionPro.ProfileFeatures = interaction.proProfileFeatures
            
            if dependencies[feature: .forceMessageFeatureProBadge] {
                result.insert(.proBadge)
            }
            
            if dependencies[feature: .forceMessageFeatureAnimatedAvatar] {
                result.insert(.animatedAvatar)
            }
            
            return result
        }()
        
        self.cellType = MessageViewModel.cellType(
            interaction: interaction,
            attachments: contentBuilder.attachments
        )
        self.optimisticMessageId = optimisticMessageId
        self.threadId = threadInfo.id
        self.threadVariant = threadInfo.variant
        self.threadIsTrusted = {
            switch threadInfo.variant {
                case .legacyGroup, .community, .group: return true /// Default to `true` for non-contact threads
                case .contact: return (dataCache.contact(for: threadInfo.id)?.isTrusted == true)
            }
        }()
        self.id = targetId
        self.variant = interaction.variant
        self.serverHash = interaction.serverHash
        self.openGroupServerMessageId = interaction.openGroupServerMessageId
        self.authorId = interaction.authorId
        self.authorUnblindedId = dataCache.unblindedId(for: authorId)
        self.bubbleBody = contentBuilder.makeBubbleBody()
        self.rawBody = interaction.body
        self.bodyForCopying = contentBuilder.makeBodyForCopying()
        self.timestampMs = interaction.timestampMs
        self.receivedAtTimestampMs = interaction.receivedAtTimestampMs
        self.expiresStartedAtMs = interaction.expiresStartedAtMs
        self.expiresInSeconds = interaction.expiresInSeconds
        self.attachments = contentBuilder.attachments
        self.reactionInfo = (reactionInfo ?? [])
        self.profile = targetProfile.with(
            proFeatures: .set(to: dependencies[singleton: .sessionProManager].profileFeatures(for: targetProfile))
        )
        self.quoteViewModel = maybeUnresolvedQuotedInfo.map { info -> QuoteViewModel? in
            /// Should be `interaction` not `quotedInteraction`
            let targetDirection: QuoteViewModel.Direction = (interaction.variant.isOutgoing ?
                .outgoing :
                .incoming
            )
            
            /// If the message contains a `Quote` but we couldn't resolve the original message then we still want to return a
            /// `QuoteViewModel` so that it's rendered correctly (it'll just render that it couldn't resolve)
            guard
                let quotedInteractionId: Int64 = info.foundQuotedInteractionId,
                let quotedInteraction: Interaction = info.resolvedQuotedInteraction
            else {
                return QuoteViewModel(
                    mode: .regular,
                    direction: targetDirection,
                    quotedInfo: nil,
                    showProBadge: false,
                    currentUserSessionIds: currentUserSessionIds,
                    displayNameRetriever: { _, _ in nil },
                    currentUserMentionImage: nil
                )
            }
            
            let quotedAuthorProfile: Profile = {
                /// If the sender is the current user then use the proper profile from the cache (instead of a random blinded one)
                guard !currentUserSessionIds.contains(quotedInteraction.authorId) else {
                    return (dataCache.profile(for: userSessionId.hexString) ?? Profile.defaultFor(userSessionId.hexString))
                }
                
                if let unblindedProfile: Profile = dataCache.unblindedId(for: quotedInteraction.authorId).map({ dataCache.profile(for: $0) }) {
                    return unblindedProfile
                }
                
                return (
                    dataCache.profile(for: quotedInteraction.authorId) ??
                    Profile.defaultFor(quotedInteraction.authorId)
                )
            }()
            let quotedContentBuilder: Interaction.ContentBuilder = Interaction.ContentBuilder(
                interaction: quotedInteraction,
                threadId: threadInfo.id,
                threadVariant: threadInfo.variant,
                dataCache: dataCache
            )
            let targetQuotedAttachment: Attachment? = (
                quotedContentBuilder.attachments.first ??
                quotedContentBuilder.linkPreviewAttachment
            )
            
            return QuoteViewModel(
                mode: .regular,
                direction: targetDirection,
                quotedInfo: QuoteViewModel.QuotedInfo(
                    interactionId: quotedInteractionId,
                    authorId: quotedInteraction.authorId,
                    authorName: quotedContentBuilder.authorDisplayName,
                    timestampMs: quotedInteraction.timestampMs,
                    body: quotedContentBuilder.makeBubbleBody(),
                    attachmentInfo: targetQuotedAttachment.map { quotedAttachment in
                        let utType: UTType = (UTType(sessionMimeType: quotedAttachment.contentType) ?? .invalid)
                        
                        return QuoteViewModel.AttachmentInfo(
                            id: quotedAttachment.id,
                            utType: utType,
                            isVoiceMessage: (quotedAttachment.variant == .voiceMessage),
                            downloadUrl: quotedAttachment.downloadUrl,
                            sourceFilename: quotedAttachment.sourceFilename,
                            thumbnailSource: quotedAttachment.downloadUrl.map { downloadUrl -> ImageDataManager.DataSource? in
                                guard
                                    let path: String = try? dependencies[singleton: .attachmentManager]
                                        .path(for: downloadUrl)
                                else { return nil }
                                
                                return .thumbnailFrom(
                                    utType: utType,
                                    path: path,
                                    sourceFilename: quotedAttachment.sourceFilename,
                                    size: .small,
                                    using: dependencies
                                )
                            }
                        )
                    }
                ),
                showProBadge: dependencies[singleton: .sessionProManager]
                    .profileFeatures(for: quotedAuthorProfile)
                    .contains(.proBadge),
                currentUserSessionIds: currentUserSessionIds,
                displayNameRetriever: dataCache.displayNameRetriever(
                    for: threadInfo.id,
                    includeSessionIdSuffixWhenInMessageBody: (threadInfo.variant == .community)
                ),
                currentUserMentionImage: currentUserMentionImage
            )
        }
        self.linkPreview = contentBuilder.linkPreview
        self.linkPreviewAttachment = contentBuilder.linkPreviewAttachment
        self.proMessageFeatures = proMessageFeatures
        self.proProfileFeatures = proProfileFeatures
        
        self.state = interaction.state
        self.hasBeenReadByRecipient = (interaction.recipientReadTimestampMs != nil)
        self.mostRecentFailureText = interaction.mostRecentFailureText
        self.isSenderModeratorOrAdmin = dataCache
            .communityModAdminIds(for: threadInfo.id)
            .contains(interaction.authorId)
        self.canFollowDisappearingMessagesSetting = {
            guard
                threadInfo.variant == .contact &&
                interaction.variant == .infoDisappearingMessagesUpdate &&
                !currentUserSessionIds.contains(interaction.authorId)
            else { return false }
            
            return (
                dataCache.disappearingMessageConfiguration(for: threadInfo.id) != DisappearingMessagesConfiguration
                    .defaultWith(threadInfo.id)
                    .with(
                        isEnabled: (interaction.expiresInSeconds ?? 0) > 0,
                        durationSeconds: interaction.expiresInSeconds,
                        type: (Int64(interaction.expiresStartedAtMs ?? 0) == interaction.timestampMs ?
                            .disappearAfterSend :
                            .disappearAfterRead
                        )
                    )
            )
        }()
        
        let isGroupThread: Bool = (
            threadVariant == .community ||
            threadVariant == .legacyGroup ||
            threadVariant == .group
        )
        let shouldShowDateBeforeThisModel: Bool = {
            guard interaction.variant != .infoCall else { return true }    /// Always show on calls
            guard !interaction.variant.isInfoMessage else { return false } /// Never show on info messages
            guard let previousInteraction: Interaction = previousInteraction else { return true }
            
            return MessageViewModel.shouldShowDateBreak(
                between: previousInteraction.timestampMs,
                and: interaction.timestampMs
            )
        }()
        let shouldShowDateBeforeNextModel: Bool = {
            /// Should be nothing after a typing indicator
            guard let nextInteraction: Interaction = nextInteraction else { return false }

            return MessageViewModel.shouldShowDateBreak(
                between: interaction.timestampMs,
                and: nextInteraction.timestampMs
            )
        }()
        self.shouldShowAuthorName = {
            /// Only show for group threads
            guard isGroupThread else { return false }
            
            /// Only show for incoming messages
            guard interaction.variant.isIncoming else { return false }
                
            /// Only if there is a date header or the senders are different
            guard
                shouldShowDateBeforeThisModel ||
                interaction.authorId != previousInteraction?.authorId ||
                previousInteraction?.variant.isInfoMessage == true
            else { return false }
                
            return true
        }()
        self.canHaveProfile = (
            /// Only group threads and incoming messages
            isGroupThread &&
            interaction.variant.isIncoming
        )
        self.shouldShowDisplayPicture = (
            /// Only group threads
            isGroupThread &&
            
            /// Only incoming messages
            interaction.variant.isIncoming &&
            
            /// Show if the next message has a different sender, isn't a standard message or has a "date break"
            (
                interaction.authorId != nextInteraction?.authorId ||
                nextInteraction?.variant.isIncoming != true ||
                shouldShowDateBeforeNextModel
            )
        )
        self.shouldShowDateHeader = shouldShowDateBeforeThisModel
        self.containsOnlyEmoji = contentBuilder.containsOnlyEmoji
        self.glyphCount = contentBuilder.glyphCount
        self.previousVariant = previousInteraction?.variant
        
        let (positionInCluster, isOnlyMessageInCluster): (Position, Bool) = {
            let isFirstInCluster: Bool = (
                interaction.variant.isInfoMessage ||
                previousInteraction == nil ||
                shouldShowDateBeforeThisModel || (
                    interaction.variant.isOutgoing &&
                    previousInteraction?.variant.isOutgoing != true
                ) || (
                    interaction.variant.isIncoming &&
                    previousInteraction?.variant.isIncoming != true
                ) ||
                interaction.authorId != previousInteraction?.authorId
            )
            let isLastInCluster: Bool = (
                interaction.variant.isInfoMessage ||
                nextInteraction == nil ||
                shouldShowDateBeforeNextModel || (
                    interaction.variant.isOutgoing &&
                    nextInteraction?.variant.isOutgoing != true
                ) || (
                    interaction.variant.isIncoming &&
                    nextInteraction?.variant.isIncoming != true
                ) ||
                interaction.authorId != nextInteraction?.authorId
            )

            let isOnlyMessageInCluster: Bool = (isFirstInCluster && isLastInCluster)

            switch (isFirstInCluster, isLastInCluster) {
                case (true, true), (false, false): return (.middle, isOnlyMessageInCluster)
                case (true, false): return (.top, isOnlyMessageInCluster)
                case (false, true): return (.bottom, isOnlyMessageInCluster)
            }
        }()
        
        self.positionInCluster = positionInCluster
        self.isOnlyMessageInCluster = isOnlyMessageInCluster
        self.isLast = isLast
        self.isLastOutgoing = isLastOutgoing
        self.currentUserSessionIds = currentUserSessionIds
        self.currentUserMentionImage = currentUserMentionImage
    }
    
    func with(
        state: Update<Interaction.State> = .useExisting,         // Optimistic outgoing messages
        mostRecentFailureText: Update<String?> = .useExisting    // Optimistic outgoing messages
    ) -> MessageViewModel {
        return MessageViewModel(
            cellType: cellType,
            optimisticMessageId: optimisticMessageId,
            threadId: threadId,
            threadVariant: threadVariant,
            threadIsTrusted: threadIsTrusted,
            id: id,
            variant: variant,
            serverHash: serverHash,
            openGroupServerMessageId: openGroupServerMessageId,
            authorId: authorId,
            authorUnblindedId: authorUnblindedId,
            bubbleBody: bubbleBody,
            rawBody: rawBody,
            bodyForCopying: bodyForCopying,
            timestampMs: timestampMs,
            receivedAtTimestampMs: receivedAtTimestampMs,
            expiresStartedAtMs: expiresStartedAtMs,
            expiresInSeconds: expiresInSeconds,
            attachments: attachments,
            reactionInfo: reactionInfo,
            profile: profile,
            quoteViewModel: quoteViewModel,
            linkPreview: linkPreview,
            linkPreviewAttachment: linkPreviewAttachment,
            proMessageFeatures: proMessageFeatures,
            proProfileFeatures: proProfileFeatures,
            state: state.or(self.state),
            hasBeenReadByRecipient: hasBeenReadByRecipient,
            mostRecentFailureText: mostRecentFailureText.or(self.mostRecentFailureText),
            isSenderModeratorOrAdmin: isSenderModeratorOrAdmin,
            canFollowDisappearingMessagesSetting: canFollowDisappearingMessagesSetting,
            shouldShowAuthorName: shouldShowAuthorName,
            canHaveProfile: canHaveProfile,
            shouldShowDisplayPicture: shouldShowDisplayPicture,
            shouldShowDateHeader: shouldShowDateHeader,
            containsOnlyEmoji: containsOnlyEmoji,
            glyphCount: glyphCount,
            previousVariant: previousVariant,
            positionInCluster: positionInCluster,
            isOnlyMessageInCluster: isOnlyMessageInCluster,
            isLast: isLast,
            isLastOutgoing: isLastOutgoing,
            currentUserSessionIds: currentUserSessionIds,
            currentUserMentionImage: currentUserMentionImage
        )
    }
    
    func authorName(
        ignoreNickname: Bool = false
    ) -> String {
        return profile.displayName(
            ignoreNickname: ignoreNickname,
            showYouForCurrentUser: true,
            currentUserSessionIds: currentUserSessionIds
        )
    }
}

// MARK: - Observations

extension MessageViewModel: ObservableKeyProvider {
    public var observedKeys: Set<ObservableKey> {
        var result: Set<ObservableKey> = [
            .messageUpdated(id: id, threadId: threadId),
            .messageDeleted(id: id, threadId: threadId),
            .reactionsChanged(messageId: id),
            .attachmentCreated(messageId: id),
            .profile(authorId)
        ]
        
        if SessionId.Prefix.isCommunityBlinded(threadId) {
            result.insert(.anyContactUnblinded) /// Author/Profile info could change
        }
        
        attachments.forEach { attachment in
            result.insert(.attachmentUpdated(id: attachment.id, messageId: id))
            result.insert(.attachmentDeleted(id: attachment.id, messageId: id))
        }
        
        if
            let quoteViewModel: QuoteViewModel = quoteViewModel,
            let quotedInfo: QuoteViewModel.QuotedInfo = quoteViewModel.quotedInfo
        {
            result.insert(.profile(quotedInfo.authorId))
            result.insert(.messageUpdated(id: quotedInfo.interactionId, threadId: threadId))
            result.insert(.messageDeleted(id: quotedInfo.interactionId, threadId: threadId))
            
            if let attachmentInfo: QuoteViewModel.AttachmentInfo = quotedInfo.attachmentInfo {
                result.insert(.attachmentUpdated(id: attachmentInfo.id, messageId: quotedInfo.interactionId))
                result.insert(.attachmentDeleted(id: attachmentInfo.id, messageId: quotedInfo.interactionId))
            }
        }
        
        return result
    }
    
    public static func handlingStrategy(for event: ObservedEvent) -> EventHandlingStrategy? {
        return event.handlingStrategy
    }
}

// MARK: - DisappeaingMessagesUpdateControlMessage

public extension MessageViewModel {
    func messageDisappearingConfiguration() -> DisappearingMessagesConfiguration {
        return DisappearingMessagesConfiguration
            .defaultWith(self.threadId)
            .with(
                isEnabled: (self.expiresInSeconds ?? 0) > 0,
                durationSeconds: self.expiresInSeconds,
                type: (Int64(self.expiresStartedAtMs ?? 0) == self.timestampMs ? .disappearAfterSend : .disappearAfterRead )
            )
    }
}

// MARK: - ReactionInfo

public extension MessageViewModel {
    struct ReactionInfo: Sendable, Equatable, Comparable, Hashable, Differentiable {
        public let reaction: Reaction
        public let profile: Profile?
        
        public init(reaction: Reaction, profile: Profile?) {
            self.reaction = reaction
            self.profile = profile
        }
        
        // MARK: - Differentiable
        
        public var differenceIdentifier: String {
            "\(reaction.emoji)-\(reaction.interactionId)-\(reaction.authorId)"
        }
        
        // MARK: - Comparable
        
        public static func < (lhs: ReactionInfo, rhs: ReactionInfo) -> Bool {
            return (lhs.reaction.sortId < rhs.reaction.sortId)
        }
    }
}

// MARK: - MaybeUnresolvedQuotedInfo

public extension MessageViewModel {
    /// If the message contains a `Quote` but we couldn't resolve the original message then we should display the "original message
    /// not found" UI (ie. show that there _was_ a quote there, even if we can't resolve it) - this type makes that possible
    struct MaybeUnresolvedQuotedInfo: Sendable, Equatable, Hashable {
        public let foundQuotedInteractionId: Int64?
        public let resolvedQuotedInteraction: Interaction?
        
        public init(
            foundQuotedInteractionId: Int64?,
            resolvedQuotedInteraction: Interaction? = nil
        ) {
            self.foundQuotedInteractionId = foundQuotedInteractionId
            self.resolvedQuotedInteraction = resolvedQuotedInteraction
        }
    }
}

// MARK: - Convenience

private extension ObservedEvent {
    var handlingStrategy: EventHandlingStrategy? {
        switch (key, key.generic) {
            case (.anyContactUnblinded, _): return [.databaseQuery, .directCacheUpdate]
            case (_, .messageUpdated), (_, .messageDeleted): return .databaseQuery
            case (_, .attachmentUpdated), (_, .attachmentDeleted): return .databaseQuery
            case (_, .reactionsChanged): return .databaseQuery
            case (_, .communityUpdated): return [.directCacheUpdate]
            case (_, .contact): return [.directCacheUpdate]
            case (_, .profile): return [.directCacheUpdate]
            case (_, .typingIndicator): return .directCacheUpdate
            default: return nil
        }
    }
}

extension MessageViewModel {
    public static func bodyTextColor(isOutgoing: Bool) -> ThemeValue {
        return (isOutgoing ?
            .messageBubble_outgoingText :
            .messageBubble_incomingText
        )
    }
    
    fileprivate static func shouldShowDateBreak(between timestamp1: Int64, and timestamp2: Int64) -> Bool {
        let diff: Int64 = abs(timestamp2 - timestamp1)
        let fiveMinutesInMs: Int64 = (5 * 60 * 1000)
        
        /// If there is more than 5 minutes between the timestamps then we should show a date break
        if diff > fiveMinutesInMs {
            return true
        }
        
        /// If we crossed midnight then we want to show a date break regardless of how much time has passed - do this by shifting the
        /// timestamps to local time (using the current timezone) and getting a "day number" to check if they are the same dat
        let seconds1: Int = Int(timestamp1 / 1000)
        let seconds2: Int = Int(timestamp2 / 1000)
        let offset: Int = TimeZone.current.secondsFromGMT()
        let day1: Int = ((seconds1 + offset) / 86400)
        let day2: Int = ((seconds2 + offset) / 86400)
        
        return (day1 != day2)
    }
}

public extension MessageViewModel {
    static func interactionFilterSQL(threadId: String) -> SQL {
        let interaction: TypedTableAlias<Interaction> = TypedTableAlias()
        
        return SQL("\(interaction[.threadId]) = \(threadId)")
    }
    
    static let interactionOrderSQL: SQL = {
        let interaction: TypedTableAlias<Interaction> = TypedTableAlias()
        
        return SQL("\(interaction[.timestampMs].desc)")
    }()
    
    static func quotedInteractionIds(
        for originalInteractionIds: Set<Int64>,
        currentUserSessionIds: Set<String>
    ) -> SQLRequest<FetchablePair<Int64, Int64?>> {
        let interaction: TypedTableAlias<Interaction> = TypedTableAlias()
        let quote: TypedTableAlias<Quote> = TypedTableAlias()
        let quoteInteraction: TypedTableAlias<Interaction> = TypedTableAlias(name: "quoteInteraction")
        
        return """
            SELECT
                \(interaction[.id]) AS \(FetchablePair<Int64, Int64?>.Columns.first),
                \(quoteInteraction[.id]) AS \(FetchablePair<Int64, Int64?>.Columns.second)
            FROM \(Interaction.self)
            JOIN \(Quote.self) ON \(quote[.interactionId]) = \(interaction[.id])
            LEFT JOIN \(quoteInteraction) ON (
                \(quoteInteraction[.timestampMs]) = \(quote[.timestampMs]) AND (
                    \(quoteInteraction[.authorId]) = \(quote[.authorId]) OR (
                        -- A users outgoing message is stored in some cases using their standard id
                        -- but the quote will use their blinded id so handle that case
                        \(quoteInteraction[.authorId]) IN \(currentUserSessionIds) AND
                        \(quote[.authorId]) IN \(currentUserSessionIds)
                    )
                )
            )
            WHERE \(interaction[.id]) IN \(originalInteractionIds)
        """
    }
}

extension MessageViewModel {
    public func createUserProfileModalInfo(
        openGroupServer: String?,
        openGroupPublicKey: String?,
        onStartThread: (@MainActor () -> Void)?,
        onProBadgeTapped: (@MainActor () -> Void)?,
        using dependencies: Dependencies
    ) async -> UserProfileModal.Info? {
        let (info, _) = ProfilePictureView.Info.generateInfoFrom(
            size: .hero,
            publicKey: authorId,
            threadVariant: .contact,    /// Always show the display picture in 'contact' mode
            displayPictureUrl: nil,
            profile: profile,
            using: dependencies
        )
        
        guard let profileInfo: ProfilePictureView.Info = info else { return nil }
        
        let sessionId: String? = await {
            if let unblindedId: String = authorUnblindedId {
                return unblindedId
            }
            
            switch try? SessionId.Prefix(from: authorId) {
                case .standard: return authorId
                case .none, .versionBlinded07, .group, .unblinded: return nil
                case .blinded15, .blinded25:
                    /// If the sessionId is blinded then check if there is an existing un-blinded thread with the contact and use that,
                    /// otherwise just use the blinded id
                    guard let openGroupServer, let openGroupPublicKey else { return nil }
                    
                    let maybeLookup: BlindedIdLookup? = try? await dependencies[singleton: .storage].writeAsync { db in
                        try BlindedIdLookup.fetchOrCreate(
                            db,
                            blindedId: authorId,
                            openGroupServer: openGroupServer,
                            openGroupPublicKey: openGroupPublicKey,
                            isCheckingForOutbox: false,
                            using: dependencies
                        )
                    }
                    
                    return maybeLookup?.sessionId
            }
        }()
        let blindedId: String? = {
            switch try? SessionId.Prefix(from: authorId) {
                case .none, .standard, .versionBlinded07, .group, .unblinded: return nil
                case .blinded15, .blinded25: return authorId
            }
        }()
        let qrCodeImage: UIImage? = {
            guard let sessionId else { return nil }
                
            return QRCode.generate(
                for: sessionId,
                hasBackground: false,
                iconName: "SessionWhite40" // stringlint:ignore
            )
        }()
        
        return UserProfileModal.Info(
            sessionId: sessionId,
            blindedId: blindedId,
            qrCodeImage: qrCodeImage,
            profileInfo: profileInfo,
            displayName: authorName(),
            contactDisplayName: authorName(ignoreNickname: true),
            shouldShowProBadge: profile.proFeatures.contains(.proBadge),
            areMessageRequestsEnabled: {
                guard threadVariant == .community else { return true }
                
                return (profile.blocksCommunityMessageRequests != true)
            }(),
            onStartThread: onStartThread,
            onProBadgeTapped: onProBadgeTapped
        )
    }
}

// MARK: - Construction

private extension MessageViewModel {
    static func cellType(
        interaction: Interaction,
        attachments: [Attachment]?
    ) -> MessageViewModel.CellType {
        guard !interaction.variant.isDeletedMessage else { return .textOnlyMessage }
        guard let attachment: Attachment = attachments?.first else {
            switch interaction.variant {
                case .infoCall: return .call
                case .infoLegacyGroupCreated, .infoLegacyGroupUpdated, .infoLegacyGroupCurrentUserLeft,
                    .infoGroupCurrentUserLeaving, .infoGroupCurrentUserErrorLeaving,
                    .infoDisappearingMessagesUpdate, .infoScreenshotNotification,
                    .infoMediaSavedNotification, .infoMessageRequestAccepted, .infoGroupInfoInvited,
                    .infoGroupInfoUpdated, .infoGroupMembersUpdated:
                    return .infoMessage
                    
                case ._legacyStandardIncomingDeleted, .standardIncomingDeleted, .standardOutgoingDeleted, .standardIncomingDeletedLocally, .standardOutgoingDeletedLocally:
                    return .textOnlyMessage /// Should be handled above
                    
                case .standardOutgoing, .standardIncoming: return .textOnlyMessage
            }
        }

        /// The only case which currently supports multiple attachments is a 'mediaMessage' (the album view)
        guard attachments?.count == 1 else { return .mediaMessage }

        // Pending audio attachments won't have a duration
        if
            attachment.isAudio && (
                ((attachment.duration ?? 0) > 0) ||
                (
                    attachment.state != .downloaded &&
                    attachment.state != .uploaded
                )
            )
        {
            return (attachment.variant == .voiceMessage ? .voiceMessage : .audio)
        }

        if attachment.isVisualMedia {
            return .mediaMessage
        }
        
        return .genericAttachment
    }
}

internal extension Interaction {
    struct ContentBuilder {
        public let interaction: Interaction?
        private let searchText: String?
        private let dataCache: ConversationDataCache
        
        private let threadId: String
        private let threadVariant: SessionThread.Variant
        private let currentUserSessionIds: Set<String>
        public let attachments: [Attachment]
        public let hasAttachments: Bool
        public let linkPreview: LinkPreview?
        public let linkPreviewAttachment: Attachment?
        
        public var rawBody: String? { interaction?.body }
        public let authorDisplayName: String
        public let authorDisplayNameNoSuffix: String
        public let threadContactDisplayName: String
        public var containsOnlyEmoji: Bool { interaction?.body?.containsOnlyEmoji == true }
        public var glyphCount: Int { interaction?.body?.glyphCount ?? 0 }
        
        init(
            interaction: Interaction?,
            threadId: String,
            threadVariant: SessionThread.Variant,
            searchText: String? = nil,
            dataCache: ConversationDataCache
        ) {
            self.interaction = interaction
            self.searchText = searchText
            self.dataCache = dataCache
            
            let currentUserSessionIds: Set<String> = dataCache.currentUserSessionIds(for: threadId)
            let linkPreviewInfo = interaction.map {
                ContentBuilder.resolveBestLinkPreview(
                    for: $0,
                    dataCache: dataCache
                )
            }
            self.threadId = threadId
            self.threadVariant = threadVariant
            self.currentUserSessionIds = currentUserSessionIds
            self.attachments = (interaction?.id.map { dataCache.attachments(for: $0) } ?? [])
            self.hasAttachments = (interaction?.id.map { dataCache.interactionAttachments(for: $0).isEmpty } == false)
            self.linkPreview = linkPreviewInfo?.preview
            self.linkPreviewAttachment = linkPreviewInfo?.attachment
            
            if let authorId: String = interaction?.authorId {
                if currentUserSessionIds.contains(authorId) {
                    self.authorDisplayName = "you".localized()
                    self.authorDisplayNameNoSuffix = "you".localized()
                }
                else {
                    let profile: Profile = (
                        dataCache.profile(for: authorId) ??
                        Profile.defaultFor(authorId)
                    )
                    
                    self.authorDisplayName = profile.displayName(
                        includeSessionIdSuffix: (threadVariant == .community)
                    )
                    self.authorDisplayNameNoSuffix = profile.displayName(includeSessionIdSuffix: false)
                }
            }
            else {
                self.authorDisplayName = ""
                self.authorDisplayNameNoSuffix = ""
            }
            
            self.threadContactDisplayName = dataCache.contactDisplayName(for: threadId)
        }
        
        func makeBubbleBody() -> String? {
            guard let interaction else { return nil }
            
            if interaction.variant.isInfoMessage {
                return makePreviewText()
            }
            
            guard let rawBody: String = interaction.body, !rawBody.isEmpty else {
                return nil
            }
            
            /// No need to process mentions if the preview doesn't contain the mention prefix
            guard rawBody.contains("@") else { return rawBody }
            
            let isOutgoing: Bool = (interaction.variant == .standardOutgoing)
            
            return MentionUtilities.taggingMentions(
                in: rawBody,
                location: (isOutgoing ? .outgoingMessage : .incomingMessage),
                currentUserSessionIds: currentUserSessionIds,
                displayNameRetriever: dataCache.displayNameRetriever(
                    for: interaction.threadId,
                    includeSessionIdSuffixWhenInMessageBody: (threadVariant == .community)
                )
            )
        }
        
        func makeBodyForCopying() -> String? {
            guard let interaction else { return nil }
            
            if interaction.variant.isInfoMessage {
                return makePreviewText()
            }
            
            return rawBody
        }
        
        func makePreviewText() -> String? {
            guard let interaction else { return nil }
            
            return Interaction.previewText(
                variant: interaction.variant,
                body: interaction.body,
                threadContactDisplayName: threadContactDisplayName,
                authorDisplayName: authorDisplayName,
                attachmentDescriptionInfo: attachments.first.map { firstAttachment in
                    Attachment.DescriptionInfo(
                        id: firstAttachment.id,
                        variant: firstAttachment.variant,
                        contentType: firstAttachment.contentType,
                        sourceFilename: firstAttachment.sourceFilename
                    )
                },
                attachmentCount: attachments.count,
                isOpenGroupInvitation: (linkPreview?.variant == .openGroupInvitation)
            )
        }
        
        func makeSnippet(dateNow: Date) -> String? {
            var result: String = ""
            let isSearchResult: Bool = (searchText != nil)
            let groupInfo: LibSession.GroupInfo? = dataCache.groupInfo(for: threadId)
            let groupKicked: Bool = (groupInfo?.wasKickedFromGroup == true)
            let groupDestroyed: Bool = (groupInfo?.wasGroupDestroyed == true)
            let groupThreadTypes: Set<SessionThread.Variant> = [.legacyGroup, .group, .community]
            let groupSourceTypes: Set<ConversationDataCache.Context.Source> = [.conversationList, .searchResults]
            let shouldIncludeAuthorPrefix: Bool = (
                interaction?.variant.isInfoMessage == false &&
                groupSourceTypes.contains(dataCache.context.source) &&
                groupThreadTypes.contains(threadVariant)
            )
            let shouldHaveStatusIcon: Bool = {
                guard !isSearchResult && !groupKicked && !groupDestroyed else { return false }
                
                /// Only the standard conversation list should have a status icon prefix
                switch dataCache.context.source {
                    case .messageList, .conversationSettings, .searchResults: return false
                    case .conversationList: return true
                }
            }()
            
            /// Add status icon prefixes
            if shouldHaveStatusIcon {
                if let thread = dataCache.thread(for: threadId) {
                    let now: TimeInterval = dateNow.timeIntervalSince1970
                    let mutedUntil: TimeInterval = (thread.mutedUntilTimestamp ?? 0)
                    
                    if now < mutedUntil {
                        result.append(NotificationsUI.mutePrefix.rawValue)
                        result.append(" ")
                    }
                    else if thread.onlyNotifyForMentions {
                        result.append(NotificationsUI.mentionPrefix.rawValue)
                        result.append("  ") /// Need a double space here
                    }
                }
            }
            
            /// If it's a group conversation then it might have a specia status
            switch (groupInfo, groupDestroyed, groupKicked, interaction?.variant) {
                case (.some(let groupInfo), true, _, _):
                    result.append(
                        "groupDeletedMemberDescription"
                            .put(key: "group_name", value: groupInfo.name)
                            .localizedDeformatted()
                    )
                    
                case (.some(let groupInfo), _, true, _):
                    result.append(
                        "groupRemovedYou"
                            .put(key: "group_name", value: groupInfo.name)
                            .localizedDeformatted()
                    )
                    
                case (.some(let groupInfo), _, _, .infoGroupCurrentUserErrorLeaving):
                    result.append(
                        "groupLeaveErrorFailed"
                            .put(key: "group_name", value: groupInfo.name)
                            .localizedDeformatted()
                    )
                    
                default:
                    if let previewText: String = makePreviewText() {
                        let finalPreviewText: String = (!previewText.contains("@") ?
                            previewText :
                            MentionUtilities.resolveMentions(
                                in: previewText,
                                currentUserSessionIds: currentUserSessionIds,
                                displayNameRetriever: dataCache.displayNameRetriever(
                                    for: threadId,
                                    includeSessionIdSuffixWhenInMessageBody: (threadVariant == .community)
                                )
                            )
                        )
                        
                        /// The search term highlighting logic will add the author directly (so it doesn't get highlighted)
                        if !isSearchResult && shouldIncludeAuthorPrefix {
                            result.append(
                                "messageSnippetGroup"
                                    .put(key: "author", value: authorDisplayName)
                                    .put(key: "message_snippet", value: finalPreviewText)
                                    .localizedDeformatted()
                            )
                        }
                        else {
                            result.append(finalPreviewText)
                        }
                    }
            }
            
            guard !result.isEmpty else { return nil }
            
            /// If we don't have a search term then return the value (deformatted), otherwise highlight the search term tokens
            guard let searchText: String = searchText else {
                return result.deformatted()
            }
            
            return GlobalSearch.highlightSearchText(
                searchText: searchText,
                content: result,
                authorName: (shouldIncludeAuthorPrefix ? authorDisplayName : nil)
            )
        }
        
        private static func resolveBestLinkPreview(
            for interaction: Interaction,
            dataCache: ConversationDataCache
        ) -> (preview: LinkPreview, attachment: Attachment?)? {
            guard let url: String = interaction.linkPreviewUrl else { return nil }
            
            /// Find all previews for the given url and sort by newest to oldest
            let possiblePreviews: Set<LinkPreview> = dataCache.linkPreviews(for: url)
            
            guard !possiblePreviews.isEmpty else { return nil }
            
            /// Try get the link preview for the time the message was sent
            let sentTimestamp: TimeInterval = (TimeInterval(interaction.timestampMs) / 1000)
            let minTimestamp: TimeInterval = (sentTimestamp - LinkPreview.timstampResolution)
            let maxTimestamp: TimeInterval = (sentTimestamp + LinkPreview.timstampResolution)
            var bestFallback: LinkPreview? = nil
            var bestInWindow: LinkPreview? = nil
            
            for preview in possiblePreviews {
                /// Evaluate the `bestFallback` (used if we can't find a `bestInWindow`)
                if let currentFallback: LinkPreview = bestFallback {
                    /// If the timestamps match then it's likely there is an optimistic link preview in the cache, so if one of the options
                    /// has an `attachmentId` then we should prioritise that one
                    switch (preview.attachmentId, currentFallback.attachmentId) {
                        case (.some, .none): bestFallback = preview
                        case (.none, .some): break
                        case (.some, .some), (.none, .none):
                            /// If this preview is newer than the `currentFallback` then use it instead
                            if preview.timestamp > currentFallback.timestamp {
                                bestFallback = preview
                            }
                    }
                }
                
                /// Evaluate the `bestInWindow`
                if preview.timestamp > minTimestamp && preview.timestamp < maxTimestamp {
                    if let currentInWindow: LinkPreview = bestInWindow {
                        /// If the timestamps match then it's likely there is an optimistic link preview in the cache, so if one of the options
                        /// has an `attachmentId` then we should prioritise that one
                        switch (preview.attachmentId, currentInWindow.attachmentId) {
                            case (.some, .none): bestInWindow = preview
                            case (.none, .some): break
                            case (.some, .some), (.none, .none):
                                /// If this preview is newer than the `currentInWindow` then use it instead
                                if preview.timestamp > currentInWindow.timestamp {
                                    bestInWindow = preview
                                }
                        }
                    }
                    else {
                        bestInWindow = preview
                    }
                }
            }
            
            guard let finalPreview: LinkPreview = (bestInWindow ?? bestFallback) else { return nil }
            
            return (finalPreview, finalPreview.attachmentId.map { dataCache.attachment(for: $0) })
        }
    }
}
