// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import GRDB
import DifferenceKit
import SessionUIKit
import SessionUtilitiesKit

fileprivate typealias ViewModel = SessionThreadViewModel

/// This type is used to populate the `ConversationCell` in the `HomeVC`, `MessageRequestsViewModel` and the
/// `GlobalSearchViewController`, it has a number of query methods which can be used to retrieve the relevant data for each
/// screen in a single location in an attempt to avoid spreading out _almost_ duplicated code in multiple places
///
/// **Note:** When updating the UI make sure to check the actual queries being run as some fields will have incorrect default values
/// in order to optimise their queries to only include the required data
public struct SessionThreadViewModel: FetchableRecordWithRowId, Decodable, Equatable, Hashable, Identifiable, Differentiable, ColumnExpressible, ThreadSafeType {
    public typealias Columns = CodingKeys
    public enum CodingKeys: String, CodingKey, ColumnExpression, CaseIterable {
        case rowId
        case threadId
        case threadVariant
        case threadCreationDateTimestamp
        case threadMemberNames
        
        case threadIsNoteToSelf
        case outdatedMemberId
        case threadIsMessageRequest
        case threadRequiresApproval
        case threadShouldBeVisible
        case threadPinnedPriority
        case threadIsBlocked
        case threadMutedUntilTimestamp
        case threadOnlyNotifyForMentions
        case threadMessageDraft
        case threadIsDraft
        
        case threadContactIsTyping
        case threadWasMarkedUnread
        case threadUnreadCount
        case threadUnreadMentionCount
        case threadHasUnreadMessagesOfAnyKind
        case threadCanWrite
        
        // Thread display info
        
        case disappearingMessagesConfiguration
        
        case contactLastKnownClientVersion
        case displayPictureFilename
        case contactProfile
        case closedGroupProfileFront
        case closedGroupProfileBack
        case closedGroupProfileBackFallback
        case closedGroupAdminProfile
        case closedGroupName
        case closedGroupDescription
        case closedGroupUserCount
        case closedGroupExpired
        case currentUserIsClosedGroupMember
        case currentUserIsClosedGroupAdmin
        case openGroupName
        case openGroupDescription
        case openGroupServer
        case openGroupRoomToken
        case openGroupPublicKey
        case openGroupUserCount
        case openGroupPermissions
        
        // Interaction display info
        
        case interactionId
        case interactionVariant
        case interactionTimestampMs
        case interactionBody
        case interactionState
        case interactionHasBeenReadByRecipient
        case interactionIsOpenGroupInvitation
        case interactionAttachmentDescriptionInfo
        case interactionAttachmentCount
        
        case authorId
        case threadContactNameInternal
        case authorNameInternal
        case currentUserSessionId
        case currentUserBlinded15SessionId
        case currentUserBlinded25SessionId
        case recentReactionEmoji
        case wasKickedFromGroup
        case groupIsDestroyed
    }
    
    public struct MessageInputState: Equatable {
        public let allowedInputTypes: MessageInputTypes
        public let message: String?
        public let accessibility: Accessibility?
        public let messageAccessibility: Accessibility?
        
        public static var all: MessageInputState = MessageInputState(allowedInputTypes: .all)
        
        // MARK: - Initialization
        
        init(
            allowedInputTypes: MessageInputTypes,
            message: String? = nil,
            accessibility: Accessibility? = nil,
            messageAccessibility: Accessibility? = nil
        ) {
            self.allowedInputTypes = allowedInputTypes
            self.message = message
            self.accessibility = accessibility
            self.messageAccessibility = messageAccessibility
        }
    }
    
    public var differenceIdentifier: String { threadId }
    public var id: String { threadId }
    
    public let rowId: Int64
    public let threadId: String
    public let threadVariant: SessionThread.Variant
    private let threadCreationDateTimestamp: TimeInterval
    public let threadMemberNames: String?
    
    public let threadIsNoteToSelf: Bool
    public let outdatedMemberId: String?
    
    /// This flag indicates whether the thread is an outgoing message request
    public let threadIsMessageRequest: Bool?
    
    /// This flag indicates whether the thread is an incoming message request
    public let threadRequiresApproval: Bool?
    public let threadShouldBeVisible: Bool?
    public let threadPinnedPriority: Int32
    public let threadIsBlocked: Bool?
    public let threadMutedUntilTimestamp: TimeInterval?
    public let threadOnlyNotifyForMentions: Bool?
    public let threadMessageDraft: String?
    public let threadIsDraft: Bool?
    
    public let threadContactIsTyping: Bool?
    public let threadWasMarkedUnread: Bool?
    public let threadUnreadCount: UInt?
    public let threadUnreadMentionCount: UInt?
    public let threadHasUnreadMessagesOfAnyKind: Bool?
    public let threadCanWrite: Bool?
    
    // Thread display info
    
    public let disappearingMessagesConfiguration: DisappearingMessagesConfiguration?
    
    public let contactLastKnownClientVersion: FeatureVersion?
    public let displayPictureFilename: String?
    private let contactProfile: Profile?
    private let closedGroupProfileFront: Profile?
    private let closedGroupProfileBack: Profile?
    private let closedGroupProfileBackFallback: Profile?
    public let closedGroupAdminProfile: Profile?
    public let closedGroupName: String?
    private let closedGroupDescription: String?
    private let closedGroupUserCount: Int?
    public let closedGroupExpired: Bool?
    public let currentUserIsClosedGroupMember: Bool?
    public let currentUserIsClosedGroupAdmin: Bool?
    public let openGroupName: String?
    private let openGroupDescription: String?
    public let openGroupServer: String?
    public let openGroupRoomToken: String?
    public let openGroupPublicKey: String?
    private let openGroupUserCount: Int?
    private let openGroupPermissions: OpenGroup.Permissions?
    
    // Interaction display info
    
    public let interactionId: Int64?
    public let interactionVariant: Interaction.Variant?
    public let interactionTimestampMs: Int64?
    public let interactionBody: String?
    public let interactionState: Interaction.State?
    public let interactionHasBeenReadByRecipient: Bool?
    public let interactionIsOpenGroupInvitation: Bool?
    public let interactionAttachmentDescriptionInfo: Attachment.DescriptionInfo?
    public let interactionAttachmentCount: Int?
    
    public let authorId: String?
    private let threadContactNameInternal: String?
    private let authorNameInternal: String?
    public let currentUserSessionId: String
    public let currentUserBlinded15SessionId: String?
    public let currentUserBlinded25SessionId: String?
    public let recentReactionEmoji: [String]?
    public let wasKickedFromGroup: Bool?
    public let groupIsDestroyed: Bool?
    
    // UI specific logic
    
    public var displayName: String {
        return SessionThread.displayName(
            threadId: threadId,
            variant: threadVariant,
            closedGroupName: closedGroupName,
            openGroupName: openGroupName,
            isNoteToSelf: threadIsNoteToSelf,
            profile: profile
        )
    }
    
    public var threadDescription: String? {
        switch threadVariant {
            case .contact, .legacyGroup: return nil
            case .community: return openGroupDescription
            case .group: return closedGroupDescription
        }
    }
    
    public var profile: Profile? {
        switch threadVariant {
            case .contact: return contactProfile
            case .legacyGroup, .group:
                return (closedGroupProfileBack ?? closedGroupProfileBackFallback)
            case .community: return nil
        }
    }
    
    public var additionalProfile: Profile? {
        switch threadVariant {
            case .legacyGroup, .group: return closedGroupProfileFront
            default: return nil
        }
    }
    
    public var lastInteractionDate: Date {
        guard let interactionTimestampMs: Int64 = interactionTimestampMs else {
            return Date(timeIntervalSince1970: threadCreationDateTimestamp)
        }
                        
        return Date(timeIntervalSince1970: TimeInterval(Double(interactionTimestampMs) / 1000))
    }
    
    public var messageInputState: MessageInputState {
        guard !threadIsNoteToSelf else { return MessageInputState(allowedInputTypes: .all) }
        guard threadIsBlocked != true else {
            return MessageInputState(
                allowedInputTypes: .none,
                message: "blockBlockedDescription".localized(),
                messageAccessibility: Accessibility(
                    identifier: "Blocked banner"
                )
            )
        }
        
        return MessageInputState(
            allowedInputTypes: (threadRequiresApproval == false && threadIsMessageRequest == false ?
                .all :
                .textOnly
            )
        )
    }
    
    public var userCount: Int? {
        switch threadVariant {
            case .contact: return nil
            case .legacyGroup, .group: return closedGroupUserCount
            case .community: return openGroupUserCount
        }
    }
    
    /// This function returns the thread contact profile name formatted for the specific type of thread provided
    ///
    /// **Note:** The 'threadVariant' parameter is used for profile context but in the search results we actually want this
    /// to always behave as the `contact` variant which is why this needs to be a function instead of just using the provided
    /// parameter
    public func threadContactName() -> String {
        return Profile.displayName(
            for: .contact,
            id: threadId,
            name: threadContactNameInternal,
            nickname: nil,      // Folded into 'threadContactNameInternal' within the Query
            suppressId: true,   // Don't include the account id in the name in the conversation list
            customFallback: "Anonymous"
        )
    }
    
    /// This function returns the profile name formatted for the specific type of thread provided
    ///
    /// **Note:** The 'threadVariant' parameter is used for profile context but in the search results we actually want this
    /// to always behave as the `contact` variant which is why this needs to be a function instead of just using the provided
    /// parameter
    public func authorName(for threadVariant: SessionThread.Variant) -> String {
        return Profile.displayName(
            for: threadVariant,
            id: (authorId ?? threadId),
            name: authorNameInternal,
            nickname: nil,      // Folded into 'authorName' within the Query
            suppressId: true,   // Don't include the account id in the name in the conversation list
            customFallback: (threadVariant == .contact ?
                "Anonymous" :
                nil
            )
        )
    }
    
    public func canAccessSettings(using dependencies: Dependencies) -> Bool {
        return (
            threadRequiresApproval == false &&
            threadIsMessageRequest == false && (
                threadVariant != .legacyGroup ||
                !dependencies[feature: .legacyGroupsDeprecated]
            )
        )
    }
    
    // MARK: - Marking as Read
    
    public enum ReadTarget {
        /// Only the thread should be marked as read
        case thread
        
        /// Both the thread and interactions should be marked as read, if no interaction id is provided then all interactions for the
        /// thread will be marked as read
        case threadAndInteractions(interactionsBeforeInclusive: Int64?)
    }
    
    /// This method marks a thread as read and depending on the target may also update the interactions within a thread as read
    public func markAsRead(target: ReadTarget, using dependencies: Dependencies) {
        // Store the logic to mark a thread as read (to paths need to run this)
        let threadId: String = self.threadId
        let threadWasMarkedUnread: Bool? = self.threadWasMarkedUnread
        let markThreadAsReadIfNeeded: (Dependencies) -> () = { dependencies in
            // Only make this change if needed (want to avoid triggering a thread update
            // if not needed)
            guard threadWasMarkedUnread == true else { return }
            
            dependencies[singleton: .storage].writeAsync { db in
                try SessionThread
                    .filter(id: threadId)
                    .updateAllAndConfig(
                        db,
                        SessionThread.Columns.markedAsUnread.set(to: false),
                        using: dependencies
                    )
            }
        }
        
        // Determine what we want to mark as read
        switch target {
            // Only mark the thread as read
            case .thread: markThreadAsReadIfNeeded(dependencies)
            
            // We want to mark both the thread and interactions as read
            case .threadAndInteractions(let interactionId):
                guard
                    self.threadHasUnreadMessagesOfAnyKind == true,
                    let targetInteractionId: Int64 = (interactionId ?? self.interactionId)
                else {
                    // No unread interactions so just mark the thread as read if needed
                    markThreadAsReadIfNeeded(dependencies)
                    return
                }
                
                let threadId: String = self.threadId
                let threadVariant: SessionThread.Variant = self.threadVariant
                let threadIsBlocked: Bool? = self.threadIsBlocked
                let threadIsMessageRequest: Bool? = self.threadIsMessageRequest
                
                dependencies[singleton: .storage].writeAsync { db in
                    markThreadAsReadIfNeeded(dependencies)
                    
                    try Interaction.markAsRead(
                        db,
                        interactionId: targetInteractionId,
                        threadId: threadId,
                        threadVariant: threadVariant,
                        includingOlder: true,
                        trySendReadReceipt: try SessionThread.canSendReadReceipt(
                            db,
                            threadId: threadId,
                            threadVariant: threadVariant,
                            isBlocked: threadIsBlocked,
                            isMessageRequest: threadIsMessageRequest,
                            using: dependencies
                        ),
                        using: dependencies
                    )
                }
        }
    }
    
    /// This method will mark a thread as read
    public func markAsUnread(using dependencies: Dependencies) {
        guard self.threadWasMarkedUnread != true else { return }
        
        let threadId: String = self.threadId
        
        dependencies[singleton: .storage].writeAsync { db in
            try SessionThread
                .filter(id: threadId)
                .updateAllAndConfig(
                    db,
                    SessionThread.Columns.markedAsUnread.set(to: true),
                    using: dependencies
                )
        }
    }
    
    // MARK: - Functions
    
