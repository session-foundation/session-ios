// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import GRDB
import DifferenceKit
import SessionUIKit
import SessionUtilitiesKit

fileprivate typealias ViewModel = MessageViewModel
fileprivate typealias AttachmentInteractionInfo = MessageViewModel.AttachmentInteractionInfo
fileprivate typealias ReactionInfo = MessageViewModel.ReactionInfo
fileprivate typealias TypingIndicatorInfo = MessageViewModel.TypingIndicatorInfo
fileprivate typealias QuotedInfo = MessageViewModel.QuotedInfo

public struct QuoteViewModel: FetchableRecord, Decodable, Equatable, Hashable, Differentiable {
    fileprivate static let numberOfColumns: Int = 4
    
    public let interactionId: Int64
    public let authorId: String
    public let timestampMs: Int64
    public let body: String?
    
    public init(interactionId: Int64, authorId: String, timestampMs: Int64, body: String?) {
        self.interactionId = interactionId
        self.authorId = authorId
        self.timestampMs = timestampMs
        self.body = body
    }
}

// TODO: [Database Relocation] Refactor this to split database data from no-database data (to avoid unneeded nullables)
public struct MessageViewModel: FetchableRecordWithRowId, Decodable, Equatable, Hashable, Identifiable, Differentiable, ColumnExpressible {
    public typealias Columns = CodingKeys
    public enum CodingKeys: String, CodingKey, ColumnExpression, CaseIterable {
        case threadId
        case threadVariant
        case threadIsTrusted
        case threadExpirationType
        case threadExpirationTimer
        case threadOpenGroupServer
        case threadOpenGroupPublicKey
        case threadContactNameInternal

        // Interaction Info

        case rowId
        case id
        case serverHash
        case openGroupServerMessageId
        case variant
        case timestampMs
        case receivedAtTimestampMs
        case authorId
        case authorNameInternal
        case body
        case rawBody
        case expiresStartedAtMs
        case expiresInSeconds
        case isProMessage

        case state
        case hasBeenReadByRecipient
        case mostRecentFailureText
        case isSenderModeratorOrAdmin
        case isTypingIndicator
        case profile
        case quotedInfo
        case linkPreview
        case linkPreviewAttachment

        case currentUserSessionId

        // Post-Query Processing Data

        case attachments
        case reactionInfo
        case cellType
        case authorName
        case authorNameSuppressedId
        case senderName
        case canHaveProfile
        case shouldShowProfile
        case shouldShowDateHeader
        case containsOnlyEmoji
        case glyphCount
        case previousVariant
        case positionInCluster
        case isOnlyMessageInCluster
        case isLast
        case isLastOutgoing
        case currentUserSessionIds
        case optimisticMessageId
    }
    
    public enum CellType: Int, Decodable, Equatable, Hashable, DatabaseValueConvertible {
        case textOnlyMessage
        case mediaMessage
        case audio
        case voiceMessage
        case genericAttachment
        case typingIndicator
        case dateHeader
        case unreadMarker
        
        /// A number of the `CellType` entries are dynamically added to the dataset after processing, this flag indicates
        /// whether the given type is one of them
        public var isPostProcessed: Bool {
            switch self {
                case .typingIndicator, .dateHeader, .unreadMarker: return true
                default: return false
            }
        }
    }
    
    public var differenceIdentifier: Int64 { id }
    
    // Thread Info
    
    public let threadId: String
    public let threadVariant: SessionThread.Variant
    public let threadIsTrusted: Bool
    public let threadExpirationType: DisappearingMessagesConfiguration.DisappearingMessageType?
    public let threadExpirationTimer: TimeInterval?
    public let threadOpenGroupServer: String?
    public let threadOpenGroupPublicKey: String?
    private let threadContactNameInternal: String?
    
    // Interaction Info
    
    public let rowId: Int64
    public let id: Int64
    public let serverHash: String?
    public let openGroupServerMessageId: Int64?
    public let variant: Interaction.Variant
    public let timestampMs: Int64
    public let receivedAtTimestampMs: Int64
    public let authorId: String
    private let authorNameInternal: String?
    public let body: String?
    public let rawBody: String?
    public let expiresStartedAtMs: Double?
    public let expiresInSeconds: TimeInterval?
    public let isProMessage: Bool
    
    public let state: Interaction.State
    public let hasBeenReadByRecipient: Bool
    public let mostRecentFailureText: String?
    public let isSenderModeratorOrAdmin: Bool
    public let isTypingIndicator: Bool?
    public let profile: Profile?
    public let quotedInfo: QuotedInfo?
    public let linkPreview: LinkPreview?
    public let linkPreviewAttachment: Attachment?
    
    public let currentUserSessionId: String
    
    // Post-Query Processing Data
    
    /// This value includes the associated attachments
    public let attachments: [Attachment]?
    
    /// This value includes the associated reactions
    public let reactionInfo: [ReactionInfo]?
    
    /// This value defines what type of cell should appear and is generated based on the interaction variant
    /// and associated attachment data
    public let cellType: CellType
    
    /// This value includes the author name information
    public let authorName: String
    
    /// This value includes the author name information with the `id` suppressed (if it was present)
    public let authorNameSuppressedId: String

    /// This value will be used to populate the author label, if it's null then the label will be hidden
    ///
    /// **Note:** This will only be populated for incoming messages
    public let senderName: String?

    /// A flag indicating whether the profile view can be displayed
    public let canHaveProfile: Bool
    
    /// A flag indicating whether the profile view should be displayed
    public let shouldShowProfile: Bool

    /// A flag which controls whether the date header should be displayed
    public let shouldShowDateHeader: Bool
    
    /// This value will be used to populate the Context Menu and date header (if present)
    public var dateForUI: Date { Date(timeIntervalSince1970: TimeInterval(Double(self.timestampMs) / 1000)) }
    
    /// This value will be used to populate the Message Info (if present)
    public var receivedDateForUI: Date {
        Date(timeIntervalSince1970: TimeInterval(Double(self.receivedAtTimestampMs) / 1000))
    }
    
    /// This value specifies whether the body contains only emoji characters
    public let containsOnlyEmoji: Bool?
    
    /// This value specifies the number of emoji characters the body contains
    public let glyphCount: Int?
    
    /// This value indicates the variant of the previous ViewModel item, if it's null then there is no previous item
    public let previousVariant: Interaction.Variant?
    
