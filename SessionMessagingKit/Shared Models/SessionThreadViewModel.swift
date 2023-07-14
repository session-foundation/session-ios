// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import Sodium
import DifferenceKit
import SessionUtilitiesKit

fileprivate typealias ViewModel = SessionThreadViewModel

/// This type is used to populate the `ConversationCell` in the `HomeVC`, `MessageRequestsViewController` and the
/// `GlobalSearchViewController`, it has a number of query methods which can be used to retrieve the relevant data for each
/// screen in a single location in an attempt to avoid spreading out _almost_ duplicated code in multiple places
///
/// **Note:** When updating the UI make sure to check the actual queries being run as some fields will have incorrect default values
/// in order to optimise their queries to only include the required data
public struct SessionThreadViewModel: FetchableRecordWithRowId, Decodable, Equatable, Hashable, Identifiable, Differentiable {
    public static let rowIdKey: SQL = SQL(stringLiteral: CodingKeys.rowId.stringValue)
    public static let threadIdKey: SQL = SQL(stringLiteral: CodingKeys.threadId.stringValue)
    public static let threadVariantKey: SQL = SQL(stringLiteral: CodingKeys.threadVariant.stringValue)
    public static let threadCreationDateTimestampKey: SQL = SQL(stringLiteral: CodingKeys.threadCreationDateTimestamp.stringValue)
    public static let threadMemberNamesKey: SQL = SQL(stringLiteral: CodingKeys.threadMemberNames.stringValue)
    public static let threadIsNoteToSelfKey: SQL = SQL(stringLiteral: CodingKeys.threadIsNoteToSelf.stringValue)
    public static let threadIsMessageRequestKey: SQL = SQL(stringLiteral: CodingKeys.threadIsMessageRequest.stringValue)
    public static let threadRequiresApprovalKey: SQL = SQL(stringLiteral: CodingKeys.threadRequiresApproval.stringValue)
    public static let threadShouldBeVisibleKey: SQL = SQL(stringLiteral: CodingKeys.threadShouldBeVisible.stringValue)
    public static let threadPinnedPriorityKey: SQL = SQL(stringLiteral: CodingKeys.threadPinnedPriority.stringValue)
    public static let threadIsBlockedKey: SQL = SQL(stringLiteral: CodingKeys.threadIsBlocked.stringValue)
    public static let threadMutedUntilTimestampKey: SQL = SQL(stringLiteral: CodingKeys.threadMutedUntilTimestamp.stringValue)
    public static let threadOnlyNotifyForMentionsKey: SQL = SQL(stringLiteral: CodingKeys.threadOnlyNotifyForMentions.stringValue)
    public static let threadMessageDraftKey: SQL = SQL(stringLiteral: CodingKeys.threadMessageDraft.stringValue)
    public static let threadContactIsTypingKey: SQL = SQL(stringLiteral: CodingKeys.threadContactIsTyping.stringValue)
    public static let threadWasMarkedUnreadKey: SQL = SQL(stringLiteral: CodingKeys.threadWasMarkedUnread.stringValue)
    public static let threadUnreadCountKey: SQL = SQL(stringLiteral: CodingKeys.threadUnreadCount.stringValue)
    public static let threadUnreadMentionCountKey: SQL = SQL(stringLiteral: CodingKeys.threadUnreadMentionCount.stringValue)
    public static let disappearingMessagesConfigurationKey: SQL = SQL(stringLiteral: CodingKeys.disappearingMessagesConfiguration.stringValue)
    public static let contactProfileKey: SQL = SQL(stringLiteral: CodingKeys.contactProfile.stringValue)
    public static let closedGroupNameKey: SQL = SQL(stringLiteral: CodingKeys.closedGroupName.stringValue)
    public static let closedGroupUserCountKey: SQL = SQL(stringLiteral: CodingKeys.closedGroupUserCount.stringValue)
    public static let currentUserIsClosedGroupMemberKey: SQL = SQL(stringLiteral: CodingKeys.currentUserIsClosedGroupMember.stringValue)
    public static let currentUserIsClosedGroupAdminKey: SQL = SQL(stringLiteral: CodingKeys.currentUserIsClosedGroupAdmin.stringValue)
    public static let closedGroupProfileFrontKey: SQL = SQL(stringLiteral: CodingKeys.closedGroupProfileFront.stringValue)
    public static let closedGroupProfileBackKey: SQL = SQL(stringLiteral: CodingKeys.closedGroupProfileBack.stringValue)
    public static let closedGroupProfileBackFallbackKey: SQL = SQL(stringLiteral: CodingKeys.closedGroupProfileBackFallback.stringValue)
    public static let openGroupNameKey: SQL = SQL(stringLiteral: CodingKeys.openGroupName.stringValue)
    public static let openGroupServerKey: SQL = SQL(stringLiteral: CodingKeys.openGroupServer.stringValue)
    public static let openGroupRoomTokenKey: SQL = SQL(stringLiteral: CodingKeys.openGroupRoomToken.stringValue)
    public static let openGroupPublicKeyKey: SQL = SQL(stringLiteral: CodingKeys.openGroupPublicKey.stringValue)
    public static let openGroupProfilePictureDataKey: SQL = SQL(stringLiteral: CodingKeys.openGroupProfilePictureData.stringValue)
    public static let openGroupUserCountKey: SQL = SQL(stringLiteral: CodingKeys.openGroupUserCount.stringValue)
    public static let openGroupPermissionsKey: SQL = SQL(stringLiteral: CodingKeys.openGroupPermissions.stringValue)
    public static let interactionIdKey: SQL = SQL(stringLiteral: CodingKeys.interactionId.stringValue)
    public static let interactionVariantKey: SQL = SQL(stringLiteral: CodingKeys.interactionVariant.stringValue)
    public static let interactionTimestampMsKey: SQL = SQL(stringLiteral: CodingKeys.interactionTimestampMs.stringValue)
    public static let interactionBodyKey: SQL = SQL(stringLiteral: CodingKeys.interactionBody.stringValue)
    public static let interactionStateKey: SQL = SQL(stringLiteral: CodingKeys.interactionState.stringValue)
    public static let interactionHasAtLeastOneReadReceiptKey: SQL = SQL(stringLiteral: CodingKeys.interactionHasAtLeastOneReadReceipt.stringValue)
    public static let interactionIsOpenGroupInvitationKey: SQL = SQL(stringLiteral: CodingKeys.interactionIsOpenGroupInvitation.stringValue)
    public static let interactionAttachmentDescriptionInfoKey: SQL = SQL(stringLiteral: CodingKeys.interactionAttachmentDescriptionInfo.stringValue)
    public static let interactionAttachmentCountKey: SQL = SQL(stringLiteral: CodingKeys.interactionAttachmentCount.stringValue)
    public static let threadContactNameInternalKey: SQL = SQL(stringLiteral: CodingKeys.threadContactNameInternal.stringValue)
    public static let authorNameInternalKey: SQL = SQL(stringLiteral: CodingKeys.authorNameInternal.stringValue)
    public static let currentUserPublicKeyKey: SQL = SQL(stringLiteral: CodingKeys.currentUserPublicKey.stringValue)
    
    public static let threadWasMarkedUnreadString: String = CodingKeys.threadWasMarkedUnread.stringValue
    public static let threadUnreadCountString: String = CodingKeys.threadUnreadCount.stringValue
    public static let threadUnreadMentionCountString: String = CodingKeys.threadUnreadMentionCount.stringValue
    public static let closedGroupUserCountString: String = CodingKeys.closedGroupUserCount.stringValue
    public static let openGroupUserCountString: String = CodingKeys.openGroupUserCount.stringValue
    public static let disappearingMessagesConfigurationString: String = CodingKeys.disappearingMessagesConfiguration.stringValue
    public static let contactProfileString: String = CodingKeys.contactProfile.stringValue
    public static let closedGroupProfileFrontString: String = CodingKeys.closedGroupProfileFront.stringValue
    public static let closedGroupProfileBackString: String = CodingKeys.closedGroupProfileBack.stringValue
    public static let closedGroupProfileBackFallbackString: String = CodingKeys.closedGroupProfileBackFallback.stringValue
    public static let interactionAttachmentDescriptionInfoString: String = CodingKeys.interactionAttachmentDescriptionInfo.stringValue
    
    public var differenceIdentifier: String { threadId }
    public var id: String { threadId }
    
    public let rowId: Int64
    public let threadId: String
    public let threadVariant: SessionThread.Variant
    private let threadCreationDateTimestamp: TimeInterval
    public let threadMemberNames: String?
    
    public let threadIsNoteToSelf: Bool
    
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
    
    public let threadContactIsTyping: Bool?
    public let threadWasMarkedUnread: Bool?
    public let threadUnreadCount: UInt?
    public let threadUnreadMentionCount: UInt?
    
    public var canWrite: Bool {
        switch threadVariant {
            case .contact: return true
            case .legacyGroup, .group:
                return (
                    currentUserIsClosedGroupMember == true &&
                    interactionVariant?.isGroupLeavingStatus != true
                )
                
            case .community:
                return (openGroupPermissions?.contains(.write) ?? false)
        }
    }
    
    // Thread display info
    
    public let disappearingMessagesConfiguration: DisappearingMessagesConfiguration?
    
    private let contactProfile: Profile?
    private let closedGroupProfileFront: Profile?
    private let closedGroupProfileBack: Profile?
    private let closedGroupProfileBackFallback: Profile?
    public let closedGroupName: String?
    private let closedGroupUserCount: Int?
    public let currentUserIsClosedGroupMember: Bool?
    public let currentUserIsClosedGroupAdmin: Bool?
    public let openGroupName: String?
    public let openGroupServer: String?
    public let openGroupRoomToken: String?
    public let openGroupPublicKey: String?
    public let openGroupProfilePictureData: Data?
    private let openGroupUserCount: Int?
    private let openGroupPermissions: OpenGroup.Permissions?
    
    // Interaction display info
    
    public let interactionId: Int64?
    public let interactionVariant: Interaction.Variant?
    public let interactionTimestampMs: Int64?
    public let interactionBody: String?
    public let interactionState: RecipientState.State?
    public let interactionHasAtLeastOneReadReceipt: Bool?
    public let interactionIsOpenGroupInvitation: Bool?
    public let interactionAttachmentDescriptionInfo: Attachment.DescriptionInfo?
    public let interactionAttachmentCount: Int?
    
    public let authorId: String?
    private let threadContactNameInternal: String?
    private let authorNameInternal: String?
    public let currentUserPublicKey: String
    public let currentUserBlinded15PublicKey: String?
    public let currentUserBlinded25PublicKey: String?
    public let recentReactionEmoji: [String]?
    
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
                        
