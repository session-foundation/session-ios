// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import UniformTypeIdentifiers
import Lucide
import GRDB
import DifferenceKit
import SessionNetworkingKit
import SessionMessagingKit
import SessionUtilitiesKit
import SessionUIKit

// MARK: - Log.Category

public extension Log.Category {
    static let conversation: Log.Category = .create("Conversation", defaultLevel: .info)
}

// MARK: - ConversationViewModel

public class ConversationViewModel: OWSAudioPlayerDelegate, NavigatableStateHolder {
    public typealias SectionModel = ArraySection<Section, MessageViewModel>
    
    // MARK: - FocusBehaviour
    
    public enum FocusBehaviour: Sendable, Equatable, Hashable {
        case none
        case highlight
    }
    
    // MARK: - ContentSwapLocation
    
    public enum ContentSwapLocation {
        case none
        case earlier
        case later
    }
    
    // MARK: - Action
    
    public enum Action {
        case none
        case compose
        case audioCall
        case videoCall
    }
    
    // MARK: - Section
    
    public enum Section: Differentiable, Equatable, Comparable, Hashable {
        case loadOlder
        case messages
        case loadNewer
    }
    
    // MARK: - OptimisticMessageData
    
    public struct OptimisticMessageData: Sendable, Equatable, Hashable {
        let temporaryId: Int64
        let interaction: Interaction
        let attachmentData: [Attachment]?
        let linkPreviewDraft: LinkPreviewDraft?
        let linkPreviewPreparedAttachment: PreparedAttachment?
        let quoteModel: QuotedReplyModel?
    }
    
    // MARK: - Variables
    
    public static let pageSize: Int = 50
    public static let legacyGroupsBannerFont: UIFont = .systemFont(ofSize: Values.miniFontSize)
    
    public let navigatableState: NavigatableState = NavigatableState()
    public var disposables: Set<AnyCancellable> = Set()
    
    public let dependencies: Dependencies
    public var sentMessageBeforeUpdate: Bool = false
    public var lastSearchedText: String?
    
    // FIXME: Can avoid this by making the view model an actor (but would require more work)
    /// Marked as `@MainActor` just to force thread safety
    @MainActor private var pendingMarkAsReadInfo: Interaction.TimestampInfo?
    @MainActor private var lastMarkAsReadInfo: Interaction.TimestampInfo?
    
    /// This value is the current state of the view
    @MainActor @Published private(set) var state: State
    private var observationTask: Task<Void, Never>?
    
    // TODO: [PRO] Remove this value (access via `state`)
    public var isCurrentUserSessionPro: Bool { dependencies[singleton: .sessionProManager].currentUserIsCurrentlyPro }
    
    // MARK: - Initialization
    
    @MainActor init(
        threadViewModel: SessionThreadViewModel,
        focusedInteractionInfo: Interaction.TimestampInfo? = nil,
        using dependencies: Dependencies
    ) {
        self.dependencies = dependencies
        self.state = State.initialState(
            threadViewModel: threadViewModel,
            focusedInteractionInfo: focusedInteractionInfo,
            using: dependencies
        )
        
        /// Bind the state
        self.observationTask = ObservationBuilder
            .initialValue(self.state)
            .debounce(for: .milliseconds(10))   /// Changes trigger multiple events at once so debounce them
            .using(dependencies: dependencies)
            .query(ConversationViewModel.queryState)
            .assign { [weak self] updatedState in self?.state = updatedState }
    }
    
    deinit {
        // Stop any audio playing when leaving the screen
        Task { @MainActor [audioPlayer] in
            audioPlayer?.stop()
        }
        
        observationTask?.cancel()
    }
    
    public enum ConversationViewModelEvent: Hashable {
        case sendMessage(data: OptimisticMessageData)
        case failedToStoreMessage(temporaryId: Int64)
        case resolveOptimisticMessage(temporaryId: Int64, databaseId: Int64)
    }
    
    // MARK: - State

    public struct State: ObservableKeyProvider {
        enum ViewState: Equatable {
            case loading
            case empty
            case loaded
        }
        
        let viewState: ViewState
        let threadId: String
        let threadVariant: SessionThread.Variant
        let userSessionId: SessionId
        let currentUserSessionIds: Set<String>
        let isBlindedContact: Bool
        let wasPreviouslyBlindedContact: Bool
        
        /// Used to determine where the paged data should start loading from, and which message should be focused on initial load
        let focusedInteractionInfo: Interaction.TimestampInfo?
        let focusBehaviour: FocusBehaviour
        let initialUnreadInteractionInfo: Interaction.TimestampInfo?
        
        let loadedPageInfo: PagedData.LoadedInfo<MessageViewModel.ID>
        let profileCache: [String: Profile]
        var linkPreviewCache: [String: [LinkPreview]]
        let interactionCache: [Int64: Interaction]
        let attachmentCache: [String: Attachment]
        let reactionCache: [Int64: [Reaction]]
        let quoteMap: [Int64: Int64]
        let attachmentMap: [Int64: Set<InteractionAttachment>]
        let modAdminCache: Set<String>
        let itemCache: [Int64: MessageViewModel]
        
        let titleViewModel: ConversationTitleViewModel
        let threadViewModel: SessionThreadViewModel
        let threadContact: Contact?
        let threadIsTrusted: Bool
        let legacyGroupsBannerIsVisible: Bool
        let reactionsSupported: Bool
        let isUserModeratorOrAdmin: Bool
        let shouldShowTypingIndicator: Bool
        
        let optimisticallyInsertedMessages: [Int64: OptimisticMessageData]
        
        var emptyStateText: String {
            let blocksCommunityMessageRequests: Bool = (threadViewModel.profile?.blocksCommunityMessageRequests == true)
            
            switch (threadViewModel.threadIsNoteToSelf, threadViewModel.threadCanWrite == true, blocksCommunityMessageRequests, threadViewModel.wasKickedFromGroup, threadViewModel.groupIsDestroyed) {
                case (true, _, _, _, _): return "noteToSelfEmpty".localized()
                case (_, false, true, _, _):
                    return "messageRequestsTurnedOff"
                        .put(key: "name", value: threadViewModel.displayName)
                        .localized()
                
                case (_, _, _, _, true):
                    return "groupDeletedMemberDescription"
                        .put(key: "group_name", value: threadViewModel.displayName)
                        .localized()
                    
                case (_, _, _, true, _):
                    return "groupRemovedYou"
                        .put(key: "group_name", value: threadViewModel.displayName)
                        .localized()
                    
                case (_, false, false, _, _):
                    return "conversationsEmpty"
                        .put(key: "conversation_name", value: threadViewModel.displayName)
                        .localized()
                
                default:
                    return "groupNoMessages"
                        .put(key: "group_name", value: threadViewModel.displayName)
                        .localized()
            }
        }
        
        var legacyGroupsBannerMessage: ThemedAttributedString {
            let localizationKey: String
            
            switch threadViewModel.currentUserIsClosedGroupAdmin == true {
                case false: localizationKey = "legacyGroupAfterDeprecationMember"
                case true: localizationKey = "legacyGroupAfterDeprecationAdmin"
            }
            
            // FIXME: Strings should be updated in Crowdin to include the {icon}
            return LocalizationHelper(template: localizationKey)
                .put(key: "date", value: Date(timeIntervalSince1970: 1743631200).formattedForBanner)
                .localizedFormatted(baseFont: ConversationViewModel.legacyGroupsBannerFont)
                .appending(string: " ")     // Designs have a space before the icon
                .appending(
                    Lucide.Icon.squareArrowUpRight
                        .attributedString(for: ConversationViewModel.legacyGroupsBannerFont)
                )
                .appending(string: " ")     // In case it's a RTL font
        }
        
        var messageInputState: SessionThreadViewModel.MessageInputState {
            guard !threadViewModel.threadIsNoteToSelf else {
                return SessionThreadViewModel.MessageInputState(allowedInputTypes: .all)
            }
            guard threadViewModel.threadIsBlocked != true else {
                return SessionThreadViewModel.MessageInputState(
                    allowedInputTypes: .none,
                    message: "blockBlockedDescription".localized(),
                    messageAccessibility: Accessibility(
                        identifier: "Blocked banner"
                    )
                )
            }
            
            if threadViewModel.threadVariant == .community && threadViewModel.threadCanWrite == false {
                return SessionThreadViewModel.MessageInputState(
                    allowedInputTypes: .none,
                    message: "permissionsWriteCommunity".localized()
                )
            }
            
            return SessionThreadViewModel.MessageInputState(
                allowedInputTypes: (threadViewModel.threadRequiresApproval == false && threadViewModel.threadIsMessageRequest == false ?
                    .all :
                    .textOnly
                )
            )
        }
        
        @MainActor public func sections(viewModel: ConversationViewModel) -> [SectionModel] {
            ConversationViewModel.sections(state: self, viewModel: viewModel)
        }
        
