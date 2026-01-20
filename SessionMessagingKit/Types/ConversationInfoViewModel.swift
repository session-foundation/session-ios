// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import GRDB
import DifferenceKit
import SessionUIKit
import SessionUtilitiesKit

/// This type is used to populate the `ConversationCell` in the `HomeVC`, `MessageRequestsViewModel` and the
/// `GlobalSearchViewController`, it should be populated via the `ConversationDataHelper` and should be tied to a screen
/// using the `ObservationBuilder` in order to properly populate it's content
public struct ConversationInfoViewModel: PagableRecord, Sendable, Equatable, Hashable, Identifiable, Differentiable {
    public typealias PagedDataType = SessionThread
    
    public var differenceIdentifier: String { id }
    
    public let id: String
    public let variant: SessionThread.Variant
    public let displayName: String
    public let displayPictureUrl: String?
    public let conversationDescription: String?
    public let creationDateTimestamp: TimeInterval
    public let shouldBeVisible: Bool
    public let pinnedPriority: Int32
    
    public let isDraft: Bool
    public let isNoteToSelf: Bool
    public let isBlocked: Bool
    
    /// This flag indicates whether the thread is an outgoing message request
    public let isMessageRequest: Bool
    
    /// This flag indicates whether the thread is an incoming message request
    public let requiresApproval: Bool
    
    public let mutedUntilTimestamp: TimeInterval?
    public let onlyNotifyForMentions: Bool
    public let wasMarkedUnread: Bool
    public let unreadCount: Int
    public let unreadMentionCount: Int
    public let hasUnreadMessagesOfAnyKind: Bool
    public let disappearingMessagesConfiguration: DisappearingMessagesConfiguration?
    public let messageDraft: String
    
    public let canWrite: Bool
    public let canUpload: Bool
    public let canAccessSettings: Bool
    public let shouldShowProBadge: Bool
    public let isTyping: Bool
    public let userCount: Int?
    public let memberNames: String
    public let messageSnippet: String?
    public let targetInteraction: InteractionInfo?
    public let lastInteraction: InteractionInfo?
    public let userSessionId: SessionId
    public let currentUserSessionIds: Set<String>
    
    // Variant-specific configuration
    
    public let profile: Profile?
    public let additionalProfile: Profile?
    public let contactInfo: ContactInfo?
    public let groupInfo: GroupInfo?
    public let communityInfo: CommunityInfo?
    
    public var dateForDisplay: String {
        let timestamp: TimeInterval
        
        switch (targetInteraction, lastInteraction) {
            case (.some(let interaction), _): timestamp = (Double(interaction.timestampMs) / 1000)
            case (_, .some(let interaction)): timestamp = (Double(interaction.timestampMs) / 1000)
            default: timestamp = creationDateTimestamp
        }
        
        return Date(timeIntervalSince1970: timestamp).formattedForDisplay
    }
    