    /// This function should only be called when initially creating/populating the `SessionThreadViewModel`, instead use
    /// `threadCanWrite == true` to determine whether the user should be able to write to a thread, this function uses
    /// external data to determine if the user can write so the result might differ from the original value when the
    /// `SessionThreadViewModel` was created
    public func determineInitialCanWriteFlag(using dependencies: Dependencies) -> Bool {
        switch threadVariant {
            case .contact:
                guard threadIsMessageRequest == true else { return true }
                
                return (profile?.blocksCommunityMessageRequests != true)
                
            case .legacyGroup:
                guard !dependencies[feature: .legacyGroupsDeprecated] else { return false }
                guard threadIsMessageRequest == false else { return true }
                
                return (
                    currentUserIsClosedGroupMember == true &&
                    interactionVariant?.isGroupLeavingStatus != true
                )
                
            case .group:
                guard groupIsDestroyed != true else { return false }
                guard wasKickedFromGroup != true else { return false }
                guard threadIsMessageRequest == false else { return true }
                
                // Double check LibSession directly just in case we the view model hasn't been
                // updated since they were changed
                guard
                    !LibSession.wasKickedFromGroup(
                        groupSessionId: SessionId(.group, hex: threadId),
                        using: dependencies
                    ) &&
                    !LibSession.groupIsDestroyed(
                        groupSessionId: SessionId(.group, hex: threadId),
                        using: dependencies
                    )
                else { return false }
                
                return interactionVariant?.isGroupLeavingStatus != true
                
            case .community:
                return (openGroupPermissions?.contains(.write) ?? false)
        }
    }
}

// MARK: - Convenience Initialization

public extension SessionThreadViewModel {
    static let invalidId: String = "INVALID_THREAD_ID"
    static let messageRequestsSectionId: String = "MESSAGE_REQUESTS_SECTION_INVALID_THREAD_ID"
    
    // Note: This init method is only used system-created cells or empty states
    init(
        threadId: String,
        threadVariant: SessionThread.Variant? = nil,
        threadIsNoteToSelf: Bool = false,
        threadIsMessageRequest: Bool? = nil,
        threadIsBlocked: Bool? = nil,
        contactProfile: Profile? = nil,
        closedGroupAdminProfile: Profile? = nil,
        closedGroupExpired: Bool? = nil,
        currentUserIsClosedGroupMember: Bool? = nil,
        currentUserIsClosedGroupAdmin: Bool? = nil,
        openGroupPermissions: OpenGroup.Permissions? = nil,
        threadWasMarkedUnread: Bool? = nil,
        unreadCount: UInt = 0,
        hasUnreadMessagesOfAnyKind: Bool = false,
        threadCanWrite: Bool = true,
        disappearingMessagesConfiguration: DisappearingMessagesConfiguration? = nil,
        using dependencies: Dependencies
    ) {
        self.rowId = -1
        self.threadId = threadId
        self.threadVariant = (threadVariant ?? .contact)
        self.threadCreationDateTimestamp = 0
        self.threadMemberNames = nil
        
        self.threadIsNoteToSelf = threadIsNoteToSelf
        self.outdatedMemberId = nil
        self.threadIsMessageRequest = threadIsMessageRequest
        self.threadRequiresApproval = false
        self.threadShouldBeVisible = false
        self.threadPinnedPriority = 0
        self.threadIsBlocked = threadIsBlocked
        self.threadMutedUntilTimestamp = nil
        self.threadOnlyNotifyForMentions = nil
        self.threadMessageDraft = nil
        self.threadIsDraft = nil
        
        self.threadContactIsTyping = nil
        self.threadWasMarkedUnread = threadWasMarkedUnread
        self.threadUnreadCount = unreadCount
        self.threadUnreadMentionCount = nil
        self.threadHasUnreadMessagesOfAnyKind = hasUnreadMessagesOfAnyKind
        self.threadCanWrite = threadCanWrite
        
        // Thread display info
        
        self.disappearingMessagesConfiguration = disappearingMessagesConfiguration
        
        self.contactLastKnownClientVersion = nil
        self.displayPictureFilename = nil
        self.contactProfile = contactProfile
        self.closedGroupProfileFront = nil
        self.closedGroupProfileBack = nil
        self.closedGroupProfileBackFallback = nil
        self.closedGroupAdminProfile = closedGroupAdminProfile
        self.closedGroupName = nil
        self.closedGroupDescription = nil
        self.closedGroupUserCount = nil
        self.closedGroupExpired = closedGroupExpired
        self.currentUserIsClosedGroupMember = currentUserIsClosedGroupMember
        self.currentUserIsClosedGroupAdmin = currentUserIsClosedGroupAdmin
        self.openGroupName = nil
        self.openGroupDescription = nil
        self.openGroupServer = nil
        self.openGroupRoomToken = nil
        self.openGroupPublicKey = nil
        self.openGroupUserCount = nil
        self.openGroupPermissions = openGroupPermissions
        
        // Interaction display info
        
        self.interactionId = nil
        self.interactionVariant = nil
        self.interactionTimestampMs = nil
        self.interactionBody = nil
        self.interactionState = nil
        self.interactionHasBeenReadByRecipient = nil
        self.interactionIsOpenGroupInvitation = nil
        self.interactionAttachmentDescriptionInfo = nil
        self.interactionAttachmentCount = nil
        
        self.authorId = nil
        self.threadContactNameInternal = nil
        self.authorNameInternal = nil
        self.currentUserSessionId = dependencies[cache: .general].sessionId.hexString
        self.currentUserBlinded15SessionId = nil
        self.currentUserBlinded25SessionId = nil
        self.recentReactionEmoji = nil
        self.wasKickedFromGroup = false
        self.groupIsDestroyed = false
    }
}

// MARK: - Mutation

public extension SessionThreadViewModel {
    func with(
        recentReactionEmoji: [String]? = nil
    ) -> SessionThreadViewModel {
        return SessionThreadViewModel(
            rowId: self.rowId,
            threadId: self.threadId,
            threadVariant: self.threadVariant,
            threadCreationDateTimestamp: self.threadCreationDateTimestamp,
            threadMemberNames: self.threadMemberNames,
            threadIsNoteToSelf: self.threadIsNoteToSelf,
            outdatedMemberId: self.outdatedMemberId,
            threadIsMessageRequest: self.threadIsMessageRequest,
            threadRequiresApproval: self.threadRequiresApproval,
            threadShouldBeVisible: self.threadShouldBeVisible,
            threadPinnedPriority: self.threadPinnedPriority,
            threadIsBlocked: self.threadIsBlocked,
            threadMutedUntilTimestamp: self.threadMutedUntilTimestamp,
            threadOnlyNotifyForMentions: self.threadOnlyNotifyForMentions,
            threadMessageDraft: self.threadMessageDraft,
            threadIsDraft: self.threadIsDraft,
            threadContactIsTyping: self.threadContactIsTyping,
            threadWasMarkedUnread: self.threadWasMarkedUnread,
            threadUnreadCount: self.threadUnreadCount,
            threadUnreadMentionCount: self.threadUnreadMentionCount,
            threadHasUnreadMessagesOfAnyKind: self.threadHasUnreadMessagesOfAnyKind,
            threadCanWrite: self.threadCanWrite,
            disappearingMessagesConfiguration: self.disappearingMessagesConfiguration,
            contactLastKnownClientVersion: self.contactLastKnownClientVersion,
            displayPictureFilename: self.displayPictureFilename,
            contactProfile: self.contactProfile,
            closedGroupProfileFront: self.closedGroupProfileFront,
            closedGroupProfileBack: self.closedGroupProfileBack,
            closedGroupProfileBackFallback: self.closedGroupProfileBackFallback,
            closedGroupAdminProfile: self.closedGroupAdminProfile,
            closedGroupName: self.closedGroupName,
            closedGroupDescription: self.closedGroupDescription,
            closedGroupUserCount: self.closedGroupUserCount,
            closedGroupExpired: self.closedGroupExpired,
            currentUserIsClosedGroupMember: self.currentUserIsClosedGroupMember,
            currentUserIsClosedGroupAdmin: self.currentUserIsClosedGroupAdmin,
            openGroupName: self.openGroupName,
            openGroupDescription: self.openGroupDescription,
            openGroupServer: self.openGroupServer,
            openGroupRoomToken: self.openGroupRoomToken,
            openGroupPublicKey: self.openGroupPublicKey,
            openGroupUserCount: self.openGroupUserCount,
            openGroupPermissions: self.openGroupPermissions,
            interactionId: self.interactionId,
            interactionVariant: self.interactionVariant,
            interactionTimestampMs: self.interactionTimestampMs,
            interactionBody: self.interactionBody,
            interactionState: self.interactionState,
            interactionHasBeenReadByRecipient: self.interactionHasBeenReadByRecipient,
            interactionIsOpenGroupInvitation: self.interactionIsOpenGroupInvitation,
            interactionAttachmentDescriptionInfo: self.interactionAttachmentDescriptionInfo,
            interactionAttachmentCount: self.interactionAttachmentCount,
            authorId: self.authorId,
            threadContactNameInternal: self.threadContactNameInternal,
            authorNameInternal: self.authorNameInternal,
            currentUserSessionId: self.currentUserSessionId,
            currentUserBlinded15SessionId: self.currentUserBlinded15SessionId,
            currentUserBlinded25SessionId: self.currentUserBlinded25SessionId,
            recentReactionEmoji: (recentReactionEmoji ?? self.recentReactionEmoji),
            wasKickedFromGroup: self.wasKickedFromGroup,
            groupIsDestroyed: self.groupIsDestroyed
        )
    }
    
    func populatingPostQueryData(
        _ db: Database? = nil,
        currentUserBlinded15SessionIdForThisThread: String?,
        currentUserBlinded25SessionIdForThisThread: String?,
        wasKickedFromGroup: Bool,
        groupIsDestroyed: Bool,
        threadCanWrite: Bool,
        using dependencies: Dependencies
    ) -> SessionThreadViewModel {
        return SessionThreadViewModel(
            rowId: self.rowId,
            threadId: self.threadId,
            threadVariant: self.threadVariant,
            threadCreationDateTimestamp: self.threadCreationDateTimestamp,
            threadMemberNames: self.threadMemberNames,
            threadIsNoteToSelf: self.threadIsNoteToSelf,
            outdatedMemberId: self.outdatedMemberId,
            threadIsMessageRequest: self.threadIsMessageRequest,
            threadRequiresApproval: self.threadRequiresApproval,
            threadShouldBeVisible: self.threadShouldBeVisible,
            threadPinnedPriority: self.threadPinnedPriority,
            threadIsBlocked: self.threadIsBlocked,
            threadMutedUntilTimestamp: self.threadMutedUntilTimestamp,
            threadOnlyNotifyForMentions: self.threadOnlyNotifyForMentions,
            threadMessageDraft: self.threadMessageDraft,
            threadIsDraft: self.threadIsDraft,
            threadContactIsTyping: self.threadContactIsTyping,
            threadWasMarkedUnread: self.threadWasMarkedUnread,
            threadUnreadCount: self.threadUnreadCount,
            threadUnreadMentionCount: self.threadUnreadMentionCount,
            threadHasUnreadMessagesOfAnyKind: self.threadHasUnreadMessagesOfAnyKind,
            threadCanWrite: threadCanWrite,
            disappearingMessagesConfiguration: self.disappearingMessagesConfiguration,
            contactLastKnownClientVersion: self.contactLastKnownClientVersion,
            displayPictureFilename: self.displayPictureFilename,
            contactProfile: self.contactProfile,
            closedGroupProfileFront: self.closedGroupProfileFront,
            closedGroupProfileBack: self.closedGroupProfileBack,
            closedGroupProfileBackFallback: self.closedGroupProfileBackFallback,
            closedGroupAdminProfile: self.closedGroupAdminProfile,
            closedGroupName: self.closedGroupName,
            closedGroupDescription: self.closedGroupDescription,
            closedGroupUserCount: self.closedGroupUserCount,
            closedGroupExpired: self.closedGroupExpired,
            currentUserIsClosedGroupMember: self.currentUserIsClosedGroupMember,
            currentUserIsClosedGroupAdmin: self.currentUserIsClosedGroupAdmin,
            openGroupName: self.openGroupName,
            openGroupDescription: self.openGroupDescription,
            openGroupServer: self.openGroupServer,
            openGroupRoomToken: self.openGroupRoomToken,
            openGroupPublicKey: self.openGroupPublicKey,
            openGroupUserCount: self.openGroupUserCount,
            openGroupPermissions: self.openGroupPermissions,
            interactionId: self.interactionId,
            interactionVariant: self.interactionVariant,
            interactionTimestampMs: self.interactionTimestampMs,
            interactionBody: self.interactionBody,
            interactionState: self.interactionState,
            interactionHasBeenReadByRecipient: self.interactionHasBeenReadByRecipient,
            interactionIsOpenGroupInvitation: self.interactionIsOpenGroupInvitation,
            interactionAttachmentDescriptionInfo: self.interactionAttachmentDescriptionInfo,
            interactionAttachmentCount: self.interactionAttachmentCount,
            authorId: self.authorId,
            threadContactNameInternal: self.threadContactNameInternal,
            authorNameInternal: self.authorNameInternal,
            currentUserSessionId: self.currentUserSessionId,
            currentUserBlinded15SessionId: (
                currentUserBlinded15SessionIdForThisThread ??
                SessionThread.getCurrentUserBlindedSessionId(
                    db,
                    threadId: self.threadId,
                    threadVariant: self.threadVariant,
                    blindingPrefix: .blinded15,
                    using: dependencies
                )?.hexString
            ),
            currentUserBlinded25SessionId: (
                currentUserBlinded25SessionIdForThisThread ??
                SessionThread.getCurrentUserBlindedSessionId(
                    db,
                    threadId: self.threadId,
                    threadVariant: self.threadVariant,
                    blindingPrefix: .blinded25,
                    using: dependencies
                )?.hexString
            ),
            recentReactionEmoji: self.recentReactionEmoji,
            wasKickedFromGroup: wasKickedFromGroup,
            groupIsDestroyed: groupIsDestroyed
        )
    }
}

// MARK: - AggregateInteraction

private struct AggregateInteraction: Decodable, ColumnExpressible {
    public typealias Columns = CodingKeys
    public enum CodingKeys: String, CodingKey, ColumnExpression, CaseIterable {
        case interactionId
        case threadId
        case interactionTimestampMs
        case threadUnreadCount
        case threadUnreadMentionCount
        case threadHasUnreadMessagesOfAnyKind
    }
    