        public var observedKeys: Set<ObservableKey> {
            var result: Set<ObservableKey> = [
                .loadPage(ConversationViewModel.self),
                .updateScreen(ConversationViewModel.self),
                .conversationUpdated(threadId),
                .conversationDeleted(threadId),
                .profile(userSessionId.hexString),
                .typingIndicator(threadId),
                .messageCreated(threadId: threadId)
            ]
            
            /// Add thread-variant specific events (eg. ensure the display picture and title change when profiles are updated, initial
            /// data is loaded, etc.)
            switch threadViewModel.threadVariant {
                case .contact:
                    result.insert(.profile(threadViewModel.threadId))
                    result.insert(.contact(threadViewModel.threadId))
                    
                case .group:
                    if let frontProfileId: String = threadViewModel.closedGroupProfileFront?.id {
                        result.insert(.profile(frontProfileId))
                    }
                    
                    if let backProfileId: String = threadViewModel.closedGroupProfileBack?.id {
                        result.insert(.profile(backProfileId))
                    }
                    
                case .community:
                    result.insert(.communityUpdated(threadId))
                    
                default: break
            }
            
            interactionCache.keys.forEach { messageId in
                result.insert(.messageUpdated(id: messageId, threadId: threadId))
                result.insert(.messageDeleted(id: messageId, threadId: threadId))
                result.insert(.reactionsChanged(messageId: messageId))
                result.insert(.attachmentCreated(messageId: messageId))
                
                attachmentMap[messageId]?.forEach { interactionAttachment in
                    result.insert(.attachmentUpdated(id: interactionAttachment.attachmentId, messageId: messageId))
                    result.insert(.attachmentDeleted(id: interactionAttachment.attachmentId, messageId: messageId))
                }
            }
            
            return result
        }
        
        static func initialState(
            threadViewModel: SessionThreadViewModel,
            focusedInteractionInfo: Interaction.TimestampInfo?,
            using dependencies: Dependencies
        ) -> State {
            let userSessionId: SessionId = dependencies[cache: .general].sessionId
            
            return State(
                viewState: .loading,
                threadId: threadViewModel.threadId,
                threadVariant: threadViewModel.threadVariant,
                userSessionId: userSessionId,
                currentUserSessionIds: [userSessionId.hexString],
                isBlindedContact: SessionId.Prefix.isCommunityBlinded(threadViewModel.threadId),
                wasPreviouslyBlindedContact: SessionId.Prefix.isCommunityBlinded(threadViewModel.threadId),
                focusedInteractionInfo: focusedInteractionInfo,
                focusBehaviour: (focusedInteractionInfo == nil ? .none : .highlight),
                initialUnreadInteractionInfo: nil,
                loadedPageInfo: PagedData.LoadedInfo(
                    record: Interaction.self,
                    pageSize: ConversationViewModel.pageSize,
                    requiredJoinSQL: nil,
                    filterSQL: MessageViewModel.interactionFilterSQL(threadId: threadViewModel.threadId),
                    groupSQL: nil,
                    orderSQL: MessageViewModel.interactionOrderSQL
                ),
                profileCache: [:],
                linkPreviewCache: [:],
                interactionCache: [:],
                attachmentCache: [:],
                reactionCache: [:],
                quoteMap: [:],
                attachmentMap: [:],
                modAdminCache: [],
                itemCache: [:],
                titleViewModel: ConversationTitleViewModel(
                    threadViewModel: threadViewModel,
                    using: dependencies
                ),
                threadViewModel: threadViewModel,
                threadContact: nil,
                threadIsTrusted: false,
                legacyGroupsBannerIsVisible: (threadViewModel.threadVariant == .legacyGroup),
                reactionsSupported: (
                    threadViewModel.threadVariant != .legacyGroup &&
                    threadViewModel.threadIsMessageRequest != true
                ),
                isUserModeratorOrAdmin: false,
                shouldShowTypingIndicator: false,
                optimisticallyInsertedMessages: [:]
            )
        }
        
        fileprivate static func orderedIdsIncludingOptimisticMessages(
            loadedPageInfo: PagedData.LoadedInfo<MessageViewModel.ID>,
            optimisticMessages: [Int64: OptimisticMessageData],
            interactionCache: [Int64: Interaction]
        ) -> [Int64] {
            guard !optimisticMessages.isEmpty else { return loadedPageInfo.currentIds }
            
            /// **Note:** The sorting of `currentIds` is newest to oldest so we need to insert in the same way
            var remainingPagedIds: [Int64] = loadedPageInfo.currentIds
            var remainingSortedOptimisticMessages: [(Int64, OptimisticMessageData)] = optimisticMessages
                .sorted { lhs, rhs in
                    lhs.value.interaction.timestampMs > rhs.value.interaction.timestampMs
                }
            var result: [Int64] = []
            
            while !remainingPagedIds.isEmpty || !remainingSortedOptimisticMessages.isEmpty {
                let nextPaged: Interaction? = remainingPagedIds.first.map { interactionCache[$0] }
                let nextOptimistic: OptimisticMessageData? = remainingSortedOptimisticMessages.first?.1
                
                switch (nextPaged, nextOptimistic) {
                    case (.some(let paged), .some(let optimistic)): /// Add the newest first and loop
                        if optimistic.interaction.timestampMs >= paged.timestampMs {
                            result.append(optimistic.temporaryId)
                            remainingSortedOptimisticMessages.removeFirst()
                        }
                        else {
                            paged.id.map { result.append($0) }
                            remainingPagedIds.removeFirst()
                        }
                        
                    case (.some, .none):    /// No optimistic messages left, add the remaining paged messages
                        result.append(contentsOf: remainingPagedIds)
                        remainingPagedIds.removeAll()
                        
                    case (.none, .some):    /// No paged results left, add the remaining optimistic messages
                        result.append(contentsOf: remainingSortedOptimisticMessages.map { $0.0 })
                        remainingSortedOptimisticMessages.removeAll()
                        
                    case (.none, .none): return result  /// Invalid case
                }
            }
            
            return result
        }
        
        fileprivate static func interaction(
            at index: Int,
            orderedIds: [Int64],
            optimisticMessages: [Int64: OptimisticMessageData],
            interactionCache: [Int64: Interaction]
        ) -> Interaction? {
            guard index >= 0, index < orderedIds.count else { return nil }
            guard orderedIds[index] >= 0 else {
                /// If the `id` is less than `0` then it's an optimistic message
                return optimisticMessages[orderedIds[index]]?.interaction
            }
            
            return interactionCache[orderedIds[index]]
        }
    }
    