    public init(
        thread: SessionThread,
        dataCache: ConversationDataCache,
        targetInteractionId: Int64? = nil,
        searchText: String? = nil,
        using dependencies: Dependencies
    ) {
        let currentUserSessionIds: Set<String> = dataCache.currentUserSessionIds(for: thread.id)
        let isMessageRequest: Bool = (
            (
                thread.variant == .group &&
                dataCache.group(for: thread.id)?.invited != false
            ) || (
                thread.variant == .contact &&
                !currentUserSessionIds.contains(thread.id) &&
                dataCache.contact(for: thread.id)?.isApproved != true
            )
        )
        let requiresApproval: Bool = (
            thread.variant == .contact &&
            dataCache.contact(for: thread.id)?.didApproveMe != true
        )
        let sortedMemberIds: [String] = dataCache.groupMembers(for: thread.id)
            .map({ $0.profileId })
            .filter({ !currentUserSessionIds.contains($0) })
            .sorted()
        let profile: Profile? = {
            switch thread.variant {
                case .contact:
                    /// If the thread is the Note to Self one then use the proper profile from the cache (instead of a random blinded one)
                    guard !currentUserSessionIds.contains(thread.id) else {
                        return (
                            dataCache.profile(for: dataCache.userSessionId.hexString) ??
                            Profile.defaultFor(dataCache.userSessionId.hexString)
                        )
                    }
                    
                    return (dataCache.profile(for: thread.id) ?? Profile.defaultFor(thread.id))
                    
                case .legacyGroup, .group:
                    let maybeTargetId: String? = sortedMemberIds.first
                    
                    return dataCache.profile(for: maybeTargetId ?? dataCache.userSessionId.hexString)
                
                case .community: return nil
            }
        }()
        let lastInteractionContentBuilder: Interaction.ContentBuilder = Interaction.ContentBuilder(
            interaction: dataCache.interactionStats(for: thread.id).map {
                dataCache.interaction(for: $0.latestInteractionId)
            },
            threadId: thread.id,
            threadVariant: thread.variant,
            searchText: searchText,
            dataCache: dataCache
        )
        let targetInteractionContentBuilder: Interaction.ContentBuilder? = targetInteractionId.map {
            Interaction.ContentBuilder(
                interaction: dataCache.interaction(for: $0),
                threadId: thread.id,
                threadVariant: thread.variant,
                searchText: searchText,
                dataCache: dataCache
            )
        }
            
        let lastInteraction: InteractionInfo? = InteractionInfo(contentBuilder: lastInteractionContentBuilder)
        let groupInfo: GroupInfo? = dataCache.group(for: thread.id).map {
            GroupInfo(
                group: $0,
                dataCache: dataCache,
                currentUserSessionIds: currentUserSessionIds
            )
        }
        let communityInfo: CommunityInfo? = dataCache.community(for: thread.id).map {
            CommunityInfo(
                openGroup: $0,
                dataCache: dataCache
            )
        }
        
        self.id = thread.id
        self.variant = thread.variant
        self.displayName = {
            let result: String = SessionThread.displayName(
                threadId: thread.id,
                variant: thread.variant,
                groupName: dataCache.group(for: thread.id)?.name,
                communityName: dataCache.community(for: thread.id)?.name,
                isNoteToSelf: currentUserSessionIds.contains(thread.id),
                ignoreNickname: false,
                profile: profile
            )
            
            /// If this is being displayed as a conversation search result then we want to highlight the `searchTerm` in the `displayName`
            ///
            /// **Note:** If there is a `targetInteractionId` then this is a message search result and we don't want to highlight
            /// the `searchText` within the title
            guard let searchText: String = searchText, targetInteractionId == nil else {
                return result
            }
            
            return GlobalSearch.highlightSearchText(
                searchText: searchText,
                content: result
            )
        }()
        self.displayPictureUrl = {
            switch thread.variant {
                case .community: return dataCache.community(for: thread.id)?.displayPictureOriginalUrl
                case .group, .legacyGroup: return dataCache.group(for: thread.id)?.displayPictureUrl
                case .contact: return dataCache.profile(for: thread.id)?.displayPictureUrl
            }
        }()
        self.conversationDescription = {
            switch thread.variant {
                case .contact, .legacyGroup: return nil
                case .community: return dataCache.community(for: thread.id)?.roomDescription
                case .group: return dataCache.group(for: thread.id)?.groupDescription
            }
        }()
        self.creationDateTimestamp = thread.creationDateTimestamp
        self.shouldBeVisible = thread.shouldBeVisible
        self.pinnedPriority = (thread.pinnedPriority.map { Int32($0) } ?? LibSession.visiblePriority)
        
        self.isDraft = (thread.isDraft == true)
        self.isNoteToSelf = currentUserSessionIds.contains(thread.id)
        self.isBlocked = (dataCache.contact(for: thread.id)?.isBlocked == true)
        self.isMessageRequest = isMessageRequest
        self.requiresApproval = requiresApproval
        
        self.mutedUntilTimestamp = thread.mutedUntilTimestamp
        self.onlyNotifyForMentions = thread.onlyNotifyForMentions
        self.wasMarkedUnread = (thread.markedAsUnread == true)
        self.disappearingMessagesConfiguration = dataCache.disappearingMessageConfiguration(for: thread.id)
        self.messageDraft = (thread.messageDraft ?? "")
        
        self.canWrite = {
            switch thread.variant {
                case .contact:
                    guard isMessageRequest else { return true }
                    
                    /// If the thread is an incoming message request then we should be able to reply regardless of the original
                    /// senders `blocksCommunityMessageRequests` setting
                    guard requiresApproval else { return true }
                    
                    return (profile?.blocksCommunityMessageRequests != true)
                    
                case .legacyGroup: return false
                case .group:
                    guard
                        groupInfo?.isDestroyed != true,
                        groupInfo?.wasKicked != true
                    else { return false }
                    guard !isMessageRequest else { return true }
                    
                    return (lastInteraction?.variant.isGroupLeavingStatus != true)
                    
                case .community: return (communityInfo?.permissions.contains(.write) ?? false)
            }
        }()
        self.canUpload = {
            switch thread.variant {
                case .contact:
                    /// If the thread is an outgoing message request then we shouldn't be able to upload
                    return (requiresApproval == false)
                    
                case .legacyGroup: return false
                case .group:
                    guard
                        groupInfo?.isDestroyed != true,
                        groupInfo?.wasKicked != true
                    else { return false }
                    guard !isMessageRequest else { return true }
                    
                    return (lastInteraction?.variant.isGroupLeavingStatus != true)
                    
                case .community: return (communityInfo?.permissions.contains(.upload) ?? false)
            }
        }()
        self.canAccessSettings = (
            !requiresApproval &&
            !isMessageRequest &&
            variant != .legacyGroup
        )
        
        self.shouldShowProBadge = {
            guard dependencies[feature: .sessionProEnabled] else { return false }
            
            switch thread.variant {
                case .contact:
                    return dependencies[singleton: .sessionProManager]
                        .profileFeatures(for: profile)
                        .contains(.proBadge)
                    
                case .group: return false   // TODO: [PRO] Determine if the group is PRO
                case .community, .legacyGroup: return false
            }
        }()
        self.isTyping = dataCache.isTyping(in: thread.id)
        self.userCount = {
            switch thread.variant {
                case .contact: return nil
                case .legacyGroup, .group:
                    return dataCache.groupMembers(for: thread.id)
                        .filter { $0.role != .zombie }
                        .count
                
                case .community: return Int(dataCache.community(for: thread.id)?.userCount ?? 0)
            }
        }()
        self.memberNames = {
            let memberNameString: String = dataCache.groupMembers(for: thread.id)
                .compactMap { member in dataCache.profile(for: member.profileId) }
                .map { profile in
                    profile.displayName(
                        showYouForCurrentUser: false    /// Don't want to show `You` here as this is displayed in Global Search
                    )
                }
                .joined(separator: ", ")
            
            /// If this is being displayed as a search result then we want to highlight the `searchTerm` in the `memberNameString`
            ///
            /// **Note:** If there is a `targetInteractionId` then this is a message search result and we won't be showing the
            /// `memberNameString` so no need to highlight it
            guard let searchText: String = searchText, targetInteractionId == nil else {
                return memberNameString
            }
            
            return GlobalSearch.highlightSearchText(
                searchText: searchText,
                content: memberNameString
            )
        }()
        self.messageSnippet = (targetInteractionContentBuilder ?? lastInteractionContentBuilder)
            .makeSnippet(dateNow: dependencies.dateNow)
        
        self.unreadCount = (dataCache.interactionStats(for: thread.id)?.unreadCount ?? 0)
        self.unreadMentionCount = (dataCache.interactionStats(for: thread.id)?.unreadMentionCount ?? 0)
        self.hasUnreadMessagesOfAnyKind = (dataCache.interactionStats(for: thread.id)?.hasUnreadMessagesOfAnyKind == true)
        self.targetInteraction = targetInteractionContentBuilder.map {
            InteractionInfo(contentBuilder: $0)
        }
        self.lastInteraction = lastInteraction
        self.userSessionId = dataCache.userSessionId
        self.currentUserSessionIds = currentUserSessionIds
        
        // Variant-specific configuration
        
        self.profile = profile.map { profile in
            profile.with(
                proFeatures: .set(to: dependencies[singleton: .sessionProManager].profileFeatures(for: profile))
            )
        }
        self.additionalProfile = {
            switch thread.variant {
                case .legacyGroup, .group:
                    guard
                        sortedMemberIds.count > 1,
                        let targetId: String = sortedMemberIds.last,
                        targetId != profile?.id
                    else { return nil }
                    
                    return dataCache.profile(for: targetId).map { profile in
                        profile.with(
                            proFeatures: .set(to: dependencies[singleton: .sessionProManager].profileFeatures(for: profile))
                        )
                    }
                
                default: return nil
            }
        }()
        self.contactInfo = dataCache.contact(for: thread.id).map {
            ContactInfo(
                contact: $0,
                profile: profile,
                threadVariant: thread.variant,
                currentUserSessionIds: currentUserSessionIds
            )
        }
        self.groupInfo = groupInfo
        self.communityInfo = communityInfo
    }
}