    let interactionId: Int64
    let threadId: String
    let interactionTimestampMs: Int64
    let threadUnreadCount: UInt?
    let threadUnreadMentionCount: UInt?
    let threadHasUnreadMessagesOfAnyKind: Bool?
}

// MARK: - ClosedGroupUserCount

private struct ClosedGroupUserCount: Decodable, ColumnExpressible {
    public typealias Columns = CodingKeys
    public enum CodingKeys: String, CodingKey, ColumnExpression, CaseIterable {
        case groupId
        case closedGroupUserCount
    }
    
    let groupId: String
    let closedGroupUserCount: Int
}

// MARK: - GroupMemberInfo

private struct GroupMemberInfo: Decodable, ColumnExpressible {
    public typealias Columns = CodingKeys
    public enum CodingKeys: String, CodingKey, ColumnExpression, CaseIterable {
        case groupId
        case threadMemberNames
    }
    
    let groupId: String
    let threadMemberNames: String
}

// MARK: - HomeVC & MessageRequestsViewModel

// MARK: --SessionThreadViewModel

public extension SessionThreadViewModel {
    /// **Note:** This query **will not** include deleted incoming messages in it's unread count (they should never be marked as unread
    /// but including this warning just in case there is a discrepancy)
    static func baseQuery(
        userSessionId: SessionId,
        groupSQL: SQL,
        orderSQL: SQL
    ) -> (([Int64]) -> AdaptedFetchRequest<SQLRequest<SessionThreadViewModel>>) {
        return { rowIds -> AdaptedFetchRequest<SQLRequest<ViewModel>> in
            let thread: TypedTableAlias<SessionThread> = TypedTableAlias()
            let contact: TypedTableAlias<Contact> = TypedTableAlias()
            let typingIndicator: TypedTableAlias<ThreadTypingIndicator> = TypedTableAlias()
            let aggregateInteraction: TypedTableAlias<AggregateInteraction> = TypedTableAlias(name: "aggregateInteraction")
            let interaction: TypedTableAlias<Interaction> = TypedTableAlias()
            let linkPreview: TypedTableAlias<LinkPreview> = TypedTableAlias()
            let firstInteractionAttachment: TypedTableAlias<InteractionAttachment> = TypedTableAlias(name: "firstInteractionAttachment")
            let attachment: TypedTableAlias<Attachment> = TypedTableAlias()
            let interactionAttachment: TypedTableAlias<InteractionAttachment> = TypedTableAlias()
            let profile: TypedTableAlias<Profile> = TypedTableAlias()
            let contactProfile: TypedTableAlias<Profile> = TypedTableAlias(ViewModel.self, column: .contactProfile)
            let closedGroup: TypedTableAlias<ClosedGroup> = TypedTableAlias()
            let closedGroupProfileFront: TypedTableAlias<Profile> = TypedTableAlias(ViewModel.self, column: .closedGroupProfileFront)
            let closedGroupProfileBack: TypedTableAlias<Profile> = TypedTableAlias(ViewModel.self, column: .closedGroupProfileBack)
            let closedGroupProfileBackFallback: TypedTableAlias<Profile> = TypedTableAlias(ViewModel.self, column: .closedGroupProfileBackFallback)
            let closedGroupAdminProfile: TypedTableAlias<Profile> = TypedTableAlias(ViewModel.self, column: .closedGroupAdminProfile)
            let groupMember: TypedTableAlias<GroupMember> = TypedTableAlias()
            let openGroup: TypedTableAlias<OpenGroup> = TypedTableAlias()
            
            /// **Note:** The `numColumnsBeforeProfiles` value **MUST** match the number of fields before
            /// the `contactProfile` entry below otherwise the query will fail to parse and might throw
            ///
            /// Explicitly set default values for the fields ignored for search results
            let numColumnsBeforeProfiles: Int = 15
            let numColumnsBetweenProfilesAndAttachmentInfo: Int = 13 // The attachment info columns will be combined
            let request: SQLRequest<ViewModel> = """
                SELECT
                    \(thread[.rowId]) AS \(ViewModel.Columns.rowId),
                    \(thread[.id]) AS \(ViewModel.Columns.threadId),
                    \(thread[.variant]) AS \(ViewModel.Columns.threadVariant),
                    \(thread[.creationDateTimestamp]) AS \(ViewModel.Columns.threadCreationDateTimestamp),

                    (\(SQL("\(thread[.id]) = \(userSessionId.hexString)"))) AS \(ViewModel.Columns.threadIsNoteToSelf),
                    IFNULL(\(thread[.pinnedPriority]), 0) AS \(ViewModel.Columns.threadPinnedPriority),
                    \(contact[.isBlocked]) AS \(ViewModel.Columns.threadIsBlocked),
                    \(thread[.mutedUntilTimestamp]) AS \(ViewModel.Columns.threadMutedUntilTimestamp),
                    \(thread[.onlyNotifyForMentions]) AS \(ViewModel.Columns.threadOnlyNotifyForMentions),
                    (
                        COALESCE(\(closedGroup[.invited]), false) = true OR (
                            \(SQL("\(thread[.variant]) = \(SessionThread.Variant.contact)")) AND
                            \(SQL("\(thread[.id]) != \(userSessionId.hexString)")) AND
                            IFNULL(\(contact[.isApproved]), false) = false
                        )
                    ) AS \(ViewModel.Columns.threadIsMessageRequest),
                    
                    (\(typingIndicator[.threadId]) IS NOT NULL) AS \(ViewModel.Columns.threadContactIsTyping),
                    \(thread[.markedAsUnread]) AS \(ViewModel.Columns.threadWasMarkedUnread),
                    \(aggregateInteraction[.threadUnreadCount]),
                    \(aggregateInteraction[.threadUnreadMentionCount]),
                    \(aggregateInteraction[.threadHasUnreadMessagesOfAnyKind]),

                    \(contactProfile.allColumns),
                    \(closedGroupProfileFront.allColumns),
                    \(closedGroupProfileBack.allColumns),
                    \(closedGroupProfileBackFallback.allColumns),
                    \(closedGroupAdminProfile.allColumns),
                    \(closedGroup[.name]) AS \(ViewModel.Columns.closedGroupName),
                    \(closedGroup[.expired]) AS \(ViewModel.Columns.closedGroupExpired),

                    EXISTS (
                        SELECT 1
                        FROM \(GroupMember.self)
                        WHERE (
                            \(groupMember[.groupId]) = \(closedGroup[.threadId]) AND
                            \(SQL("\(groupMember[.role]) != \(GroupMember.Role.zombie)")) AND
                            \(SQL("\(groupMember[.profileId]) = \(userSessionId.hexString)"))
                        )
                    ) AS \(ViewModel.Columns.currentUserIsClosedGroupMember),

                    EXISTS (
                        SELECT 1
                        FROM \(GroupMember.self)
                        WHERE (
                            \(groupMember[.groupId]) = \(closedGroup[.threadId]) AND
                            \(SQL("\(groupMember[.role]) = \(GroupMember.Role.admin)")) AND
                            \(SQL("\(groupMember[.profileId]) = \(userSessionId.hexString)")) AND (
                                (
                                    -- Legacy groups don't have a 'roleStatus' so just let those through
                                    -- based solely on the 'role'
                                    \(groupMember[.groupId]) > \(SessionId.Prefix.standard.rawValue) AND
                                    \(groupMember[.groupId]) < \(SessionId.Prefix.standard.endOfRangeString)
                                ) OR
                                \(SQL("\(groupMember[.roleStatus]) = \(GroupMember.RoleStatus.accepted)"))
                            )
                        )
                    ) AS \(ViewModel.Columns.currentUserIsClosedGroupAdmin),

                    \(openGroup[.name]) AS \(ViewModel.Columns.openGroupName),
            
                    COALESCE(
                        \(openGroup[.displayPictureFilename]),
                        \(closedGroup[.displayPictureFilename]),
                        \(contactProfile[.profilePictureFileName])
                    ) AS \(ViewModel.Columns.displayPictureFilename),

                    \(interaction[.id]) AS \(ViewModel.Columns.interactionId),
                    \(interaction[.variant]) AS \(ViewModel.Columns.interactionVariant),
                    \(interaction[.timestampMs]) AS \(ViewModel.Columns.interactionTimestampMs),
                    \(interaction[.body]) AS \(ViewModel.Columns.interactionBody),
                    \(interaction[.state]) AS \(ViewModel.Columns.interactionState),
                    (\(interaction[.recipientReadTimestampMs]) IS NOT NULL) AS \(ViewModel.Columns.interactionHasBeenReadByRecipient),
                    (\(linkPreview[.url]) IS NOT NULL) AS \(ViewModel.Columns.interactionIsOpenGroupInvitation),

                    -- These 4 properties will be combined into 'Attachment.DescriptionInfo'
                    \(attachment[.id]),
                    \(attachment[.variant]),
                    \(attachment[.contentType]),
                    \(attachment[.sourceFilename]),
                    COUNT(\(interactionAttachment[.interactionId])) AS \(ViewModel.Columns.interactionAttachmentCount),

                    \(interaction[.authorId]),
                    IFNULL(\(contactProfile[.nickname]), \(contactProfile[.name])) AS \(ViewModel.Columns.threadContactNameInternal),
                    IFNULL(\(profile[.nickname]), \(profile[.name])) AS \(ViewModel.Columns.authorNameInternal),
                    \(SQL("\(userSessionId.hexString)")) AS \(ViewModel.Columns.currentUserSessionId)

                FROM \(SessionThread.self)
                LEFT JOIN \(Contact.self) ON \(contact[.id]) = \(thread[.id])
                LEFT JOIN \(ThreadTypingIndicator.self) ON \(typingIndicator[.threadId]) = \(thread[.id])

                LEFT JOIN (
                    SELECT
                        \(interaction[.id]) AS \(AggregateInteraction.Columns.interactionId),
                        \(interaction[.threadId]) AS \(AggregateInteraction.Columns.threadId),
                        MAX(\(interaction[.timestampMs])) AS \(AggregateInteraction.Columns.interactionTimestampMs),
                        SUM(\(interaction[.wasRead]) = false) AS \(AggregateInteraction.Columns.threadUnreadCount),
                        SUM(\(interaction[.wasRead]) = false AND \(interaction[.hasMention]) = true) AS \(AggregateInteraction.Columns.threadUnreadMentionCount),
                        (SUM(\(interaction[.wasRead]) = false) > 0) AS \(AggregateInteraction.Columns.threadHasUnreadMessagesOfAnyKind)
            
                    FROM \(Interaction.self)
                    WHERE \(SQL("\(interaction[.variant]) IN \(Interaction.Variant.variantsToShowConversationSnippet)"))
                    GROUP BY \(interaction[.threadId])
                ) AS \(aggregateInteraction) ON \(aggregateInteraction[.threadId]) = \(thread[.id])
                
                LEFT JOIN \(Interaction.self) ON (
                    \(interaction[.threadId]) = \(thread[.id]) AND
                    \(interaction[.id]) = \(aggregateInteraction[.interactionId])
                )

                LEFT JOIN \(LinkPreview.self) ON (
                    \(linkPreview[.url]) = \(interaction[.linkPreviewUrl]) AND
                    \(Interaction.linkPreviewFilterLiteral()) AND
                    \(SQL("\(linkPreview[.variant]) = \(LinkPreview.Variant.openGroupInvitation)"))
                )
                LEFT JOIN \(firstInteractionAttachment) ON (
                    \(firstInteractionAttachment[.interactionId]) = \(interaction[.id]) AND
                    \(firstInteractionAttachment[.albumIndex]) = 0
                )
                LEFT JOIN \(Attachment.self) ON \(attachment[.id]) = \(firstInteractionAttachment[.attachmentId])
                LEFT JOIN \(InteractionAttachment.self) ON \(interactionAttachment[.interactionId]) = \(interaction[.id])
                LEFT JOIN \(Profile.self) ON \(profile[.id]) = \(interaction[.authorId])

                -- Thread naming & avatar content

                LEFT JOIN \(contactProfile) ON \(contactProfile[.id]) = \(thread[.id])
                LEFT JOIN \(OpenGroup.self) ON \(openGroup[.threadId]) = \(thread[.id])
                LEFT JOIN \(ClosedGroup.self) ON \(closedGroup[.threadId]) = \(thread[.id])

                LEFT JOIN \(closedGroupProfileFront) ON (
                    \(closedGroupProfileFront[.id]) = (
                        SELECT MIN(\(groupMember[.profileId]))
                        FROM \(GroupMember.self)
                        JOIN \(Profile.self) ON \(profile[.id]) = \(groupMember[.profileId])
                        WHERE (
                            \(groupMember[.groupId]) = \(closedGroup[.threadId]) AND
                            \(SQL("\(groupMember[.role]) = \(GroupMember.Role.standard)")) AND
                            \(SQL("\(groupMember[.profileId]) != \(userSessionId.hexString)"))
                        )
                    )
                )
                LEFT JOIN \(closedGroupProfileBack) ON (
                    \(closedGroupProfileBack[.id]) != \(closedGroupProfileFront[.id]) AND
                    \(closedGroupProfileBack[.id]) = (
                        SELECT MAX(\(groupMember[.profileId]))
                        FROM \(GroupMember.self)
                        JOIN \(Profile.self) ON \(profile[.id]) = \(groupMember[.profileId])
                        WHERE (
                            \(groupMember[.groupId]) = \(closedGroup[.threadId]) AND
                            \(SQL("\(groupMember[.role]) = \(GroupMember.Role.standard)")) AND
                            \(SQL("\(groupMember[.profileId]) != \(userSessionId.hexString)"))
                        )
                    )
                )
                LEFT JOIN \(closedGroupProfileBackFallback) ON (
                    \(closedGroup[.threadId]) IS NOT NULL AND
                    \(closedGroupProfileBack[.id]) IS NULL AND
                    \(closedGroupProfileBackFallback[.id]) = \(SQL("\(userSessionId.hexString)"))
                )
                LEFT JOIN \(closedGroupAdminProfile) ON (
                    \(closedGroupAdminProfile[.id]) = (
                        SELECT MIN(\(groupMember[.profileId]))
                        FROM \(GroupMember.self)
                        JOIN \(Profile.self) ON \(profile[.id]) = \(groupMember[.profileId])
                        WHERE (
                            \(groupMember[.groupId]) = \(closedGroup[.threadId]) AND
                            \(SQL("\(groupMember[.role]) = \(GroupMember.Role.admin)"))
                        )
                    )
                )

                WHERE \(thread[.rowId]) IN \(rowIds)
                \(groupSQL)
                ORDER BY \(orderSQL)
            """
            
            return request.adapted { db in
                let adapters = try splittingRowAdapters(columnCounts: [
                    numColumnsBeforeProfiles,
                    Profile.numberOfSelectedColumns(db),
                    Profile.numberOfSelectedColumns(db),
                    Profile.numberOfSelectedColumns(db),
                    Profile.numberOfSelectedColumns(db),
                    Profile.numberOfSelectedColumns(db),
                    numColumnsBetweenProfilesAndAttachmentInfo,
                    Attachment.DescriptionInfo.numberOfSelectedColumns()
                ])
                
                return ScopeAdapter.with(ViewModel.self, [
                    .contactProfile: adapters[1],
                    .closedGroupProfileFront: adapters[2],
                    .closedGroupProfileBack: adapters[3],
                    .closedGroupProfileBackFallback: adapters[4],
                    .closedGroupAdminProfile: adapters[5],
                    .interactionAttachmentDescriptionInfo: adapters[7]
                ])
            }
        }
    }
    