    @Sendable private static func queryState(
        previousState: State,
        events: [ObservedEvent],
        isInitialQuery: Bool,
        using dependencies: Dependencies
    ) async -> State {
        var threadId: String = previousState.threadId
        let threadVariant: SessionThread.Variant = previousState.threadVariant
        var currentUserSessionIds: Set<String> = previousState.currentUserSessionIds
        var focusedInteractionInfo: Interaction.TimestampInfo? = previousState.focusedInteractionInfo
        var initialUnreadInteractionInfo: Interaction.TimestampInfo? = previousState.initialUnreadInteractionInfo
        var loadResult: PagedData.LoadResult = previousState.loadedPageInfo.asResult
        var profileCache: [String: Profile] = previousState.profileCache
        var linkPreviewCache: [String: [LinkPreview]] = previousState.linkPreviewCache
        var interactionCache: [Int64: Interaction] = previousState.interactionCache
        var attachmentCache: [String: Attachment] = previousState.attachmentCache
        var reactionCache: [Int64: [Reaction]] = previousState.reactionCache
        var quoteMap: [Int64: Int64] = previousState.quoteMap
        var attachmentMap: [Int64: Set<InteractionAttachment>] = previousState.attachmentMap
        var modAdminCache: Set<String> = previousState.modAdminCache
        var itemCache: [Int64: MessageViewModel] = previousState.itemCache
        var threadViewModel: SessionThreadViewModel = previousState.threadViewModel
        var threadContact: Contact? = previousState.threadContact
        var threadIsTrusted: Bool = previousState.threadIsTrusted
        var reactionsSupported: Bool = previousState.reactionsSupported
        var isUserModeratorOrAdmin: Bool = previousState.isUserModeratorOrAdmin
        var threadWasKickedFromGroup: Bool = (threadViewModel.wasKickedFromGroup == true)
        var threadGroupIsDestroyed: Bool = (threadViewModel.groupIsDestroyed == true)
        var shouldShowTypingIndicator: Bool = false
        var optimisticallyInsertedMessages: [Int64: OptimisticMessageData] = previousState.optimisticallyInsertedMessages
        
        /// Store a local copy of the events so we can manipulate it based on the state changes
        var eventsToProcess: [ObservedEvent] = events
        var profileIdsNeedingFetch: Set<String> = []
        var shouldFetchInitialUnreadInteractionInfo: Bool = false
        
        /// If this is the initial query then we need to properly fetch the initial state
        if isInitialQuery {
            /// Insert a fake event to force the initial page load
            eventsToProcess.append(ObservedEvent(
                key: .loadPage(ConversationViewModelEvent.self),
                value: (
                    focusedInteractionInfo.map { LoadPageEvent.initialPageAround(id: $0.id) } ??
                    LoadPageEvent.initial
                )
            ))
            
            /// Determine reactions support
            switch threadVariant {
                case .legacyGroup:
                    reactionsSupported = false
                    isUserModeratorOrAdmin = (threadViewModel.currentUserIsClosedGroupAdmin == true)
                
                case .contact:
                    reactionsSupported = (threadViewModel.threadIsMessageRequest != true)
                    shouldShowTypingIndicator = await dependencies[singleton: .typingIndicators]
                        .isRecipientTyping(threadId: threadId)
                    
                case .group:
                    reactionsSupported = (threadViewModel.threadIsMessageRequest != true)
                    isUserModeratorOrAdmin = (threadViewModel.currentUserIsClosedGroupAdmin == true)
                
                case .community:
                    reactionsSupported = await dependencies[singleton: .communityManager].doesOpenGroupSupport(
                        capability: .reactions,
                        on: threadViewModel.openGroupServer
                    )
                    
                    /// Get the session id options for the current user
                    if
                        let server: String = threadViewModel.openGroupServer,
                        let serverInfo: CommunityManager.Server = await dependencies[singleton: .communityManager].server(server)
                    {
                        currentUserSessionIds = serverInfo.currentUserSessionIds
                    }
                    
                    modAdminCache = await dependencies[singleton: .communityManager].allModeratorsAndAdmins(
                        server: threadViewModel.openGroupServer,
                        roomToken: threadViewModel.openGroupRoomToken,
                        includingHidden: true
                    )
                    isUserModeratorOrAdmin = !modAdminCache.isDisjoint(with: currentUserSessionIds)
            }
            
            /// Determine whether we need to fetch the initial unread interaction info
            shouldFetchInitialUnreadInteractionInfo = (initialUnreadInteractionInfo == nil)
            
            /// Check if the typing indicator should be visible
            shouldShowTypingIndicator = await dependencies[singleton: .typingIndicators].isRecipientTyping(
                threadId: threadId
            )
        }
        
        /// If there are no events we want to process then just return the current state
        guard !eventsToProcess.isEmpty else { return previousState }
        
        /// Split the events between those that need database access and those that don't
        let splitEvents: [EventDataRequirement: Set<ObservedEvent>] = eventsToProcess
            .reduce(into: [:]) { result, next in
                switch next.dataRequirement {
                    case .databaseQuery: result[.databaseQuery, default: []].insert(next)
                    case .other: result[.other, default: []].insert(next)
                    case .bothDatabaseQueryAndOther:
                        result[.databaseQuery, default: []].insert(next)
                        result[.other, default: []].insert(next)
                }
            }
        var databaseEvents: Set<ObservedEvent> = (splitEvents[.databaseQuery] ?? [])
        let groupedOtherEvents: [GenericObservableKey: Set<ObservedEvent>]? = splitEvents[.other]?
            .reduce(into: [:]) { result, event in
                result[event.key.generic, default: []].insert(event)
            }
        var loadPageEvent: LoadPageEvent? = splitEvents[.databaseQuery]?
            .first(where: { $0.key.generic == .loadPage })?
            .value as? LoadPageEvent
        
        // FIXME: We should be able to make this far more efficient by splitting this query up and only fetching diffs
        var threadNeedsRefresh: Bool = (
            threadId != previousState.threadId ||
            events.contains(where: {
                $0.key.generic == .conversationUpdated ||
                $0.key.generic == .contact ||
                $0.key.generic == .profile
            })
        )
        
        /// Handle thread specific changes first (as this could include a conversation being unblinded)
        switch threadVariant {
            case .contact:
                groupedOtherEvents?[.contact]?.forEach { event in
                    guard let eventValue: ContactEvent = event.value as? ContactEvent else { return }
                    
                    switch eventValue.change {
                        case .isTrusted(let value):
                            threadContact = threadContact?.with(
                                isTrusted: .set(to: value),
                                currentUserSessionId: previousState.userSessionId
                            )
                            
                        case .isApproved(let value):
                            threadContact = threadContact?.with(
                                isApproved: .set(to: value),
                                currentUserSessionId: previousState.userSessionId
                            )
                            
                        case .isBlocked(let value):
                            threadContact = threadContact?.with(
                                isBlocked: .set(to: value),
                                currentUserSessionId: previousState.userSessionId
                            )
                            
                        case .didApproveMe(let value):
                            threadContact = threadContact?.with(
                                didApproveMe: .set(to: value),
                                currentUserSessionId: previousState.userSessionId
                            )
                            
                        case .unblinded(let blindedId, let unblindedId):
                            /// Need to handle a potential "unblinding" event first since it changes the `threadId` (and then
                            /// we reload the messages based on the initial paged data query just in case - there isn't a perfect
                            /// solution to capture the current messages plus any others that may have been added by the
                            /// merge so do the best we can)
                            guard blindedId == threadId else { return }
                            
                            threadId = unblindedId
                            loadResult = loadResult.info
                                .with(filterSQL: MessageViewModel.interactionFilterSQL(threadId: unblindedId))
                                .asResult
                            loadPageEvent = .initial
                            databaseEvents.insert(
                                ObservedEvent(
                                    key: .loadPage(ConversationViewModel.self),
                                    value: LoadPageEvent.initial
                                )
                            )
                    }
                }
                
            case .legacyGroup, .group:
                groupedOtherEvents?[.groupMemberUpdated]?.forEach { event in
                    guard let eventValue: GroupMemberEvent = event.value as? GroupMemberEvent else { return }
                    
                    switch eventValue.change {
                        case .none: break
                        case .role(let role, _):
                            guard eventValue.profileId == previousState.userSessionId.hexString else { return }
                            
                            isUserModeratorOrAdmin = (role == .admin)
                    }
                }
            
            case .community:
                /// Handle community changes (users could change to mods which would need all of their interaction data updated)
                groupedOtherEvents?[.communityUpdated]?.forEach { event in
                    guard let eventValue: CommunityEvent = event.value as? CommunityEvent else { return }
                    
                    switch eventValue.change {
                        case .receivedInitialMessages:
                            /// If we already have a `loadPageEvent` then that takes prescedence, otherwise we should load
                            /// the initial page once we've received the initial messages for a community
                            guard loadPageEvent == nil else { break }
                            
                            loadPageEvent = .initial
                        
                        case .role(let moderator, let admin, let hiddenModerator, let hiddenAdmin):
                            isUserModeratorOrAdmin = (moderator || admin || hiddenModerator || hiddenAdmin)
                        
                        case .moderatorsAndAdmins(let admins, let hiddenAdmins, let moderators, let hiddenModerators):
                            modAdminCache = Set(admins + hiddenAdmins + moderators + hiddenModerators)
                            isUserModeratorOrAdmin = !modAdminCache.isDisjoint(with: currentUserSessionIds)
                            
                        // FIXME: When we break apart the SessionThreadViewModel these should be handled
                        case .capabilities, .permissions: break
                    }
                }
        }
        
        /// Profile events
        groupedOtherEvents?[.profile]?.forEach { event in
            guard let eventValue: ProfileEvent = event.value as? ProfileEvent else { return }
            guard var profileData: Profile = profileCache[eventValue.id] else {
                /// This profile (somehow) isn't in the cache, so we need to fetch it
                profileIdsNeedingFetch.insert(eventValue.id)
                return
            }
            
            switch eventValue.change {
                case .name(let name): profileData = profileData.with(name: name)
                case .nickname(let nickname): profileData = profileData.with(nickname: .set(to: nickname))
                case .displayPictureUrl(let url): profileData = profileData.with(displayPictureUrl: .set(to: url))
                case .proStatus(_, let features, let proExpiryUnixTimestampMs, let proGenIndexHash):
                    let finalFeatures: SessionPro.Features = {
                        guard dependencies[feature: .sessionProEnabled] else { return .none }
                        
                        return features
                            .union(dependencies[feature: .proBadgeEverywhere] ? .proBadge : .none)
                    }()
                    
                    profileData = profileData.with(
                        proFeatures: .set(to: finalFeatures),
                        proExpiryUnixTimestampMs: .set(to: proExpiryUnixTimestampMs),
                        proGenIndexHash: .set(to: proGenIndexHash)
                    )
            }
            
            profileCache[eventValue.id] = profileData
        }
        
        /// Pull data from libSession
        if threadNeedsRefresh {
            let result: (wasKickedFromGroup: Bool, groupIsDestroyed: Bool) = {
                guard threadVariant == .group else { return (false, false) }
                
                let sessionId: SessionId = SessionId(.group, hex: threadId)
                return dependencies.mutate(cache: .libSession) { cache in
                    (
                        cache.wasKickedFromGroup(groupSessionId: sessionId),
                        cache.groupIsDestroyed(groupSessionId: sessionId)
                    )
                }
            }()
            threadWasKickedFromGroup = result.wasKickedFromGroup
            threadGroupIsDestroyed = result.groupIsDestroyed
        }
        
        /// Then handle database events
        if !dependencies[singleton: .storage].isSuspended, (threadNeedsRefresh || !databaseEvents.isEmpty) {
            do {
                var fetchedInteractions: [Interaction] = []
                var fetchedProfiles: [Profile] = []
                var fetchedLinkPreviews: [LinkPreview] = []
                var fetchedAttachments: [Attachment] = []
                var fetchedInteractionAttachments: [InteractionAttachment] = []
                var fetchedReactions: [Int64: [Reaction]] = [:]
                var fetchedQuoteMap: [Int64: Int64] = [:]
                
                /// Identify any inserted/deleted records
                var insertedInteractionIds: Set<Int64> = []
                var updatedInteractionIds: Set<Int64> = []
                var deletedInteractionIds: Set<Int64> = []
                var updatedAttachmentIds: Set<String> = []
                var interactionIdsNeedingReactionUpdates: Set<Int64> = []
                
                databaseEvents.forEach { event in
                    switch event.value {
                        case let messageEvent as MessageEvent:
                            guard let messageId: Int64 = messageEvent.id else { return }
                            
                            switch event.key.generic {
                                case .messageCreated: insertedInteractionIds.insert(messageId)
                                case .messageUpdated: updatedInteractionIds.insert(messageId)
                                case .messageDeleted: deletedInteractionIds.insert(messageId)
                                default: break
                            }
                            
                        case let conversationEvent as ConversationEvent:
                            switch conversationEvent.change {
                                /// Since we cache whether a messages disappearing message config can be followed we
                                /// need to update the value if the disappearing message config on the conversation changes
                                case .disappearingMessageConfiguration:
                                    itemCache.forEach { id, item in
                                        guard item.canFollowDisappearingMessagesSetting else { return }
                                        
                                        updatedInteractionIds.insert(id)
                                    }
                                    
                                default: break
                            }
                            
                        case let attachmentEvent as AttachmentEvent:
                            switch event.key.generic {
                                case .attachmentUpdated: updatedAttachmentIds.insert(attachmentEvent.id)
                                default: break
                            }
                            
                        case let reactionEvent as ReactionEvent:
                            interactionIdsNeedingReactionUpdates.insert(reactionEvent.messageId)
                        
                        case let communityEvent as CommunityEvent:
                            switch communityEvent.change {
                                case .receivedInitialMessages: break /// This is custom handled above
                                case .role:
                                    updatedInteractionIds.insert(
                                        contentsOf: Set(itemCache
                                            .filter { currentUserSessionIds.contains($0.value.authorId) }
                                            .keys)
                                    )
                                    
                                case .moderatorsAndAdmins(let admins, let hiddenAdmins, let moderators, let hiddenModerators):
                                    let modAdminIds: Set<String> = Set(admins + hiddenAdmins + moderators + hiddenModerators)
                                    updatedInteractionIds.insert(
                                        contentsOf: Set(itemCache
                                            .filter {
                                                guard modAdminIds.contains($0.value.authorId) else {
                                                    return $0.value.isSenderModeratorOrAdmin
                                                }
                                                
                                                return !$0.value.isSenderModeratorOrAdmin
                                            }
                                            .keys)
                                    )
                                    
                                case .capabilities, .permissions: break /// Shouldn't affect messages
                            }
                            
                        default: break
                    }
                }
                
                try await dependencies[singleton: .storage].readAsync { db in
                    var interactionIdsNeedingFetch: [Int64] = Array(updatedInteractionIds)
                    var attachmentIdsNeedingFetch: [String] = Array(updatedAttachmentIds)
                    
                    /// Separately fetch the `initialUnreadInteractionInfo` if needed
                    if shouldFetchInitialUnreadInteractionInfo {
                        initialUnreadInteractionInfo = try Interaction
                            .select(.id, .timestampMs)
                            .filter(Interaction.Columns.wasRead == false)
                            .filter(Interaction.Columns.threadId == threadId)
                            .order(Interaction.Columns.timestampMs.asc)
                            .asRequest(of: Interaction.TimestampInfo.self)
                            .fetchOne(db)
                    }
                    
                    /// If we don't have the `Contact` data and need it then fetch it now
                    if threadVariant == .contact && threadContact?.id != threadId {
                        threadContact = try Contact.fetchOne(db, id: threadId)
                    }
                    
                    /// Update loaded page info as needed
                    if loadPageEvent != nil || !insertedInteractionIds.isEmpty || !deletedInteractionIds.isEmpty {
                        let target: PagedData.Target<MessageViewModel.ID>
                        
                        switch loadPageEvent?.target {
                            case .initial:
                                /// If we don't have an initial `focusedInteractionInfo` then we should default to loading
                                /// data around the `initialUnreadInteractionInfo` and focus on that
                                let finalLoadPageEvent: LoadPageEvent = (
                                    initialUnreadInteractionInfo.map { .initialPageAround(id: $0.id) } ??
                                    .initial
                                )
                                
                                focusedInteractionInfo = initialUnreadInteractionInfo
                                target = (
                                    finalLoadPageEvent.target(with: loadResult) ??
                                    .newItems(insertedIds: insertedInteractionIds, deletedIds: deletedInteractionIds)
                                )
                                
                            default:
                                target = (
                                    loadPageEvent?.target(with: loadResult) ??
                                    .newItems(insertedIds: insertedInteractionIds, deletedIds: deletedInteractionIds)
                                )
                        }
                        
                        loadResult = try loadResult.load(
                            db,
                            target: target
                        )
                        interactionIdsNeedingFetch += loadResult.newIds
                    }
                    
                    /// Get the ids of any quoted interactions
                    let quoteInteractionIdResults: Set<FetchablePair<Int64, Int64>> = try MessageViewModel
                        .quotedInteractionIds(
                            for: interactionIdsNeedingFetch,
                            currentUserSessionIds: currentUserSessionIds
                        )
                        .fetchSet(db)
                    quoteInteractionIdResults.forEach { pair in
                        fetchedQuoteMap[pair.first] = pair.second
                    }
                    interactionIdsNeedingFetch += Array(fetchedQuoteMap.values)
                    
                    /// Fetch any records needed
                    fetchedInteractions = try Interaction.fetchAll(db, ids: interactionIdsNeedingFetch)
                    
                    /// Determine if we need to fetch any profile data
                    let profileIdsForFetchedInteractions: Set<String> = fetchedInteractions.reduce(into: []) { result, next in
                        result.insert(next.authorId)
                        result.insert(contentsOf: MentionUtilities.allPubkeys(in: (next.body ?? "")))
                    }
                    let missingProfileIds: Set<String> = profileIdsForFetchedInteractions
                        .subtracting(profileCache.keys)
                    
                    if !missingProfileIds.isEmpty {
                        fetchedProfiles = try Profile.fetchAll(db, ids: Array(missingProfileIds))
                    }
                    
                    /// Fetch any link previews needed
                    let linkPreviewLookupInfo: [(url: String, timestamp: Int64)] = fetchedInteractions.compactMap {
                        guard let url: String = $0.linkPreviewUrl else { return nil }
                        
                        return (url, $0.timestampMs)
                    }
                    
                    if !linkPreviewLookupInfo.isEmpty {
                        let urls: [String] = linkPreviewLookupInfo.map(\.url)
                        let minTimestampMs: Int64 = (linkPreviewLookupInfo.map(\.timestamp).min() ?? 0)
                        let maxTimestampMs: Int64 = (linkPreviewLookupInfo.map(\.timestamp).max() ?? Int64.max)
                        let finalMinTimestamp: TimeInterval = (TimeInterval(minTimestampMs / 1000) - LinkPreview.timstampResolution)
                        let finalMaxTimestamp: TimeInterval = (TimeInterval(maxTimestampMs / 1000) + LinkPreview.timstampResolution)
                            
                        fetchedLinkPreviews = try LinkPreview
                            .filter(urls.contains(LinkPreview.Columns.url))
                            .filter(LinkPreview.Columns.timestamp > finalMinTimestamp)
                            .filter(LinkPreview.Columns.timestamp < finalMaxTimestamp)
                            .fetchAll(db)
                        attachmentIdsNeedingFetch += fetchedLinkPreviews.compactMap { $0.attachmentId }
                    }
                    
                    /// Fetch any attachments needed (ensuring we keep the album order)
                    fetchedInteractionAttachments = try InteractionAttachment
                        .filter(interactionIdsNeedingFetch.contains(InteractionAttachment.Columns.interactionId))
                        .order(InteractionAttachment.Columns.albumIndex)
                        .fetchAll(db)
                    attachmentIdsNeedingFetch += fetchedInteractionAttachments.map { $0.attachmentId }
                    
                    if !attachmentIdsNeedingFetch.isEmpty {
                        fetchedAttachments = try Attachment.fetchAll(db, ids: attachmentIdsNeedingFetch)
                    }
                    
                    /// Fetch any reactions (just refetch all of them as handling individual reaction events, especially with "pending"
                    /// reactions in SOGS, will likely result in bugs)
                    interactionIdsNeedingReactionUpdates.insert(contentsOf: Set(interactionIdsNeedingFetch))
                    fetchedReactions = try Reaction
                        .filter(interactionIdsNeedingReactionUpdates.contains(Reaction.Columns.interactionId))
                        .fetchAll(db)
                        .grouped(by: \.interactionId)
                    
                    /// Fetch any thread data needed
                    if threadNeedsRefresh {
                        threadViewModel = try ConversationViewModel.fetchThreadViewModel(
                            db,
                            threadId: threadId,
                            userSessionId: previousState.userSessionId,
                            currentUserSessionIds: currentUserSessionIds,
                            threadWasKickedFromGroup: threadWasKickedFromGroup,
                            threadGroupIsDestroyed: threadGroupIsDestroyed,
                            using: dependencies
                        )
                    }
                }
                
                threadIsTrusted = {
                    switch threadVariant {
                        case .legacyGroup, .community, .group: return true /// Default to `true` for non-contact threads
                        case .contact: return (threadContact?.isTrusted == true)
                    }
                }()
                
                /// Update the caches with the newly fetched values
                quoteMap.merge(fetchedQuoteMap, uniquingKeysWith: { _, new in new })
                fetchedProfiles.forEach { profile in
                    let finalFeatures: SessionPro.Features = {
                        guard dependencies[feature: .sessionProEnabled] else { return .none }
                        
                        return profile.proFeatures
                            .union(dependencies[feature: .proBadgeEverywhere] ? .proBadge : .none)
                    }()
                    
                    profileCache[profile.id] = profile
                }
                fetchedLinkPreviews.forEach { linkPreviewCache[$0.url, default: []].append($0) }
                fetchedAttachments.forEach { attachmentCache[$0.id] = $0 }
                fetchedReactions.forEach { interactionId, reactions in
                    guard !reactions.isEmpty else {
                        reactionCache.removeValue(forKey: interactionId)
                        return
                    }
                    
                    reactionCache[interactionId, default: []] = reactions
                }
                let groupedInteractionAttachments: [Int64: Set<InteractionAttachment>] = fetchedInteractionAttachments
                    .grouped(by: \.interactionId)
                    .mapValues { Set($0) }
                fetchedInteractions.forEach { interaction in
                    guard let id: Int64 = interaction.id else { return }
                    
                    interactionCache[id] = interaction
                    
                    if
                        let attachments: Set<InteractionAttachment> = groupedInteractionAttachments[id],
                        !attachments.isEmpty
                    {
                        attachmentMap[id] = attachments
                    }
                    else {
                        attachmentMap.removeValue(forKey: id)
                    }
                }
                
                /// Remove any deleted values
                deletedInteractionIds.forEach { id in
                    itemCache.removeValue(forKey: id)
                    interactionCache.removeValue(forKey: id)
                    reactionCache.removeValue(forKey: id)
                    quoteMap.removeValue(forKey: id)
                    
                    attachmentMap[id]?.forEach { attachmentCache.removeValue(forKey: $0.attachmentId) }
                    attachmentMap.removeValue(forKey: id)
                }
            } catch {
                let eventList: String = databaseEvents.map { $0.key.rawValue }.joined(separator: ", ")
                Log.critical(.conversation, "Failed to fetch state for events [\(eventList)], due to error: \(error)")
            }
        }
        else if !databaseEvents.isEmpty {
            Log.warn(.conversation, "Ignored \(databaseEvents.count) database event(s) sent while storage was suspended.")
        }
        
        /// If we refreshed the thread data then reaction support may have changed, so update it
        if threadNeedsRefresh {
            switch threadVariant {
                case .legacyGroup: reactionsSupported = false
                case .contact, .group:
                    reactionsSupported = (threadViewModel.threadIsMessageRequest != true)
                    
                case .community:
                    reactionsSupported = await dependencies[singleton: .communityManager].doesOpenGroupSupport(
                        capability: .reactions,
                        on: threadViewModel.openGroupServer
                    )
            }
        }
        
        /// Update the typing indicator state if needed
        groupedOtherEvents?[.typingIndicator]?.forEach { event in
            guard let eventValue: TypingIndicatorEvent = event.value as? TypingIndicatorEvent else { return }
            
            shouldShowTypingIndicator = (eventValue.change == .started)
        }
        
        /// Handle optimistic messages
        groupedOtherEvents?[.updateScreen]?.forEach { event in
            guard let eventValue: ConversationViewModelEvent = event.value as? ConversationViewModelEvent else {
                return
            }
            
            switch eventValue {
                case .sendMessage(let data):
                    optimisticallyInsertedMessages[data.temporaryId] = data
                    
                    if let attachments: [Attachment] = data.attachmentData {
                        attachments.forEach { attachmentCache[$0.id] = $0 }
                        attachmentMap[data.temporaryId] = Set(attachments.enumerated().map { index, attachment in
                            InteractionAttachment(
                                albumIndex: index,
                                interactionId: data.temporaryId,
                                attachmentId: attachment.id
                            )
                        })
                    }
                    
                    if let draft: LinkPreviewDraft = data.linkPreviewDraft {
                        linkPreviewCache[draft.urlString, default: []].append(
                            LinkPreview(
                                url: draft.urlString,
                                title: draft.title,
                                attachmentId: nil,    /// Can't save to db optimistically
                                using: dependencies
                            )
                        )
                    }
                    
                case .failedToStoreMessage(let temporaryId):
                    guard let data: OptimisticMessageData = optimisticallyInsertedMessages[temporaryId] else {
                        break
                    }
                    
                    optimisticallyInsertedMessages[temporaryId] = OptimisticMessageData(
                        temporaryId: temporaryId,
                        interaction: data.interaction.with(
                            state: .failed,
                            mostRecentFailureText: "shareExtensionDatabaseError".localized()
                        ),
                        attachmentData: data.attachmentData,
                        linkPreviewDraft: data.linkPreviewDraft,
                        linkPreviewPreparedAttachment: data.linkPreviewPreparedAttachment,
                        quoteModel: data.quoteModel
                    )
                
                case .resolveOptimisticMessage(let temporaryId, let databaseId):
                    guard interactionCache[databaseId] != nil else {
                        Log.warn(.conversation, "Attempted to resolve an optimistic message but it was missing from the cache")
                        return
                    }
                    
                    optimisticallyInsertedMessages.removeValue(forKey: temporaryId)
                    attachmentMap.removeValue(forKey: temporaryId)
                    itemCache.removeValue(forKey: temporaryId)
            }
        }
        
        /// Generating the `MessageViewModel` requires both the "preview" and "next" messages that will appear on
        /// the screen in order to be generated correctly so we need to iterate over the interactions again - additionally since
        /// modifying interactions could impact this clustering behaviour (or ever other cached content), and we add messages
        /// optimistically, it's simplest to just fully regenerate the entire `itemCache` and rely on diffing to prevent incorrect changes
        let orderedIds: [Int64] = State.orderedIdsIncludingOptimisticMessages(
            loadedPageInfo: loadResult.info,
            optimisticMessages: optimisticallyInsertedMessages,
            interactionCache: interactionCache
        )
        
        orderedIds.enumerated().forEach { index, id in
            let optimisticMessageId: Int64?
            let interaction: Interaction
            let reactionInfo: [MessageViewModel.ReactionInfo]?
            let quotedInteraction: Interaction?
            
            /// Source the interaction data from the appropriate location
            switch id {
                case ..<0:  /// If the `id` is less than `0` then it's an optimistic message
                    guard let data: OptimisticMessageData = optimisticallyInsertedMessages[id] else { return }
                    
                    optimisticMessageId = data.temporaryId
                    interaction = data.interaction
                    reactionInfo = nil  /// Can't react to an optimistic message
                    quotedInteraction = data.quoteModel.map { model -> Interaction? in
                        guard let interactionId: Int64 = model.quotedInteractionId else { return nil }
                        
                        return quoteMap[interactionId].map { interactionCache[$0] }
                    }
                    
                default:
                    guard let targetInteraction: Interaction = interactionCache[id] else { return }
                    
                    optimisticMessageId = nil
                    interaction = targetInteraction
                    reactionInfo = reactionCache[id].map { reactions in
                        reactions.map {
                            MessageViewModel.ReactionInfo(
                                reaction: $0,
                                profile: profileCache[$0.authorId]
                            )
                        }
                    }
                    quotedInteraction = quoteMap[id].map { interactionCache[$0] }
            }
            
            itemCache[id] = MessageViewModel(
                optimisticMessageId: optimisticMessageId,
                threadId: threadId,
                threadVariant: threadVariant,
                threadIsTrusted: threadIsTrusted,
                threadDisappearingConfiguration: threadViewModel.disappearingMessagesConfiguration,
                interaction: interaction,
                reactionInfo: reactionInfo,
                quotedInteraction: quotedInteraction,
                profileCache: profileCache,
                attachmentCache: attachmentCache,
                linkPreviewCache: linkPreviewCache,
                attachmentMap: attachmentMap,
                isSenderModeratorOrAdmin: modAdminCache.contains(interaction.authorId),
                currentUserSessionIds: currentUserSessionIds,
                previousInteraction: State.interaction(
                    at: index + 1,  /// Order is inverted so `previousInteraction` is the next element
                    orderedIds: orderedIds,
                    optimisticMessages: optimisticallyInsertedMessages,
                    interactionCache: interactionCache
                ),
                nextInteraction: State.interaction(
                    at: index - 1,  /// Order is inverted so `nextInteraction` is the previous element
                    orderedIds: orderedIds,
                    optimisticMessages: optimisticallyInsertedMessages,
                    interactionCache: interactionCache
                ),
                isLast: (
                    /// Order is inverted so we need to check the start of the list
                    index == 0 &&
                    !loadResult.info.hasPrevPage
                ),
                isLastOutgoing: (
                    /// Order is inverted so we need to check the start of the list
                    id == orderedIds
                        .prefix(index + 1)  /// Want to include the value for `index` in the result
                        .enumerated()
                        .compactMap { prefixIndex, _ in
                            State.interaction(
                                at: prefixIndex,
                                orderedIds: orderedIds,
                                optimisticMessages: optimisticallyInsertedMessages,
                                interactionCache: interactionCache
                            )
                        }
                        .first(where: { currentUserSessionIds.contains($0.authorId) })?
                        .id
                ),
                using: dependencies
            )
        }
        
        return State(
            viewState: (loadResult.info.totalCount == 0 ? .empty : .loaded),
            threadId: threadId,
            threadVariant: threadVariant,
            userSessionId: previousState.userSessionId,
            currentUserSessionIds: currentUserSessionIds,
            isBlindedContact: SessionId.Prefix.isCommunityBlinded(threadId),
            wasPreviouslyBlindedContact: SessionId.Prefix.isCommunityBlinded(previousState.threadId),
            focusedInteractionInfo: focusedInteractionInfo,
            focusBehaviour: previousState.focusBehaviour,
            initialUnreadInteractionInfo: initialUnreadInteractionInfo,
            loadedPageInfo: loadResult.info,
            profileCache: profileCache,
            linkPreviewCache: linkPreviewCache,
            interactionCache: interactionCache,
            attachmentCache: attachmentCache,
            reactionCache: reactionCache,
            quoteMap: quoteMap,
            attachmentMap: attachmentMap,
            modAdminCache: modAdminCache,
            itemCache: itemCache,
            titleViewModel: ConversationTitleViewModel(
                threadViewModel: threadViewModel,
                using: dependencies
            ),
            threadViewModel: threadViewModel,
            threadContact: threadContact,
            threadIsTrusted: threadIsTrusted,
            legacyGroupsBannerIsVisible: previousState.legacyGroupsBannerIsVisible,
            reactionsSupported: reactionsSupported,
            isUserModeratorOrAdmin: isUserModeratorOrAdmin,
            shouldShowTypingIndicator: shouldShowTypingIndicator,
            optimisticallyInsertedMessages: optimisticallyInsertedMessages
        )
    }
    