// MARK: - Observations

extension ConversationInfoViewModel: ObservableKeyProvider {
    public var observedKeys: Set<ObservableKey> {
        var result: Set<ObservableKey> = [
            .conversationCreated,
            .conversationUpdated(id),
            .conversationDeleted(id),
            .messageCreated(threadId: id),
            .typingIndicator(id)
        ]
        
        if SessionId.Prefix.isCommunityBlinded(id) {
            result.insert(.anyContactUnblinded)
        }
        
        if let targetInteraction: InteractionInfo = self.targetInteraction {
            result.insert(.profile(targetInteraction.authorId))
            result.insert(.messageUpdated(id: targetInteraction.id, threadId: id))
            result.insert(.messageDeleted(id: targetInteraction.id, threadId: id))
        }
        
        if let lastInteraction: InteractionInfo = self.lastInteraction {
            result.insert(.profile(lastInteraction.authorId))
            result.insert(.messageUpdated(id: lastInteraction.id, threadId: id))
            result.insert(.messageDeleted(id: lastInteraction.id, threadId: id))
        }
        
        if let profile: Profile = self.profile {
            result.insert(.profile(profile.id))
        }
        
        if let additionalProfile: Profile = self.additionalProfile {
            result.insert(.profile(additionalProfile.id))
        }
        
        switch variant {
            case .contact: result.insert(.contact(id))
            case .group:
                result.insert(.groupInfo(groupId: id))
                result.insert(.groupMemberCreated(threadId: id))
                result.insert(.anyGroupMemberDeleted(threadId: id))
                
            case .community:
                result.insert(.communityUpdated(id))
                result.insert(.anyContactUnblinded) /// To update profile info and blinded mapping
            
            case .legacyGroup: break
        }
        
        return result
    }
    