    /// This value indicates the position of this message within a cluser of messages
    public let positionInCluster: Position
    
    /// This value indicates whether this is the only message in a cluser of messages
    public let isOnlyMessageInCluster: Bool
    
    /// This value indicates whether this is the last message in the thread
    public let isLast: Bool
    
    public let isLastOutgoing: Bool
    
    /// This contains all sessionId values for the current user (standard and any blinded variants)
    public let currentUserSessionIds: Set<String>?
    
    /// This is a temporary id used before an outgoing message is persisted into the database
    public let optimisticMessageId: UUID?

    // MARK: - Mutation
    
    public func with(
        state: Update<Interaction.State> = .useExisting,         // Optimistic outgoing messages
        mostRecentFailureText: Update<String?> = .useExisting,   // Optimistic outgoing messages
        profile: Update<Profile?> = .useExisting,
        quotedInfo: Update<QuotedInfo?> = .useExisting,           // Workaround for blinded current user
        attachments: Update<[Attachment]?> = .useExisting,
        reactionInfo: Update<[ReactionInfo]?> = .useExisting
    ) -> MessageViewModel {
        return MessageViewModel(
            threadId: self.threadId,
            threadVariant: self.threadVariant,
            threadIsTrusted: self.threadIsTrusted,
            threadExpirationType: self.threadExpirationType,
            threadExpirationTimer: self.threadExpirationTimer,
            threadOpenGroupServer: self.threadOpenGroupServer,
            threadOpenGroupPublicKey: self.threadOpenGroupPublicKey,
            threadContactNameInternal: self.threadContactNameInternal,
            rowId: self.rowId,
            id: self.id,
            serverHash: self.serverHash,
            openGroupServerMessageId: self.openGroupServerMessageId,
            variant: self.variant,
            timestampMs: self.timestampMs,
            receivedAtTimestampMs: self.receivedAtTimestampMs,
            authorId: self.authorId,
            authorNameInternal: self.authorNameInternal,
            body: self.body,
            rawBody: self.rawBody,
            expiresStartedAtMs: self.expiresStartedAtMs,
            expiresInSeconds: self.expiresInSeconds,
            isProMessage: self.isProMessage,
            state: state.or(self.state),
            hasBeenReadByRecipient: self.hasBeenReadByRecipient,
            mostRecentFailureText: mostRecentFailureText.or(self.mostRecentFailureText),
            isSenderModeratorOrAdmin: self.isSenderModeratorOrAdmin,
            isTypingIndicator: self.isTypingIndicator,
            profile: profile.or(self.profile),
            quotedInfo: quotedInfo.or(self.quotedInfo),
            linkPreview: self.linkPreview,
            linkPreviewAttachment: self.linkPreviewAttachment,
            currentUserSessionId: self.currentUserSessionId,
            attachments: attachments.or(self.attachments),
            reactionInfo: reactionInfo.or(self.reactionInfo),
            cellType: self.cellType,
            authorName: self.authorName,
            authorNameSuppressedId: self.authorNameSuppressedId,
            senderName: self.senderName,
            canHaveProfile: self.canHaveProfile,
            shouldShowProfile: self.shouldShowProfile,
            shouldShowDateHeader: self.shouldShowDateHeader,
            containsOnlyEmoji: self.containsOnlyEmoji,
            glyphCount: self.glyphCount,
            previousVariant: self.previousVariant,
            positionInCluster: self.positionInCluster,
            isOnlyMessageInCluster: self.isOnlyMessageInCluster,
            isLast: self.isLast,
            isLastOutgoing: self.isLastOutgoing,
            currentUserSessionIds: self.currentUserSessionIds,
            optimisticMessageId: self.optimisticMessageId
        )
    }
    