    private static func sections(state: State, viewModel: ConversationViewModel) -> [SectionModel] {
        let orderedIds: [Int64] = State.orderedIdsIncludingOptimisticMessages(
            loadedPageInfo: state.loadedPageInfo,
            optimisticMessages: state.optimisticallyInsertedMessages,
            interactionCache: state.interactionCache
        )
        
        /// Messages are fetched in decending order (so the message at index `0` is the most recent message), we then render the
        /// messages in the reverse order (so the most recent appears at the bottom of the screen) so as a result the `loadOlder`
        /// section is based on `hasNextPage` and vice-versa
        return [
            (!state.loadedPageInfo.currentIds.isEmpty && state.loadedPageInfo.hasNextPage ?
                [SectionModel(section: .loadOlder)] :
                []
            ),
            [
                SectionModel(
                    section: .messages,
                    elements: orderedIds
                        .reversed() /// Interactions are loaded from newest to oldest, but we want the newest at the bottom so reverse the result
                        .compactMap { state.itemCache[$0] }
                        .reduce(into: []) { result, next in
                            /// Insert the unread indicator above the first unread message
                            if next.id == state.initialUnreadInteractionInfo?.id {
                                result.append(
                                    MessageViewModel(
                                        cellType: .unreadMarker,
                                        timestampMs: next.timestampMs
                                    )
                                )
                            }
                            
                            /// If we should have a date header above this message then add it
                            if next.shouldShowDateHeader {
                                result.append(
                                    MessageViewModel(
                                        cellType: .dateHeader,
                                        timestampMs: next.timestampMs
                                    )
                                )
                            }
                            
                            /// Since we've added whatever was needed before the message we can now add it to the result
                            result.append(next)
                        }
                        .appending(!state.shouldShowTypingIndicator ? nil :
                            MessageViewModel.typingIndicator
                        )
                )
            ],
            (!state.loadedPageInfo.currentIds.isEmpty && state.loadedPageInfo.hasPrevPage ?
                [SectionModel(section: .loadNewer)] :
                []
            )
        ].flatMap { $0 }
    }
    