    static var optimisedJoinSQL: SQL = {
        let thread: TypedTableAlias<SessionThread> = TypedTableAlias()
        let contact: TypedTableAlias<Contact> = TypedTableAlias()
        let closedGroup: TypedTableAlias<ClosedGroup> = TypedTableAlias()
        let interaction: TypedTableAlias<Interaction> = TypedTableAlias()
        
        let timestampMsColumnLiteral: SQL = SQL(stringLiteral: Interaction.Columns.timestampMs.name)
        
        return """
            LEFT JOIN \(Contact.self) ON \(contact[.id]) = \(thread[.id])
            LEFT JOIN \(ClosedGroup.self) ON \(closedGroup[.threadId]) = \(thread[.id])
            LEFT JOIN (
                SELECT
                    \(interaction[.threadId]),
                    MAX(\(interaction[.timestampMs])) AS \(timestampMsColumnLiteral)
                FROM \(Interaction.self)
                WHERE \(SQL("\(interaction[.variant]) IN \(Interaction.Variant.variantsToShowConversationSnippet)"))
                GROUP BY \(interaction[.threadId])
            ) AS \(Interaction.self) ON \(interaction[.threadId]) = \(thread[.id])
        """
    }()
    
    static func homeFilterSQL(userSessionId: SessionId) -> SQL {
        let thread: TypedTableAlias<SessionThread> = TypedTableAlias()
        let contact: TypedTableAlias<Contact> = TypedTableAlias()
        let closedGroup: TypedTableAlias<ClosedGroup> = TypedTableAlias()
        
        return """
            \(thread[.shouldBeVisible]) = true AND
            -- Is not a message request
            COALESCE(\(closedGroup[.invited]), false) = false AND (
                \(SQL("\(thread[.variant]) != \(SessionThread.Variant.contact)")) OR
                \(SQL("\(thread[.id]) = \(userSessionId.hexString)")) OR
                \(contact[.isApproved]) = true
            ) AND
            -- Is not a blocked contact
            (
                \(SQL("\(thread[.variant]) != \(SessionThread.Variant.contact)")) OR
                \(contact[.isBlocked]) != true
            )
        """
    }
    
    static func messageRequestsFilterSQL(userSessionId: SessionId) -> SQL {
        let thread: TypedTableAlias<SessionThread> = TypedTableAlias()
        let contact: TypedTableAlias<Contact> = TypedTableAlias()
        let closedGroup: TypedTableAlias<ClosedGroup> = TypedTableAlias()
        
        return """
            \(thread[.shouldBeVisible]) = true AND (
                -- Is a message request
                COALESCE(\(closedGroup[.invited]), false) = true OR (
                    \(SQL("\(thread[.variant]) = \(SessionThread.Variant.contact)")) AND
                    \(SQL("\(thread[.id]) != \(userSessionId.hexString)")) AND
                    IFNULL(\(contact[.isApproved]), false) = false
                )
            )
        """
    }
    
    static let groupSQL: SQL = {
        let thread: TypedTableAlias<SessionThread> = TypedTableAlias()
        
        return SQL("GROUP BY \(thread[.id])")
    }()
    
    static let homeOrderSQL: SQL = {
        let thread: TypedTableAlias<SessionThread> = TypedTableAlias()
        let interaction: TypedTableAlias<Interaction> = TypedTableAlias()
        
        return SQL("""
            (IFNULL(\(thread[.pinnedPriority]), 0) > 0) DESC,
            IFNULL(\(interaction[.timestampMs]), (\(thread[.creationDateTimestamp]) * 1000)) DESC
        """)
    }()
    
    static let messageRequetsOrderSQL: SQL = {
        let thread: TypedTableAlias<SessionThread> = TypedTableAlias()
        let interaction: TypedTableAlias<Interaction> = TypedTableAlias()
        
        return SQL("IFNULL(\(interaction[.timestampMs]), (\(thread[.creationDateTimestamp]) * 1000)) DESC")
    }()
}

// MARK: - ConversationVC

public extension SessionThreadViewModel {
    /// **Note:** This query **will** include deleted incoming messages in it's unread count (they should never be marked as unread
    /// but including this warning just in case there is a discrepancy)
    static func conversationQuery(threadId: String, userSessionId: SessionId) -> AdaptedFetchRequest<SQLRequest<SessionThreadViewModel>> {
        let thread: TypedTableAlias<SessionThread> = TypedTableAlias()
        let disappearingMessagesConfiguration: TypedTableAlias<DisappearingMessagesConfiguration> = TypedTableAlias()
        let contact: TypedTableAlias<Contact> = TypedTableAlias()
        let contactProfile: TypedTableAlias<Profile> = TypedTableAlias(ViewModel.self, column: .contactProfile)
        let closedGroup: TypedTableAlias<ClosedGroup> = TypedTableAlias()
        let groupMember: TypedTableAlias<GroupMember> = TypedTableAlias()
        let openGroup: TypedTableAlias<OpenGroup> = TypedTableAlias()
        let aggregateInteraction: TypedTableAlias<AggregateInteraction> = TypedTableAlias(name: "aggregateInteraction")
        let interaction: TypedTableAlias<Interaction> = TypedTableAlias()
        let closedGroupUserCount: TypedTableAlias<ClosedGroupUserCount> = TypedTableAlias(name: "closedGroupUserCount")
        
        /// **Note:** The `numColumnsBeforeProfiles` value **MUST** match the number of fields before
        /// the `disappearingMessageSConfiguration` entry below otherwise the query will fail to parse and might throw
        ///
        /// Explicitly set default values for the fields ignored for search results
        let numColumnsBeforeProfiles: Int = 18
        let request: SQLRequest<ViewModel> = """
            SELECT
                \(thread[.rowId]) AS \(ViewModel.Columns.rowId),
                \(thread[.id]) AS \(ViewModel.Columns.threadId),
                \(thread[.variant]) AS \(ViewModel.Columns.threadVariant),
                \(thread[.creationDateTimestamp]) AS \(ViewModel.Columns.threadCreationDateTimestamp),
                
                (\(SQL("\(thread[.id]) = \(userSessionId.hexString)"))) AS \(ViewModel.Columns.threadIsNoteToSelf),
                (
                    SELECT \(contactProfile[.id])
                    FROM \(contactProfile.self)
                    LEFT JOIN \(contact.self) ON \(contactProfile[.id]) = \(contact[.id])
                    LEFT JOIN \(groupMember.self) ON \(groupMember[.groupId]) = \(threadId)
                    WHERE (
                        (\(groupMember[.profileId]) = \(contactProfile[.id]) OR
                        \(contact[.id]) = \(threadId)) AND
                        \(contact[.id]) <> \(userSessionId.hexString) AND
                        \(contact[.lastKnownClientVersion]) = \(FeatureVersion.legacyDisappearingMessages)
                    )
                ) AS \(ViewModel.Columns.outdatedMemberId),
                (
                    COALESCE(\(closedGroup[.invited]), false) = true OR (
                        \(SQL("\(thread[.variant]) = \(SessionThread.Variant.contact)")) AND
                        \(SQL("\(thread[.id]) != \(userSessionId.hexString)")) AND
                        IFNULL(\(contact[.isApproved]), false) = false
                    )
                ) AS \(ViewModel.Columns.threadIsMessageRequest),
                (
                    \(SQL("\(thread[.variant]) = \(SessionThread.Variant.contact)")) AND
                    IFNULL(\(contact[.didApproveMe]), false) = false
                ) AS \(ViewModel.Columns.threadRequiresApproval),
                \(thread[.shouldBeVisible]) AS \(ViewModel.Columns.threadShouldBeVisible),
        
                IFNULL(\(thread[.pinnedPriority]), 0) AS \(ViewModel.Columns.threadPinnedPriority),
                \(contact[.isBlocked]) AS \(ViewModel.Columns.threadIsBlocked),
                \(thread[.mutedUntilTimestamp]) AS \(ViewModel.Columns.threadMutedUntilTimestamp),
                \(thread[.onlyNotifyForMentions]) AS \(ViewModel.Columns.threadOnlyNotifyForMentions),
                \(thread[.messageDraft]) AS \(ViewModel.Columns.threadMessageDraft),
                \(thread[.isDraft]) AS \(ViewModel.Columns.threadIsDraft),
                
                \(thread[.markedAsUnread]) AS \(ViewModel.Columns.threadWasMarkedUnread),
                \(aggregateInteraction[.threadUnreadCount]),
                \(aggregateInteraction[.threadHasUnreadMessagesOfAnyKind]),
        
                \(disappearingMessagesConfiguration.allColumns),
                \(contactProfile.allColumns),
                \(contact[.lastKnownClientVersion]) AS \(ViewModel.Columns.contactLastKnownClientVersion),
                \(closedGroup[.name]) AS \(ViewModel.Columns.closedGroupName),
                \(closedGroupUserCount[.closedGroupUserCount]),
                \(closedGroup[.expired]) AS \(ViewModel.Columns.closedGroupExpired),
                
                EXISTS (
                    SELECT 1
                    FROM \(GroupMember.self)
                    WHERE (
                        \(groupMember[.groupId]) = \(closedGroup[.threadId]) AND
                        \(SQL("\(groupMember[.role]) != \(GroupMember.Role.zombie)")) AND
                        \(SQL("\(groupMember[.profileId]) = \(userSessionId.hexString)"))
                    )
                ) AS \(ViewModel.Columns.currentUserIsClosedGroupMember),
        
                EXISTS (
                    SELECT 1
                    FROM \(GroupMember.self)
                    WHERE (
                        \(groupMember[.groupId]) = \(closedGroup[.threadId]) AND
                        \(SQL("\(groupMember[.role]) = \(GroupMember.Role.admin)")) AND
                        \(SQL("\(groupMember[.profileId]) = \(userSessionId.hexString)")) AND (
                            (
                                -- Legacy groups don't have a 'roleStatus' so just let those through
                                -- based solely on the 'role'
                                \(groupMember[.groupId]) > \(SessionId.Prefix.standard.rawValue) AND
                                \(groupMember[.groupId]) < \(SessionId.Prefix.standard.endOfRangeString)
                            ) OR
                            \(SQL("\(groupMember[.roleStatus]) = \(GroupMember.RoleStatus.accepted)"))
                        )
                    )
                ) AS \(ViewModel.Columns.currentUserIsClosedGroupAdmin),
                
                \(openGroup[.name]) AS \(ViewModel.Columns.openGroupName),
                \(openGroup[.server]) AS \(ViewModel.Columns.openGroupServer),
                \(openGroup[.roomToken]) AS \(ViewModel.Columns.openGroupRoomToken),
                \(openGroup[.publicKey]) AS \(ViewModel.Columns.openGroupPublicKey),
                \(openGroup[.userCount]) AS \(ViewModel.Columns.openGroupUserCount),
                \(openGroup[.permissions]) AS \(ViewModel.Columns.openGroupPermissions),
        
                \(aggregateInteraction[.interactionId]),
                \(aggregateInteraction[.interactionTimestampMs]),
            
                \(SQL("\(userSessionId.hexString)")) AS \(ViewModel.Columns.currentUserSessionId)
            
            FROM \(SessionThread.self)
            LEFT JOIN \(DisappearingMessagesConfiguration.self) ON \(disappearingMessagesConfiguration[.threadId]) = \(thread[.id])
            LEFT JOIN \(Contact.self) ON \(contact[.id]) = \(thread[.id])
            LEFT JOIN (
                SELECT
                    \(interaction[.id]) AS \(AggregateInteraction.Columns.interactionId),
                    \(interaction[.threadId]) AS \(AggregateInteraction.Columns.threadId),
                    MAX(\(interaction[.timestampMs])) AS \(AggregateInteraction.Columns.interactionTimestampMs),
                    SUM(\(interaction[.wasRead]) = false) AS \(AggregateInteraction.Columns.threadUnreadCount),
                    0 AS \(AggregateInteraction.Columns.threadUnreadMentionCount),
                    (SUM(\(interaction[.wasRead]) = false) > 0) AS \(AggregateInteraction.Columns.threadHasUnreadMessagesOfAnyKind)
                FROM \(Interaction.self)
                WHERE (
                    \(SQL("\(interaction[.threadId]) = \(threadId)")) AND
                    \(SQL("\(interaction[.variant]) != \(Interaction.Variant.standardIncomingDeleted)"))
                )
            ) AS \(aggregateInteraction) ON \(aggregateInteraction[.threadId]) = \(thread[.id])
            
            LEFT JOIN \(contactProfile) ON \(contactProfile[.id]) = \(thread[.id])
            LEFT JOIN \(OpenGroup.self) ON \(openGroup[.threadId]) = \(thread[.id])
            LEFT JOIN \(ClosedGroup.self) ON \(closedGroup[.threadId]) = \(thread[.id])
            LEFT JOIN (
                SELECT
                    \(groupMember[.groupId]),
                    COUNT(DISTINCT \(groupMember[.profileId])) AS \(ClosedGroupUserCount.Columns.closedGroupUserCount)
                FROM \(GroupMember.self)
                WHERE (
                    \(SQL("\(groupMember[.groupId]) = \(threadId)")) AND
                    \(SQL("\(groupMember[.role]) != \(GroupMember.Role.zombie)"))
                )
            ) AS \(closedGroupUserCount) ON \(SQL("\(closedGroupUserCount[.groupId]) = \(threadId)"))
            
            WHERE \(SQL("\(thread[.id]) = \(threadId)"))
        """
        
        return request.adapted { db in
            let adapters = try splittingRowAdapters(columnCounts: [
                numColumnsBeforeProfiles,
                DisappearingMessagesConfiguration.numberOfSelectedColumns(db),
                Profile.numberOfSelectedColumns(db)
            ])
            
            return ScopeAdapter.with(ViewModel.self, [
                .disappearingMessagesConfiguration: adapters[1],
                .contactProfile: adapters[2]
            ])
        }
    }
    