    public static func handlingStrategy(for event: ObservedEvent) -> EventHandlingStrategy? {
        return event.handlingStrategy
    }
}

public extension ConversationInfoViewModel {
    // MARK: - Marking as Read
    
    enum ReadTarget {
        /// Only the thread should be marked as read
        case thread
        
        /// Both the thread and interactions should be marked as read, if no interaction id is provided then all interactions for the
        /// thread will be marked as read
        case threadAndInteractions(interactionsBeforeInclusive: Int64?)
    }
    
    /// This method marks a thread as read and depending on the target may also update the interactions within a thread as read
    func markAsRead(target: ReadTarget, using dependencies: Dependencies) async throws {
        let targetInteractionId: Int64? = {
            guard case .threadAndInteractions(let interactionId) = target else { return nil }
            guard hasUnreadMessagesOfAnyKind else { return nil }
            
            return (interactionId ?? self.lastInteraction?.id)
        }()
        
        /// No need to do anything if the thread is already marked as read and we don't have a target interaction
        guard wasMarkedUnread || targetInteractionId != nil else { return }
        
        /// Perform the updates
        try await dependencies[singleton: .storage].writeAsync { [id, variant] db in
            if wasMarkedUnread {
                try SessionThread
                    .filter(id: id)
                    .updateAllAndConfig(
                        db,
                        SessionThread.Columns.markedAsUnread.set(to: false),
                        using: dependencies
                    )
                db.addConversationEvent(
                    id: id,
                    variant: variant,
                    type: .updated(.markedAsUnread(false))
                )
            }
            
            if let interactionId: Int64 = targetInteractionId {
                try Interaction.markAsRead(
                    db,
                    interactionId: interactionId,
                    threadId: id,
                    threadVariant: variant,
                    includingOlder: true,
                    trySendReadReceipt: SessionThread.canSendReadReceipt(
                        threadId: id,
                        threadVariant: variant,
                        using: dependencies
                    ),
                    using: dependencies
                )
            }
        }
    }
    