    // MARK: - Interaction Data
    
    @MainActor public private(set) var reactionExpandedInteractionIds: Set<Int64> = []
    @MainActor public private(set) var messageExpandedInteractionIds: Set<Int64> = []
    
    // MARK: - Optimistic Message Handling
    
    public func optimisticallyAppendOutgoingMessage(
        text: String?,
        sentTimestampMs: Int64,
        attachments: [PendingAttachment]?,
        linkPreviewDraft: LinkPreviewDraft?,
        quoteModel: QuotedReplyModel?
    ) async throws -> OptimisticMessageData {
        // Generate the optimistic data
        let optimisticMessageId: Int64 = (-Int64.max + sentTimestampMs) /// Unique but avoids collisions with messages
        let currentState: State = await self.state
        let proFeatures: SessionPro.Features = try {
            let userProfileFeatures: SessionPro.Features = .none // TODO: [PRO] Need to add in `proBadge` if enabled
            let result: SessionPro.FeaturesForMessage = dependencies[singleton: .sessionProManager].features(
                for: (text ?? ""),
                features: userProfileFeatures
            )
            
            switch result.status {
                case .success: return result.features
                case .utfDecodingError:
                    Log.warn(.messageSender, "Failed to extract features for message, falling back to manual handling")
                    guard (text ?? "").utf16.count > SessionPro.CharacterLimit else {
                        return userProfileFeatures
                    }
                    
                    return userProfileFeatures.union(.largerCharacterLimit)
                    
                case .exceedsCharacterLimit: throw MessageError.messageTooLarge
            }
        }()
        let interaction: Interaction = Interaction(
            threadId: currentState.threadId,
            threadVariant: currentState.threadVariant,
            authorId: currentState.currentUserSessionIds
                .first { $0.hasPrefix(SessionId.Prefix.blinded15.rawValue) }
                .defaulting(to: currentState.userSessionId.hexString),
            variant: .standardOutgoing,
            body: text,
            timestampMs: sentTimestampMs,
            hasMention: Interaction.isUserMentioned(
                publicKeysToCheck: currentState.currentUserSessionIds,
                body: text
            ),
            expiresInSeconds: currentState.threadViewModel.disappearingMessagesConfiguration?.expiresInSeconds(),
            linkPreviewUrl: linkPreviewDraft?.urlString,
            proFeatures: proFeatures,
            using: dependencies
        )
        var optimisticAttachments: [Attachment]?
        var linkPreviewPreparedAttachment: PreparedAttachment?
        
        if let pendingAttachments: [PendingAttachment] = attachments {
            optimisticAttachments = try? await AttachmentUploadJob.preparePriorToUpload(
                attachments: pendingAttachments,
                using: dependencies
            )
        }
        
        if let draft: LinkPreviewDraft = linkPreviewDraft {
            linkPreviewPreparedAttachment = try? await LinkPreview.prepareAttachmentIfPossible(
                urlString: draft.urlString,
                imageSource: draft.imageSource,
                using: dependencies
            )
        }
        
        let optimisticData: OptimisticMessageData = OptimisticMessageData(
            temporaryId: optimisticMessageId,
            interaction: interaction,
            attachmentData: optimisticAttachments,
            linkPreviewDraft: linkPreviewDraft,
            linkPreviewPreparedAttachment: linkPreviewPreparedAttachment,
            quoteModel: quoteModel
        )
        
        await dependencies.notify(
            key: .updateScreen(ConversationViewModel.self),
            value: ConversationViewModelEvent.sendMessage(data: optimisticData)
        )
        
        return optimisticData
    }
    