    static func conversationSettingsQuery(threadId: String, userSessionId: SessionId) -> AdaptedFetchRequest<SQLRequest<SessionThreadViewModel>> {
        let thread: TypedTableAlias<SessionThread> = TypedTableAlias()
        let contact: TypedTableAlias<Contact> = TypedTableAlias()
        let contactProfile: TypedTableAlias<Profile> = TypedTableAlias(ViewModel.self, column: .contactProfile)
        let closedGroup: TypedTableAlias<ClosedGroup> = TypedTableAlias()
        let closedGroupProfileFront: TypedTableAlias<Profile> = TypedTableAlias(ViewModel.self, column: .closedGroupProfileFront)
        let closedGroupProfileBack: TypedTableAlias<Profile> = TypedTableAlias(ViewModel.self, column: .closedGroupProfileBack)
        let closedGroupProfileBackFallback: TypedTableAlias<Profile> = TypedTableAlias(ViewModel.self, column: .closedGroupProfileBackFallback)
        let closedGroupAdminProfile: TypedTableAlias<Profile> = TypedTableAlias(ViewModel.self, column: .closedGroupAdminProfile)
        let groupMember: TypedTableAlias<GroupMember> = TypedTableAlias()
        let openGroup: TypedTableAlias<OpenGroup> = TypedTableAlias()
        let profile: TypedTableAlias<Profile> = TypedTableAlias()
        
        /// **Note:** The `numColumnsBeforeProfiles` value **MUST** match the number of fields before
        /// the `contactProfile` entry below otherwise the query will fail to parse and might throw
        ///
        /// Explicitly set default values for the fields ignored for search results
        let numColumnsBeforeProfiles: Int = 9
        let request: SQLRequest<ViewModel> = """
            SELECT
                \(thread[.rowId]) AS \(ViewModel.Columns.rowId),
                \(thread[.id]) AS \(ViewModel.Columns.threadId),
                \(thread[.variant]) AS \(ViewModel.Columns.threadVariant),
                \(thread[.creationDateTimestamp]) AS \(ViewModel.Columns.threadCreationDateTimestamp),
                
                (\(SQL("\(thread[.id]) = \(userSessionId.hexString)"))) AS \(ViewModel.Columns.threadIsNoteToSelf),
                
                IFNULL(\(thread[.pinnedPriority]), 0) AS \(ViewModel.Columns.threadPinnedPriority),
                \(contact[.isBlocked]) AS \(ViewModel.Columns.threadIsBlocked),
                \(thread[.mutedUntilTimestamp]) AS \(ViewModel.Columns.threadMutedUntilTimestamp),
                \(thread[.onlyNotifyForMentions]) AS \(ViewModel.Columns.threadOnlyNotifyForMentions),
        
                \(contactProfile.allColumns),
                \(closedGroupProfileFront.allColumns),
                \(closedGroupProfileBack.allColumns),
                \(closedGroupProfileBackFallback.allColumns),
                \(closedGroupAdminProfile.allColumns),
        
                \(closedGroup[.name]) AS \(ViewModel.Columns.closedGroupName),
                \(closedGroup[.groupDescription]) AS \(ViewModel.Columns.closedGroupDescription),
                \(closedGroup[.expired]) AS \(ViewModel.Columns.closedGroupExpired),
                
                EXISTS (
                    SELECT 1
                    FROM \(GroupMember.self)
                    WHERE (
                        \(groupMember[.groupId]) = \(closedGroup[.threadId]) AND
                        \(SQL("\(groupMember[.role]) != \(GroupMember.Role.zombie)")) AND
                        \(SQL("\(groupMember[.profileId]) = \(userSessionId.hexString)"))
                    )
                ) AS \(ViewModel.Columns.currentUserIsClosedGroupMember),

                EXISTS (
                    SELECT 1
                    FROM \(GroupMember.self)
                    WHERE (
                        \(groupMember[.groupId]) = \(closedGroup[.threadId]) AND
                        \(SQL("\(groupMember[.role]) = \(GroupMember.Role.admin)")) AND
                        \(SQL("\(groupMember[.profileId]) = \(userSessionId.hexString)")) AND (
                            (
                                -- Legacy groups don't have a 'roleStatus' so just let those through
                                -- based solely on the 'role'
                                \(groupMember[.groupId]) > \(SessionId.Prefix.standard.rawValue) AND
                                \(groupMember[.groupId]) < \(SessionId.Prefix.standard.endOfRangeString)
                            ) OR
                            \(SQL("\(groupMember[.roleStatus]) = \(GroupMember.RoleStatus.accepted)"))
                        )
                    )
                ) AS \(ViewModel.Columns.currentUserIsClosedGroupAdmin),
        
                \(openGroup[.name]) AS \(ViewModel.Columns.openGroupName),
                \(openGroup[.roomDescription]) AS \(ViewModel.Columns.openGroupDescription),
                \(openGroup[.server]) AS \(ViewModel.Columns.openGroupServer),
                \(openGroup[.roomToken]) AS \(ViewModel.Columns.openGroupRoomToken),
                \(openGroup[.publicKey]) AS \(ViewModel.Columns.openGroupPublicKey),
        
                COALESCE(
                    \(openGroup[.displayPictureFilename]),
                    \(closedGroup[.displayPictureFilename]),
                    \(contactProfile[.profilePictureFileName])
                ) AS \(ViewModel.Columns.displayPictureFilename),
                    
                \(SQL("\(userSessionId.hexString)")) AS \(ViewModel.Columns.currentUserSessionId)
            
            FROM \(SessionThread.self)
            LEFT JOIN \(Contact.self) ON \(contact[.id]) = \(thread[.id])
            LEFT JOIN \(contactProfile) ON \(contactProfile[.id]) = \(thread[.id])
            LEFT JOIN \(OpenGroup.self) ON \(openGroup[.threadId]) = \(thread[.id])
            LEFT JOIN \(ClosedGroup.self) ON \(closedGroup[.threadId]) = \(thread[.id])
        
            LEFT JOIN \(closedGroupProfileFront) ON (
                \(closedGroupProfileFront[.id]) = (
                    SELECT MIN(\(groupMember[.profileId]))
                    FROM \(GroupMember.self)
                    JOIN \(Profile.self) ON \(profile[.id]) = \(groupMember[.profileId])
                    WHERE (
                        \(groupMember[.groupId]) = \(closedGroup[.threadId]) AND
                        \(SQL("\(groupMember[.role]) = \(GroupMember.Role.standard)")) AND
                        \(SQL("\(groupMember[.profileId]) != \(userSessionId.hexString)"))
                    )
                )
            )
            LEFT JOIN \(closedGroupProfileBack) ON (
                \(closedGroupProfileBack[.id]) != \(closedGroupProfileFront[.id]) AND
                \(closedGroupProfileBack[.id]) = (
                    SELECT MAX(\(groupMember[.profileId]))
                    FROM \(GroupMember.self)
                    JOIN \(Profile.self) ON \(profile[.id]) = \(groupMember[.profileId])
                    WHERE (
                        \(groupMember[.groupId]) = \(closedGroup[.threadId]) AND
                        \(SQL("\(groupMember[.role]) = \(GroupMember.Role.standard)")) AND
                        \(SQL("\(groupMember[.profileId]) != \(userSessionId.hexString)"))
                    )
                )
            )
            LEFT JOIN \(closedGroupProfileBackFallback) ON (
                \(closedGroup[.threadId]) IS NOT NULL AND
                \(closedGroupProfileBack[.id]) IS NULL AND
                \(closedGroupProfileBackFallback[.id]) = \(SQL("\(userSessionId.hexString)"))
            )            
            LEFT JOIN \(closedGroupAdminProfile.never)
            
            WHERE \(SQL("\(thread[.id]) = \(threadId)"))
        """
        
        return request.adapted { db in
            let adapters = try splittingRowAdapters(columnCounts: [
                numColumnsBeforeProfiles,
                Profile.numberOfSelectedColumns(db),
                Profile.numberOfSelectedColumns(db),
                Profile.numberOfSelectedColumns(db),
                Profile.numberOfSelectedColumns(db),
                Profile.numberOfSelectedColumns(db)
            ])
            
            return ScopeAdapter.with(ViewModel.self, [
                .contactProfile: adapters[1],
                .closedGroupProfileFront: adapters[2],
                .closedGroupProfileBack: adapters[3],
                .closedGroupProfileBackFallback: adapters[4],
                .closedGroupAdminProfile: adapters[5]
            ])
        }
    }
}

// MARK: - Search Queries

public extension SessionThreadViewModel {
    static let searchResultsLimit: Int = 500
    
    /// FTS will fail or try to process characters outside of `[A-Za-z0-9]` are included directly in a search
    /// term, in order to resolve this the term needs to be wrapped in quotation marks so the eventual SQL
    /// is `MATCH '"{term}"'` or `MATCH '"{term}"*'`
    static func searchSafeTerm(_ term: String) -> String {
        return "\"\(term)\""
    }
    
