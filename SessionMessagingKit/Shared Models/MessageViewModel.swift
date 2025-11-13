// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import GRDB
import DifferenceKit
import SessionUIKit
import SessionUtilitiesKit

public struct MessageViewModel: Sendable, Equatable, Hashable, Identifiable, Differentiable {
    public enum CellType: Int, Sendable, Decodable, Equatable, Hashable {
        case textOnlyMessage
        case mediaMessage
        case audio
        case voiceMessage
        case genericAttachment
        case typingIndicator
        case dateHeader
        case unreadMarker
    }
    
    public var differenceIdentifier: Int64 { id }
    
    /// This value will be used to populate the Context Menu and date header (if present)
    public var dateForUI: Date { Date(timeIntervalSince1970: TimeInterval(Double(self.timestampMs) / 1000)) }
    
    /// This value will be used to populate the Message Info (if present)
    public var receivedDateForUI: Date {
        Date(timeIntervalSince1970: TimeInterval(Double(self.receivedAtTimestampMs) / 1000))
    }
    
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
    public let body: String?
    public let rawBody: String?
    public let timestampMs: Int64
    public let receivedAtTimestampMs: Int64
    public let expiresStartedAtMs: Double?
    public let expiresInSeconds: TimeInterval?
    public let attachments: [Attachment]
    public let reactionInfo: [ReactionInfo]
    public let profile: Profile
    public let quotedInfo: QuotedInfo?
    public let linkPreview: LinkPreview?
    public let linkPreviewAttachment: Attachment?
    public let proFeatures: SessionPro.Features
    
    /// This value includes the author name information
    public let authorName: String
    
    /// This value includes the author name information with the `id` suppressed (if it was present)
    public let authorNameSuppressedId: String
    
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
        quotedInfo: MessageViewModel.QuotedInfo? = nil,
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
        self.body = body
        self.quotedInfo = quotedInfo
        
        /// These values shouldn't be used for the custom types
        self.optimisticMessageId = nil
        self.threadId = "INVALID_THREAD_ID"
        self.threadVariant = .contact
        self.threadIsTrusted = false
        self.serverHash = ""
        self.openGroupServerMessageId = nil
        self.authorId = ""
        self.rawBody = nil
        self.receivedAtTimestampMs = 0
        self.expiresStartedAtMs = nil
        self.expiresInSeconds = nil
        self.attachments = []
        self.reactionInfo = []
        self.profile = Profile(id: "", name: "")
        self.linkPreview = nil
        self.linkPreviewAttachment = nil
        self.proFeatures = .none
        