    public func failedToStoreOptimisticOutgoingMessage(id: Int64, error: Error) async {
        await dependencies.notify(
            key: .updateScreen(ConversationViewModel.self),
            value: ConversationViewModelEvent.failedToStoreMessage(temporaryId: id)
        )
    }
    
    /// Record an association between an `optimisticMessageId` and a specific `interactionId`
    public func associate(_ db: ObservingDatabase, optimisticMessageId: Int64, to interactionId: Int64?) {
        guard let interactionId: Int64 = interactionId else { return }
        
        db.addEvent(
            ConversationViewModelEvent.resolveOptimisticMessage(
                temporaryId: optimisticMessageId,
                databaseId: interactionId
            ),
            forKey: .updateScreen(ConversationViewModel.self)
        )
    }
    
    // MARK: - Mentions
    
    public func mentions(for query: String = "") async -> [MentionInfo] {
        let userSessionId: SessionId = dependencies[cache: .general].sessionId
        let threadData: SessionThreadViewModel = await self.state.threadViewModel
        
        return ((try? await dependencies[singleton: .storage].readAsync { db -> [MentionInfo] in
            let pattern: FTS5Pattern? = try? SessionThreadViewModel.pattern(db, searchTerm: query, forTable: Profile.self)
            let capabilities: Set<Capability.Variant> = (threadData.threadVariant != .community ?
                nil :
                try? Capability
                    .select(.variant)
                    .filter(Capability.Columns.openGroupServer == threadData.openGroupServer)
                    .asRequest(of: Capability.Variant.self)
                    .fetchSet(db)
            )
            .defaulting(to: [])
            let targetPrefixes: [SessionId.Prefix] = (capabilities.contains(.blind) ?
                [.blinded15, .blinded25] :
                [.standard]
            )
            
            return (try? MentionInfo
                .query(
                    threadId: threadData.threadId,
                    threadVariant: threadData.threadVariant,
                    targetPrefixes: targetPrefixes,
                    currentUserSessionIds: (
                        threadData.currentUserSessionIds ??
                        [userSessionId.hexString]
                    ),
                    pattern: pattern
                )?
                .fetchAll(db))
                .defaulting(to: [])
        }) ?? [])
    }

    // MARK: - Functions
    
    @MainActor func loadPageBefore() {
        /// We render the messages in the reverse order from the way we fetch them (see `sections`) so as a result when loading
        /// the "page before" we _actually_ need to load the `nextPage`
        dependencies.notifyAsync(
            key: .loadPage(ConversationViewModel.self),
            value: LoadPageEvent.nextPage(lastIndex: state.loadedPageInfo.lastIndex)
        )
    }
    
    @MainActor public func loadPageAfter() {
        /// We render the messages in the reverse order from the way we fetch them (see `sections`) so as a result when loading
        /// the "page after" we _actually_ need to load the `previousPage`
        dependencies.notifyAsync(
            key: .loadPage(ConversationViewModel.self),
            value: LoadPageEvent.previousPage(firstIndex: state.loadedPageInfo.firstIndex)
        )
    }
    
    @MainActor public func jumpToPage(for id: Int64, padding: Int) {
        dependencies.notifyAsync(
            key: .loadPage(ConversationViewModel.self),
            value: LoadPageEvent.jumpTo(id: id, padding: padding)
        )
    }
    
    @MainActor public func updateDraft(to draft: String) {
        /// Kick off an async process to save the `draft` message to the conversation (don't want to block the UI while doing this,
        /// worst case the `draft` just won't be saved)
        Task.detached(priority: .userInitiated) { [threadId = state.threadId, dependencies] in
            let existingDraft: String? = try? await dependencies[singleton: .storage].readAsync { db in
                try SessionThread
                    .select(.messageDraft)
                    .filter(id: threadId)
                    .asRequest(of: String.self)
                    .fetchOne(db)
            }
            
            guard draft != existingDraft else { return }
            
            _ = try? await dependencies[singleton: .storage].writeAsync { db in
                try SessionThread
                    .filter(id: threadId)
                    .updateAll(db, SessionThread.Columns.messageDraft.set(to: draft))
            }
        }
    }
    