    /// This method will mark a thread as read
    func markAsUnread(using dependencies: Dependencies) async throws {
        guard !wasMarkedUnread else { return }
        
        try await dependencies[singleton: .storage].writeAsync { [id] db in
            try SessionThread
                .filter(id: id)
                .updateAllAndConfig(
                    db,
                    SessionThread.Columns.markedAsUnread.set(to: true),
                    using: dependencies
                )
            db.addConversationEvent(
                id: id,
                variant: variant,
                type: .updated(.markedAsUnread(true))
            )
        }
    }
    
    // MARK: - Draft
    
    func updateDraft(_ draft: String, using dependencies: Dependencies) async throws {
        guard draft != self.messageDraft else { return }
        
        try await dependencies[singleton: .storage].writeAsync { [id, variant] db in
            try SessionThread
                .filter(id: id)
                .updateAll(db, SessionThread.Columns.messageDraft.set(to: draft))
            db.addConversationEvent(
                id: id,
                variant: variant,
                type: .updated(.messageDraft(draft))
            )
        }
    }
}

// MARK: - Convenience Initialization

public extension ConversationInfoViewModel {
    private static let messageRequestsSectionId: String = "MESSAGE_REQUESTS_SECTION_INVALID_THREAD_ID"
    
    var isMessageRequestsSection: Bool { id == ConversationInfoViewModel.messageRequestsSectionId }
    
    static func unreadMessageRequestsBanner(unreadCount: Int) -> ConversationInfoViewModel {
        return ConversationInfoViewModel(
            id: messageRequestsSectionId,
            displayName: "sessionMessageRequests".localized(),
            unreadCount: unreadCount
        )
    }
    
    private init(
        id: String,
        displayName: String = "",
        unreadCount: Int = 0
    ) {
        self.id = id
        self.variant = .contact
        self.displayName = displayName
        self.displayPictureUrl = nil
        self.conversationDescription = nil
        self.creationDateTimestamp = 0
        self.shouldBeVisible = true
        self.pinnedPriority = LibSession.visiblePriority
        
        self.isDraft = false
        self.isNoteToSelf = false
        self.isBlocked = false
        self.isMessageRequest = false
        self.requiresApproval = false
        
        self.mutedUntilTimestamp = nil
        self.onlyNotifyForMentions = false
        self.wasMarkedUnread = false
        self.unreadCount = unreadCount
        self.unreadMentionCount = 0
        self.hasUnreadMessagesOfAnyKind = false
        self.disappearingMessagesConfiguration = nil
        self.messageDraft = ""
        
        self.canWrite = false
        self.canUpload = false
        self.canAccessSettings = false
        self.shouldShowProBadge = false
        self.isTyping = false
        self.userCount = nil
        self.memberNames = ""
        self.messageSnippet = ""
        self.targetInteraction = nil
        self.lastInteraction = nil
        self.userSessionId = .invalid
        self.currentUserSessionIds = []
        
        // Variant-specific configuration
        
        self.profile = nil
        self.additionalProfile = nil
        self.contactInfo = nil
        self.groupInfo = nil
        self.communityInfo = nil
    }
}

// MARK: - ContactInfo

public extension ConversationInfoViewModel {
    struct ContactInfo: Sendable, Equatable, Hashable {
        public let id: String
        public let isCurrentUser: Bool
        public let displayName: String
        public let displayNameInMessageBody: String
        public let isApproved: Bool
        public let lastKnownClientVersion: FeatureVersion?
        