        self.authorName = ""
        self.authorNameSuppressedId = ""
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
    }
    
    init?(
        optimisticMessageId: Int64? = nil,
        threadId: String,
        threadVariant: SessionThread.Variant,
        threadIsTrusted: Bool,
        threadDisappearingConfiguration: DisappearingMessagesConfiguration?,
        interaction: Interaction,
        reactionInfo: [ReactionInfo]?,
        quotedInteraction: Interaction?,
        profileCache: [String: Profile],
        attachmentCache: [String: Attachment],
        linkPreviewCache: [String: [LinkPreview]],
        attachmentMap: [Int64: Set<InteractionAttachment>],
        isSenderModeratorOrAdmin: Bool,
        currentUserSessionIds: Set<String>,
        previousInteraction: Interaction?,
        nextInteraction: Interaction?,
        isLast: Bool,
        isLastOutgoing: Bool,
        using dependencies: Dependencies
    ) {
        let targetId: Int64
        
        switch (optimisticMessageId, interaction.id) {
            case (.some(let id), _): targetId = id
            case (_, .some(let id)): targetId = id
            case (.none, .none): return nil
        }
        
        let authorDisplayName: String = {
            guard !currentUserSessionIds.contains(interaction.authorId) else { return "you".localized() }
            
            return Profile.displayName(
                for: threadVariant,
                id: interaction.authorId,
                name: profileCache[interaction.authorId]?.name,
                nickname: profileCache[interaction.authorId]?.nickname,
                suppressId: false   // Show the id next to the author name if desired
            )
        }()
        let linkPreviewInfo: (preview: LinkPreview, attachment: Attachment?)? = interaction.linkPreview(
            linkPreviewCache: linkPreviewCache,
            attachmentCache: attachmentCache
        )
        let attachments: [Attachment] = (attachmentMap[targetId]?
            .sorted { $0.albumIndex < $1.albumIndex }
            .compactMap { attachmentCache[$0.attachmentId] } ?? [])
        let body: String? = interaction.body(
            threadId: threadId,
            threadVariant: threadVariant,
            authorDisplayName: authorDisplayName,
            attachments: attachments,
            linkPreview: linkPreviewInfo?.preview,
            profileCache: profileCache,
            using: dependencies
        )
        let proFeatures: SessionPro.Features = {
            guard dependencies[feature: .sessionProEnabled] else { return .none }
            
            return interaction.proFeatures
                .union(dependencies[feature: .forceMessageFeatureProBadge] ? .proBadge : .none)
                .union(dependencies[feature: .forceMessageFeatureLongMessage] ? .largerCharacterLimit : .none)
                .union(dependencies[feature: .forceMessageFeatureAnimatedAvatar] ? .animatedAvatar : .none)
        }()
        
        self.cellType = MessageViewModel.cellType(
            interaction: interaction,
            attachments: attachments
        )
        self.optimisticMessageId = optimisticMessageId
        self.threadId = threadId
        self.threadVariant = threadVariant
        self.threadIsTrusted = threadIsTrusted
        self.id = targetId
        self.variant = interaction.variant
        self.serverHash = interaction.serverHash
        self.openGroupServerMessageId = interaction.openGroupServerMessageId
        self.authorId = interaction.authorId
        self.body = body
        self.rawBody = interaction.body
        self.timestampMs = interaction.timestampMs
        self.receivedAtTimestampMs = interaction.receivedAtTimestampMs
        self.expiresStartedAtMs = interaction.expiresStartedAtMs
        self.expiresInSeconds = interaction.expiresInSeconds
        self.attachments = attachments
        self.reactionInfo = (reactionInfo ?? [])
        self.profile = (profileCache[interaction.authorId] ?? Profile.defaultFor(interaction.authorId))
        self.quotedInfo = quotedInteraction.map { quotedInteraction -> QuotedInfo? in
            guard let quoteInteractionId: Int64 = quotedInteraction.id else { return nil }
            
            let quotedAttachments: [Attachment]? = (attachmentMap[quotedInteraction.id]?
                .sorted { $0.albumIndex < $1.albumIndex }
                .compactMap { attachmentCache[$0.attachmentId] } ?? [])
            let quotedLinkPreviewInfo: (preview: LinkPreview, attachment: Attachment?)? = quotedInteraction.linkPreview(
                linkPreviewCache: linkPreviewCache,
                attachmentCache: attachmentCache
            )
            let quotedInteractionProFeatures: SessionPro.Features = {
                guard dependencies[feature: .sessionProEnabled] else { return .none }
                
                return quotedInteraction.proFeatures
                    .union(dependencies[feature: .forceMessageFeatureProBadge] ? .proBadge : .none)
                    .union(dependencies[feature: .forceMessageFeatureLongMessage] ? .largerCharacterLimit : .none)
                    .union(dependencies[feature: .forceMessageFeatureAnimatedAvatar] ? .animatedAvatar : .none)
            }()
            
            return MessageViewModel.QuotedInfo(
                interactionId: quoteInteractionId,
                authorName: {
                    guard !currentUserSessionIds.contains(quotedInteraction.authorId) else {
                        return "you".localized()
                    }
                    
                    return Profile.displayName(
                        for: threadVariant,
                        id: quotedInteraction.authorId,
                        name: profileCache[quotedInteraction.authorId]?.name,
                        nickname: profileCache[quotedInteraction.authorId]?.nickname,
                        suppressId: true
                    )
                }(),
                timestampMs: quotedInteraction.timestampMs,
                body: quotedInteraction.body(
                    threadId: threadId,
                    threadVariant: threadVariant,
                    authorDisplayName: authorDisplayName,
                    attachments: quotedAttachments,
                    linkPreview: quotedLinkPreviewInfo?.preview,
                    profileCache: profileCache,
                    using: dependencies
                ),
                attachment: (quotedAttachments?.first ?? quotedLinkPreviewInfo?.attachment),
                proFeatures: quotedInteractionProFeatures
            )
        }
        self.linkPreview = linkPreviewInfo?.preview
        self.linkPreviewAttachment = linkPreviewInfo?.attachment
        self.proFeatures = proFeatures
        
        self.authorName = authorDisplayName
        self.authorNameSuppressedId = {
            guard !currentUserSessionIds.contains(interaction.authorId) else { return "you".localized() }
            
            return Profile.displayName(
                for: threadVariant,
                id: interaction.authorId,
                name: profileCache[interaction.authorId]?.name,
                nickname: profileCache[interaction.authorId]?.nickname,
                suppressId: true   // Exclude the id next to the author name
            )
        }()
        
        self.state = interaction.state
        self.hasBeenReadByRecipient = (interaction.recipientReadTimestampMs != nil)
        self.mostRecentFailureText = interaction.mostRecentFailureText
        self.isSenderModeratorOrAdmin = isSenderModeratorOrAdmin
        self.canFollowDisappearingMessagesSetting = {
            guard
                threadVariant == .contact &&
                interaction.variant == .infoDisappearingMessagesUpdate &&
                !currentUserSessionIds.contains(interaction.authorId)
            else { return false }
            
            return (
                threadDisappearingConfiguration != DisappearingMessagesConfiguration
                    .defaultWith(threadId)
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
        self.containsOnlyEmoji = (body?.containsOnlyEmoji == true)
        self.glyphCount = (body?.glyphCount ?? 0)
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
    }
    
    func with(
        state: Update<Interaction.State> = .useExisting,         // Optimistic outgoing messages
        mostRecentFailureText: Update<String?> = .useExisting,   // Optimistic outgoing messages
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
            body: body,
            rawBody: rawBody,
            timestampMs: timestampMs,
            receivedAtTimestampMs: receivedAtTimestampMs,
            expiresStartedAtMs: expiresStartedAtMs,
            expiresInSeconds: expiresInSeconds,
            attachments: attachments,
            reactionInfo: reactionInfo,
            profile: profile,
            quotedInfo: quotedInfo,
            linkPreview: linkPreview,
            linkPreviewAttachment: linkPreviewAttachment,
            proFeatures: proFeatures,
            authorName: authorName,
            authorNameSuppressedId: authorNameSuppressedId,
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
            currentUserSessionIds: currentUserSessionIds
        )
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

// MARK: - TypingIndicatorInfo

public extension MessageViewModel {
    struct TypingIndicatorInfo: FetchableRecordWithRowId, Decodable, Identifiable, Equatable, ColumnExpressible {
        public typealias Columns = CodingKeys
        public enum CodingKeys: String, CodingKey, ColumnExpression, CaseIterable {
            case rowId
            case threadId
        }
        
        public let rowId: Int64
        public let threadId: String
        
        // MARK: - Identifiable
        
        public var id: String { threadId }
    }
}

// MARK: - QuotedInfo

public extension MessageViewModel {
    struct QuotedInfo: Sendable, Equatable, Hashable {
        public let interactionId: Int64
        public let authorName: String
        public let timestampMs: Int64
        public let body: String?
        public let attachment: Attachment?
        public let proFeatures: SessionPro.Features
        
        // MARK: - Initialization
        
        public init(
            interactionId: Int64,
            authorName: String,
            timestampMs: Int64,
            body: String?,
            attachment: Attachment?,
            proFeatures: SessionPro.Features
        ) {
            self.interactionId = interactionId
            self.authorName = authorName
            self.timestampMs = timestampMs
            self.body = body
            self.attachment = attachment
            self.proFeatures = proFeatures
        }
        
        public init(previewBody: String) {
            self.body = previewBody
            
            /// This is a preview version so none of these values matter
            self.interactionId = -1
            self.authorName = ""
            self.timestampMs = 0
            self.attachment = nil
            self.proFeatures = .none
        }
        
        public init?(replyModel: QuotedReplyModel?, authorName: String?) {
            guard let model: QuotedReplyModel = replyModel else { return nil }
            
            self.authorName = (authorName ?? model.authorId.truncated())
            self.timestampMs = model.timestampMs
            self.body = model.body
            self.attachment = model.attachment
            self.proFeatures = model.proFeatures
            
            /// This is an optimistic version so none of these values exist yet
            self.interactionId = -1
        }
    }
}

// MARK: - Convenience

extension MessageViewModel {
    private static let maxMinutesBetweenTwoDateBreaks: Int = 5
    
    /// Returns the difference in minutes, ignoring seconds
    ///
    /// If both dates are the same date, returns 0
    /// If firstDate is one minute before secondDate, returns 1
    ///
    /// **Note:** Assumes both dates use the "current" calendar
    private static func minutesFrom(_ firstDate: Date, to secondDate: Date) -> Int? {
        let calendar: Calendar = Calendar.current
        let components1: DateComponents = calendar.dateComponents(
            [.era, .year, .month, .day, .hour, .minute],
            from: firstDate
        )
        let components2: DateComponents = calendar.dateComponents(
            [.era, .year, .month, .day, .hour, .minute],
            from: secondDate
        )
        
        guard
            let date1: Date = calendar.date(from: components1),
            let date2: Date = calendar.date(from: components2)
        else { return nil }
        
        return calendar.dateComponents([.minute], from: date1, to: date2).minute
    }
    
    fileprivate static func shouldShowDateBreak(between timestamp1: Int64, and timestamp2: Int64) -> Bool {
        let date1: Date = Date(timeIntervalSince1970: TimeInterval(Double(timestamp1) / 1000))
        let date2: Date = Date(timeIntervalSince1970: TimeInterval(Double(timestamp2) / 1000))
        
        return ((minutesFrom(date1, to: date2) ?? 0) > maxMinutesBetweenTwoDateBreaks)
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
        for originalInteractionIds: [Int64],
        currentUserSessionIds: Set<String>
    ) -> SQLRequest<FetchablePair<Int64, Int64>> {
        let interaction: TypedTableAlias<Interaction> = TypedTableAlias()
        let quote: TypedTableAlias<Quote> = TypedTableAlias()
        let quoteInteraction: TypedTableAlias<Interaction> = TypedTableAlias(name: "quoteInteraction")
        
        return """
            SELECT
                \(interaction[.id]) AS \(FetchablePair<Int64, Int64>.Columns.first),
                \(quoteInteraction[.id]) AS \(FetchablePair<Int64, Int64>.Columns.second)
            FROM \(Interaction.self)
            JOIN \(Quote.self) ON \(quote[.interactionId]) = \(interaction[.id])
            JOIN \(quoteInteraction) ON (
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

// MARK: - Construction

private extension MessageViewModel {
    static func cellType(
        interaction: Interaction,
        attachments: [Attachment]?
    ) -> MessageViewModel.CellType {
        guard !interaction.variant.isDeletedMessage else { return .textOnlyMessage }
        guard let attachment: Attachment = attachments?.first else { return .textOnlyMessage }

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

private extension Interaction {
    func body(
        threadId: String,
        threadVariant: SessionThread.Variant,
        authorDisplayName: String,
        attachments: [Attachment]?,
        linkPreview: LinkPreview?,
        profileCache: [String: Profile],
        using dependencies: Dependencies
    ) -> String? {
        guard variant.isInfoMessage else { return body }
        
        /// Info messages might not have a body so we should use the 'previewText' value instead
        return Interaction.previewText(
            variant: variant,
            body: body,
            threadContactDisplayName: Profile.displayName(
                for: threadVariant,
                id: threadId,
                name: profileCache[authorId]?.name,
                nickname: profileCache[authorId]?.nickname,
                suppressId: false   // Show the id next to the author name if desired
            ),
            authorDisplayName: authorDisplayName,
            attachmentDescriptionInfo: attachments?.first.map { firstAttachment in
                Attachment.DescriptionInfo(
                    id: firstAttachment.id,
                    variant: firstAttachment.variant,
                    contentType: firstAttachment.contentType,
                    sourceFilename: firstAttachment.sourceFilename
                )
            },
            attachmentCount: attachments?.count,
            isOpenGroupInvitation: (linkPreview?.variant == .openGroupInvitation),
            using: dependencies
        )
    }
    
    func linkPreview(
        linkPreviewCache: [String: [LinkPreview]],
        attachmentCache: [String: Attachment],
    ) -> (preview: LinkPreview, attachment: Attachment?)? {
        let preview: LinkPreview? = linkPreviewUrl.map { url -> LinkPreview? in
            /// Find all previews for the given url and sort by newest to oldest
            guard let possiblePreviews: [LinkPreview] = linkPreviewCache[url]?.sorted(by: { lhs, rhs in
                guard lhs.timestamp != rhs.timestamp else {
                    /// If the timestamps match then it's likely there is an optimistic link preview in the cache, so if one of the options
                    /// has an `attachmentId` then we should prioritise that one
                    switch (lhs.attachmentId, rhs.attachmentId) {
                        case (.some, .none): return true
                        case (.none, .some): return false
                        case (.some, .some), (.none, .none): return true    /// Whatever was added to the cache first wins
                    }
                }
                
                return lhs.timestamp > rhs.timestamp
            }) else { return nil }
            
            /// Try get the link preview for the time the message was sent
            let minTimestamp: TimeInterval = (TimeInterval(timestampMs / 1000) - LinkPreview.timstampResolution)
            let maxTimestamp: TimeInterval = (TimeInterval(timestampMs / 1000) + LinkPreview.timstampResolution)
            let targetPreview: LinkPreview? = possiblePreviews.first {
                $0.timestamp > minTimestamp &&
                $0.timestamp < maxTimestamp
            }
            
            /// Fallback to the newest preview
            return (targetPreview ?? possiblePreviews.first)
        }
        
        return preview.map { ($0, $0.attachmentId.map { attachmentCache[$0] }) }
    }
}