    public func markThreadAsRead() async {
        let threadViewModel: SessionThreadViewModel = await state.threadViewModel
        try? await threadViewModel.markAsRead(target: .thread, using: dependencies)
    }
    
    /// This method marks a thread as read and depending on the target may also update the interactions within a thread as read
    public func markAsReadIfNeeded(
        interactionInfo: Interaction.TimestampInfo?,
        visibleViewModelRetriever: ((@MainActor () -> [MessageViewModel]?))?
    ) async {
        /// Since this method now gets triggered when scrolling we want to try to optimise it and avoid busying the database
        /// write queue when it isn't needed, in order to do this we:
        /// - Only retrieve the visible message view models if the state suggests there is something that can be marked as read
        /// - Throttle the updates to 100ms (quick enough that users shouldn't notice, but will help the DB when the user flings the list)
        /// - Only mark interactions as read if they have newer `timestampMs` or `id` values (ie. were sent later or were more-recent
        /// entries in the database), **Note:** Old messages will be marked as read upon insertion so shouldn't be an issue
        ///
        /// The `ThreadViewModel.markAsRead` method also tries to avoid marking as read if a conversation is already fully read
        let needsToMarkAsRead: Bool = await MainActor.run {
            guard
                (state.threadViewModel.threadUnreadCount ?? 0) > 0 ||
                state.threadViewModel.threadWasMarkedUnread == true
            else { return false }
            
            /// We want to mark messages as read while we scroll, so grab the "newest" visible message and mark everything older as read
            let targetInfo: Interaction.TimestampInfo
            
            if let newestCellViewModel: MessageViewModel = visibleViewModelRetriever?()?.last {
                targetInfo = Interaction.TimestampInfo(
                    id: newestCellViewModel.id,
                    timestampMs: newestCellViewModel.timestampMs
                )
            }
            else if let interactionInfo: Interaction.TimestampInfo = interactionInfo {
                /// If we weren't able to get any visible cells for some reason then we should fall back to marking the provided
                /// `interactionInfo` as read just in case
                targetInfo = interactionInfo
            }
            else {
                /// If we can't get any interaction info then there is nothing to mark as read
                return false
            }
            
            /// If we previously marked something as read and it's "newer" than the target info then it should already be read so no
            /// need to do anything
            if
                let oldValue: Interaction.TimestampInfo = lastMarkAsReadInfo, (
                    targetInfo.id < oldValue.id ||
                    targetInfo.timestampMs < oldValue.timestampMs
                )
            {
                return false
            }
            
            /// If we already have pending info to mark as read then no need to trigger another update
            if let pendingValue: Interaction.TimestampInfo = pendingMarkAsReadInfo {
                /// If the target info is "newer" than the pending info then we sould update the pending info so the "newer" value ends
                /// up getting marked as read
                if targetInfo.id > pendingValue.id || targetInfo.timestampMs > pendingValue.timestampMs {
                    pendingMarkAsReadInfo = targetInfo
                }
                
                return false
            }
            
            /// If we got here then we do need to mark the target info as read
            pendingMarkAsReadInfo = targetInfo
            return true
        }
        
        /// Only continue if we need to
        guard needsToMarkAsRead else { return }
        
        do { try await Task.sleep(for: .milliseconds(100)) }
        catch { return }
        
        /// Get the latest values
        let (threadViewModel, pendingInfo): (SessionThreadViewModel, Interaction.TimestampInfo?) = await MainActor.run {
            (
                state.threadViewModel,
                pendingMarkAsReadInfo
            )
        }
        
        guard let info: Interaction.TimestampInfo = pendingInfo else { return }
        
        try? await threadViewModel.markAsRead(
            target: .threadAndInteractions(interactionsBeforeInclusive: info.id),
            using: dependencies
        )
        
        /// Clear the pending info so we can mark something else as read
        await MainActor.run {
            pendingMarkAsReadInfo = nil
        }
    }
    
    @MainActor public func trustContact() {
        guard state.threadVariant == .contact else { return }
        
        Task.detached(priority: .userInitiated) { [threadId = state.threadId, dependencies] in
            try? await dependencies[singleton: .storage].writeAsync { db in
                try Contact
                    .filter(id: threadId)
                    .updateAll(db, Contact.Columns.isTrusted.set(to: true))
                db.addContactEvent(id: threadId, change: .isTrusted(true))
                
                // Start downloading any pending attachments for this contact (UI will automatically be
                // updated due to the database observation)
                try Attachment
                    .stateInfo(authorId: threadId, state: .pendingDownload)
                    .fetchAll(db)
                    .forEach { attachmentDownloadInfo in
                        dependencies[singleton: .jobRunner].add(
                            db,
                            job: Job(
                                variant: .attachmentDownload,
                                threadId: threadId,
                                interactionId: attachmentDownloadInfo.interactionId,
                                details: AttachmentDownloadJob.Details(
                                    attachmentId: attachmentDownloadInfo.attachmentId
                                )
                            ),
                            canStartJob: true
                        )
                    }
            }
        }
    }
    
    @MainActor public func unblockContact() {
        guard state.threadVariant == .contact else { return }
        
        Task.detached(priority: .userInitiated) { [threadId = state.threadId, dependencies] in
            try? await dependencies[singleton: .storage].writeAsync { db in
                try Contact
                    .filter(id: threadId)
                    .updateAllAndConfig(
                        db,
                        Contact.Columns.isBlocked.set(to: false),
                        using: dependencies
                    )
                db.addContactEvent(id: threadId, change: .isBlocked(false))
            }
        }
    }
    
    @MainActor public func expandReactions(for interactionId: Int64) {
        reactionExpandedInteractionIds.insert(interactionId)
    }
    
    @MainActor public func collapseReactions(for interactionId: Int64) {
        reactionExpandedInteractionIds.remove(interactionId)
    }
    
    @MainActor public func expandMessage(for interactionId: Int64) {
        messageExpandedInteractionIds.insert(interactionId)
    }
    
    @MainActor public func deletionActions(for cellViewModels: [MessageViewModel]) -> MessageViewModel.DeletionBehaviours? {
        return MessageViewModel.DeletionBehaviours.deletionActions(
            for: cellViewModels,
            threadData: state.threadViewModel,
            isUserModeratorOrAdmin: state.isUserModeratorOrAdmin,
            using: dependencies
        )
    }
    
    // MARK: - Audio Playback
    
    public struct PlaybackInfo {
        let state: AudioPlaybackState
        let progress: TimeInterval
        let playbackRate: Double
        let oldPlaybackRate: Double
        let updateCallback: (PlaybackInfo?, Error?) -> ()
        
        public func with(
            state: AudioPlaybackState? = nil,
            progress: TimeInterval? = nil,
            playbackRate: Double? = nil,
            updateCallback: ((PlaybackInfo?, Error?) -> ())? = nil
        ) -> PlaybackInfo {
            return PlaybackInfo(
                state: (state ?? self.state),
                progress: (progress ?? self.progress),
                playbackRate: (playbackRate ?? self.playbackRate),
                oldPlaybackRate: self.playbackRate,
                updateCallback: (updateCallback ?? self.updateCallback)
            )
        }
    }
    
    @MainActor private var audioPlayer: OWSAudioPlayer? = nil
    @MainActor private var currentPlayingInteraction: Int64? = nil
    @MainActor private var playbackInfo: [Int64: PlaybackInfo] = [:]
    
    @MainActor public func playbackInfo(for viewModel: MessageViewModel, updateCallback: ((PlaybackInfo?, Error?) -> ())? = nil) -> PlaybackInfo? {
        // Use the existing info if it already exists (update it's callback if provided as that means
        // the cell was reloaded)
        if let currentPlaybackInfo: PlaybackInfo = playbackInfo[viewModel.id] {
            let updatedPlaybackInfo: PlaybackInfo = currentPlaybackInfo
                .with(updateCallback: updateCallback)
            playbackInfo[viewModel.id] = updatedPlaybackInfo
            return updatedPlaybackInfo
        }
        
        // Validate the item is a valid audio item
        guard
            let updateCallback: ((PlaybackInfo?, Error?) -> ()) = updateCallback,
            let attachment: Attachment = viewModel.attachments.first,
            attachment.isAudio,
            attachment.isValid,
            let path: String = try? dependencies[singleton: .attachmentManager].path(for: attachment.downloadUrl),
            dependencies[singleton: .fileManager].fileExists(atPath: path)
        else { return nil }
        
        // Create the info with the update callback
        let newPlaybackInfo: PlaybackInfo = PlaybackInfo(
            state: .stopped,
            progress: 0,
            playbackRate: 1,
            oldPlaybackRate: 1,
            updateCallback: updateCallback
        )
        
        // Cache the info
        playbackInfo[viewModel.id] = newPlaybackInfo
        
        return newPlaybackInfo
    }
    