        return Date(timeIntervalSince1970: (TimeInterval(interactionTimestampMs) / 1000))
    }
    
    public var enabledMessageTypes: MessageInputTypes {
        guard !threadIsNoteToSelf else { return .all }
        
        return (threadRequiresApproval == false && threadIsMessageRequest == false ?
            .all :
            .textOnly
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
            nickname: nil,  // Folded into 'threadContactNameInternal' within the Query
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
            nickname: nil,  // Folded into 'authorName' within the Query
            customFallback: (threadVariant == .contact ?
                "Anonymous" :
                nil
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
    public func markAsRead(target: ReadTarget) {
        // Store the logic to mark a thread as read (to paths need to run this)
        let threadId: String = self.threadId
        let threadWasMarkedUnread: Bool? = self.threadWasMarkedUnread
        let markThreadAsReadIfNeeded: () -> () = {
            // Only make this change if needed (want to avoid triggering a thread update
            // if not needed)
            guard threadWasMarkedUnread == true else { return }
            
            Storage.shared.writeAsync { db in
                try SessionThread
                    .filter(id: threadId)
                    .updateAllAndConfig(
                        db,
                        SessionThread.Columns.markedAsUnread.set(to: false)
                    )
            }
        }
        
        // Determine what we want to mark as read
        switch target {
            // Only mark the thread as read
            case .thread: markThreadAsReadIfNeeded()
            
            // We want to mark both the thread and interactions as read
            case .threadAndInteractions(let interactionId):
                guard
                    (self.threadUnreadCount ?? 0) > 0,
                    let targetInteractionId: Int64 = (interactionId ?? self.interactionId)
                else {
                    // No unread interactions so just mark the thread as read if needed
                    markThreadAsReadIfNeeded()
                    return
                }
                
                let threadId: String = self.threadId
                let threadVariant: SessionThread.Variant = self.threadVariant
                let threadIsBlocked: Bool? = self.threadIsBlocked
                let threadIsMessageRequest: Bool? = self.threadIsMessageRequest
                
                Storage.shared.writeAsync { db in
                    markThreadAsReadIfNeeded()
                    
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
                            isMessageRequest: threadIsMessageRequest
                        )
                    )
                }
        }
    }
    
    /// This method will mark a thread as read
    public func markAsUnread() {
        guard self.threadWasMarkedUnread != true else { return }
        
        let threadId: String = self.threadId
        
        Storage.shared.writeAsync { db in
            try SessionThread
                .filter(id: threadId)
                .updateAllAndConfig(
                    db,
                    SessionThread.Columns.markedAsUnread.set(to: true)
                )
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
        threadIsBlocked: Bool? = nil,
        contactProfile: Profile? = nil,
        currentUserIsClosedGroupMember: Bool? = nil,
        openGroupPermissions: OpenGroup.Permissions? = nil,
        unreadCount: UInt = 0,
        disappearingMessagesConfiguration: DisappearingMessagesConfiguration? = nil
    ) {
        self.rowId = -1
        self.threadId = threadId
        self.threadVariant = (threadVariant ?? .contact)
        self.threadCreationDateTimestamp = 0
        self.threadMemberNames = nil
        
        self.threadIsNoteToSelf = threadIsNoteToSelf
        self.threadIsMessageRequest = false
        self.threadRequiresApproval = false
        self.threadShouldBeVisible = false
        self.threadPinnedPriority = 0
        self.threadIsBlocked = threadIsBlocked
        self.threadMutedUntilTimestamp = nil
        self.threadOnlyNotifyForMentions = nil
        self.threadMessageDraft = nil
        
        self.threadContactIsTyping = nil
        self.threadWasMarkedUnread = nil
        self.threadUnreadCount = unreadCount
        self.threadUnreadMentionCount = nil
        
        // Thread display info
        
        self.disappearingMessagesConfiguration = disappearingMessagesConfiguration
        
        self.contactProfile = contactProfile
        self.closedGroupProfileFront = nil
        self.closedGroupProfileBack = nil
        self.closedGroupProfileBackFallback = nil
        self.closedGroupName = nil
        self.closedGroupUserCount = nil
        self.currentUserIsClosedGroupMember = currentUserIsClosedGroupMember
        self.currentUserIsClosedGroupAdmin = nil
        self.openGroupName = nil
        self.openGroupServer = nil
        self.openGroupRoomToken = nil
        self.openGroupPublicKey = nil
        self.openGroupProfilePictureData = nil
        self.openGroupUserCount = nil
        self.openGroupPermissions = openGroupPermissions
        
        // Interaction display info
        
        self.interactionId = nil
        self.interactionVariant = nil
        self.interactionTimestampMs = nil
        self.interactionBody = nil
        self.interactionState = nil
        self.interactionHasAtLeastOneReadReceipt = nil
        self.interactionIsOpenGroupInvitation = nil
        self.interactionAttachmentDescriptionInfo = nil
        self.interactionAttachmentCount = nil
        
        self.authorId = nil
        self.threadContactNameInternal = nil
        self.authorNameInternal = nil
        self.currentUserPublicKey = getUserHexEncodedPublicKey()
        self.currentUserBlinded15PublicKey = nil
        self.currentUserBlinded25PublicKey = nil
        self.recentReactionEmoji = nil
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
            threadIsMessageRequest: self.threadIsMessageRequest,
            threadRequiresApproval: self.threadRequiresApproval,
            threadShouldBeVisible: self.threadShouldBeVisible,
            threadPinnedPriority: self.threadPinnedPriority,
            threadIsBlocked: self.threadIsBlocked,
            threadMutedUntilTimestamp: self.threadMutedUntilTimestamp,
            threadOnlyNotifyForMentions: self.threadOnlyNotifyForMentions,
            threadMessageDraft: self.threadMessageDraft,
            threadContactIsTyping: self.threadContactIsTyping,
            threadWasMarkedUnread: self.threadWasMarkedUnread,
            threadUnreadCount: self.threadUnreadCount,
            threadUnreadMentionCount: self.threadUnreadMentionCount,
            disappearingMessagesConfiguration: self.disappearingMessagesConfiguration,
            contactProfile: self.contactProfile,
            closedGroupProfileFront: self.closedGroupProfileFront,
            closedGroupProfileBack: self.closedGroupProfileBack,
            closedGroupProfileBackFallback: self.closedGroupProfileBackFallback,
            closedGroupName: self.closedGroupName,
            closedGroupUserCount: self.closedGroupUserCount,
            currentUserIsClosedGroupMember: self.currentUserIsClosedGroupMember,
            currentUserIsClosedGroupAdmin: self.currentUserIsClosedGroupAdmin,
            openGroupName: self.openGroupName,
            openGroupServer: self.openGroupServer,
            openGroupRoomToken: self.openGroupRoomToken,
            openGroupPublicKey: self.openGroupPublicKey,
            openGroupProfilePictureData: self.openGroupProfilePictureData,
            openGroupUserCount: self.openGroupUserCount,
            openGroupPermissions: self.openGroupPermissions,
            interactionId: self.interactionId,
            interactionVariant: self.interactionVariant,
            interactionTimestampMs: self.interactionTimestampMs,
            interactionBody: self.interactionBody,
            interactionState: self.interactionState,
            interactionHasAtLeastOneReadReceipt: self.interactionHasAtLeastOneReadReceipt,
            interactionIsOpenGroupInvitation: self.interactionIsOpenGroupInvitation,
            interactionAttachmentDescriptionInfo: self.interactionAttachmentDescriptionInfo,
            interactionAttachmentCount: self.interactionAttachmentCount,
            authorId: self.authorId,
            threadContactNameInternal: self.threadContactNameInternal,
            authorNameInternal: self.authorNameInternal,
            currentUserPublicKey: self.currentUserPublicKey,
            currentUserBlinded15PublicKey: self.currentUserBlinded15PublicKey,
            currentUserBlinded25PublicKey: self.currentUserBlinded25PublicKey,
            recentReactionEmoji: (recentReactionEmoji ?? self.recentReactionEmoji)
        )
    }
    
    func populatingCurrentUserBlindedKeys(
        _ db: Database? = nil,
        currentUserBlinded15PublicKeyForThisThread: String? = nil,
        currentUserBlinded25PublicKeyForThisThread: String? = nil
    ) -> SessionThreadViewModel {
        return SessionThreadViewModel(
            rowId: self.rowId,
            threadId: self.threadId,
            threadVariant: self.threadVariant,
            threadCreationDateTimestamp: self.threadCreationDateTimestamp,
            threadMemberNames: self.threadMemberNames,
            threadIsNoteToSelf: self.threadIsNoteToSelf,
            threadIsMessageRequest: self.threadIsMessageRequest,
            threadRequiresApproval: self.threadRequiresApproval,
            threadShouldBeVisible: self.threadShouldBeVisible,
            threadPinnedPriority: self.threadPinnedPriority,
            threadIsBlocked: self.threadIsBlocked,
            threadMutedUntilTimestamp: self.threadMutedUntilTimestamp,
            threadOnlyNotifyForMentions: self.threadOnlyNotifyForMentions,
            threadMessageDraft: self.threadMessageDraft,
            threadContactIsTyping: self.threadContactIsTyping,
            threadWasMarkedUnread: self.threadWasMarkedUnread,
            threadUnreadCount: self.threadUnreadCount,
            threadUnreadMentionCount: self.threadUnreadMentionCount,
            disappearingMessagesConfiguration: self.disappearingMessagesConfiguration,
            contactProfile: self.contactProfile,
            closedGroupProfileFront: self.closedGroupProfileFront,
            closedGroupProfileBack: self.closedGroupProfileBack,
            closedGroupProfileBackFallback: self.closedGroupProfileBackFallback,
            closedGroupName: self.closedGroupName,
            closedGroupUserCount: self.closedGroupUserCount,
            currentUserIsClosedGroupMember: self.currentUserIsClosedGroupMember,
            currentUserIsClosedGroupAdmin: self.currentUserIsClosedGroupAdmin,
            openGroupName: self.openGroupName,
            openGroupServer: self.openGroupServer,
            openGroupRoomToken: self.openGroupRoomToken,
            openGroupPublicKey: self.openGroupPublicKey,
            openGroupProfilePictureData: self.openGroupProfilePictureData,
            openGroupUserCount: self.openGroupUserCount,
            openGroupPermissions: self.openGroupPermissions,
            interactionId: self.interactionId,
            interactionVariant: self.interactionVariant,
            interactionTimestampMs: self.interactionTimestampMs,
            interactionBody: self.interactionBody,
            interactionState: self.interactionState,
            interactionHasAtLeastOneReadReceipt: self.interactionHasAtLeastOneReadReceipt,
            interactionIsOpenGroupInvitation: self.interactionIsOpenGroupInvitation,
            interactionAttachmentDescriptionInfo: self.interactionAttachmentDescriptionInfo,
            interactionAttachmentCount: self.interactionAttachmentCount,
            authorId: self.authorId,
            threadContactNameInternal: self.threadContactNameInternal,
            authorNameInternal: self.authorNameInternal,
            currentUserPublicKey: self.currentUserPublicKey,
            currentUserBlinded15PublicKey: (
                currentUserBlinded15PublicKeyForThisThread ??
                SessionThread.getUserHexEncodedBlindedKey(
                    db,
                    threadId: self.threadId,
                    threadVariant: self.threadVariant,
                    blindingPrefix: .blinded15
                )
            ),
            currentUserBlinded25PublicKey: (
                currentUserBlinded25PublicKeyForThisThread ??
                SessionThread.getUserHexEncodedBlindedKey(
                    db,
                    threadId: self.threadId,
                    threadVariant: self.threadVariant,
                    blindingPrefix: .blinded25
                )
            ),
            recentReactionEmoji: self.recentReactionEmoji
        )
    }
}