    static func searchTermParts(_ searchTerm: String) -> [String] {
        /// Process the search term in order to extract the parts of the search pattern we want
        ///
        /// Step 1 - Keep any "quoted" sections as stand-alone search
        /// Step 2 - Separate any words outside of quotes
        /// Step 3 - Join the different search term parts with 'OR" (include results for each individual term)
        /// Step 4 - Append a wild-card character to the final word (as long as the last word doesn't end in a quote)
        let normalisedTerm: String = standardQuotes(searchTerm)
        
        guard let regex = try? NSRegularExpression(pattern: "[^\\s\"']+|\"([^\"]*)\"") else {
            // Fallback to removing the quotes and just splitting on spaces
            return normalisedTerm
                .replacingOccurrences(of: "\"", with: "")
                .split(separator: " ")
                .map { "\"\($0)\"" }
                .filter { !$0.isEmpty }
        }
            
        return regex
            .matches(in: normalisedTerm, range: NSRange(location: 0, length: normalisedTerm.count))
            .compactMap { Range($0.range, in: normalisedTerm) }
            .map { normalisedTerm[$0].trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
            .map { "\"\($0)\"" }
    }
    
    static func standardQuotes(_ term: String) -> String {
        // Apple like to use the special '""' quote characters when typing so replace them with normal ones
        return term
            .replacingOccurrences(of: "”", with: "\"")
            .replacingOccurrences(of: "“", with: "\"")
    }
    
    static func pattern(_ db: Database, searchTerm: String) throws -> FTS5Pattern {
        return try pattern(db, searchTerm: searchTerm, forTable: Interaction.self)
    }
    
    static func pattern<T>(_ db: Database, searchTerm: String, forTable table: T.Type) throws -> FTS5Pattern where T: TableRecord, T: ColumnExpressible {
        // Note: FTS doesn't support both prefix/suffix wild cards so don't bother trying to
        // add a prefix one
        let rawPattern: String = {
            let result: String = searchTermParts(searchTerm)
                .joined(separator: " OR ")
            
            // If the last character is a quotation mark then assume the user doesn't want to append
            // a wildcard character
            guard !standardQuotes(searchTerm).hasSuffix("\"") else { return result }
            
            return "\(result)*"
        }()
        let fallbackTerm: String = "\(searchSafeTerm(searchTerm))*"
        
        /// There are cases where creating a pattern can fail, we want to try and recover from those cases
        /// by failling back to simpler patterns if needed
        return try {
            if let pattern: FTS5Pattern = try? db.makeFTS5Pattern(rawPattern: rawPattern, forTable: table) {
                return pattern
            }
            
            if let pattern: FTS5Pattern = try? db.makeFTS5Pattern(rawPattern: fallbackTerm, forTable: table) {
                return pattern
            }
            
            return try FTS5Pattern(matchingAnyTokenIn: fallbackTerm) ?? { throw StorageError.invalidSearchPattern }()
        }()
    }
    
    static func messagesQuery(userSessionId: SessionId, pattern: FTS5Pattern) -> AdaptedFetchRequest<SQLRequest<SessionThreadViewModel>> {
        let interaction: TypedTableAlias<Interaction> = TypedTableAlias()
        let thread: TypedTableAlias<SessionThread> = TypedTableAlias()
        let profile: TypedTableAlias<Profile> = TypedTableAlias()
        let contactProfile: TypedTableAlias<Profile> = TypedTableAlias(ViewModel.self, column: .contactProfile)
        let closedGroup: TypedTableAlias<ClosedGroup> = TypedTableAlias()
        let closedGroupProfileFront: TypedTableAlias<Profile> = TypedTableAlias(ViewModel.self, column: .closedGroupProfileFront)
        let closedGroupProfileBack: TypedTableAlias<Profile> = TypedTableAlias(ViewModel.self, column: .closedGroupProfileBack)
        let closedGroupProfileBackFallback: TypedTableAlias<Profile> = TypedTableAlias(ViewModel.self, column: .closedGroupProfileBackFallback)
        let closedGroupAdminProfile: TypedTableAlias<Profile> = TypedTableAlias(ViewModel.self, column: .closedGroupAdminProfile)
        let groupMember: TypedTableAlias<GroupMember> = TypedTableAlias()
        let openGroup: TypedTableAlias<OpenGroup> = TypedTableAlias()
        let interactionFullTextSearch: TypedTableAlias<Interaction.FullTextSearch> = TypedTableAlias(name: Interaction.fullTextSearchTableName)
        
        /// **Note:** The `numColumnsBeforeProfiles` value **MUST** match the number of fields before
        /// the `ViewModel.contactProfileKey` entry below otherwise the query will fail to
        /// parse and might throw
        ///
        /// Explicitly set default values for the fields ignored for search results
        let numColumnsBeforeProfiles: Int = 6
        let request: SQLRequest<ViewModel> = """
            SELECT
                \(interaction[.rowId]) AS \(ViewModel.Columns.rowId),
                \(thread[.id]) AS \(ViewModel.Columns.threadId),
                \(thread[.variant]) AS \(ViewModel.Columns.threadVariant),
                \(thread[.creationDateTimestamp]) AS \(ViewModel.Columns.threadCreationDateTimestamp),
                
                (\(SQL("\(thread[.id]) = \(userSessionId.hexString)"))) AS \(ViewModel.Columns.threadIsNoteToSelf),
                IFNULL(\(thread[.pinnedPriority]), 0) AS \(ViewModel.Columns.threadPinnedPriority),
                
                \(contactProfile.allColumns),
                \(closedGroupProfileFront.allColumns),
                \(closedGroupProfileBack.allColumns),
                \(closedGroupProfileBackFallback.allColumns),
                \(closedGroupAdminProfile.allColumns),
                \(closedGroup[.name]) AS \(ViewModel.Columns.closedGroupName),
                \(openGroup[.name]) AS \(ViewModel.Columns.openGroupName),
        
                COALESCE(
                    \(openGroup[.displayPictureFilename]),
                    \(closedGroup[.displayPictureFilename]),
                    \(contactProfile[.profilePictureFileName])
                ) AS \(ViewModel.Columns.displayPictureFilename),
            
                \(interaction[.id]) AS \(ViewModel.Columns.interactionId),
                \(interaction[.variant]) AS \(ViewModel.Columns.interactionVariant),
                \(interaction[.timestampMs]) AS \(ViewModel.Columns.interactionTimestampMs),
                snippet(\(interactionFullTextSearch), -1, '', '', '...', 6) AS \(ViewModel.Columns.interactionBody),
        
                \(interaction[.authorId]),
                IFNULL(\(profile[.nickname]), \(profile[.name])) AS \(ViewModel.Columns.authorNameInternal),
                \(SQL("\(userSessionId.hexString)")) AS \(ViewModel.Columns.currentUserSessionId)
            
            FROM \(Interaction.self)
            JOIN \(interactionFullTextSearch) ON (
                \(interactionFullTextSearch[.rowId]) = \(interaction[.rowId]) AND
                \(interactionFullTextSearch[.body]) MATCH \(pattern)
            )
            JOIN \(SessionThread.self) ON \(thread[.id]) = \(interaction[.threadId])
            JOIN \(Profile.self) ON \(profile[.id]) = \(interaction[.authorId])
            LEFT JOIN \(contactProfile) ON \(contactProfile[.id]) = \(interaction[.threadId])
            LEFT JOIN \(ClosedGroup.self) ON \(closedGroup[.threadId]) = \(interaction[.threadId])
            LEFT JOIN \(OpenGroup.self) ON \(openGroup[.threadId]) = \(interaction[.threadId])
        
            LEFT JOIN \(closedGroupProfileFront) ON (
                \(closedGroupProfileFront[.id]) = (
                    SELECT MIN(\(groupMember[.profileId]))
                    FROM \(GroupMember.self)
                    JOIN \(Profile.self) ON \(profile[.id]) = \(groupMember[.profileId])
                    WHERE (
                        \(SQL("\(groupMember[.role]) = \(GroupMember.Role.standard)")) AND
                        \(groupMember[.groupId]) = \(closedGroup[.threadId]) AND
                        \(groupMember[.profileId]) != \(userSessionId.hexString)
                    )
                )
            )
            LEFT JOIN \(closedGroupProfileBack) ON (
                \(closedGroupProfileBack[.id]) != \(closedGroupProfileFront[.id]) AND
                \(closedGroupProfileBack[.id]) = (
                    SELECT MAX(\(groupMember[.profileId]))
                    FROM \(GroupMember.self)
                    JOIN \(Profile.self) ON \(profile[.id]) = \(groupMember[.profileId])
                    WHERE (
                        \(SQL("\(groupMember[.role]) = \(GroupMember.Role.standard)")) AND
                        \(groupMember[.groupId]) = \(closedGroup[.threadId]) AND
                        \(groupMember[.profileId]) != \(userSessionId.hexString)
                    )
                )
            )
            LEFT JOIN \(closedGroupProfileBackFallback) ON (
                \(closedGroup[.threadId]) IS NOT NULL AND
                \(closedGroupProfileBack[.id]) IS NULL AND
                \(closedGroupProfileBackFallback[.id]) = \(userSessionId.hexString)
            )            
            LEFT JOIN \(closedGroupAdminProfile.never)
        
            ORDER BY \(Column.rank), \(interaction[.timestampMs].desc)
            LIMIT \(SQL("\(SessionThreadViewModel.searchResultsLimit)"))
        """
        
        return request.adapted { db in
            let adapters = try splittingRowAdapters(columnCounts: [
                numColumnsBeforeProfiles,
                Profile.numberOfSelectedColumns(db),
                Profile.numberOfSelectedColumns(db),
                Profile.numberOfSelectedColumns(db),
                Profile.numberOfSelectedColumns(db),
                Profile.numberOfSelectedColumns(db)
            ])
            
            return ScopeAdapter.with(ViewModel.self, [
                .contactProfile: adapters[1],
                .closedGroupProfileFront: adapters[2],
                .closedGroupProfileBack: adapters[3],
                .closedGroupProfileBackFallback: adapters[4],
                .closedGroupAdminProfile: adapters[5]
            ])
        }
    }
    
    /// This method does an FTS search against threads and their contacts to find any which contain the pattern
    ///
    /// **Note:** Unfortunately the FTS search only allows for a single pattern match per query which means we
    /// need to combine the results of **all** of the following potential matches as unioned queries:
    /// - Contact thread contact nickname
    /// - Contact thread contact name
    /// - Closed group name
    /// - Closed group member nickname
    /// - Closed group member name
    /// - Open group name
    /// - "Note to self" text match
    /// - Hidden contact nickname
    /// - Hidden contact name
    ///
    /// **Note 2:** Since the "Hidden Contact" records don't have associated threads the `rowId` value in the
    /// returned results will always be `-1` for those results
    static func contactsAndGroupsQuery(userSessionId: SessionId, pattern: FTS5Pattern, searchTerm: String) -> AdaptedFetchRequest<SQLRequest<SessionThreadViewModel>> {
        let thread: TypedTableAlias<SessionThread> = TypedTableAlias()
        let contactProfile: TypedTableAlias<Profile> = TypedTableAlias(ViewModel.self, column: .contactProfile)
        let closedGroup: TypedTableAlias<ClosedGroup> = TypedTableAlias()
        let closedGroupProfileFront: TypedTableAlias<Profile> = TypedTableAlias(ViewModel.self, column: .closedGroupProfileFront)
        let closedGroupProfileBack: TypedTableAlias<Profile> = TypedTableAlias(ViewModel.self, column: .closedGroupProfileBack)
        let closedGroupProfileBackFallback: TypedTableAlias<Profile> = TypedTableAlias(ViewModel.self, column: .closedGroupProfileBackFallback)
        let closedGroupAdminProfile: TypedTableAlias<Profile> = TypedTableAlias(ViewModel.self, column: .closedGroupAdminProfile)
        let groupMember: TypedTableAlias<GroupMember> = TypedTableAlias()
        let groupMemberProfile: TypedTableAlias<Profile> = TypedTableAlias(name: "groupMemberProfile")
        let openGroup: TypedTableAlias<OpenGroup> = TypedTableAlias()
        let groupMemberInfo: TypedTableAlias<GroupMemberInfo> = TypedTableAlias(name: "groupMemberInfo")
        let profile: TypedTableAlias<Profile> = TypedTableAlias()
        let contact: TypedTableAlias<Contact> = TypedTableAlias()
        let profileFullTextSearch: TypedTableAlias<Profile.FullTextSearch> = TypedTableAlias(name: Profile.fullTextSearchTableName)
        let closedGroupFullTextSearch: TypedTableAlias<ClosedGroup.FullTextSearch> = TypedTableAlias(name: ClosedGroup.fullTextSearchTableName)
        let openGroupFullTextSearch: TypedTableAlias<OpenGroup.FullTextSearch> = TypedTableAlias(name: OpenGroup.fullTextSearchTableName)
        
        let noteToSelfLiteral: SQL = SQL(stringLiteral: "noteToSelf".localized().lowercased())
        let searchTermLiteral: SQL = SQL(stringLiteral: searchTerm.lowercased())
        
        /// **Note:** The `numColumnsBeforeProfiles` value **MUST** match the number of fields before
        /// the `contactProfile` entry below otherwise the query will fail to parse and might throw
        ///
        /// We use `IFNULL(rank, 100)` because the custom `Note to Self` like comparison will get a null
        /// `rank` value which ends up as the first result, by defaulting to `100` it will always be ranked last compared
        /// to any relevance-based results
        let numColumnsBeforeProfiles: Int = 8
        var sqlQuery: SQL = ""
        let selectQuery: SQL = """
            SELECT
                IFNULL(\(Column.rank), 100) AS \(Column.rank),
                
                \(thread[.rowId]) AS \(ViewModel.Columns.rowId),
                \(thread[.id]) AS \(ViewModel.Columns.threadId),
                \(thread[.variant]) AS \(ViewModel.Columns.threadVariant),
                \(thread[.creationDateTimestamp]) AS \(ViewModel.Columns.threadCreationDateTimestamp),
                \(groupMemberInfo[.threadMemberNames]),
                
                (\(SQL("\(thread[.id]) = \(userSessionId.hexString)"))) AS \(ViewModel.Columns.threadIsNoteToSelf),
                IFNULL(\(thread[.pinnedPriority]), 0) AS \(ViewModel.Columns.threadPinnedPriority),
                
                \(contactProfile.allColumns),
                \(closedGroupProfileFront.allColumns),
                \(closedGroupProfileBack.allColumns),
                \(closedGroupProfileBackFallback.allColumns),
                \(closedGroupAdminProfile.allColumns),
                \(closedGroup[.name]) AS \(ViewModel.Columns.closedGroupName),
                \(openGroup[.name]) AS \(ViewModel.Columns.openGroupName),
        
                COALESCE(
                    \(openGroup[.displayPictureFilename]),
                    \(closedGroup[.displayPictureFilename]),
                    \(contactProfile[.profilePictureFileName])
                ) AS \(ViewModel.Columns.displayPictureFilename),
                
                \(SQL("\(userSessionId.hexString)")) AS \(ViewModel.Columns.currentUserSessionId)

            FROM \(SessionThread.self)
        
        """
        
        // MARK: --Contact Threads
        let contactQueryCommonJoinFilterGroup: SQL = """
            JOIN \(contactProfile) ON \(contactProfile[.id]) = \(thread[.id])
            LEFT JOIN \(closedGroupProfileFront.never)
            LEFT JOIN \(closedGroupProfileBack.never)
            LEFT JOIN \(closedGroupProfileBackFallback.never)
            LEFT JOIN \(closedGroupAdminProfile.never)
            LEFT JOIN \(closedGroup.never)
            LEFT JOIN \(openGroup.never)
            LEFT JOIN \(groupMemberInfo.never)
        
            WHERE
                \(SQL("\(thread[.variant]) = \(SessionThread.Variant.contact)")) AND
                \(SQL("\(thread[.id]) != \(userSessionId.hexString)"))
            GROUP BY \(thread[.id])
        """
        
        // Contact thread nickname searching (ignoring note to self - handled separately)
        sqlQuery += selectQuery
        sqlQuery += """
            JOIN \(profileFullTextSearch) ON (
                \(profileFullTextSearch[.rowId]) = \(contactProfile[.rowId]) AND
                \(profileFullTextSearch[.nickname]) MATCH \(pattern)
            )
        """
        sqlQuery += contactQueryCommonJoinFilterGroup
        
        // Contact thread name searching (ignoring note to self - handled separately)
        sqlQuery += """
        
            UNION ALL
        
        """
        sqlQuery += selectQuery
        sqlQuery += """
            JOIN \(profileFullTextSearch) ON (
                \(profileFullTextSearch[.rowId]) = \(contactProfile[.rowId]) AND
                \(profileFullTextSearch[.name]) MATCH \(pattern)
            )
        """
        sqlQuery += contactQueryCommonJoinFilterGroup
        
        // MARK: --Closed Group Threads
        let closedGroupQueryCommonJoinFilterGroup: SQL = """
            JOIN \(ClosedGroup.self) ON \(closedGroup[.threadId]) = \(thread[.id])
            JOIN \(GroupMember.self) ON (
                \(SQL("\(groupMember[.role]) = \(GroupMember.Role.standard)")) AND
                \(groupMember[.groupId]) = \(thread[.id])
            )
            LEFT JOIN (
                SELECT
                    \(groupMember[.groupId]),
                    GROUP_CONCAT(IFNULL(\(profile[.nickname]), \(profile[.name])), ', ') AS \(GroupMemberInfo.Columns.threadMemberNames)
                FROM \(GroupMember.self)
                JOIN \(Profile.self) ON \(profile[.id]) = \(groupMember[.profileId])
                WHERE \(SQL("\(groupMember[.role]) = \(GroupMember.Role.standard)"))
                GROUP BY \(groupMember[.groupId])
            ) AS \(groupMemberInfo) ON \(groupMemberInfo[.groupId]) = \(closedGroup[.threadId])
            LEFT JOIN \(closedGroupProfileFront) ON (
                \(closedGroupProfileFront[.id]) = (
                    SELECT MIN(\(groupMember[.profileId]))
                    FROM \(GroupMember.self)
                    JOIN \(Profile.self) ON \(profile[.id]) = \(groupMember[.profileId])
                    WHERE (
                        \(SQL("\(groupMember[.role]) = \(GroupMember.Role.standard)")) AND
                        \(groupMember[.groupId]) = \(closedGroup[.threadId]) AND
                        \(groupMember[.profileId]) != \(userSessionId.hexString)
                    )
                )
            )
            LEFT JOIN \(closedGroupProfileBack) ON (
                \(closedGroupProfileBack[.id]) != \(closedGroupProfileFront[.id]) AND
                \(closedGroupProfileBack[.id]) = (
                    SELECT MAX(\(groupMember[.profileId]))
                    FROM \(GroupMember.self)
                    JOIN \(Profile.self) ON \(profile[.id]) = \(groupMember[.profileId])
                    WHERE (
                        \(SQL("\(groupMember[.role]) = \(GroupMember.Role.standard)")) AND
                        \(groupMember[.groupId]) = \(closedGroup[.threadId]) AND
                        \(groupMember[.profileId]) != \(userSessionId.hexString)
                    )
                )
            )
            LEFT JOIN \(closedGroupProfileBackFallback) ON (
                \(closedGroupProfileBack[.id]) IS NULL AND
                \(closedGroupProfileBackFallback[.id]) = \(userSessionId.hexString)
            )
            LEFT JOIN \(closedGroupAdminProfile.never)
        
            LEFT JOIN \(contactProfile.never)
            LEFT JOIN \(openGroup.never)
        
            WHERE (
                \(SQL("\(thread[.variant]) = \(SessionThread.Variant.legacyGroup)")) OR
                \(SQL("\(thread[.variant]) = \(SessionThread.Variant.group)"))
            )
            GROUP BY \(thread[.id])
        """
        
        // Closed group thread name searching
        sqlQuery += """
        
            UNION ALL
        
        """
        sqlQuery += selectQuery
        sqlQuery += """
            JOIN \(closedGroupFullTextSearch) ON (
                \(closedGroupFullTextSearch[.rowId]) = \(closedGroup[.rowId]) AND
                \(closedGroupFullTextSearch[.name]) MATCH \(pattern)
            )
        """
        sqlQuery += closedGroupQueryCommonJoinFilterGroup
        
        // Closed group member nickname searching
        sqlQuery += """
        
            UNION ALL
        
        """
        sqlQuery += selectQuery
        sqlQuery += """
            JOIN \(groupMemberProfile) ON \(groupMemberProfile[.id]) = \(groupMember[.profileId])
            JOIN \(profileFullTextSearch) ON (
                \(profileFullTextSearch[.rowId]) = \(groupMemberProfile[.rowId]) AND
                \(profileFullTextSearch[.nickname]) MATCH \(pattern)
            )
        """
        sqlQuery += closedGroupQueryCommonJoinFilterGroup
        
        // Closed group member name searching
        sqlQuery += """
        
            UNION ALL
        
        """
        sqlQuery += selectQuery
        sqlQuery += """
            JOIN \(groupMemberProfile) ON \(groupMemberProfile[.id]) = \(groupMember[.profileId])
            JOIN \(profileFullTextSearch) ON (
                \(profileFullTextSearch[.rowId]) = \(groupMemberProfile[.rowId]) AND
                \(profileFullTextSearch[.name]) MATCH \(pattern)
            )
        """
        sqlQuery += closedGroupQueryCommonJoinFilterGroup
        
        // MARK: --Open Group Threads
        // Open group thread name searching
        sqlQuery += """
        
            UNION ALL
        
        """
        sqlQuery += selectQuery
        sqlQuery += """
            JOIN \(OpenGroup.self) ON \(openGroup[.threadId]) = \(thread[.id])
            JOIN \(openGroupFullTextSearch) ON (
                \(openGroupFullTextSearch[.rowId]) = \(openGroup[.rowId]) AND
                \(openGroupFullTextSearch[.name]) MATCH \(pattern)
            )
            LEFT JOIN \(contactProfile.never)
            LEFT JOIN \(closedGroupProfileFront.never)
            LEFT JOIN \(closedGroupProfileBack.never)
            LEFT JOIN \(closedGroupProfileBackFallback.never)
            LEFT JOIN \(closedGroupAdminProfile.never)
            LEFT JOIN \(closedGroup.never)
            LEFT JOIN \(groupMemberInfo.never)
        
            WHERE
                \(SQL("\(thread[.variant]) = \(SessionThread.Variant.community)")) AND
                \(SQL("\(thread[.id]) != \(userSessionId.hexString)"))
            GROUP BY \(thread[.id])
        """
        
        // MARK: --Note to Self Thread
        let noteToSelfQueryCommonJoins: SQL = """
            JOIN \(contactProfile) ON \(contactProfile[.id]) = \(thread[.id])
            LEFT JOIN \(closedGroupProfileFront.never)
            LEFT JOIN \(closedGroupProfileBack.never)
            LEFT JOIN \(closedGroupProfileBackFallback.never)
            LEFT JOIN \(closedGroupAdminProfile.never)
            LEFT JOIN \(openGroup.never)
            LEFT JOIN \(closedGroup.never)
            LEFT JOIN \(groupMemberInfo.never)
        """
        
        // Note to self thread searching for 'Note to Self' (need to join an FTS table to
        // ensure there is a 'rank' column)
        sqlQuery += """
        
            UNION ALL
        
        """
        sqlQuery += selectQuery
        sqlQuery += """
        
            LEFT JOIN \(profileFullTextSearch) ON false
        """
        sqlQuery += noteToSelfQueryCommonJoins
        sqlQuery += """
        
            WHERE
                \(SQL("\(thread[.id]) = \(userSessionId.hexString)")) AND
                '\(noteToSelfLiteral)' LIKE '%\(searchTermLiteral)%'
        """
        
        // Note to self thread nickname searching
        sqlQuery += """
        
            UNION ALL
        
        """
        sqlQuery += selectQuery
        sqlQuery += """
        
            JOIN \(profileFullTextSearch) ON (
                \(profileFullTextSearch[.rowId]) = \(contactProfile[.rowId]) AND
                \(profileFullTextSearch[.nickname]) MATCH \(pattern)
            )
        """
        sqlQuery += noteToSelfQueryCommonJoins
        sqlQuery += """
        
            WHERE \(SQL("\(thread[.id]) = \(userSessionId.hexString)"))
        """
        
        // Note to self thread name searching
        sqlQuery += """
        
            UNION ALL
        
        """
        sqlQuery += selectQuery
        sqlQuery += """
        
            JOIN \(profileFullTextSearch) ON (
                \(profileFullTextSearch[.rowId]) = \(contactProfile[.rowId]) AND
                \(profileFullTextSearch[.name]) MATCH \(pattern)
            )
        """
        sqlQuery += noteToSelfQueryCommonJoins
        sqlQuery += """
        
            WHERE \(SQL("\(thread[.id]) = \(userSessionId.hexString)"))
        """
        
        // MARK: --Contacts without threads
        let hiddenContactQuery: SQL = """
            SELECT
                IFNULL(\(Column.rank), 100) AS \(Column.rank),
                
                -1 AS \(ViewModel.Columns.rowId),
                \(contact[.id]) AS \(ViewModel.Columns.threadId),
                \(SQL("\(SessionThread.Variant.contact)")) AS \(ViewModel.Columns.threadVariant),
                0 AS \(ViewModel.Columns.threadCreationDateTimestamp),
                \(groupMemberInfo[.threadMemberNames]),
                
                false AS \(ViewModel.Columns.threadIsNoteToSelf),
                -1 AS \(ViewModel.Columns.threadPinnedPriority),
                
                \(contactProfile.allColumns),
                \(closedGroupProfileFront.allColumns),
                \(closedGroupProfileBack.allColumns),
                \(closedGroupProfileBackFallback.allColumns),
                \(closedGroupAdminProfile.allColumns),
                \(closedGroup[.name]) AS \(ViewModel.Columns.closedGroupName),
                \(openGroup[.name]) AS \(ViewModel.Columns.openGroupName),
                
                COALESCE(
                    \(openGroup[.displayPictureFilename]),
                    \(closedGroup[.displayPictureFilename]),
                    \(contactProfile[.profilePictureFileName])
                ) AS \(ViewModel.Columns.displayPictureFilename),
                
                \(SQL("\(userSessionId.hexString)")) AS \(ViewModel.Columns.currentUserSessionId)

            FROM \(Contact.self)
        """
        let hiddenContactQueryCommonJoins: SQL = """
            JOIN \(contactProfile) ON \(contactProfile[.id]) = \(contact[.id])
            LEFT JOIN \(SessionThread.self) ON \(thread[.id]) = \(contact[.id])
            LEFT JOIN \(closedGroupProfileFront.never)
            LEFT JOIN \(closedGroupProfileBack.never)
            LEFT JOIN \(closedGroupProfileBackFallback.never)
            LEFT JOIN \(closedGroupAdminProfile.never)
            LEFT JOIN \(closedGroup.never)
            LEFT JOIN \(openGroup.never)
            LEFT JOIN \(groupMemberInfo.never)
        
            WHERE \(thread[.id]) IS NULL
            GROUP BY \(contact[.id])
        """
        
        // Hidden contact by nickname
        sqlQuery += """
        
            UNION ALL
        
        """
        sqlQuery += hiddenContactQuery
        sqlQuery += """
        
            JOIN \(profileFullTextSearch) ON (
                \(profileFullTextSearch[.rowId]) = \(contactProfile[.rowId]) AND
                \(profileFullTextSearch[.nickname]) MATCH \(pattern)
            )
        """
        sqlQuery += hiddenContactQueryCommonJoins
        
        // Hidden contact by name
        sqlQuery += """
        
            UNION ALL
        
        """
        sqlQuery += hiddenContactQuery
        sqlQuery += """
        
            JOIN \(profileFullTextSearch) ON (
                \(profileFullTextSearch[.rowId]) = \(contactProfile[.rowId]) AND
                \(profileFullTextSearch[.name]) MATCH \(pattern)
            )
        """
        sqlQuery += hiddenContactQueryCommonJoins
        
        // Group everything by 'threadId' (the same thread can be found in multiple queries due
        // to seaerching both nickname and name), then order everything by 'rank' (relevance)
        // first, 'Note to Self' second (want it to appear at the bottom of threads unless it
        // has relevance) adn then try to group and sort based on thread type and names
        let finalQuery: SQL = """
            SELECT *
            FROM (
                \(sqlQuery)
            )
        
            GROUP BY \(ViewModel.Columns.threadId)
            ORDER BY
                \(Column.rank),
                \(ViewModel.Columns.threadIsNoteToSelf),
                \(ViewModel.Columns.closedGroupName),
                \(ViewModel.Columns.openGroupName),
                \(ViewModel.Columns.threadId)
            LIMIT \(SQL("\(SessionThreadViewModel.searchResultsLimit)"))
        """
        
        // Construct the actual request
        let request: SQLRequest<ViewModel> = SQLRequest(
            literal: finalQuery,
            adapter: RenameColumnAdapter { column in
                // Note: The query automatically adds a suffix to the various profile columns
                // to make them easier to distinguish (ie. 'id' -> 'id:1') - this breaks the
                // decoding so we need to strip the information after the colon
                guard column.contains(":") else { return column }
                
                return String(column.split(separator: ":")[0])
            },
            cached: false
        )
        
        // Add adapters which will group the various 'Profile' columns so they can be decoded
        // as instances of 'Profile' types
        return request.adapted { db in
            let adapters = try splittingRowAdapters(columnCounts: [
                numColumnsBeforeProfiles,
                Profile.numberOfSelectedColumns(db),
                Profile.numberOfSelectedColumns(db),
                Profile.numberOfSelectedColumns(db),
                Profile.numberOfSelectedColumns(db),
                Profile.numberOfSelectedColumns(db)
            ])

            return ScopeAdapter.with(ViewModel.self, [
                .contactProfile: adapters[1],
                .closedGroupProfileFront: adapters[2],
                .closedGroupProfileBack: adapters[3],
                .closedGroupProfileBackFallback: adapters[4],
                .closedGroupAdminProfile: adapters[5]
            ])
        }
    }
    
    static func defaultContactsQuery(using dependencies: Dependencies) -> AdaptedFetchRequest<SQLRequest<SessionThreadViewModel>> {
        let userSessionId: SessionId = dependencies[cache: .general].sessionId
        let currentTimestamp: TimeInterval = dependencies.dateNow.timeIntervalSince1970
        
        let thread: TypedTableAlias<SessionThread> = TypedTableAlias()
        let contact: TypedTableAlias<Contact> = TypedTableAlias()
        let contactProfile: TypedTableAlias<Profile> = TypedTableAlias(ViewModel.self, column: .contactProfile)
        
        /// **Note:** The `numColumnsBeforeProfiles` value **MUST** match the number of fields before
        /// the `contactProfile` entry below otherwise the query will fail to parse and might throw
        let numColumnsBeforeProfiles: Int = 8
        let request: SQLRequest<ViewModel> = """
            SELECT
                100 AS \(Column.rank),
                
                \(contact[.rowId]) AS \(ViewModel.Columns.rowId),
                \(contact[.id]) AS \(ViewModel.Columns.threadId),
                \(SessionThread.Variant.contact) AS \(ViewModel.Columns.threadVariant),
                IFNULL(\(thread[.creationDateTimestamp]), \(currentTimestamp)) AS \(ViewModel.Columns.threadCreationDateTimestamp),
                '' AS \(ViewModel.Columns.threadMemberNames),
                
                (\(SQL("\(contact[.id]) = \(userSessionId.hexString)"))) AS \(ViewModel.Columns.threadIsNoteToSelf),
                IFNULL(\(thread[.pinnedPriority]), 0) AS \(ViewModel.Columns.threadPinnedPriority),
                
                \(contactProfile.allColumns),
                
                \(SQL("\(userSessionId.hexString)")) AS \(ViewModel.Columns.currentUserSessionId)

            FROM \(Contact.self)
            LEFT JOIN \(thread) ON \(thread[.id]) = \(contact[.id])
            LEFT JOIN \(contactProfile) ON \(contactProfile[.id]) = \(contact[.id])
            WHERE \(contact[.isBlocked]) = false
        """
        
        // Add adapters which will group the various 'Profile' columns so they can be decoded
        // as instances of 'Profile' types
        return request.adapted { db in
            let adapters = try splittingRowAdapters(columnCounts: [
                numColumnsBeforeProfiles,
                Profile.numberOfSelectedColumns(db)
            ])
            
            return ScopeAdapter.with(ViewModel.self, [
                .contactProfile: adapters[1]
            ])
        }
    }
    
    /// This method returns only the 'Note to Self' thread in the structure of a search result conversation
    static func noteToSelfOnlyQuery(userSessionId: SessionId) -> AdaptedFetchRequest<SQLRequest<SessionThreadViewModel>> {
        let thread: TypedTableAlias<SessionThread> = TypedTableAlias()
        let contactProfile: TypedTableAlias<Profile> = TypedTableAlias(ViewModel.self, column: .contactProfile)
        
        /// **Note:** The `numColumnsBeforeProfiles` value **MUST** match the number of fields before
        /// the `contactProfile` entry below otherwise the query will fail to parse and might throw
        let numColumnsBeforeProfiles: Int = 8
        let request: SQLRequest<ViewModel> = """
            SELECT
                100 AS \(Column.rank),
                
                \(thread[.rowId]) AS \(ViewModel.Columns.rowId),
                \(thread[.id]) AS \(ViewModel.Columns.threadId),
                \(thread[.variant]) AS \(ViewModel.Columns.threadVariant),
                \(thread[.creationDateTimestamp]) AS \(ViewModel.Columns.threadCreationDateTimestamp),
                '' AS \(ViewModel.Columns.threadMemberNames),
                
                true AS \(ViewModel.Columns.threadIsNoteToSelf),
                IFNULL(\(thread[.pinnedPriority]), 0) AS \(ViewModel.Columns.threadPinnedPriority),
                
                \(contactProfile.allColumns),
                
                \(SQL("\(userSessionId.hexString)")) AS \(ViewModel.Columns.currentUserSessionId)

            FROM \(SessionThread.self)
            JOIN \(contactProfile) ON \(contactProfile[.id]) = \(thread[.id])
        
            WHERE \(SQL("\(thread[.id]) = \(userSessionId.hexString)"))
        """
        
        // Add adapters which will group the various 'Profile' columns so they can be decoded
        // as instances of 'Profile' types
        return request.adapted { db in
            let adapters = try splittingRowAdapters(columnCounts: [
                numColumnsBeforeProfiles,
                Profile.numberOfSelectedColumns(db)
            ])

            return ScopeAdapter.with(ViewModel.self, [
                .contactProfile: adapters[1]
            ])
        }
    }
}

// MARK: - Share Extension

public extension SessionThreadViewModel {
    static func shareQuery(userSessionId: SessionId) -> AdaptedFetchRequest<SQLRequest<SessionThreadViewModel>> {
        let thread: TypedTableAlias<SessionThread> = TypedTableAlias()
        let contact: TypedTableAlias<Contact> = TypedTableAlias()
        let contactProfile: TypedTableAlias<Profile> = TypedTableAlias(ViewModel.self, column: .contactProfile)
        let closedGroup: TypedTableAlias<ClosedGroup> = TypedTableAlias()
        let closedGroupProfileFront: TypedTableAlias<Profile> = TypedTableAlias(ViewModel.self, column: .closedGroupProfileFront)
        let closedGroupProfileBack: TypedTableAlias<Profile> = TypedTableAlias(ViewModel.self, column: .closedGroupProfileBack)
        let closedGroupProfileBackFallback: TypedTableAlias<Profile> = TypedTableAlias(ViewModel.self, column: .closedGroupProfileBackFallback)
        let closedGroupAdminProfile: TypedTableAlias<Profile> = TypedTableAlias(ViewModel.self, column: .closedGroupAdminProfile)
        let groupMember: TypedTableAlias<GroupMember> = TypedTableAlias()
        let openGroup: TypedTableAlias<OpenGroup> = TypedTableAlias()
        let profile: TypedTableAlias<Profile> = TypedTableAlias()
        let aggregateInteraction: TypedTableAlias<AggregateInteraction> = TypedTableAlias(name: "aggregateInteraction")
        let interaction: TypedTableAlias<Interaction> = TypedTableAlias()
        
        /// **Note:** The `numColumnsBeforeProfiles` value **MUST** match the number of fields before
        /// the `contactProfile` entry below otherwise the query will fail to parse and might throw
        ///
        /// Explicitly set default values for the fields ignored for search results
        let numColumnsBeforeProfiles: Int = 8
        
        let request: SQLRequest<ViewModel> = """
            SELECT
                \(thread[.rowId]) AS \(ViewModel.Columns.rowId),
                \(thread[.id]) AS \(ViewModel.Columns.threadId),
                \(thread[.variant]) AS \(ViewModel.Columns.threadVariant),
                \(thread[.creationDateTimestamp]) AS \(ViewModel.Columns.threadCreationDateTimestamp),
                
                (\(SQL("\(thread[.id]) = \(userSessionId.hexString)"))) AS \(ViewModel.Columns.threadIsNoteToSelf),
                (
                    COALESCE(\(closedGroup[.invited]), false) = true OR (
                        \(SQL("\(thread[.variant]) = \(SessionThread.Variant.contact)")) AND
                        \(SQL("\(thread[.id]) != \(userSessionId.hexString)")) AND
                        IFNULL(\(contact[.isApproved]), false) = false
                    )
                ) AS \(ViewModel.Columns.threadIsMessageRequest),
                
                IFNULL(\(thread[.pinnedPriority]), 0) AS \(ViewModel.Columns.threadPinnedPriority),
                \(contact[.isBlocked]) AS \(ViewModel.Columns.threadIsBlocked),
        
                \(contactProfile.allColumns),
                \(closedGroupProfileFront.allColumns),
                \(closedGroupProfileBack.allColumns),
                \(closedGroupProfileBackFallback.allColumns),
                \(closedGroupAdminProfile.allColumns),
                \(closedGroup[.name]) AS \(ViewModel.Columns.closedGroupName),
                \(closedGroup[.expired]) AS \(ViewModel.Columns.closedGroupExpired),
        
                EXISTS (
                    SELECT 1
                    FROM \(GroupMember.self)
                    WHERE (
                        \(groupMember[.groupId]) = \(closedGroup[.threadId]) AND
                        \(SQL("\(groupMember[.role]) != \(GroupMember.Role.zombie)")) AND
                        \(SQL("\(groupMember[.profileId]) = \(userSessionId.hexString)"))
                    )
                ) AS \(ViewModel.Columns.currentUserIsClosedGroupMember),
        
                \(openGroup[.name]) AS \(ViewModel.Columns.openGroupName),
                \(openGroup[.permissions]) AS \(ViewModel.Columns.openGroupPermissions),
        
                COALESCE(
                    \(openGroup[.displayPictureFilename]),
                    \(closedGroup[.displayPictureFilename]),
                    \(contactProfile[.profilePictureFileName])
                ) AS \(ViewModel.Columns.displayPictureFilename),
        
                \(interaction[.id]) AS \(ViewModel.Columns.interactionId),
                \(interaction[.variant]) AS \(ViewModel.Columns.interactionVariant),
        
                \(SQL("\(userSessionId.hexString)")) AS \(ViewModel.Columns.currentUserSessionId)
            
            FROM \(SessionThread.self)
            LEFT JOIN \(Contact.self) ON \(contact[.id]) = \(thread[.id])
            
            LEFT JOIN (
                SELECT
                    \(interaction[.id]) AS \(AggregateInteraction.Columns.interactionId),
                    \(interaction[.threadId]) AS \(AggregateInteraction.Columns.threadId),
                    MAX(\(interaction[.timestampMs])) AS \(AggregateInteraction.Columns.interactionTimestampMs),
                    0 AS \(AggregateInteraction.Columns.threadUnreadCount),
                    0 AS \(AggregateInteraction.Columns.threadUnreadMentionCount)
                FROM \(Interaction.self)
                WHERE \(SQL("\(interaction[.variant]) IN \(Interaction.Variant.variantsToShowConversationSnippet)"))
                GROUP BY \(interaction[.threadId])
            ) AS \(aggregateInteraction) ON \(aggregateInteraction[.threadId]) = \(thread[.id])
            LEFT JOIN \(Interaction.self) ON (
                \(interaction[.threadId]) = \(thread[.id]) AND
                \(interaction[.id]) = \(aggregateInteraction[.interactionId])
            )
        
            LEFT JOIN \(contactProfile) ON \(contactProfile[.id]) = \(thread[.id])
            LEFT JOIN \(ClosedGroup.self) ON \(closedGroup[.threadId]) = \(thread[.id])
            LEFT JOIN \(OpenGroup.self) ON \(openGroup[.threadId]) = \(thread[.id])
        
            LEFT JOIN \(closedGroupProfileFront) ON (
                \(closedGroupProfileFront[.id]) = (
                    SELECT MIN(\(groupMember[.profileId]))
                    FROM \(GroupMember.self)
                    JOIN \(Profile.self) ON \(profile[.id]) = \(groupMember[.profileId])
                    WHERE (
                        \(SQL("\(groupMember[.role]) = \(GroupMember.Role.standard)")) AND
                        \(groupMember[.groupId]) = \(closedGroup[.threadId]) AND
                        \(SQL("\(groupMember[.profileId]) != \(userSessionId.hexString)"))
                    )
                )
            )
            LEFT JOIN \(closedGroupProfileBack) ON (
                \(closedGroupProfileBack[.id]) != \(closedGroupProfileFront[.id]) AND
                \(closedGroupProfileBack[.id]) = (
                    SELECT MAX(\(groupMember[.profileId]))
                    FROM \(GroupMember.self)
                    JOIN \(Profile.self) ON \(profile[.id]) = \(groupMember[.profileId])
                    WHERE (
                        \(SQL("\(groupMember[.role]) = \(GroupMember.Role.standard)")) AND
                        \(groupMember[.groupId]) = \(closedGroup[.threadId]) AND
                        \(SQL("\(groupMember[.profileId]) != \(userSessionId.hexString)"))
                    )
                )
            )
            LEFT JOIN \(closedGroupProfileBackFallback) ON (
                \(closedGroup[.threadId]) IS NOT NULL AND
                \(closedGroupProfileBack[.id]) IS NULL AND
                \(closedGroupProfileBackFallback[.id]) = \(SQL("\(userSessionId.hexString)"))
            )
            LEFT JOIN \(closedGroupAdminProfile.never)
            
            WHERE (
                \(thread[.shouldBeVisible]) = true AND
                COALESCE(\(closedGroup[.invited]), false) = false AND (
                    -- Is not a message request
                    \(SQL("\(thread[.variant]) != \(SessionThread.Variant.contact)")) OR
                    \(SQL("\(thread[.id]) = \(userSessionId.hexString)")) OR
                    \(contact[.isApproved]) = true
                )
                -- Always show the 'Note to Self' thread when sharing
                OR \(SQL("\(thread[.id]) = \(userSessionId.hexString)"))
            )
        
            GROUP BY \(thread[.id])
            -- 'Note to Self', then by most recent message
            ORDER BY \(SQL("\(thread[.id]) = \(userSessionId.hexString)")) DESC, IFNULL(\(interaction[.timestampMs]), (\(thread[.creationDateTimestamp]) * 1000)) DESC
        """
        
        return request.adapted { db in
            let adapters = try splittingRowAdapters(columnCounts: [
                numColumnsBeforeProfiles,
                Profile.numberOfSelectedColumns(db),
                Profile.numberOfSelectedColumns(db),
                Profile.numberOfSelectedColumns(db),
                Profile.numberOfSelectedColumns(db),
                Profile.numberOfSelectedColumns(db)
            ])
            
            return ScopeAdapter.with(ViewModel.self, [
                .contactProfile: adapters[1],
                .closedGroupProfileFront: adapters[2],
                .closedGroupProfileBack: adapters[3],
                .closedGroupProfileBackFallback: adapters[4],
                .closedGroupAdminProfile: adapters[5]
            ])
        }
    }
}