    public func withClusteringChanges(
        prevModel: MessageViewModel?,
        nextModel: MessageViewModel?,
        isLast: Bool,
        isLastOutgoing: Bool,
        currentUserSessionIds: Set<String>,
        currentUserProfile: Profile,
        threadIsTrusted: Bool,
        using dependencies: Dependencies
    ) -> MessageViewModel {
        let cellType: CellType = {
            guard self.isTypingIndicator != true else { return .typingIndicator }
            guard !self.variant.isDeletedMessage else { return .textOnlyMessage }
            guard let attachment: Attachment = self.attachments?.first else { return .textOnlyMessage }

            // The only case which currently supports multiple attachments is a 'mediaMessage'
            // (the album view)
            guard self.attachments?.count == 1 else { return .mediaMessage }

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
        }()
        // TODO: [Database Relocation] Clean up `currentUserProfile` logic (profile data should be sourced from a separate query for efficiency)
        let authorDisplayName: String = {
            guard authorId != currentUserProfile.id else {
                return currentUserProfile.displayName(
                    for: self.threadVariant,
                    ignoringNickname: true,    // Current user has no nickname
                    suppressId: false          // Show the id next to the author name if desired
                )
            }
            
            return Profile.displayName(
                for: self.threadVariant,
                id: self.authorId,
                name: self.authorNameInternal,
                nickname: nil,      // Folded into 'authorName' within the Query
                suppressId: false   // Show the id next to the author name if desired
            )
        }()
        let authorDisplayNameSuppressedId: String = {
            guard authorId != currentUserProfile.id else {
                return currentUserProfile.displayName(
                    for: self.threadVariant,
                    ignoringNickname: true,    // Current user has no nickname
                    suppressId: true          // Exclude the id next to the author name
                )
            }
            
            return Profile.displayName(
                for: self.threadVariant,
                id: self.authorId,
                name: self.authorNameInternal,
                nickname: nil,      // Folded into 'authorName' within the Query
                suppressId: true   // Exclude the id next to the author name
            )
        }()
        let shouldShowDateBeforeThisModel: Bool = {
            guard self.isTypingIndicator != true else { return false }
            guard self.variant != .infoCall else { return true }    // Always show on calls
            guard !self.variant.isInfoMessage else { return false } // Never show on info messages
            guard let prevModel: ViewModel = prevModel else { return true }
            
            return MessageViewModel.shouldShowDateBreak(
                between: prevModel.timestampMs,
                and: self.timestampMs
            )
        }()
        let shouldShowDateBeforeNextModel: Bool = {
            // Should be nothing after a typing indicator
            guard self.isTypingIndicator != true else { return false }
            guard let nextModel: ViewModel = nextModel else { return false }

            return MessageViewModel.shouldShowDateBreak(
                between: self.timestampMs,
                and: nextModel.timestampMs
            )
        }()
        let (positionInCluster, isOnlyMessageInCluster): (Position, Bool) = {
            let isFirstInCluster: Bool = (
                self.variant.isInfoMessage ||
                prevModel == nil ||
                shouldShowDateBeforeThisModel || (
                    self.variant.isOutgoing &&
                    prevModel?.variant.isOutgoing != true
                ) || (
                    self.variant.isIncoming &&
                    prevModel?.variant.isIncoming != true
                ) ||
                self.authorId != prevModel?.authorId
            )
            let isLastInCluster: Bool = (
                self.variant.isInfoMessage ||
                nextModel == nil ||
                shouldShowDateBeforeNextModel || (
                    self.variant.isOutgoing &&
                    prevModel?.variant.isOutgoing != true
                ) || (
                    self.variant.isIncoming &&
                    prevModel?.variant.isIncoming != true
                ) ||
                self.authorId != nextModel?.authorId
            )

            let isOnlyMessageInCluster: Bool = (isFirstInCluster && isLastInCluster)

            switch (isFirstInCluster, isLastInCluster) {
                case (true, true), (false, false): return (.middle, isOnlyMessageInCluster)
                case (true, false): return (.top, isOnlyMessageInCluster)
                case (false, true): return (.bottom, isOnlyMessageInCluster)
            }
        }()
        let isGroupThread: Bool = (
            self.threadVariant == .community ||
            self.threadVariant == .legacyGroup ||
            self.threadVariant == .group
        )
        
        return ViewModel(
            threadId: self.threadId,
            threadVariant: self.threadVariant,
            threadIsTrusted: (threadIsTrusted || self.threadIsTrusted),
            threadExpirationType: self.threadExpirationType,
            threadExpirationTimer: self.threadExpirationTimer,
            threadOpenGroupServer: self.threadOpenGroupServer,
            threadOpenGroupPublicKey: self.threadOpenGroupPublicKey,
            threadContactNameInternal: self.threadContactNameInternal,
            rowId: self.rowId,
            id: self.id,
            serverHash: self.serverHash,
            openGroupServerMessageId: self.openGroupServerMessageId,
            variant: self.variant,
            timestampMs: self.timestampMs,
            receivedAtTimestampMs: self.receivedAtTimestampMs,
            authorId: self.authorId,
            authorNameInternal: (self.threadId == currentUserProfile.id ?
                "you".localized() :
                self.authorNameInternal
            ),
            body: (!self.variant.isInfoMessage ?
                self.body :
                // Info messages might not have a body so we should use the 'previewText' value instead
                Interaction.previewText(
                    variant: self.variant,
                    body: self.body,
                    threadContactDisplayName: Profile.displayName(
                        for: self.threadVariant,
                        id: self.threadId,
                        name: self.threadContactNameInternal,
                        nickname: nil,      // Folded into 'threadContactNameInternal' within the Query
                        suppressId: false   // Show the id next to the author name if desired
                    ),
                    authorDisplayName: authorDisplayName,
                    attachmentDescriptionInfo: self.attachments?.first.map { firstAttachment in
                        Attachment.DescriptionInfo(
                            id: firstAttachment.id,
                            variant: firstAttachment.variant,
                            contentType: firstAttachment.contentType,
                            sourceFilename: firstAttachment.sourceFilename
                        )
                    },
                    attachmentCount: self.attachments?.count,
                    isOpenGroupInvitation: (self.linkPreview?.variant == .openGroupInvitation),
                    using: dependencies
                )
            ),
            rawBody: self.body,
            expiresStartedAtMs: self.expiresStartedAtMs,
            expiresInSeconds: self.expiresInSeconds,
            isProMessage: self.isProMessage,
            state: self.state,
            hasBeenReadByRecipient: self.hasBeenReadByRecipient,
            mostRecentFailureText: self.mostRecentFailureText,
            isSenderModeratorOrAdmin: self.isSenderModeratorOrAdmin,
            isTypingIndicator: self.isTypingIndicator,
            profile: (self.profile?.id == currentUserProfile.id ? currentUserProfile : self.profile),
            quotedInfo: self.quotedInfo,
            linkPreview: self.linkPreview,
            linkPreviewAttachment: self.linkPreviewAttachment,
            currentUserSessionId: self.currentUserSessionId,
            attachments: self.attachments,
            reactionInfo: self.reactionInfo,
            cellType: cellType,
            authorName: authorDisplayName,
            authorNameSuppressedId: authorDisplayNameSuppressedId,
            senderName: {
                // Only show for group threads
                guard isGroupThread else { return nil }
                
                // Only show for incoming messages
                guard self.variant.isIncoming else { return nil }
                    
                // Only if there is a date header or the senders are different
                guard
                    shouldShowDateBeforeThisModel ||
                    self.authorId != prevModel?.authorId ||
                    prevModel?.variant.isInfoMessage == true
                else { return nil }
                    
                return authorDisplayName
            }(),
            canHaveProfile: (
                // Only group threads and incoming messages
                isGroupThread &&
                self.variant.isIncoming
            ),
            shouldShowProfile: (
                // Only group threads
                isGroupThread &&
                
                // Only incoming messages
                self.variant.isIncoming &&
                
                // Show if the next message has a different sender, isn't a standard message or has a "date break"
                (
                    self.authorId != nextModel?.authorId ||
                    nextModel?.variant.isIncoming != true ||
                    shouldShowDateBeforeNextModel
                ) &&
                
                // Need a profile to be able to show it
                self.profile != nil
            ),
            shouldShowDateHeader: shouldShowDateBeforeThisModel,
            containsOnlyEmoji: self.body?.containsOnlyEmoji,
            glyphCount: self.body?.glyphCount,
            previousVariant: prevModel?.variant,
            positionInCluster: positionInCluster,
            isOnlyMessageInCluster: isOnlyMessageInCluster,
            isLast: isLast,
            isLastOutgoing: isLastOutgoing,
            currentUserSessionIds: currentUserSessionIds,
            optimisticMessageId: self.optimisticMessageId
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
    
    func threadDisappearingConfiguration() -> DisappearingMessagesConfiguration {
        return DisappearingMessagesConfiguration
            .defaultWith(self.threadId)
            .with(
                isEnabled: (self.threadExpirationTimer ?? 0) > 0,
                durationSeconds: self.threadExpirationTimer,
                type: self.threadExpirationType
            )
    }
    
    func canDoFollowingSetting() -> Bool {
        guard self.variant == .infoDisappearingMessagesUpdate else { return false }
        guard self.authorId != self.currentUserSessionId else { return false }
        guard self.threadVariant == .contact else { return false }
        return self.messageDisappearingConfiguration() != self.threadDisappearingConfiguration()
    }
}

// MARK: - AttachmentInteractionInfo

public extension MessageViewModel {
    struct AttachmentInteractionInfo: FetchableRecordWithRowId, Decodable, Identifiable, Equatable, Comparable, ColumnExpressible {
        public typealias Columns = CodingKeys
        public enum CodingKeys: String, CodingKey, ColumnExpression, CaseIterable {
            case rowId
            case attachment
            case interactionAttachment
        }
        
        public let rowId: Int64
        public let attachment: Attachment
        public let interactionAttachment: InteractionAttachment
        
        // MARK: - Identifiable
        
        public var id: String {
            "\(interactionAttachment.interactionId)-\(interactionAttachment.albumIndex)"
        }
        
        // MARK: - Comparable
        
        public static func < (lhs: AttachmentInteractionInfo, rhs: AttachmentInteractionInfo) -> Bool {
            return (lhs.interactionAttachment.albumIndex < rhs.interactionAttachment.albumIndex)
        }
    }
}

// MARK: - ReactionInfo

public extension MessageViewModel {
    struct ReactionInfo: FetchableRecordWithRowId, Decodable, Identifiable, Equatable, Comparable, Hashable, Differentiable, ColumnExpressible {
        public typealias Columns = CodingKeys
        public enum CodingKeys: String, CodingKey, ColumnExpression, CaseIterable {
            case rowId
            case reaction
            case profile
        }
        
        public let rowId: Int64
        public let reaction: Reaction
        public let profile: Profile?
        
        // MARK: - Identifiable
        
        public var differenceIdentifier: String { return id }
        
        public var id: String {
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
    struct QuotedInfo: FetchableRecordWithRowId, Decodable, Identifiable, Equatable, Hashable, ColumnExpressible {
        public typealias Columns = CodingKeys
        public enum CodingKeys: String, CodingKey, ColumnExpression, CaseIterable {
            case rowId
            case interactionId
            case authorId
            case timestampMs
            case body
            case attachment
            case quotedInteractionId
            case quotedInteractionVariant
        }
        
        public let rowId: Int64
        public let interactionId: Int64
        public let authorId: String
        public let timestampMs: Int64
        public let body: String?
        public let attachment: Attachment?
        public let quotedInteractionId: Int64
        public let quotedInteractionVariant: Interaction.Variant
        
        // MARK: - Identifiable
        
        public var id: String { "quote-\(interactionId)-attachment_\(attachment?.id ?? "None")" }
        
        // MARK: - Initialization
        
        public init(previewBody: String) {
            self.body = previewBody
            
            /// This is an preview version so none of these values matter
            self.rowId = -1
            self.interactionId = -1
            self.authorId = ""
            self.timestampMs = 0
            self.attachment = nil
            self.quotedInteractionId = -1
            self.quotedInteractionVariant = .standardOutgoing
        }
        
        public init?(replyModel: QuotedReplyModel?) {
            guard let model: QuotedReplyModel = replyModel else { return nil }
            
            self.authorId = model.authorId
            self.timestampMs = model.timestampMs
            self.body = model.body
            self.attachment = model.attachment
            
            /// This is an optimistic version so none of these values exist yet
            self.rowId = -1
            self.interactionId = -1
            self.quotedInteractionId = -1
            self.quotedInteractionVariant = .standardOutgoing
        }
    }
}

// MARK: - Convenience Initialization

public extension MessageViewModel {
    static let genericId: Int64 = -1
    static let typingIndicatorId: Int64 = -2
    static let optimisticUpdateId: Int64 = -3
    
    /// This init method is only used for system-created cells or empty states
    init(
        variant: Interaction.Variant = .standardOutgoing,
        timestampMs: Int64 = Int64.max,
        receivedAtTimestampMs: Int64 = Int64.max,
        body: String? = nil,
        quotedInfo: QuotedInfo? = nil,
        cellType: CellType = .typingIndicator,
        isTypingIndicator: Bool? = nil,
        isLast: Bool = true,
        isLastOutgoing: Bool = false
    ) {
        self.threadId = "INVALID_THREAD_ID"
        self.threadVariant = .contact
        self.threadIsTrusted = false
        self.threadExpirationType = nil
        self.threadExpirationTimer = nil
        self.threadOpenGroupServer = nil
        self.threadOpenGroupPublicKey = nil
        self.threadContactNameInternal = nil
        
        // Interaction Info
        
        let targetId: Int64 = {
            guard isTypingIndicator != true else { return MessageViewModel.typingIndicatorId }
            guard cellType != .dateHeader else { return -timestampMs }
            
            return MessageViewModel.genericId
        }()
        self.rowId = targetId
        self.id = targetId
        self.serverHash = nil
        self.openGroupServerMessageId = nil
        self.variant = variant
        self.timestampMs = timestampMs
        self.receivedAtTimestampMs = receivedAtTimestampMs
        self.authorId = ""
        self.authorNameInternal = nil
        self.body = body
        self.rawBody = nil
        self.expiresStartedAtMs = nil
        self.expiresInSeconds = nil
        self.isProMessage = false
        
        self.state = .sent
        self.hasBeenReadByRecipient = false
        self.mostRecentFailureText = nil
        self.isSenderModeratorOrAdmin = false
        self.isTypingIndicator = isTypingIndicator
        self.profile = nil
        self.quotedInfo = quotedInfo
        self.linkPreview = nil
        self.linkPreviewAttachment = nil
        self.currentUserSessionId = ""
        self.attachments = nil
        self.reactionInfo = nil
        
        // Post-Query Processing Data
        
        self.cellType = cellType
        self.authorName = ""
        self.authorNameSuppressedId = ""
        self.senderName = nil
        self.canHaveProfile = false
        self.shouldShowProfile = false
        self.shouldShowDateHeader = false
        self.containsOnlyEmoji = nil
        self.glyphCount = nil
        self.previousVariant = nil
        self.positionInCluster = .middle
        self.isOnlyMessageInCluster = true
        self.isLast = isLast
        self.isLastOutgoing = isLastOutgoing
        self.currentUserSessionIds = [currentUserSessionId]
        self.optimisticMessageId = nil
    }
    
    /// This init method is only used for optimistic outgoing messages
    init(
        optimisticMessageId: UUID,
        threadId: String,
        threadVariant: SessionThread.Variant,
        threadExpirationType: DisappearingMessagesConfiguration.DisappearingMessageType?,
        threadExpirationTimer: TimeInterval?,
        threadOpenGroupServer: String?,
        threadOpenGroupPublicKey: String?,
        threadContactNameInternal: String,
        timestampMs: Int64,
        receivedAtTimestampMs: Int64,
        authorId: String,
        authorNameInternal: String,
        body: String?,
        expiresStartedAtMs: Double?,
        expiresInSeconds: TimeInterval?,
        isProMessage: Bool,
        state: Interaction.State = .sending,
        isSenderModeratorOrAdmin: Bool,
        currentUserProfile: Profile,
        quotedInfo: QuotedInfo?,
        linkPreview: LinkPreview?,
        linkPreviewAttachment: Attachment?,
        attachments: [Attachment]?
    ) {
        self.threadId = threadId
        self.threadVariant = threadVariant
        self.threadIsTrusted = false
        self.threadExpirationType = threadExpirationType
        self.threadExpirationTimer = threadExpirationTimer
        self.threadOpenGroupServer = threadOpenGroupServer
        self.threadOpenGroupPublicKey = threadOpenGroupPublicKey
        self.threadContactNameInternal = threadContactNameInternal
        
        // Interaction Info
        
        self.rowId = MessageViewModel.optimisticUpdateId
        self.id = MessageViewModel.optimisticUpdateId
        self.serverHash = nil
        self.openGroupServerMessageId = nil
        self.variant = .standardOutgoing
        self.timestampMs = timestampMs
        self.receivedAtTimestampMs = receivedAtTimestampMs
        self.authorId = authorId
        self.authorNameInternal = authorNameInternal
        self.body = body
        self.rawBody = body
        self.expiresStartedAtMs = expiresStartedAtMs
        self.expiresInSeconds = expiresInSeconds
        self.isProMessage = isProMessage
        
        self.state = state
        self.hasBeenReadByRecipient = false
        self.mostRecentFailureText = nil
        self.isSenderModeratorOrAdmin = isSenderModeratorOrAdmin
        self.isTypingIndicator = false
        self.profile = currentUserProfile
        self.quotedInfo = quotedInfo
        self.linkPreview = linkPreview
        self.linkPreviewAttachment = linkPreviewAttachment
        self.currentUserSessionId = currentUserProfile.id
        self.attachments = attachments
        self.reactionInfo = nil
        
        // Post-Query Processing Data
        
        self.cellType = .textOnlyMessage
        self.authorName = ""
        self.authorNameSuppressedId = ""
        self.senderName = nil
        self.canHaveProfile = false
        self.shouldShowProfile = false
        self.shouldShowDateHeader = false
        self.containsOnlyEmoji = nil
        self.glyphCount = nil
        self.previousVariant = nil
        self.positionInCluster = .middle
        self.isOnlyMessageInCluster = true
        self.isLast = false
        self.isLastOutgoing = false
        self.currentUserSessionIds = [currentUserProfile.id]
        self.optimisticMessageId = optimisticMessageId
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

// MARK: - ConversationVC

// MARK: --MessageViewModel

public extension MessageViewModel {
    static func filterSQL(threadId: String) -> SQL {
        let interaction: TypedTableAlias<Interaction> = TypedTableAlias()
        
        return SQL("\(interaction[.threadId]) = \(threadId)")
    }
    
    static let groupSQL: SQL = {
        let interaction: TypedTableAlias<Interaction> = TypedTableAlias()
        
        return SQL("GROUP BY \(interaction[.id])")
    }()
    
    static let orderSQL: SQL = {
        let interaction: TypedTableAlias<Interaction> = TypedTableAlias()
        
        return SQL("\(interaction[.timestampMs].desc)")
    }()
    
    static func baseQuery(
        userSessionId: SessionId,
        currentUserSessionIds: Set<String>,
        orderSQL: SQL,
        groupSQL: SQL?
    ) -> (([Int64]) -> AdaptedFetchRequest<SQLRequest<MessageViewModel>>) {
        return { rowIds -> AdaptedFetchRequest<SQLRequest<ViewModel>> in
            let interaction: TypedTableAlias<Interaction> = TypedTableAlias()
            let thread: TypedTableAlias<SessionThread> = TypedTableAlias()
            let openGroup: TypedTableAlias<OpenGroup> = TypedTableAlias()
            let groupMember: TypedTableAlias<GroupMember> = TypedTableAlias()
            let contact: TypedTableAlias<Contact> = TypedTableAlias()
            let disappearingMessagesConfig: TypedTableAlias<DisappearingMessagesConfiguration> = TypedTableAlias()
            let profile: TypedTableAlias<Profile> = TypedTableAlias()
            let threadProfile: TypedTableAlias<Profile> = TypedTableAlias(name: "threadProfile")
            let linkPreview: TypedTableAlias<LinkPreview> = TypedTableAlias()
            let linkPreviewAttachment: TypedTableAlias<Attachment> = TypedTableAlias(ViewModel.self, column: .linkPreviewAttachment)
            
            let numColumnsBeforeLinkedRecords: Int = 25
            let finalGroupSQL: SQL = (groupSQL ?? "")
            let request: SQLRequest<ViewModel> = """
                SELECT
                    \(thread[.id]) AS \(ViewModel.Columns.threadId),
                    \(thread[.variant]) AS \(ViewModel.Columns.threadVariant),
                    -- Default to 'true' for non-contact threads
                    IFNULL(\(contact[.isTrusted]), true) AS \(ViewModel.Columns.threadIsTrusted),
                    \(disappearingMessagesConfig[.type]) AS \(ViewModel.Columns.threadExpirationType),
                    \(disappearingMessagesConfig[.durationSeconds]) AS \(ViewModel.Columns.threadExpirationTimer),
                    \(openGroup[.server]) AS \(ViewModel.Columns.threadOpenGroupServer),
                    \(openGroup[.publicKey]) AS \(ViewModel.Columns.threadOpenGroupPublicKey),
                    IFNULL(\(threadProfile[.nickname]), \(threadProfile[.name])) AS \(ViewModel.Columns.threadContactNameInternal),
            
                    \(interaction[.rowId]) AS \(ViewModel.Columns.rowId),
                    \(interaction[.id]),
                    \(interaction[.serverHash]),
                    \(interaction[.openGroupServerMessageId]),
                    \(interaction[.variant]),
                    \(interaction[.timestampMs]),
                    \(interaction[.receivedAtTimestampMs]),
                    \(interaction[.authorId]),
                    IFNULL(\(profile[.nickname]), \(profile[.name])) AS \(ViewModel.Columns.authorNameInternal),
                    \(interaction[.body]),
                    \(interaction[.expiresStartedAtMs]),
                    \(interaction[.expiresInSeconds]),
                    \(interaction[.isProMessage]),
                    \(interaction[.state]),
                    (\(interaction[.recipientReadTimestampMs]) IS NOT NULL) AS \(ViewModel.Columns.hasBeenReadByRecipient),
                    \(interaction[.mostRecentFailureText]),
                    
                    EXISTS (
                        SELECT 1
                        FROM \(GroupMember.self)
                        WHERE (
                            \(groupMember[.groupId]) = \(interaction[.threadId]) AND
                            \(groupMember[.profileId]) = \(interaction[.authorId]) AND
                            \(SQL("\(groupMember[.role]) IN \([GroupMember.Role.moderator, GroupMember.Role.admin])"))
                        )
                    ) AS \(ViewModel.Columns.isSenderModeratorOrAdmin),
            
                    \(profile.allColumns),
                    \(linkPreview.allColumns),
                    \(linkPreviewAttachment.allColumns),
                    
                    \(SQL("\(userSessionId.hexString)")) AS \(ViewModel.Columns.currentUserSessionId),
            
                    -- All of the below properties are set in post-query processing but to prevent the
                    -- query from crashing when decoding we need to provide default values
                    \(CellType.textOnlyMessage) AS \(ViewModel.Columns.cellType),
                    '' AS \(ViewModel.Columns.authorName),
                    '' AS \(ViewModel.Columns.authorNameSuppressedId),
                    false AS \(ViewModel.Columns.canHaveProfile),
                    false AS \(ViewModel.Columns.shouldShowProfile),
                    false AS \(ViewModel.Columns.shouldShowDateHeader),
                    \(Position.middle) AS \(ViewModel.Columns.positionInCluster),
                    false AS \(ViewModel.Columns.isOnlyMessageInCluster),
                    false AS \(ViewModel.Columns.isLast),
                    false AS \(ViewModel.Columns.isLastOutgoing)
                
                FROM \(Interaction.self)
                JOIN \(SessionThread.self) ON \(thread[.id]) = \(interaction[.threadId])
                LEFT JOIN \(Contact.self) ON \(contact[.id]) = \(interaction[.threadId])
                LEFT JOIN \(threadProfile) ON \(threadProfile[.id]) = \(interaction[.threadId])
                LEFT JOIN \(DisappearingMessagesConfiguration.self) ON \(disappearingMessagesConfig[.threadId]) = \(interaction[.threadId])
                LEFT JOIN \(OpenGroup.self) ON \(openGroup[.threadId]) = \(interaction[.threadId])
                LEFT JOIN \(Profile.self) ON \(profile[.id]) = \(interaction[.authorId])
            
                LEFT JOIN \(LinkPreview.self) ON (
                    \(linkPreview[.url]) = \(interaction[.linkPreviewUrl]) AND
                    \(Interaction.linkPreviewFilterLiteral())
                )
                LEFT JOIN \(linkPreviewAttachment) ON \(linkPreviewAttachment[.id]) = \(linkPreview[.attachmentId])
                
                WHERE \(interaction[.rowId]) IN \(rowIds)
                \(finalGroupSQL)
                ORDER BY \(orderSQL)
            """
            
            return request.adapted { db in
                let adapters = try splittingRowAdapters(columnCounts: [
                    numColumnsBeforeLinkedRecords,
                    Profile.numberOfSelectedColumns(db),
                    LinkPreview.numberOfSelectedColumns(db),
                    Attachment.numberOfSelectedColumns(db)
                ])
                
                return ScopeAdapter.with(ViewModel.self, [
                    .profile: adapters[1],
                    .linkPreview: adapters[2],
                    .linkPreviewAttachment: adapters[3]
                ])
            }
        }
    }
}

// MARK: --AttachmentInteractionInfo

public extension MessageViewModel.AttachmentInteractionInfo {
    static let baseQuery: ((SQL?) -> AdaptedFetchRequest<SQLRequest<MessageViewModel.AttachmentInteractionInfo>>) = {
        return { additionalFilters -> AdaptedFetchRequest<SQLRequest<AttachmentInteractionInfo>> in
            let attachment: TypedTableAlias<Attachment> = TypedTableAlias()
            let interactionAttachment: TypedTableAlias<InteractionAttachment> = TypedTableAlias()
            
            let finalFilterSQL: SQL = {
                guard let additionalFilters: SQL = additionalFilters else {
                    return SQL(stringLiteral: "")
                }
                
                return """
                    WHERE \(additionalFilters)
                """
            }()
            let numColumnsBeforeLinkedRecords: Int = 1
            let request: SQLRequest<AttachmentInteractionInfo> = """
                SELECT
                    \(attachment[.rowId]) AS \(AttachmentInteractionInfo.Columns.rowId),
                    \(attachment.allColumns),
                    \(interactionAttachment.allColumns)
                FROM \(Attachment.self)
                JOIN \(InteractionAttachment.self) ON \(interactionAttachment[.attachmentId]) = \(attachment[.id])
                \(finalFilterSQL)
            """
            
            return request.adapted { db in
                let adapters = try splittingRowAdapters(columnCounts: [
                    numColumnsBeforeLinkedRecords,
                    Attachment.numberOfSelectedColumns(db),
                    InteractionAttachment.numberOfSelectedColumns(db)
                ])
                
                return ScopeAdapter.with(AttachmentInteractionInfo.self, [
                    .attachment: adapters[1],
                    .interactionAttachment: adapters[2]
                ])
            }
        }
    }()
    
    static var joinToViewModelQuerySQL: SQL = {
        let interaction: TypedTableAlias<Interaction> = TypedTableAlias()
        let attachment: TypedTableAlias<Attachment> = TypedTableAlias()
        let interactionAttachment: TypedTableAlias<InteractionAttachment> = TypedTableAlias()
        
        return """
            JOIN \(InteractionAttachment.self) ON \(interactionAttachment[.interactionId]) = \(interaction[.id])
            JOIN \(Attachment.self) ON \(attachment[.id]) = \(interactionAttachment[.attachmentId])
        """
    }()
    
    static func createAssociateDataClosure() -> (DataCache<MessageViewModel.AttachmentInteractionInfo>, DataCache<MessageViewModel>) -> DataCache<MessageViewModel> {
        return { dataCache, pagedDataCache -> DataCache<MessageViewModel> in
            var updatedPagedDataCache: DataCache<MessageViewModel> = pagedDataCache
            
            dataCache
                .values
                .grouped(by: \.interactionAttachment.interactionId)
                .forEach { (interactionId: Int64, attachments: [MessageViewModel.AttachmentInteractionInfo]) in
                    guard
                        let interactionRowId: Int64 = updatedPagedDataCache.lookup[interactionId],
                        let dataToUpdate: ViewModel = updatedPagedDataCache.data[interactionRowId]
                    else { return }
                    
                    updatedPagedDataCache = updatedPagedDataCache.upserting(
                        dataToUpdate.with(
                            attachments: .set(to: attachments
                                .sorted()
                                .map { $0.attachment })
                        )
                    )
                }
            
            return updatedPagedDataCache
        }
    }
}

// MARK: --ReactionInfo

public extension MessageViewModel.ReactionInfo {
    static let baseQuery: ((SQL?) -> AdaptedFetchRequest<SQLRequest<MessageViewModel.ReactionInfo>>) = {
        return { additionalFilters -> AdaptedFetchRequest<SQLRequest<ReactionInfo>> in
            let reaction: TypedTableAlias<Reaction> = TypedTableAlias()
            let profile: TypedTableAlias<Profile> = TypedTableAlias()
            
            let finalFilterSQL: SQL = {
                guard let additionalFilters: SQL = additionalFilters else {
                    return SQL(stringLiteral: "")
                }
                
                return """
                    WHERE \(additionalFilters)
                """
            }()
            let numColumnsBeforeLinkedRecords: Int = 1
            let request: SQLRequest<ReactionInfo> = """
                SELECT
                    \(reaction[.rowId]) AS \(ReactionInfo.Columns.rowId),
                    \(reaction.allColumns),
                    \(profile.allColumns)
                FROM \(Reaction.self)
                LEFT JOIN \(Profile.self) ON \(profile[.id]) = \(reaction[.authorId])
                \(finalFilterSQL)
            """
            
            return request.adapted { db in
                let adapters = try splittingRowAdapters(columnCounts: [
                    numColumnsBeforeLinkedRecords,
                    Reaction.numberOfSelectedColumns(db),
                    Profile.numberOfSelectedColumns(db)
                ])
                
                return ScopeAdapter.with(ReactionInfo.self, [
                    .reaction: adapters[1],
                    .profile: adapters[2]
                ])
            }
        }
    }()
    
    static var joinToViewModelQuerySQL: SQL = {
        let interaction: TypedTableAlias<Interaction> = TypedTableAlias()
        let reaction: TypedTableAlias<Reaction> = TypedTableAlias()
        
        return """
            JOIN \(Reaction.self) ON \(reaction[.interactionId]) = \(interaction[.id])
        """
    }()
    
    static func createAssociateDataClosure() -> (DataCache<MessageViewModel.ReactionInfo>, DataCache<MessageViewModel>) -> DataCache<MessageViewModel> {
        return { dataCache, pagedDataCache -> DataCache<MessageViewModel> in
            var updatedPagedDataCache: DataCache<MessageViewModel> = pagedDataCache
            var pagedRowIdsWithNoReactions: Set<Int64> = Set(pagedDataCache.data.keys)
            
            // Add any new reactions
            dataCache
                .values
                .grouped(by: \.reaction.interactionId)
                .forEach { (interactionId: Int64, reactionInfo: [MessageViewModel.ReactionInfo]) in
                    guard
                        let interactionRowId: Int64 = updatedPagedDataCache.lookup[interactionId],
                        let dataToUpdate: ViewModel = updatedPagedDataCache.data[interactionRowId]
                    else { return }
                    
                    updatedPagedDataCache = updatedPagedDataCache.upserting(
                        dataToUpdate.with(reactionInfo: .set(to: reactionInfo.sorted()))
                    )
                    pagedRowIdsWithNoReactions.remove(interactionRowId)
                }
            
            // Remove any removed reactions
            updatedPagedDataCache = updatedPagedDataCache.upserting(
                items: pagedRowIdsWithNoReactions
                    .compactMap { rowId -> ViewModel? in updatedPagedDataCache.data[rowId] }
                    .filter { viewModel -> Bool in (viewModel.reactionInfo?.isEmpty == false) }
                    .map { viewModel -> ViewModel in viewModel.with(reactionInfo: .set(to: nil)) }
            )
            
            return updatedPagedDataCache
        }
    }
}

// MARK: --TypingIndicatorInfo

public extension MessageViewModel.TypingIndicatorInfo {
    static let baseQuery: ((SQL?) -> SQLRequest<MessageViewModel.TypingIndicatorInfo>) = {
        return { additionalFilters -> SQLRequest<TypingIndicatorInfo> in
            let threadTypingIndicator: TypedTableAlias<ThreadTypingIndicator> = TypedTableAlias()
            let finalFilterSQL: SQL = {
                guard let additionalFilters: SQL = additionalFilters else {
                    return SQL(stringLiteral: "")
                }
                
                return """
                    WHERE \(additionalFilters)
                """
            }()
            let request: SQLRequest<MessageViewModel.TypingIndicatorInfo> = """
                SELECT
                    \(threadTypingIndicator[.rowId]),
                    \(threadTypingIndicator[.threadId])
                FROM \(ThreadTypingIndicator.self)
                \(finalFilterSQL)
            """
            
            return request
        }
    }()
    
    static var joinToViewModelQuerySQL: SQL = {
        let interaction: TypedTableAlias<Interaction> = TypedTableAlias()
        let threadTypingIndicator: TypedTableAlias<ThreadTypingIndicator> = TypedTableAlias()
        
        return """
            JOIN \(ThreadTypingIndicator.self) ON \(threadTypingIndicator[.threadId]) = \(interaction[.threadId])
        """
    }()
    
    static func createAssociateDataClosure() -> (DataCache<MessageViewModel.TypingIndicatorInfo>, DataCache<MessageViewModel>) -> DataCache<MessageViewModel> {
        return { dataCache, pagedDataCache -> DataCache<MessageViewModel> in
            guard !dataCache.data.isEmpty else {
                return pagedDataCache.deleting(rowIds: [MessageViewModel.typingIndicatorId])
            }
            
            return pagedDataCache
                .upserting(MessageViewModel(isTypingIndicator: true))
        }
    }
}

// MARK: --QuotedInfo

public extension MessageViewModel.QuotedInfo {
    static func baseQuery(
        userSessionId: SessionId,
        currentUserSessionIds: Set<String>
    ) -> ((SQL?) -> AdaptedFetchRequest<SQLRequest<MessageViewModel.QuotedInfo>>) {
        return { additionalFilters -> AdaptedFetchRequest<SQLRequest<QuotedInfo>> in
            let quote: TypedTableAlias<Quote> = TypedTableAlias()
            let quoteInteraction: TypedTableAlias<Interaction> = TypedTableAlias(name: "quoteInteraction")
            let quoteInteractionAttachment: TypedTableAlias<InteractionAttachment> = TypedTableAlias(
                name: "quoteInteractionAttachment"
            )
            let quoteLinkPreview: TypedTableAlias<LinkPreview> = TypedTableAlias(name: "quoteLinkPreview")
            let attachment: TypedTableAlias<Attachment> = TypedTableAlias()
            
            let finalFilterSQL: SQL = {
                guard let additionalFilters: SQL = additionalFilters else {
                    return SQL(stringLiteral: "")
                }
                
                return """
                    WHERE \(additionalFilters)
                """
            }()
            
            let numColumnsBeforeLinkedRecords: Int = 5
            let request: SQLRequest<QuotedInfo> = """
                SELECT
                    \(quote[.rowId]) AS \(QuotedInfo.Columns.rowId),
                    \(quote[.interactionId]) AS \(QuotedInfo.Columns.interactionId),
                    \(quote[.authorId]) AS \(QuotedInfo.Columns.authorId),
                    \(quote[.timestampMs]) AS \(QuotedInfo.Columns.timestampMs),
                    \(quoteInteraction[.body]) AS \(QuotedInfo.Columns.body),
                    \(attachment.allColumns),
                    \(quoteInteraction[.id]) AS \(QuotedInfo.Columns.quotedInteractionId),
                    \(quoteInteraction[.variant]) AS \(QuotedInfo.Columns.quotedInteractionVariant)
                FROM \(Quote.self)
                JOIN \(quoteInteraction) ON (
                    \(quoteInteraction[.timestampMs]) = \(quote[.timestampMs]) AND (
                        \(quoteInteraction[.authorId]) = \(quote[.authorId]) OR (
                            -- A users outgoing message is stored in some cases using their standard id
                            -- but the quote will use their blinded id so handle that case
                            \(quoteInteraction[.authorId]) = \(userSessionId.hexString) AND
                            \(quote[.authorId]) IN \(currentUserSessionIds)
                        )
                    )
                )   
                LEFT JOIN \(quoteInteractionAttachment) ON (
                    \(quoteInteractionAttachment[.interactionId]) = \(quoteInteraction[.id]) AND
                    \(quoteInteractionAttachment[.albumIndex]) = 0
                )
                LEFT JOIN \(quoteLinkPreview) ON (
                    \(quoteLinkPreview[.url]) = \(quoteInteraction[.linkPreviewUrl]) AND
                    \(Interaction.linkPreviewFilterLiteral(
                        interaction: quoteInteraction,
                        linkPreview: quoteLinkPreview
                    ))
                )
                LEFT JOIN \(Attachment.self) ON (
                    \(attachment[.id]) = \(quoteInteractionAttachment[.attachmentId]) OR
                    \(attachment[.id]) = \(quoteLinkPreview[.attachmentId])
                )
                \(finalFilterSQL)
            """
            
            return request.adapted { db in
                let adapters = try splittingRowAdapters(columnCounts: [
                    numColumnsBeforeLinkedRecords,
                    Attachment.numberOfSelectedColumns(db)
                ])
                
                return ScopeAdapter.with(QuotedInfo.self, [
                    .attachment: adapters[1]
                ])
            }
        }
    }
    
    static func joinToViewModelQuerySQL() -> SQL {
        let quote: TypedTableAlias<Quote> = TypedTableAlias()
        let interaction: TypedTableAlias<Interaction> = TypedTableAlias()
        
        return """
            JOIN \(Quote.self) ON \(quote[.interactionId]) = \(interaction[.id])
        """
    }
    
    static func createReferencedRowIdsRetriever() -> (([Int64], DataCache<MessageViewModel.QuotedInfo>) -> [Int64]) {
        return { pagedRowIds, dataCache -> [Int64] in
            dataCache.values.compactMap { quotedInfo in
                guard
                    pagedRowIds.contains(quotedInfo.quotedInteractionId) ||
                    pagedRowIds.contains(quotedInfo.interactionId)
                else { return nil }
                
                return quotedInfo.rowId
            }
        }
    }
    
    static func createAssociateDataClosure() -> (DataCache<MessageViewModel.QuotedInfo>, DataCache<MessageViewModel>) -> DataCache<MessageViewModel> {
        return { dataCache, pagedDataCache -> DataCache<MessageViewModel> in
            var updatedPagedDataCache: DataCache<MessageViewModel> = pagedDataCache
            
            // Update changed records
            dataCache.values.forEach { quoteInfo in
                guard
                    let interactionRowId: Int64 = updatedPagedDataCache.lookup[quoteInfo.interactionId],
                    let dataToUpdate: ViewModel = updatedPagedDataCache.data[interactionRowId]
                else { return }
                
                switch quoteInfo.quotedInteractionVariant.isDeletedMessage {
                    // If the original message wasn't deleted and the quote contains some of it's content
                    // then remove that content from the quote
                    case false:
                        updatedPagedDataCache = updatedPagedDataCache.upserting(
                            dataToUpdate.with(quotedInfo: .set(to: quoteInfo))
                        )
                        
                    // If the original message was deleted and the quote contains some of it's content
                    // then remove that content from the quote
                    case true:
                        guard dataToUpdate.quotedInfo != nil else { return }
                        
                        updatedPagedDataCache = updatedPagedDataCache.upserting(
                            dataToUpdate.with(quotedInfo: .set(to: nil))
                        )
                }
            }
            
            return updatedPagedDataCache
        }
    }
}