        init(
            contact: Contact,
            profile: Profile?,
            threadVariant: SessionThread.Variant,
            currentUserSessionIds: Set<String>
        ) {
            self.id = contact.id
            self.isCurrentUser = currentUserSessionIds.contains(contact.id)
            self.displayName = (profile ?? Profile.defaultFor(contact.id)).displayName()
            self.displayNameInMessageBody = (profile ?? Profile.defaultFor(contact.id)).displayName(
                includeSessionIdSuffix: (threadVariant == .community)
            )
            self.isApproved = contact.isApproved
            self.lastKnownClientVersion = contact.lastKnownClientVersion
        }
    }
}

// MARK: - GroupInfo

public extension ConversationInfoViewModel {
    struct GroupInfo: Sendable, Equatable, Hashable {
        public let name: String
        public let expired: Bool
        public let wasKicked: Bool
        public let isDestroyed: Bool
        public let adminProfile: Profile?
        public let currentUserRole: GroupMember.Role?
        public let numAdmins: Int
        public let isProGroup: Bool
        
        init(
            group: ClosedGroup,
            dataCache: ConversationDataCache,
            currentUserSessionIds: Set<String>
        ) {
            let adminIds: [String] = dataCache.groupMembers(for: group.threadId)
                .filter { $0.role == .admin }
                .map { $0.profileId }
                .sorted()
            
            self.name = group.name
            self.expired = (group.expired == true)
            self.wasKicked = (dataCache.groupInfo(for: group.threadId)?.wasKickedFromGroup == true)
            self.isDestroyed = (dataCache.groupInfo(for: group.threadId)?.wasGroupDestroyed == true)
            self.adminProfile = adminIds.compactMap { dataCache.profile(for: $0) }.first
            self.currentUserRole = dataCache.groupMembers(for: group.threadId)
                .filter { currentUserSessionIds.contains($0.profileId) }
                .map { $0.role }
                .sorted()
                .last   /// We want the highest-ranking role (in case there are multiple entries)
            self.numAdmins = dataCache.groupMembers(for: group.threadId)
                .filter { $0.role == .admin }
                .count
            
            // TODO: [PRO] Need to determine whether it's a PRO group conversation
            self.isProGroup = false
        }
    }
}

// MARK: - CommunityInfo

public extension ConversationInfoViewModel {
    struct CommunityInfo: Sendable, Equatable, Hashable {
        public let name: String
        public let server: String
        public let roomToken: String
        public let publicKey: String
        public let permissions: OpenGroup.Permissions
        public let capabilities: Set<Capability.Variant>
        
        init(
            openGroup: OpenGroup,
            dataCache: ConversationDataCache
        ) {
            self.name = openGroup.name
            self.server = openGroup.server
            self.roomToken = openGroup.roomToken
            self.publicKey = openGroup.publicKey
            self.permissions = (openGroup.permissions ?? .noPermissions)
            self.capabilities = dataCache.communityCapabilities(for: openGroup.server)
        }
    }
}

// MARK: - InteractionInfo

public extension ConversationInfoViewModel {
    struct InteractionInfo: Sendable, Equatable, Hashable {
        public let id: Int64
        public let threadId: String
        public let authorId: String
        public let authorName: String
        public let variant: Interaction.Variant
        public let bubbleBody: String?
        public let timestampMs: Int64
        public let state: Interaction.State
        public let hasBeenReadByRecipient: Bool
        public let hasAttachments: Bool
        
        internal init?(contentBuilder: Interaction.ContentBuilder) {
            guard
                let interaction: Interaction = contentBuilder.interaction,
                let interactionId: Int64 = interaction.id
            else { return nil }
            
            self.id = interactionId
            self.threadId = interaction.threadId
            self.authorId = interaction.authorId
            self.authorName = contentBuilder.authorDisplayName
            self.variant = interaction.variant
            self.bubbleBody = contentBuilder.makeBubbleBody()
            self.timestampMs = interaction.timestampMs
            self.state = interaction.state
            self.hasBeenReadByRecipient = (interaction.recipientReadTimestampMs != nil)
            self.hasAttachments = contentBuilder.hasAttachments
        }
    }
}

// MARK: - InteractionStats

public extension ConversationInfoViewModel {
    struct InteractionStats: Sendable, Codable, Equatable, Hashable, ColumnExpressible, FetchableRecord {
        public typealias Columns = CodingKeys
        public enum CodingKeys: String, CodingKey, ColumnExpression, CaseIterable {
            case threadId
            case unreadCount
            case unreadMentionCount
            case hasUnreadMessagesOfAnyKind
            case latestInteractionId
            case latestInteractionTimestampMs
        }
        