// MARK: - HomeVC & MessageRequestsViewController

// MARK: --SessionThreadViewModel

public extension SessionThreadViewModel {
    /// **Note:** This query **will not** include deleted incoming messages in it's unread count (they should never be marked as unread
    /// but including this warning just in case there is a discrepancy)
    static func baseQuery(
        userPublicKey: String,
        groupSQL: SQL,
        orderSQL: SQL
    ) -> (([Int64]) -> AdaptedFetchRequest<SQLRequest<SessionThreadViewModel>>) {
        return { rowIds -> AdaptedFetchRequest<SQLRequest<ViewModel>> in
            let thread: TypedTableAlias<SessionThread> = TypedTableAlias()
            let contact: TypedTableAlias<Contact> = TypedTableAlias()
            let typingIndicator: TypedTableAlias<ThreadTypingIndicator> = TypedTableAlias()
            let closedGroup: TypedTableAlias<ClosedGroup> = TypedTableAlias()
            let groupMember: TypedTableAlias<GroupMember> = TypedTableAlias()
            let openGroup: TypedTableAlias<OpenGroup> = TypedTableAlias()
            let interaction: TypedTableAlias<Interaction> = TypedTableAlias()
            let recipientState: TypedTableAlias<RecipientState> = TypedTableAlias()
            let linkPreview: TypedTableAlias<LinkPreview> = TypedTableAlias()
            let attachment: TypedTableAlias<Attachment> = TypedTableAlias()
            let interactionAttachment: TypedTableAlias<InteractionAttachment> = TypedTableAlias()
            let profile: TypedTableAlias<Profile> = TypedTableAlias()
            
            let aggregateInteractionLiteral: SQL = SQL(stringLiteral: "aggregateInteraction")
            let timestampMsColumnLiteral: SQL = SQL(stringLiteral: Interaction.Columns.timestampMs.name)
            let interactionStateInteractionIdColumnLiteral: SQL = SQL(stringLiteral: RecipientState.Columns.interactionId.name)
            let readReceiptTableLiteral: SQL = SQL(stringLiteral: "readReceipt")
            let readReceiptReadTimestampMsColumnLiteral: SQL = SQL(stringLiteral: RecipientState.Columns.readTimestampMs.name)
            let profileIdColumnLiteral: SQL = SQL(stringLiteral: Profile.Columns.id.name)
            let profileNicknameColumnLiteral: SQL = SQL(stringLiteral: Profile.Columns.nickname.name)
            let profileNameColumnLiteral: SQL = SQL(stringLiteral: Profile.Columns.name.name)
            let firstInteractionAttachmentLiteral: SQL = SQL(stringLiteral: "firstInteractionAttachment")
            let interactionAttachmentAttachmentIdColumnLiteral: SQL = SQL(stringLiteral: InteractionAttachment.Columns.attachmentId.name)
            let interactionAttachmentInteractionIdColumnLiteral: SQL = SQL(stringLiteral: InteractionAttachment.Columns.interactionId.name)
            let interactionAttachmentAlbumIndexColumnLiteral: SQL = SQL(stringLiteral: InteractionAttachment.Columns.albumIndex.name)
            
            
            /// **Note:** The `numColumnsBeforeProfiles` value **MUST** match the number of fields before
            /// the `ViewModel.contactProfileKey` entry below otherwise the query will fail to
            /// parse and might throw
            ///
            /// Explicitly set default values for the fields ignored for search results
            let numColumnsBeforeProfiles: Int = 14
            let numColumnsBetweenProfilesAndAttachmentInfo: Int = 12 // The attachment info columns will be combined
            let request: SQLRequest<ViewModel> = """
                SELECT
                    \(thread.alias[Column.rowID]) AS \(ViewModel.rowIdKey),
                    \(thread[.id]) AS \(ViewModel.threadIdKey),
                    \(thread[.variant]) AS \(ViewModel.threadVariantKey),
                    \(thread[.creationDateTimestamp]) AS \(ViewModel.threadCreationDateTimestampKey),

                    (\(SQL("\(thread[.id]) = \(userPublicKey)"))) AS \(ViewModel.threadIsNoteToSelfKey),
                    IFNULL(\(thread[.pinnedPriority]), 0) AS \(ViewModel.threadPinnedPriorityKey),
                    \(contact[.isBlocked]) AS \(ViewModel.threadIsBlockedKey),
                    \(thread[.mutedUntilTimestamp]) AS \(ViewModel.threadMutedUntilTimestampKey),
                    \(thread[.onlyNotifyForMentions]) AS \(ViewModel.threadOnlyNotifyForMentionsKey),
                    (
                        \(SQL("\(thread[.variant]) = \(SessionThread.Variant.contact)")) AND
                        \(SQL("\(thread[.id]) != \(userPublicKey)")) AND
                        IFNULL(\(contact[.isApproved]), false) = false
                    ) AS \(ViewModel.threadIsMessageRequestKey),
            
                    (\(typingIndicator[.threadId]) IS NOT NULL) AS \(ViewModel.threadContactIsTypingKey),
                    \(thread[.markedAsUnread]) AS \(ViewModel.threadWasMarkedUnreadKey),
                    \(aggregateInteractionLiteral).\(ViewModel.threadUnreadCountKey),
                    \(aggregateInteractionLiteral).\(ViewModel.threadUnreadMentionCountKey),

                    \(ViewModel.contactProfileKey).*,
                    \(ViewModel.closedGroupProfileFrontKey).*,
                    \(ViewModel.closedGroupProfileBackKey).*,
                    \(ViewModel.closedGroupProfileBackFallbackKey).*,
                    \(closedGroup[.name]) AS \(ViewModel.closedGroupNameKey),

                    EXISTS (
                        SELECT 1
                        FROM \(GroupMember.self)
                        WHERE (
                            \(groupMember[.groupId]) = \(closedGroup[.threadId]) AND
                            \(SQL("\(groupMember[.role]) != \(GroupMember.Role.zombie)")) AND
                            \(SQL("\(groupMember[.profileId]) = \(userPublicKey)"))
                        )
                    ) AS \(ViewModel.currentUserIsClosedGroupMemberKey),

                    EXISTS (
                        SELECT 1
                        FROM \(GroupMember.self)
                        WHERE (
                            \(groupMember[.groupId]) = \(closedGroup[.threadId]) AND
                            \(SQL("\(groupMember[.role]) = \(GroupMember.Role.admin)")) AND
                            \(SQL("\(groupMember[.profileId]) = \(userPublicKey)"))
                        )
                    ) AS \(ViewModel.currentUserIsClosedGroupAdminKey),

                    \(openGroup[.name]) AS \(ViewModel.openGroupNameKey),
                    \(openGroup[.imageData]) AS \(ViewModel.openGroupProfilePictureDataKey),

                    \(interaction[.id]) AS \(ViewModel.interactionIdKey),
                    \(interaction[.variant]) AS \(ViewModel.interactionVariantKey),
                    \(interaction[.timestampMs]) AS \(ViewModel.interactionTimestampMsKey),
                    \(interaction[.body]) AS \(ViewModel.interactionBodyKey),

                    -- Default to 'sending' assuming non-processed interaction when null
                    IFNULL((
                        SELECT \(recipientState[.state])
                        FROM \(RecipientState.self)
                        WHERE (
                            \(recipientState[.interactionId]) = \(interaction[.id]) AND
                            -- Ignore 'skipped' states
                            \(SQL("\(recipientState[.state]) != \(RecipientState.State.skipped)"))
                        )
                        LIMIT 1
                    ), \(SQL("\(RecipientState.State.sending)"))) AS \(ViewModel.interactionStateKey),
                    
                    (\(readReceiptTableLiteral).\(readReceiptReadTimestampMsColumnLiteral) IS NOT NULL) AS \(ViewModel.interactionHasAtLeastOneReadReceiptKey),
                    (\(linkPreview[.url]) IS NOT NULL) AS \(ViewModel.interactionIsOpenGroupInvitationKey),

                    -- These 4 properties will be combined into 'Attachment.DescriptionInfo'
                    \(attachment[.id]),
                    \(attachment[.variant]),
                    \(attachment[.contentType]),
                    \(attachment[.sourceFilename]),
                    COUNT(\(interactionAttachment[.interactionId])) AS \(ViewModel.interactionAttachmentCountKey),

                    \(interaction[.authorId]),
                    IFNULL(\(ViewModel.contactProfileKey).\(profileNicknameColumnLiteral), \(ViewModel.contactProfileKey).\(profileNameColumnLiteral)) AS \(ViewModel.threadContactNameInternalKey),
                    IFNULL(\(profile[.nickname]), \(profile[.name])) AS \(ViewModel.authorNameInternalKey),
                    \(SQL("\(userPublicKey)")) AS \(ViewModel.currentUserPublicKeyKey)

                FROM \(SessionThread.self)
                LEFT JOIN \(Contact.self) ON \(contact[.id]) = \(thread[.id])
                LEFT JOIN \(ThreadTypingIndicator.self) ON \(typingIndicator[.threadId]) = \(thread[.id])

                LEFT JOIN (
                    SELECT
                        \(interaction[.id]) AS \(ViewModel.interactionIdKey),
                        \(interaction[.threadId]) AS \(ViewModel.threadIdKey),
                        MAX(\(interaction[.timestampMs])) AS \(timestampMsColumnLiteral),
                        SUM(\(interaction[.wasRead]) = false) AS \(ViewModel.threadUnreadCountKey),
                        SUM(\(interaction[.wasRead]) = false AND \(interaction[.hasMention]) = true) AS \(ViewModel.threadUnreadMentionCountKey)
                    FROM \(Interaction.self)
                    WHERE \(SQL("\(interaction[.variant]) != \(Interaction.Variant.standardIncomingDeleted)"))
                    GROUP BY \(interaction[.threadId])
                ) AS \(aggregateInteractionLiteral) ON \(aggregateInteractionLiteral).\(ViewModel.threadIdKey) = \(thread[.id])
                
                LEFT JOIN \(Interaction.self) ON (
                    \(interaction[.threadId]) = \(thread[.id]) AND
                    \(interaction[.id]) = \(aggregateInteractionLiteral).\(ViewModel.interactionIdKey)
                )

                LEFT JOIN \(RecipientState.self) AS \(readReceiptTableLiteral) ON (
                    \(interaction[.id]) = \(readReceiptTableLiteral).\(interactionStateInteractionIdColumnLiteral) AND
                    \(readReceiptTableLiteral).\(readReceiptReadTimestampMsColumnLiteral) IS NOT NULL
                )
                LEFT JOIN \(LinkPreview.self) ON (
                    \(linkPreview[.url]) = \(interaction[.linkPreviewUrl]) AND
                    \(Interaction.linkPreviewFilterLiteral) AND
                    \(SQL("\(linkPreview[.variant]) = \(LinkPreview.Variant.openGroupInvitation)"))
                )
                LEFT JOIN \(InteractionAttachment.self) AS \(firstInteractionAttachmentLiteral) ON (
                    \(firstInteractionAttachmentLiteral).\(interactionAttachmentInteractionIdColumnLiteral) = \(interaction[.id]) AND
                    \(firstInteractionAttachmentLiteral).\(interactionAttachmentAlbumIndexColumnLiteral) = 0
                )
                LEFT JOIN \(Attachment.self) ON \(attachment[.id]) = \(firstInteractionAttachmentLiteral).\(interactionAttachmentAttachmentIdColumnLiteral)
                LEFT JOIN \(InteractionAttachment.self) ON \(interactionAttachment[.interactionId]) = \(interaction[.id])
                LEFT JOIN \(Profile.self) ON \(profile[.id]) = \(interaction[.authorId])

                -- Thread naming & avatar content

                LEFT JOIN \(Profile.self) AS \(ViewModel.contactProfileKey) ON \(ViewModel.contactProfileKey).\(profileIdColumnLiteral) = \(thread[.id])
                LEFT JOIN \(OpenGroup.self) ON \(openGroup[.threadId]) = \(thread[.id])
                LEFT JOIN \(ClosedGroup.self) ON \(closedGroup[.threadId]) = \(thread[.id])

                LEFT JOIN \(Profile.self) AS \(ViewModel.closedGroupProfileFrontKey) ON (
                    \(ViewModel.closedGroupProfileFrontKey).\(profileIdColumnLiteral) = (
                        SELECT MIN(\(groupMember[.profileId]))
                        FROM \(GroupMember.self)
                        JOIN \(Profile.self) ON \(profile[.id]) = \(groupMember[.profileId])
                        WHERE (
                            \(groupMember[.groupId]) = \(closedGroup[.threadId]) AND
                            \(SQL("\(groupMember[.role]) = \(GroupMember.Role.standard)")) AND
                            \(SQL("\(groupMember[.profileId]) != \(userPublicKey)"))
                        )
                    )
                )
                LEFT JOIN \(Profile.self) AS \(ViewModel.closedGroupProfileBackKey) ON (
                    \(ViewModel.closedGroupProfileBackKey).\(profileIdColumnLiteral) != \(ViewModel.closedGroupProfileFrontKey).\(profileIdColumnLiteral) AND
                    \(ViewModel.closedGroupProfileBackKey).\(profileIdColumnLiteral) = (
                        SELECT MAX(\(groupMember[.profileId]))
                        FROM \(GroupMember.self)
                        JOIN \(Profile.self) ON \(profile[.id]) = \(groupMember[.profileId])
                        WHERE (
                            \(groupMember[.groupId]) = \(closedGroup[.threadId]) AND
                            \(SQL("\(groupMember[.role]) = \(GroupMember.Role.standard)")) AND
                            \(SQL("\(groupMember[.profileId]) != \(userPublicKey)"))
                        )
                    )
                )
                LEFT JOIN \(Profile.self) AS \(ViewModel.closedGroupProfileBackFallbackKey) ON (
                    \(closedGroup[.threadId]) IS NOT NULL AND
                    \(ViewModel.closedGroupProfileBackKey).\(profileIdColumnLiteral) IS NULL AND
                    \(ViewModel.closedGroupProfileBackFallbackKey).\(profileIdColumnLiteral) = \(SQL("\(userPublicKey)"))
                )

                WHERE \(thread.alias[Column.rowID]) IN \(rowIds)
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
                    numColumnsBetweenProfilesAndAttachmentInfo,
                    Attachment.DescriptionInfo.numberOfSelectedColumns()
                ])
                
                return ScopeAdapter([
                    ViewModel.contactProfileString: adapters[1],
                    ViewModel.closedGroupProfileFrontString: adapters[2],
                    ViewModel.closedGroupProfileBackString: adapters[3],
                    ViewModel.closedGroupProfileBackFallbackString: adapters[4],
                    ViewModel.interactionAttachmentDescriptionInfoString: adapters[6]
                ])
            }
        }
    }
    
    static var optimisedJoinSQL: SQL = {
        let thread: TypedTableAlias<SessionThread> = TypedTableAlias()
        let contact: TypedTableAlias<Contact> = TypedTableAlias()
        let interaction: TypedTableAlias<Interaction> = TypedTableAlias()
        
        let timestampMsColumnLiteral: SQL = SQL(stringLiteral: Interaction.Columns.timestampMs.name)
        
        return """
            LEFT JOIN \(Contact.self) ON \(contact[.id]) = \(thread[.id])
            LEFT JOIN (
                SELECT
                    \(interaction[.threadId]),
                    MAX(\(interaction[.timestampMs])) AS \(timestampMsColumnLiteral)
                FROM \(Interaction.self)
                WHERE \(SQL("\(interaction[.variant]) != \(Interaction.Variant.standardIncomingDeleted)"))
                GROUP BY \(interaction[.threadId])
            ) AS \(Interaction.self) ON \(interaction[.threadId]) = \(thread[.id])
        """
    }()
    
    static func homeFilterSQL(userPublicKey: String) -> SQL {
        let thread: TypedTableAlias<SessionThread> = TypedTableAlias()
        let contact: TypedTableAlias<Contact> = TypedTableAlias()
        
        return """
            \(thread[.shouldBeVisible]) = true AND (
                -- Is not a message request
                \(SQL("\(thread[.variant]) != \(SessionThread.Variant.contact)")) OR
                \(SQL("\(thread[.id]) = \(userPublicKey)")) OR
                \(contact[.isApproved]) = true
            )
        """
    }
    
    static func messageRequestsFilterSQL(userPublicKey: String) -> SQL {
        let thread: TypedTableAlias<SessionThread> = TypedTableAlias()
        let contact: TypedTableAlias<Contact> = TypedTableAlias()
        
        return """
            \(thread[.shouldBeVisible]) = true AND (
                -- Is a message request
                \(SQL("\(thread[.variant]) = \(SessionThread.Variant.contact)")) AND
                \(SQL("\(thread[.id]) != \(userPublicKey)")) AND
                IFNULL(\(contact[.isApproved]), false) = false
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
    static func conversationQuery(threadId: String, userPublicKey: String) -> AdaptedFetchRequest<SQLRequest<SessionThreadViewModel>> {
        let thread: TypedTableAlias<SessionThread> = TypedTableAlias()
        let disappearingMessagesConfiguration: TypedTableAlias<DisappearingMessagesConfiguration> = TypedTableAlias()
        let contact: TypedTableAlias<Contact> = TypedTableAlias()
        let closedGroup: TypedTableAlias<ClosedGroup> = TypedTableAlias()
        let groupMember: TypedTableAlias<GroupMember> = TypedTableAlias()
        let openGroup: TypedTableAlias<OpenGroup> = TypedTableAlias()
        let interaction: TypedTableAlias<Interaction> = TypedTableAlias()
        
        let aggregateInteractionLiteral: SQL = SQL(stringLiteral: "aggregateInteraction")
        let closedGroupUserCountTableLiteral: SQL = SQL(stringLiteral: "\(ViewModel.closedGroupUserCountString)_table")
        let groupMemberGroupIdColumnLiteral: SQL = SQL(stringLiteral: GroupMember.Columns.groupId.name)
        let profileIdColumnLiteral: SQL = SQL(stringLiteral: Profile.Columns.id.name)
        
        /// **Note:** The `numColumnsBeforeProfiles` value **MUST** match the number of fields before
        /// the `ViewModel.contactProfileKey` entry below otherwise the query will fail to
        /// parse and might throw
        ///
        /// Explicitly set default values for the fields ignored for search results
        let numColumnsBeforeProfiles: Int = 15
        let request: SQLRequest<ViewModel> = """
            SELECT
                \(thread.alias[Column.rowID]) AS \(ViewModel.rowIdKey),
                \(thread[.id]) AS \(ViewModel.threadIdKey),
                \(thread[.variant]) AS \(ViewModel.threadVariantKey),
                \(thread[.creationDateTimestamp]) AS \(ViewModel.threadCreationDateTimestampKey),
                
                (\(SQL("\(thread[.id]) = \(userPublicKey)"))) AS \(ViewModel.threadIsNoteToSelfKey),
                (
                    \(SQL("\(thread[.variant]) = \(SessionThread.Variant.contact)")) AND
                    \(SQL("\(thread[.id]) != \(userPublicKey)")) AND
                    IFNULL(\(contact[.isApproved]), false) = false
                ) AS \(ViewModel.threadIsMessageRequestKey),
                (
                    \(SQL("\(thread[.variant]) = \(SessionThread.Variant.contact)")) AND
                    IFNULL(\(contact[.didApproveMe]), false) = false
                ) AS \(ViewModel.threadRequiresApprovalKey),
                \(thread[.shouldBeVisible]) AS \(ViewModel.threadShouldBeVisibleKey),
        
                IFNULL(\(thread[.pinnedPriority]), 0) AS \(ViewModel.threadPinnedPriorityKey),
                \(contact[.isBlocked]) AS \(ViewModel.threadIsBlockedKey),
                \(thread[.mutedUntilTimestamp]) AS \(ViewModel.threadMutedUntilTimestampKey),
                \(thread[.onlyNotifyForMentions]) AS \(ViewModel.threadOnlyNotifyForMentionsKey),
                \(thread[.messageDraft]) AS \(ViewModel.threadMessageDraftKey),
                
                \(thread[.markedAsUnread]) AS \(ViewModel.threadWasMarkedUnreadKey),
                \(aggregateInteractionLiteral).\(ViewModel.threadUnreadCountKey),
        
                \(ViewModel.disappearingMessagesConfigurationKey).*,
            
                \(ViewModel.contactProfileKey).*,
                \(closedGroup[.name]) AS \(ViewModel.closedGroupNameKey),
                \(closedGroupUserCountTableLiteral).\(ViewModel.closedGroupUserCountKey) AS \(ViewModel.closedGroupUserCountKey),
                
                EXISTS (
                    SELECT 1
                    FROM \(GroupMember.self)
                    WHERE (
                        \(groupMember[.groupId]) = \(closedGroup[.threadId]) AND
                        \(SQL("\(groupMember[.role]) != \(GroupMember.Role.zombie)")) AND
                        \(SQL("\(groupMember[.profileId]) = \(userPublicKey)"))
                    )
                ) AS \(ViewModel.currentUserIsClosedGroupMemberKey),
                
                \(openGroup[.name]) AS \(ViewModel.openGroupNameKey),
                \(openGroup[.server]) AS \(ViewModel.openGroupServerKey),
                \(openGroup[.roomToken]) AS \(ViewModel.openGroupRoomTokenKey),
                \(openGroup[.publicKey]) AS \(ViewModel.openGroupPublicKeyKey),
                \(openGroup[.userCount]) AS \(ViewModel.openGroupUserCountKey),
                \(openGroup[.permissions]) AS \(ViewModel.openGroupPermissionsKey),
        
                \(aggregateInteractionLiteral).\(ViewModel.interactionIdKey),
                \(aggregateInteractionLiteral).\(ViewModel.interactionTimestampMsKey),
            
                \(SQL("\(userPublicKey)")) AS \(ViewModel.currentUserPublicKeyKey)
            
            FROM \(SessionThread.self)
            LEFT JOIN \(DisappearingMessagesConfiguration.self) ON \(disappearingMessagesConfiguration[.threadId]) = \(thread[.id])
            LEFT JOIN \(Contact.self) ON \(contact[.id]) = \(thread[.id])
            LEFT JOIN (
                SELECT
                    \(interaction[.id]) AS \(ViewModel.interactionIdKey),
                    \(interaction[.threadId]) AS \(ViewModel.threadIdKey),
                    MAX(\(interaction[.timestampMs])) AS \(ViewModel.interactionTimestampMsKey),
                    SUM(\(interaction[.wasRead]) = false) AS \(ViewModel.threadUnreadCountKey)
                FROM \(Interaction.self)
                WHERE (
                    \(SQL("\(interaction[.threadId]) = \(threadId)")) AND
                    \(SQL("\(interaction[.variant]) != \(Interaction.Variant.standardIncomingDeleted)"))
                )
            ) AS \(aggregateInteractionLiteral) ON \(aggregateInteractionLiteral).\(ViewModel.threadIdKey) = \(thread[.id])
            
            LEFT JOIN \(Profile.self) AS \(ViewModel.contactProfileKey) ON \(ViewModel.contactProfileKey).\(profileIdColumnLiteral) = \(thread[.id])
            LEFT JOIN \(OpenGroup.self) ON \(openGroup[.threadId]) = \(thread[.id])
            LEFT JOIN \(ClosedGroup.self) ON \(closedGroup[.threadId]) = \(thread[.id])
            LEFT JOIN (
                SELECT
                    \(groupMember[.groupId]),
                    COUNT(\(groupMember.alias[Column.rowID])) AS \(ViewModel.closedGroupUserCountKey)
                FROM \(GroupMember.self)
                WHERE (
                    \(SQL("\(groupMember[.groupId]) = \(threadId)")) AND
                    \(SQL("\(groupMember[.role]) = \(GroupMember.Role.standard)"))
                )
            ) AS \(closedGroupUserCountTableLiteral) ON \(SQL("\(closedGroupUserCountTableLiteral).\(groupMemberGroupIdColumnLiteral) = \(threadId)"))
            
            WHERE \(SQL("\(thread[.id]) = \(threadId)"))
        """
        
        return request.adapted { db in
            let adapters = try splittingRowAdapters(columnCounts: [
                numColumnsBeforeProfiles,
                DisappearingMessagesConfiguration.numberOfSelectedColumns(db),
                Profile.numberOfSelectedColumns(db)
            ])
            
            return ScopeAdapter([
                ViewModel.disappearingMessagesConfigurationString: adapters[1],
                ViewModel.contactProfileString: adapters[2]
            ])
        }
    }
    
    static func conversationSettingsQuery(threadId: String, userPublicKey: String) -> AdaptedFetchRequest<SQLRequest<SessionThreadViewModel>> {
        let thread: TypedTableAlias<SessionThread> = TypedTableAlias()
        let contact: TypedTableAlias<Contact> = TypedTableAlias()
        let closedGroup: TypedTableAlias<ClosedGroup> = TypedTableAlias()
        let groupMember: TypedTableAlias<GroupMember> = TypedTableAlias()
        let openGroup: TypedTableAlias<OpenGroup> = TypedTableAlias()
        let profile: TypedTableAlias<Profile> = TypedTableAlias()
        
        let profileIdColumnLiteral: SQL = SQL(stringLiteral: Profile.Columns.id.name)
        
        /// **Note:** The `numColumnsBeforeProfiles` value **MUST** match the number of fields before
        /// the `ViewModel.contactProfileKey` entry below otherwise the query will fail to
        /// parse and might throw
        ///
        /// Explicitly set default values for the fields ignored for search results
        let numColumnsBeforeProfiles: Int = 9
        let request: SQLRequest<ViewModel> = """
            SELECT
                \(thread.alias[Column.rowID]) AS \(ViewModel.rowIdKey),
                \(thread[.id]) AS \(ViewModel.threadIdKey),
                \(thread[.variant]) AS \(ViewModel.threadVariantKey),
                \(thread[.creationDateTimestamp]) AS \(ViewModel.threadCreationDateTimestampKey),
                
                (\(SQL("\(thread[.id]) = \(userPublicKey)"))) AS \(ViewModel.threadIsNoteToSelfKey),
                
                IFNULL(\(thread[.pinnedPriority]), 0) AS \(ViewModel.threadPinnedPriorityKey),
                \(contact[.isBlocked]) AS \(ViewModel.threadIsBlockedKey),
                \(thread[.mutedUntilTimestamp]) AS \(ViewModel.threadMutedUntilTimestampKey),
                \(thread[.onlyNotifyForMentions]) AS \(ViewModel.threadOnlyNotifyForMentionsKey),
        
                \(ViewModel.contactProfileKey).*,
                \(ViewModel.closedGroupProfileFrontKey).*,
                \(ViewModel.closedGroupProfileBackKey).*,
                \(ViewModel.closedGroupProfileBackFallbackKey).*,
                
                \(closedGroup[.name]) AS \(ViewModel.closedGroupNameKey),
                
                EXISTS (
                    SELECT 1
                    FROM \(GroupMember.self)
                    WHERE (
                        \(groupMember[.groupId]) = \(closedGroup[.threadId]) AND
                        \(SQL("\(groupMember[.role]) != \(GroupMember.Role.zombie)")) AND
                        \(SQL("\(groupMember[.profileId]) = \(userPublicKey)"))
                    )
                ) AS \(ViewModel.currentUserIsClosedGroupMemberKey),

                EXISTS (
                    SELECT 1
                    FROM \(GroupMember.self)
                    WHERE (
                        \(groupMember[.groupId]) = \(closedGroup[.threadId]) AND
                        \(SQL("\(groupMember[.role]) = \(GroupMember.Role.admin)")) AND
                        \(SQL("\(groupMember[.profileId]) = \(userPublicKey)"))
                    )
                ) AS \(ViewModel.currentUserIsClosedGroupAdminKey),
        
                \(openGroup[.name]) AS \(ViewModel.openGroupNameKey),
                \(openGroup[.server]) AS \(ViewModel.openGroupServerKey),
                \(openGroup[.roomToken]) AS \(ViewModel.openGroupRoomTokenKey),
                \(openGroup[.publicKey]) AS \(ViewModel.openGroupPublicKeyKey),
                \(openGroup[.imageData]) AS \(ViewModel.openGroupProfilePictureDataKey),
                    
                \(SQL("\(userPublicKey)")) AS \(ViewModel.currentUserPublicKeyKey)
            
            FROM \(SessionThread.self)
            LEFT JOIN \(Contact.self) ON \(contact[.id]) = \(thread[.id])
            LEFT JOIN \(Profile.self) AS \(ViewModel.contactProfileKey) ON \(ViewModel.contactProfileKey).\(profileIdColumnLiteral) = \(thread[.id])
            LEFT JOIN \(OpenGroup.self) ON \(openGroup[.threadId]) = \(thread[.id])
            LEFT JOIN \(ClosedGroup.self) ON \(closedGroup[.threadId]) = \(thread[.id])
        
            LEFT JOIN \(Profile.self) AS \(ViewModel.closedGroupProfileFrontKey) ON (
                \(ViewModel.closedGroupProfileFrontKey).\(profileIdColumnLiteral) = (
                    SELECT MIN(\(groupMember[.profileId]))
                    FROM \(GroupMember.self)
                    JOIN \(Profile.self) ON \(profile[.id]) = \(groupMember[.profileId])
                    WHERE (
                        \(groupMember[.groupId]) = \(closedGroup[.threadId]) AND
                        \(SQL("\(groupMember[.role]) = \(GroupMember.Role.standard)")) AND
                        \(SQL("\(groupMember[.profileId]) != \(userPublicKey)"))
                    )
                )
            )
            LEFT JOIN \(Profile.self) AS \(ViewModel.closedGroupProfileBackKey) ON (
                \(ViewModel.closedGroupProfileBackKey).\(profileIdColumnLiteral) != \(ViewModel.closedGroupProfileFrontKey).\(profileIdColumnLiteral) AND
                \(ViewModel.closedGroupProfileBackKey).\(profileIdColumnLiteral) = (
                    SELECT MAX(\(groupMember[.profileId]))
                    FROM \(GroupMember.self)
                    JOIN \(Profile.self) ON \(profile[.id]) = \(groupMember[.profileId])
                    WHERE (
                        \(groupMember[.groupId]) = \(closedGroup[.threadId]) AND
                        \(SQL("\(groupMember[.role]) = \(GroupMember.Role.standard)")) AND
                        \(SQL("\(groupMember[.profileId]) != \(userPublicKey)"))
                    )
                )
            )
            LEFT JOIN \(Profile.self) AS \(ViewModel.closedGroupProfileBackFallbackKey) ON (
                \(closedGroup[.threadId]) IS NOT NULL AND
                \(ViewModel.closedGroupProfileBackKey).\(profileIdColumnLiteral) IS NULL AND
                \(ViewModel.closedGroupProfileBackFallbackKey).\(profileIdColumnLiteral) = \(SQL("\(userPublicKey)"))
            )
            
            WHERE \(SQL("\(thread[.id]) = \(threadId)"))
        """
        
        return request.adapted { db in
            let adapters = try splittingRowAdapters(columnCounts: [
                numColumnsBeforeProfiles,
                Profile.numberOfSelectedColumns(db),
                Profile.numberOfSelectedColumns(db),
                Profile.numberOfSelectedColumns(db),
                Profile.numberOfSelectedColumns(db)
            ])
            
            return ScopeAdapter([
                ViewModel.contactProfileString: adapters[1],
                ViewModel.closedGroupProfileFrontString: adapters[2],
                ViewModel.closedGroupProfileBackString: adapters[3],
                ViewModel.closedGroupProfileBackFallbackString: adapters[4]
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
        // Apple like to use the special '”“' quote characters when typing so replace them with normal ones
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
    
    static func messagesQuery(userPublicKey: String, pattern: FTS5Pattern) -> AdaptedFetchRequest<SQLRequest<SessionThreadViewModel>> {
        let interaction: TypedTableAlias<Interaction> = TypedTableAlias()
        let thread: TypedTableAlias<SessionThread> = TypedTableAlias()
        let closedGroup: TypedTableAlias<ClosedGroup> = TypedTableAlias()
        let groupMember: TypedTableAlias<GroupMember> = TypedTableAlias()
        let openGroup: TypedTableAlias<OpenGroup> = TypedTableAlias()
        let profile: TypedTableAlias<Profile> = TypedTableAlias()
        let profileIdColumnLiteral: SQL = SQL(stringLiteral: Profile.Columns.id.name)
        let interactionLiteral: SQL = SQL(stringLiteral: Interaction.databaseTableName)
        let interactionFullTextSearch: SQL = SQL(stringLiteral: Interaction.fullTextSearchTableName)
        
        /// **Note:** The `numColumnsBeforeProfiles` value **MUST** match the number of fields before
        /// the `ViewModel.contactProfileKey` entry below otherwise the query will fail to
        /// parse and might throw
        ///
        /// Explicitly set default values for the fields ignored for search results
        let numColumnsBeforeProfiles: Int = 6
        let request: SQLRequest<ViewModel> = """
            SELECT
                \(interaction.alias[Column.rowID]) AS \(ViewModel.rowIdKey),
                \(thread[.id]) AS \(ViewModel.threadIdKey),
                \(thread[.variant]) AS \(ViewModel.threadVariantKey),
                \(thread[.creationDateTimestamp]) AS \(ViewModel.threadCreationDateTimestampKey),
                
                (\(SQL("\(thread[.id]) = \(userPublicKey)"))) AS \(ViewModel.threadIsNoteToSelfKey),
                IFNULL(\(thread[.pinnedPriority]), 0) AS \(ViewModel.threadPinnedPriorityKey),
                
                \(ViewModel.contactProfileKey).*,
                \(ViewModel.closedGroupProfileFrontKey).*,
                \(ViewModel.closedGroupProfileBackKey).*,
                \(ViewModel.closedGroupProfileBackFallbackKey).*,
                \(closedGroup[.name]) AS \(ViewModel.closedGroupNameKey),
                \(openGroup[.name]) AS \(ViewModel.openGroupNameKey),
                \(openGroup[.imageData]) AS \(ViewModel.openGroupProfilePictureDataKey),
            
                \(interaction[.id]) AS \(ViewModel.interactionIdKey),
                \(interaction[.variant]) AS \(ViewModel.interactionVariantKey),
                \(interaction[.timestampMs]) AS \(ViewModel.interactionTimestampMsKey),
                snippet(\(interactionFullTextSearch), -1, '', '', '...', 6) AS \(ViewModel.interactionBodyKey),
        
                \(interaction[.authorId]),
                IFNULL(\(profile[.nickname]), \(profile[.name])) AS \(ViewModel.authorNameInternalKey),
                \(SQL("\(userPublicKey)")) AS \(ViewModel.currentUserPublicKeyKey)
            
            FROM \(Interaction.self)
            JOIN \(interactionFullTextSearch) ON (
                \(interactionFullTextSearch).rowid = \(interactionLiteral).rowid AND
                \(interactionFullTextSearch).\(SQL(stringLiteral: Interaction.Columns.body.name)) MATCH \(pattern)
            )
            JOIN \(SessionThread.self) ON \(thread[.id]) = \(interaction[.threadId])
            JOIN \(Profile.self) ON \(profile[.id]) = \(interaction[.authorId])
            LEFT JOIN \(Profile.self) AS \(ViewModel.contactProfileKey) ON \(ViewModel.contactProfileKey).\(profileIdColumnLiteral) = \(interaction[.threadId])
            LEFT JOIN \(ClosedGroup.self) ON \(closedGroup[.threadId]) = \(interaction[.threadId])
            LEFT JOIN \(OpenGroup.self) ON \(openGroup[.threadId]) = \(interaction[.threadId])
        
            LEFT JOIN \(Profile.self) AS \(ViewModel.closedGroupProfileFrontKey) ON (
                \(ViewModel.closedGroupProfileFrontKey).\(profileIdColumnLiteral) = (
                    SELECT MIN(\(groupMember[.profileId]))
                    FROM \(GroupMember.self)
                    JOIN \(Profile.self) ON \(profile[.id]) = \(groupMember[.profileId])
                    WHERE (
                        \(SQL("\(groupMember[.role]) = \(GroupMember.Role.standard)")) AND
                        \(groupMember[.groupId]) = \(closedGroup[.threadId]) AND
                        \(groupMember[.profileId]) != \(userPublicKey)
                    )
                )
            )
            LEFT JOIN \(Profile.self) AS \(ViewModel.closedGroupProfileBackKey) ON (
                \(ViewModel.closedGroupProfileBackKey).\(profileIdColumnLiteral) != \(ViewModel.closedGroupProfileFrontKey).\(profileIdColumnLiteral) AND
                \(ViewModel.closedGroupProfileBackKey).\(profileIdColumnLiteral) = (
                    SELECT MAX(\(groupMember[.profileId]))
                    FROM \(GroupMember.self)
                    JOIN \(Profile.self) ON \(profile[.id]) = \(groupMember[.profileId])
                    WHERE (
                        \(SQL("\(groupMember[.role]) = \(GroupMember.Role.standard)")) AND
                        \(groupMember[.groupId]) = \(closedGroup[.threadId]) AND
                        \(groupMember[.profileId]) != \(userPublicKey)
                    )
                )
            )
            LEFT JOIN \(Profile.self) AS \(ViewModel.closedGroupProfileBackFallbackKey) ON (
                \(closedGroup[.threadId]) IS NOT NULL AND
                \(ViewModel.closedGroupProfileBackKey).\(profileIdColumnLiteral) IS NULL AND
                \(ViewModel.closedGroupProfileBackFallbackKey).\(profileIdColumnLiteral) = \(userPublicKey)
            )
        
            ORDER BY \(Column.rank), \(interaction[.timestampMs].desc)
            LIMIT \(SQL("\(SessionThreadViewModel.searchResultsLimit)"))
        """
        
        return request.adapted { db in
            let adapters = try splittingRowAdapters(columnCounts: [
                numColumnsBeforeProfiles,
                Profile.numberOfSelectedColumns(db),
                Profile.numberOfSelectedColumns(db),
                Profile.numberOfSelectedColumns(db),
                Profile.numberOfSelectedColumns(db)
            ])
            
            return ScopeAdapter([
                ViewModel.contactProfileString: adapters[1],
                ViewModel.closedGroupProfileFrontString: adapters[2],
                ViewModel.closedGroupProfileBackString: adapters[3],
                ViewModel.closedGroupProfileBackFallbackString: adapters[4]
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
    static func contactsAndGroupsQuery(userPublicKey: String, pattern: FTS5Pattern, searchTerm: String) -> AdaptedFetchRequest<SQLRequest<SessionThreadViewModel>> {
        let thread: TypedTableAlias<SessionThread> = TypedTableAlias()
        let closedGroup: TypedTableAlias<ClosedGroup> = TypedTableAlias()
        let groupMember: TypedTableAlias<GroupMember> = TypedTableAlias()
        let openGroup: TypedTableAlias<OpenGroup> = TypedTableAlias()
        let profile: TypedTableAlias<Profile> = TypedTableAlias()
        let contact: TypedTableAlias<Contact> = TypedTableAlias()
        let profileIdColumnLiteral: SQL = SQL(stringLiteral: Profile.Columns.id.name)
        let profileNicknameColumnLiteral: SQL = SQL(stringLiteral: Profile.Columns.nickname.name)
        let profileNameColumnLiteral: SQL = SQL(stringLiteral: Profile.Columns.name.name)
        
        let profileFullTextSearch: SQL = SQL(stringLiteral: Profile.fullTextSearchTableName)
        let closedGroupNameColumnLiteral: SQL = SQL(stringLiteral: ClosedGroup.Columns.name.name)
        let closedGroupLiteral: SQL = SQL(stringLiteral: ClosedGroup.databaseTableName)
        let closedGroupFullTextSearch: SQL = SQL(stringLiteral: ClosedGroup.fullTextSearchTableName)
        let openGroupNameColumnLiteral: SQL = SQL(stringLiteral: OpenGroup.Columns.name.name)
        let openGroupLiteral: SQL = SQL(stringLiteral: OpenGroup.databaseTableName)
        let openGroupFullTextSearch: SQL = SQL(stringLiteral: OpenGroup.fullTextSearchTableName)
        let groupMemberInfoLiteral: SQL = SQL(stringLiteral: "groupMemberInfo")
        let groupMemberGroupIdColumnLiteral: SQL = SQL(stringLiteral: GroupMember.Columns.groupId.name)
        let groupMemberProfileLiteral: SQL = SQL(stringLiteral: "groupMemberProfile")
        let noteToSelfLiteral: SQL = SQL(stringLiteral: "NOTE_TO_SELF".localized().lowercased())
        let searchTermLiteral: SQL = SQL(stringLiteral: searchTerm.lowercased())
        
        /// **Note:** The `numColumnsBeforeProfiles` value **MUST** match the number of fields before
        /// the `ViewModel.contactProfileKey` entry below otherwise the query will fail to
        /// parse and might throw
        ///
        /// We use `IFNULL(rank, 100)` because the custom `Note to Self` like comparison will get a null
        /// `rank` value which ends up as the first result, by defaulting to `100` it will always be ranked last compared
        /// to any relevance-based results
        let numColumnsBeforeProfiles: Int = 8
        var sqlQuery: SQL = ""
        let selectQuery: SQL = """
            SELECT
                IFNULL(\(Column.rank), 100) AS \(Column.rank),
                
                \(thread.alias[Column.rowID]) AS \(ViewModel.rowIdKey),
                \(thread[.id]) AS \(ViewModel.threadIdKey),
                \(thread[.variant]) AS \(ViewModel.threadVariantKey),
                \(thread[.creationDateTimestamp]) AS \(ViewModel.threadCreationDateTimestampKey),
                \(groupMemberInfoLiteral).\(ViewModel.threadMemberNamesKey),
                
                (\(SQL("\(thread[.id]) = \(userPublicKey)"))) AS \(ViewModel.threadIsNoteToSelfKey),
                IFNULL(\(thread[.pinnedPriority]), 0) AS \(ViewModel.threadPinnedPriorityKey),
                
                \(ViewModel.contactProfileKey).*,
                \(ViewModel.closedGroupProfileFrontKey).*,
                \(ViewModel.closedGroupProfileBackKey).*,
                \(ViewModel.closedGroupProfileBackFallbackKey).*,
                \(closedGroup[.name]) AS \(ViewModel.closedGroupNameKey),
                \(openGroup[.name]) AS \(ViewModel.openGroupNameKey),
                \(openGroup[.imageData]) AS \(ViewModel.openGroupProfilePictureDataKey),
                
                \(SQL("\(userPublicKey)")) AS \(ViewModel.currentUserPublicKeyKey)

            FROM \(SessionThread.self)
        
        """
        
        // MARK: --Contact Threads
        let contactQueryCommonJoinFilterGroup: SQL = """
            JOIN \(Profile.self) AS \(ViewModel.contactProfileKey) ON \(ViewModel.contactProfileKey).\(profileIdColumnLiteral) = \(thread[.id])
            LEFT JOIN \(Profile.self) AS \(ViewModel.closedGroupProfileFrontKey) ON false
            LEFT JOIN \(Profile.self) AS \(ViewModel.closedGroupProfileBackKey) ON false
            LEFT JOIN \(Profile.self) AS \(ViewModel.closedGroupProfileBackFallbackKey) ON false
            LEFT JOIN \(ClosedGroup.self) ON false
            LEFT JOIN \(OpenGroup.self) ON false
            LEFT JOIN (
                SELECT
                    \(groupMember[.groupId]),
                    '' AS \(ViewModel.threadMemberNamesKey)
                FROM \(GroupMember.self)
            ) AS \(groupMemberInfoLiteral) ON false
        
            WHERE
                \(SQL("\(thread[.variant]) = \(SessionThread.Variant.contact)")) AND
                \(SQL("\(thread[.id]) != \(userPublicKey)"))
            GROUP BY \(thread[.id])
        """
        
        // Contact thread nickname searching (ignoring note to self - handled separately)
        sqlQuery += selectQuery
        sqlQuery += """
            JOIN \(profileFullTextSearch) ON (
                \(profileFullTextSearch).rowid = \(ViewModel.contactProfileKey).rowid AND
                \(profileFullTextSearch).\(profileNicknameColumnLiteral) MATCH \(pattern)
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
                \(profileFullTextSearch).rowid = \(ViewModel.contactProfileKey).rowid AND
                \(profileFullTextSearch).\(profileNameColumnLiteral) MATCH \(pattern)
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
                    GROUP_CONCAT(IFNULL(\(profile[.nickname]), \(profile[.name])), ', ') AS \(ViewModel.threadMemberNamesKey)
                FROM \(GroupMember.self)
                JOIN \(Profile.self) ON \(profile[.id]) = \(groupMember[.profileId])
                WHERE \(SQL("\(groupMember[.role]) = \(GroupMember.Role.standard)"))
                GROUP BY \(groupMember[.groupId])
            ) AS \(groupMemberInfoLiteral) ON \(groupMemberInfoLiteral).\(groupMemberGroupIdColumnLiteral) = \(closedGroup[.threadId])
            LEFT JOIN \(Profile.self) AS \(ViewModel.closedGroupProfileFrontKey) ON (
                \(ViewModel.closedGroupProfileFrontKey).\(profileIdColumnLiteral) = (
                    SELECT MIN(\(groupMember[.profileId]))
                    FROM \(GroupMember.self)
                    JOIN \(Profile.self) ON \(profile[.id]) = \(groupMember[.profileId])
                    WHERE (
                        \(SQL("\(groupMember[.role]) = \(GroupMember.Role.standard)")) AND
                        \(groupMember[.groupId]) = \(closedGroup[.threadId]) AND
                        \(groupMember[.profileId]) != \(userPublicKey)
                    )
                )
            )
            LEFT JOIN \(Profile.self) AS \(ViewModel.closedGroupProfileBackKey) ON (
                \(ViewModel.closedGroupProfileBackKey).\(profileIdColumnLiteral) != \(ViewModel.closedGroupProfileFrontKey).\(profileIdColumnLiteral) AND
                \(ViewModel.closedGroupProfileBackKey).\(profileIdColumnLiteral) = (
                    SELECT MAX(\(groupMember[.profileId]))
                    FROM \(GroupMember.self)
                    JOIN \(Profile.self) ON \(profile[.id]) = \(groupMember[.profileId])
                    WHERE (
                        \(SQL("\(groupMember[.role]) = \(GroupMember.Role.standard)")) AND
                        \(groupMember[.groupId]) = \(closedGroup[.threadId]) AND
                        \(groupMember[.profileId]) != \(userPublicKey)
                    )
                )
            )
            LEFT JOIN \(Profile.self) AS \(ViewModel.closedGroupProfileBackFallbackKey) ON (
                \(ViewModel.closedGroupProfileBackKey).\(profileIdColumnLiteral) IS NULL AND
                \(ViewModel.closedGroupProfileBackFallbackKey).\(profileIdColumnLiteral) = \(userPublicKey)
            )
        
            LEFT JOIN \(Profile.self) AS \(ViewModel.contactProfileKey) ON false
            LEFT JOIN \(OpenGroup.self) ON false
        
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
                \(closedGroupFullTextSearch).rowid = \(closedGroupLiteral).rowid AND
                \(closedGroupFullTextSearch).\(closedGroupNameColumnLiteral) MATCH \(pattern)
            )
        """
        sqlQuery += closedGroupQueryCommonJoinFilterGroup
        
        // Closed group member nickname searching
        sqlQuery += """
        
            UNION ALL
        
        """
        sqlQuery += selectQuery
        sqlQuery += """
            JOIN \(Profile.self) AS \(groupMemberProfileLiteral) ON \(groupMemberProfileLiteral).\(profileIdColumnLiteral) = \(groupMember[.profileId])
            JOIN \(profileFullTextSearch) ON (
                \(profileFullTextSearch).rowid = \(groupMemberProfileLiteral).rowid AND
                \(profileFullTextSearch).\(profileNicknameColumnLiteral) MATCH \(pattern)
            )
        """
        sqlQuery += closedGroupQueryCommonJoinFilterGroup
        
        // Closed group member name searching
        sqlQuery += """
        
            UNION ALL
        
        """
        sqlQuery += selectQuery
        sqlQuery += """
            JOIN \(Profile.self) AS \(groupMemberProfileLiteral) ON \(groupMemberProfileLiteral).\(profileIdColumnLiteral) = \(groupMember[.profileId])
            JOIN \(profileFullTextSearch) ON (
                \(profileFullTextSearch).rowid = \(groupMemberProfileLiteral).rowid AND
                \(profileFullTextSearch).\(profileNameColumnLiteral) MATCH \(pattern)
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
                \(openGroupFullTextSearch).rowid = \(openGroupLiteral).rowid AND
                \(openGroupFullTextSearch).\(openGroupNameColumnLiteral) MATCH \(pattern)
            )
            LEFT JOIN \(Profile.self) AS \(ViewModel.contactProfileKey) ON false
            LEFT JOIN \(Profile.self) AS \(ViewModel.closedGroupProfileFrontKey) ON false
            LEFT JOIN \(Profile.self) AS \(ViewModel.closedGroupProfileBackKey) ON false
            LEFT JOIN \(Profile.self) AS \(ViewModel.closedGroupProfileBackFallbackKey) ON false
            LEFT JOIN \(ClosedGroup.self) ON false
            LEFT JOIN (
                SELECT
                    \(groupMember[.groupId]),
                    '' AS \(ViewModel.threadMemberNamesKey)
                FROM \(GroupMember.self)
            ) AS \(groupMemberInfoLiteral) ON false
        
            WHERE
                \(SQL("\(thread[.variant]) = \(SessionThread.Variant.community)")) AND
                \(SQL("\(thread[.id]) != \(userPublicKey)"))
            GROUP BY \(thread[.id])
        """
        
        // MARK: --Note to Self Thread
        let noteToSelfQueryCommonJoins: SQL = """
            JOIN \(Profile.self) AS \(ViewModel.contactProfileKey) ON \(ViewModel.contactProfileKey).\(profileIdColumnLiteral) = \(thread[.id])
            LEFT JOIN \(Profile.self) AS \(ViewModel.closedGroupProfileFrontKey) ON false
            LEFT JOIN \(Profile.self) AS \(ViewModel.closedGroupProfileBackKey) ON false
            LEFT JOIN \(Profile.self) AS \(ViewModel.closedGroupProfileBackFallbackKey) ON false
            LEFT JOIN \(OpenGroup.self) ON false
            LEFT JOIN \(ClosedGroup.self) ON false
            LEFT JOIN (
                SELECT
                    \(groupMember[.groupId]),
                    '' AS \(ViewModel.threadMemberNamesKey)
                FROM \(GroupMember.self)
            ) AS \(groupMemberInfoLiteral) ON false
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
                \(SQL("\(thread[.id]) = \(userPublicKey)")) AND
                '\(noteToSelfLiteral)' LIKE '%\(searchTermLiteral)%'
        """
        
        // Note to self thread nickname searching
        sqlQuery += """
        
            UNION ALL
        
        """
        sqlQuery += selectQuery
        sqlQuery += """
        
            JOIN \(profileFullTextSearch) ON (
                \(profileFullTextSearch).rowid = \(ViewModel.contactProfileKey).rowid AND
                \(profileFullTextSearch).\(profileNicknameColumnLiteral) MATCH \(pattern)
            )
        """
        sqlQuery += noteToSelfQueryCommonJoins
        sqlQuery += """
        
            WHERE \(SQL("\(thread[.id]) = \(userPublicKey)"))
        """
        
        // Note to self thread name searching
        sqlQuery += """
        
            UNION ALL
        
        """
        sqlQuery += selectQuery
        sqlQuery += """
        
            JOIN \(profileFullTextSearch) ON (
                \(profileFullTextSearch).rowid = \(ViewModel.contactProfileKey).rowid AND
                \(profileFullTextSearch).\(profileNameColumnLiteral) MATCH \(pattern)
            )
        """
        sqlQuery += noteToSelfQueryCommonJoins
        sqlQuery += """
        
            WHERE \(SQL("\(thread[.id]) = \(userPublicKey)"))
        """
        
        // MARK: --Contacts without threads
        let hiddenContactQuery: SQL = """
            SELECT
                IFNULL(\(Column.rank), 100) AS \(Column.rank),
                
                -1 AS \(ViewModel.rowIdKey),
                \(contact[.id]) AS \(ViewModel.threadIdKey),
                \(SQL("\(SessionThread.Variant.contact)")) AS \(ViewModel.threadVariantKey),
                0 AS \(ViewModel.threadCreationDateTimestampKey),
                \(groupMemberInfoLiteral).\(ViewModel.threadMemberNamesKey),
                
                false AS \(ViewModel.threadIsNoteToSelfKey),
                -1 AS \(ViewModel.threadPinnedPriorityKey),
                
                \(ViewModel.contactProfileKey).*,
                \(ViewModel.closedGroupProfileFrontKey).*,
                \(ViewModel.closedGroupProfileBackKey).*,
                \(ViewModel.closedGroupProfileBackFallbackKey).*,
                \(closedGroup[.name]) AS \(ViewModel.closedGroupNameKey),
                \(openGroup[.name]) AS \(ViewModel.openGroupNameKey),
                \(openGroup[.imageData]) AS \(ViewModel.openGroupProfilePictureDataKey),
                
                \(SQL("\(userPublicKey)")) AS \(ViewModel.currentUserPublicKeyKey)

            FROM \(Contact.self)
        """
        let hiddenContactQueryCommonJoins: SQL = """
            JOIN \(Profile.self) AS \(ViewModel.contactProfileKey) ON \(ViewModel.contactProfileKey).\(profileIdColumnLiteral) = \(contact[.id])
            LEFT JOIN \(SessionThread.self) ON \(thread[.id]) = \(contact[.id])
            LEFT JOIN \(Profile.self) AS \(ViewModel.closedGroupProfileFrontKey) ON false
            LEFT JOIN \(Profile.self) AS \(ViewModel.closedGroupProfileBackKey) ON false
            LEFT JOIN \(Profile.self) AS \(ViewModel.closedGroupProfileBackFallbackKey) ON false
            LEFT JOIN \(ClosedGroup.self) ON false
            LEFT JOIN \(OpenGroup.self) ON false
            LEFT JOIN (
                SELECT
                    \(groupMember[.groupId]),
                    '' AS \(ViewModel.threadMemberNamesKey)
                FROM \(GroupMember.self)
            ) AS \(groupMemberInfoLiteral) ON false
        
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
                \(profileFullTextSearch).rowid = \(ViewModel.contactProfileKey).rowid AND
                \(profileFullTextSearch).\(profileNicknameColumnLiteral) MATCH \(pattern)
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
                \(profileFullTextSearch).rowid = \(ViewModel.contactProfileKey).rowid AND
                \(profileFullTextSearch).\(profileNameColumnLiteral) MATCH \(pattern)
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
        
            GROUP BY \(ViewModel.threadIdKey)
            ORDER BY
                \(Column.rank),
                \(ViewModel.threadIsNoteToSelfKey),
                \(ViewModel.closedGroupNameKey),
                \(ViewModel.openGroupNameKey),
                \(ViewModel.threadIdKey)
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
                Profile.numberOfSelectedColumns(db)
            ])

            return ScopeAdapter([
                ViewModel.contactProfileString: adapters[1],
                ViewModel.closedGroupProfileFrontString: adapters[2],
                ViewModel.closedGroupProfileBackString: adapters[3],
                ViewModel.closedGroupProfileBackFallbackString: adapters[4]
            ])
        }
    }
    
    /// This method returns only the 'Note to Self' thread in the structure of a search result conversation
    static func noteToSelfOnlyQuery(userPublicKey: String) -> AdaptedFetchRequest<SQLRequest<SessionThreadViewModel>> {
        let thread: TypedTableAlias<SessionThread> = TypedTableAlias()
        let profileIdColumnLiteral: SQL = SQL(stringLiteral: Profile.Columns.id.name)
        
        /// **Note:** The `numColumnsBeforeProfiles` value **MUST** match the number of fields before
        /// the `ViewModel.contactProfileKey` entry below otherwise the query will fail to
        /// parse and might throw
        let numColumnsBeforeProfiles: Int = 8
        let request: SQLRequest<ViewModel> = """
            SELECT
                100 AS \(Column.rank),
                
                \(thread.alias[Column.rowID]) AS \(ViewModel.rowIdKey),
                \(thread[.id]) AS \(ViewModel.threadIdKey),
                \(thread[.variant]) AS \(ViewModel.threadVariantKey),
                \(thread[.creationDateTimestamp]) AS \(ViewModel.threadCreationDateTimestampKey),
                '' AS \(ViewModel.threadMemberNamesKey),
                
                true AS \(ViewModel.threadIsNoteToSelfKey),
                IFNULL(\(thread[.pinnedPriority]), 0) AS \(ViewModel.threadPinnedPriorityKey),
                
                \(ViewModel.contactProfileKey).*,
                
                \(SQL("\(userPublicKey)")) AS \(ViewModel.currentUserPublicKeyKey)

            FROM \(SessionThread.self)
            JOIN \(Profile.self) AS \(ViewModel.contactProfileKey) ON \(ViewModel.contactProfileKey).\(profileIdColumnLiteral) = \(thread[.id])
        
            WHERE \(SQL("\(thread[.id]) = \(userPublicKey)"))
        """
        
        // Add adapters which will group the various 'Profile' columns so they can be decoded
        // as instances of 'Profile' types
        return request.adapted { db in
            let adapters = try splittingRowAdapters(columnCounts: [
                numColumnsBeforeProfiles,
                Profile.numberOfSelectedColumns(db)
            ])

            return ScopeAdapter([
                ViewModel.contactProfileString: adapters[1]
            ])
        }
    }
}

// MARK: - Share Extension

public extension SessionThreadViewModel {
    static func shareQuery(userPublicKey: String) -> AdaptedFetchRequest<SQLRequest<SessionThreadViewModel>> {
        let thread: TypedTableAlias<SessionThread> = TypedTableAlias()
        let contact: TypedTableAlias<Contact> = TypedTableAlias()
        let closedGroup: TypedTableAlias<ClosedGroup> = TypedTableAlias()
        let groupMember: TypedTableAlias<GroupMember> = TypedTableAlias()
        let openGroup: TypedTableAlias<OpenGroup> = TypedTableAlias()
        let profile: TypedTableAlias<Profile> = TypedTableAlias()
        let interaction: TypedTableAlias<Interaction> = TypedTableAlias()
        
        let aggregateInteractionLiteral: SQL = SQL(stringLiteral: "aggregateInteraction")
        let profileIdColumnLiteral: SQL = SQL(stringLiteral: Profile.Columns.id.name)
        
        /// **Note:** The `numColumnsBeforeProfiles` value **MUST** match the number of fields before
        /// the `ViewModel.contactProfileKey` entry below otherwise the query will fail to
        /// parse and might throw
        ///
        /// Explicitly set default values for the fields ignored for search results
        let numColumnsBeforeProfiles: Int = 7
        
        let request: SQLRequest<ViewModel> = """
            SELECT
                \(thread.alias[Column.rowID]) AS \(ViewModel.rowIdKey),
                \(thread[.id]) AS \(ViewModel.threadIdKey),
                \(thread[.variant]) AS \(ViewModel.threadVariantKey),
                \(thread[.creationDateTimestamp]) AS \(ViewModel.threadCreationDateTimestampKey),
                
                (\(SQL("\(thread[.id]) = \(userPublicKey)"))) AS \(ViewModel.threadIsNoteToSelfKey),
                
                IFNULL(\(thread[.pinnedPriority]), 0) AS \(ViewModel.threadPinnedPriorityKey),
                \(contact[.isBlocked]) AS \(ViewModel.threadIsBlockedKey),
        
                \(ViewModel.contactProfileKey).*,
                \(ViewModel.closedGroupProfileFrontKey).*,
                \(ViewModel.closedGroupProfileBackKey).*,
                \(ViewModel.closedGroupProfileBackFallbackKey).*,
                \(closedGroup[.name]) AS \(ViewModel.closedGroupNameKey),
                \(openGroup[.name]) AS \(ViewModel.openGroupNameKey),
                \(openGroup[.imageData]) AS \(ViewModel.openGroupProfilePictureDataKey),
        
                \(SQL("\(userPublicKey)")) AS \(ViewModel.currentUserPublicKeyKey)
            
            FROM \(SessionThread.self)
            LEFT JOIN \(Contact.self) ON \(contact[.id]) = \(thread[.id])
            
            LEFT JOIN (
                SELECT
                    \(interaction[.id]) AS \(ViewModel.interactionIdKey),
                    \(interaction[.threadId]) AS \(ViewModel.threadIdKey),
                    MAX(\(interaction[.timestampMs]))
                FROM \(Interaction.self)
                WHERE \(SQL("\(interaction[.variant]) != \(Interaction.Variant.standardIncomingDeleted)"))
                GROUP BY \(interaction[.threadId])
            ) AS \(aggregateInteractionLiteral) ON \(aggregateInteractionLiteral).\(ViewModel.threadIdKey) = \(thread[.id])
            LEFT JOIN \(Interaction.self) ON (
                \(interaction[.threadId]) = \(thread[.id]) AND
                \(interaction[.id]) = \(aggregateInteractionLiteral).\(ViewModel.interactionIdKey)
            )
        
            LEFT JOIN \(Profile.self) AS \(ViewModel.contactProfileKey) ON \(ViewModel.contactProfileKey).\(profileIdColumnLiteral) = \(thread[.id])
            LEFT JOIN \(ClosedGroup.self) ON \(closedGroup[.threadId]) = \(thread[.id])
            LEFT JOIN \(OpenGroup.self) ON \(openGroup[.threadId]) = \(thread[.id])
        
            LEFT JOIN \(Profile.self) AS \(ViewModel.closedGroupProfileFrontKey) ON (
                \(ViewModel.closedGroupProfileFrontKey).\(profileIdColumnLiteral) = (
                    SELECT MIN(\(groupMember[.profileId]))
                    FROM \(GroupMember.self)
                    JOIN \(Profile.self) ON \(profile[.id]) = \(groupMember[.profileId])
                    WHERE (
                        \(SQL("\(groupMember[.role]) = \(GroupMember.Role.standard)")) AND
                        \(groupMember[.groupId]) = \(closedGroup[.threadId]) AND
                        \(SQL("\(groupMember[.profileId]) != \(userPublicKey)"))
                    )
                )
            )
            LEFT JOIN \(Profile.self) AS \(ViewModel.closedGroupProfileBackKey) ON (
                \(ViewModel.closedGroupProfileBackKey).\(profileIdColumnLiteral) != \(ViewModel.closedGroupProfileFrontKey).\(profileIdColumnLiteral) AND
                \(ViewModel.closedGroupProfileBackKey).\(profileIdColumnLiteral) = (
                    SELECT MAX(\(groupMember[.profileId]))
                    FROM \(GroupMember.self)
                    JOIN \(Profile.self) ON \(profile[.id]) = \(groupMember[.profileId])
                    WHERE (
                        \(SQL("\(groupMember[.role]) = \(GroupMember.Role.standard)")) AND
                        \(groupMember[.groupId]) = \(closedGroup[.threadId]) AND
                        \(SQL("\(groupMember[.profileId]) != \(userPublicKey)"))
                    )
                )
            )
            LEFT JOIN \(Profile.self) AS \(ViewModel.closedGroupProfileBackFallbackKey) ON (
                \(closedGroup[.threadId]) IS NOT NULL AND
                \(ViewModel.closedGroupProfileBackKey).\(profileIdColumnLiteral) IS NULL AND
                \(ViewModel.closedGroupProfileBackFallbackKey).\(profileIdColumnLiteral) = \(SQL("\(userPublicKey)"))
            )
            
            WHERE (
                \(thread[.shouldBeVisible]) = true AND (
                    -- Is not a message request
                    \(SQL("\(thread[.variant]) != \(SessionThread.Variant.contact)")) OR
                    \(SQL("\(thread[.id]) = \(userPublicKey)")) OR
                    \(contact[.isApproved]) = true
                )
                -- Always show the 'Note to Self' thread when sharing
                OR \(SQL("\(thread[.id]) = \(userPublicKey)"))
            )
        
            GROUP BY \(thread[.id])
            -- 'Note to Self', then by most recent message
            ORDER BY \(SQL("\(thread[.id]) = \(userPublicKey)")) DESC, IFNULL(\(interaction[.timestampMs]), (\(thread[.creationDateTimestamp]) * 1000)) DESC
        """
        
        return request.adapted { db in
            let adapters = try splittingRowAdapters(columnCounts: [
                numColumnsBeforeProfiles,
                Profile.numberOfSelectedColumns(db),
                Profile.numberOfSelectedColumns(db),
                Profile.numberOfSelectedColumns(db),
                Profile.numberOfSelectedColumns(db)
            ])
            
            return ScopeAdapter([
                ViewModel.contactProfileString: adapters[1],
                ViewModel.closedGroupProfileFrontString: adapters[2],
                ViewModel.closedGroupProfileBackString: adapters[3],
                ViewModel.closedGroupProfileBackFallbackString: adapters[4]
            ])
        }
    }
}