    @MainActor public func playOrPauseAudio(for viewModel: MessageViewModel) {
        guard
            let attachment: Attachment = viewModel.attachments.first,
            let filePath: String = try? dependencies[singleton: .attachmentManager].path(for: attachment.downloadUrl),
            dependencies[singleton: .fileManager].fileExists(atPath: filePath)
        else { return }
        
        // If the user interacted with the currently playing item
        guard currentPlayingInteraction != viewModel.id else {
            let currentPlaybackInfo: PlaybackInfo? = playbackInfo[viewModel.id]
            let updatedPlaybackInfo: PlaybackInfo? = currentPlaybackInfo?
                .with(
                    state: (currentPlaybackInfo?.state != .playing ? .playing : .paused),
                    playbackRate: 1
                )
            
            audioPlayer?.playbackRate = 1
            
            switch currentPlaybackInfo?.state {
                case .playing: audioPlayer?.pause()
                default: audioPlayer?.play()
            }
            
            // Update the state and then update the UI with the updated state
            playbackInfo[viewModel.id] = updatedPlaybackInfo
            updatedPlaybackInfo?.updateCallback(updatedPlaybackInfo, nil)
            return
        }
        
        // First stop any existing audio
        audioPlayer?.stop()
        
        // Then setup the state for the new audio
        currentPlayingInteraction = viewModel.id
        
        let currentPlaybackTime: TimeInterval? = playbackInfo[viewModel.id]?.progress
        
        // Note: We clear the delegate and explicitly set to nil here as when the OWSAudioPlayer
        // gets deallocated it triggers state changes which cause UI bugs when auto-playing
        audioPlayer?.delegate = nil
        audioPlayer = nil
        
        let newAudioPlayer: OWSAudioPlayer = OWSAudioPlayer(
            mediaUrl: URL(fileURLWithPath: filePath),
            audioBehavior: .audioMessagePlayback,
            delegate: self,
            using: dependencies
        )
        newAudioPlayer.play()
        newAudioPlayer.currentTime = (currentPlaybackTime ?? 0)
        audioPlayer = newAudioPlayer
    }
    
    @MainActor public func speedUpAudio(for viewModel: MessageViewModel) {
        // If we aren't playing the specified item then just start playing it
        guard viewModel.id == currentPlayingInteraction else {
            playOrPauseAudio(for: viewModel)
            return
        }
        
        let updatedPlaybackInfo: PlaybackInfo? = playbackInfo[viewModel.id]?
            .with(playbackRate: 1.5)
        
        // Speed up the audio player
        audioPlayer?.playbackRate = 1.5
        playbackInfo[viewModel.id] = updatedPlaybackInfo
        updatedPlaybackInfo?.updateCallback(updatedPlaybackInfo, nil)
    }
    
    @MainActor public func stopAudioIfNeeded(for viewModel: MessageViewModel) {
        guard viewModel.id == currentPlayingInteraction else { return }
        
        stopAudio()
    }
    
    @MainActor public func stopAudio() {
        audioPlayer?.stop()
        
        currentPlayingInteraction = nil
        // Note: We clear the delegate and explicitly set to nil here as when the OWSAudioPlayer
        // gets deallocated it triggers state changes which cause UI bugs when auto-playing
        audioPlayer?.delegate = nil
        audioPlayer = nil
    }
    
    // MARK: - OWSAudioPlayerDelegate
    
    @MainActor public var audioPlaybackState: AudioPlaybackState {
        get {
            guard let interactionId: Int64 = currentPlayingInteraction else { return .stopped }
            
            return (playbackInfo[interactionId]?.state ?? .stopped)
        }
        set {
            guard let interactionId: Int64 = currentPlayingInteraction else { return }
            
            let updatedPlaybackInfo: PlaybackInfo? = playbackInfo[interactionId]?
                .with(state: newValue)
            
            playbackInfo[interactionId] = updatedPlaybackInfo
            updatedPlaybackInfo?.updateCallback(updatedPlaybackInfo, nil)
        }
    }
    
    @MainActor public func setAudioProgress(_ progress: CGFloat, duration: CGFloat) {
        guard let interactionId: Int64 = currentPlayingInteraction else { return }
        
        let updatedPlaybackInfo: PlaybackInfo? = playbackInfo[interactionId]?
            .with(progress: TimeInterval(progress))
        
        playbackInfo[interactionId] = updatedPlaybackInfo
        updatedPlaybackInfo?.updateCallback(updatedPlaybackInfo, nil)
    }
    
    @MainActor public func audioPlayerDidFinishPlaying(_ player: OWSAudioPlayer, successfully: Bool) {
        guard let interactionId: Int64 = currentPlayingInteraction else { return }
        guard successfully else { return }
        
        let updatedPlaybackInfo: PlaybackInfo? = playbackInfo[interactionId]?
            .with(
                state: .stopped,
                progress: 0,
                playbackRate: 1
            )
        
        // Safe the changes and send one final update to the UI
        playbackInfo[interactionId] = updatedPlaybackInfo
        updatedPlaybackInfo?.updateCallback(updatedPlaybackInfo, nil)
        
        // Clear out the currently playing record
        stopAudio()
        
        /// If the next interaction is another voice message then autoplay it
        ///
        /// **Note:** Order is inverted so the next item has an earlier index
        guard
            let currentIndex: Int = state.loadedPageInfo.currentIds
                .firstIndex(where: { $0 == interactionId }),
            currentIndex > 0,
            let nextItem: MessageViewModel = state.itemCache[state.loadedPageInfo.currentIds[currentIndex - 1]],
            nextItem.cellType == .voiceMessage,
            dependencies.mutate(cache: .libSession, { $0.get(.shouldAutoPlayConsecutiveAudioMessages) })
        else { return }
        
        playOrPauseAudio(for: nextItem)
    }
    
    @MainActor public func showInvalidAudioFileAlert() {
        guard let interactionId: Int64 = currentPlayingInteraction else { return }
        
        let updatedPlaybackInfo: PlaybackInfo? = playbackInfo[interactionId]?
            .with(
                state: .stopped,
                progress: 0,
                playbackRate: 1
            )
        
        stopAudio()
        playbackInfo[interactionId] = updatedPlaybackInfo
        updatedPlaybackInfo?.updateCallback(updatedPlaybackInfo, AttachmentError.invalidData)
    }
}

// MARK: - Convenience

private enum EventDataRequirement {
    case databaseQuery
    case other
    case bothDatabaseQueryAndOther
}

private extension ObservedEvent {
    var dataRequirement: EventDataRequirement {
        // FIXME: Should be able to optimise this further
        switch (key, key.generic) {
            case (_, .loadPage): return .databaseQuery
            case (.anyMessageCreatedInAnyConversation, _): return .databaseQuery
            case (.anyContactBlockedStatusChanged, _): return .databaseQuery
            case (_, .typingIndicator): return .databaseQuery
            case (_, .conversationUpdated), (_, .conversationDeleted): return .databaseQuery
            case (_, .messageCreated), (_, .messageUpdated), (_, .messageDeleted): return .databaseQuery
            case (_, .attachmentCreated), (_, .attachmentUpdated), (_, .attachmentDeleted): return .databaseQuery
            case (_, .reactionsChanged): return .databaseQuery
            case (_, .communityUpdated): return .bothDatabaseQueryAndOther
            case (_, .contact): return .bothDatabaseQueryAndOther
            case (_, .profile): return .bothDatabaseQueryAndOther
            default: return .other
        }
    }
}

private extension ConversationTitleViewModel {
    init(threadViewModel: SessionThreadViewModel, using dependencies: Dependencies) {
        self.threadVariant = threadViewModel.threadVariant
        self.displayName = threadViewModel.displayName
        self.isNoteToSelf = threadViewModel.threadIsNoteToSelf
        self.isMessageRequest = (threadViewModel.threadIsMessageRequest == true)
        self.isSessionPro = dependencies[singleton: .sessionProManager].currentUserIsCurrentlyPro
        self.isMuted = (dependencies.dateNow.timeIntervalSince1970 <= (threadViewModel.threadMutedUntilTimestamp ?? 0))
        self.onlyNotifyForMentions = (threadViewModel.threadOnlyNotifyForMentions == true)
        self.userCount = threadViewModel.userCount
        self.disappearingMessagesConfig = threadViewModel.disappearingMessagesConfiguration
    }
}

// MARK: - Convenience

public extension ConversationViewModel {
    static func fetchThreadViewModel(
        _ db: ObservingDatabase,
        threadId: String,
        userSessionId: SessionId,
        currentUserSessionIds: Set<String>,
        threadWasKickedFromGroup: Bool,
        threadGroupIsDestroyed: Bool,
        using dependencies: Dependencies
    ) throws -> SessionThreadViewModel {
        let threadData: SessionThreadViewModel = try SessionThreadViewModel
            .conversationQuery(
                threadId: threadId,
                userSessionId: userSessionId
            )
            .fetchOne(db) ?? { throw StorageError.objectNotFound }()
        let threadRecentReactionEmoji: [String]? = try Emoji.getRecent(db, withDefaultEmoji: true)
        var threadOpenGroupCapabilities: Set<Capability.Variant>?
        
        if threadData.threadVariant == .community {
            threadOpenGroupCapabilities = try Capability
                .select(.variant)
                .filter(Capability.Columns.openGroupServer == threadData.openGroupServer?.lowercased())
                .filter(Capability.Columns.isMissing == false)
                .asRequest(of: Capability.Variant.self)
                .fetchSet(db)
        }
        
        return threadData.populatingPostQueryData(
            recentReactionEmoji: threadRecentReactionEmoji,
            openGroupCapabilities: threadOpenGroupCapabilities,
            currentUserSessionIds: currentUserSessionIds,
            wasKickedFromGroup: threadWasKickedFromGroup,
            groupIsDestroyed: threadGroupIsDestroyed,
            threadCanWrite: threadData.determineInitialCanWriteFlag(using: dependencies),
            threadCanUpload: threadData.determineInitialCanUploadFlag(using: dependencies)
        )
    }
}

private extension SessionId.Prefix {
    static func isCommunityBlinded(_ id: String?) -> Bool {
        switch try? SessionId.Prefix(from: id) {
            case .blinded15, .blinded25: return true
            case .standard, .unblinded, .group, .versionBlinded07, .none: return false
        }
    }
}