        public let threadId: String
        public let unreadCount: Int
        public let unreadMentionCount: Int
        public let hasUnreadMessagesOfAnyKind: Bool
        public let latestInteractionId: Int64
        public let latestInteractionTimestampMs: Int64
        
        public static func request(for conversationIds: Set<String>) -> SQLRequest<InteractionStats> {
            let interaction: TypedTableAlias<Interaction> = TypedTableAlias()
            
            return """
                SELECT
                    \(interaction[.threadId]) AS \(Columns.threadId),
                    SUM(\(interaction[.wasRead]) = false) AS \(Columns.unreadCount),
                    SUM(\(interaction[.wasRead]) = false AND \(interaction[.hasMention]) = true) AS \(Columns.unreadMentionCount),
                    (SUM(\(interaction[.wasRead]) = false) > 0) AS \(Columns.hasUnreadMessagesOfAnyKind),
                    \(interaction[.id]) AS \(Columns.latestInteractionId),
                    MAX(\(interaction[.timestampMs])) AS \(Columns.latestInteractionTimestampMs)
                FROM \(Interaction.self)
                WHERE (
                    \(interaction[.threadId]) IN \(conversationIds) AND
                    \(SQL("\(interaction[.variant]) IN \(Interaction.Variant.variantsToShowConversationSnippet)"))
                )
                GROUP BY \(interaction[.threadId])
            """
        }
    }
}

// MARK: - Convenience

private extension ObservedEvent {
    var handlingStrategy: EventHandlingStrategy? {
        switch (key, key.generic) {
            case (_, .profile): return [.databaseQuery, .directCacheUpdate]
            case (_, .groupMemberCreated), (_, .groupMemberUpdated), (_, .groupMemberDeleted):
                return [.databaseQuery, .directCacheUpdate]
            
            case (_, .groupInfo): return .libSessionQuery
            
            case (_, .typingIndicator): return .directCacheUpdate
            case (_, .conversationUpdated): return [.directCacheUpdate, .libSessionQuery]
            case (_, .contact): return .directCacheUpdate
            case (_, .communityUpdated): return .directCacheUpdate
                
            case (.anyContactBlockedStatusChanged, _): return .databaseQuery
            case (_, .conversationCreated), (_, .conversationDeleted): return .databaseQuery
            case (.anyMessageCreatedInAnyConversation, _): return .databaseQuery
            case (_, .messageCreated), (_, .messageUpdated), (_, .messageDeleted): return .databaseQuery
            default: return nil
        }
    }
}

private extension ContactEvent.Change {
    var isUnblindEvent: Bool {
        switch self {
            case .unblinded: return true
            default: return false
        }
    }
}

public extension SessionId.Prefix {
    static func isCommunityBlinded(_ id: String?) -> Bool {
        switch try? SessionId.Prefix(from: id) {
            case .blinded15, .blinded25: return true
            case .standard, .unblinded, .group, .versionBlinded07, .none: return false
        }
    }
}

public extension ConversationInfoViewModel {
    static var requiredJoinSQL: SQL = {
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
    
    static let homeOrderSQL: SQL = {
        let thread: TypedTableAlias<SessionThread> = TypedTableAlias()
        let interaction: TypedTableAlias<Interaction> = TypedTableAlias()
        
        return SQL("""
            (IFNULL(\(thread[.pinnedPriority]), 0) > 0) DESC,
            IFNULL(\(interaction[.timestampMs]), (\(thread[.creationDateTimestamp]) * 1000)) DESC,
            \(thread[.id]) DESC
        """)
    }()
    
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
    
    static let messageRequestsOrderSQL: SQL = {
        let thread: TypedTableAlias<SessionThread> = TypedTableAlias()
        let interaction: TypedTableAlias<Interaction> = TypedTableAlias()
        
        return SQL("""
            IFNULL(\(interaction[.timestampMs]), (\(thread[.creationDateTimestamp]) * 1000)) DESC,
            \(thread[.id]) DESC
        """)
    }()
}
