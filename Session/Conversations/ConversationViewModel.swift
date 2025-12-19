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
        let linkPreviewViewModel: LinkPreviewViewModel?
        let linkPreviewPreparedAttachment: PreparedAttachment?
        let quoteViewModel: QuoteViewModel?
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
    
    // MARK: - Initialization
    
    @MainActor init(
        threadInfo: ConversationInfoViewModel,
        focusedInteractionInfo: Interaction.TimestampInfo? = nil,
        currentUserMentionImage: UIImage,
        using dependencies: Dependencies
    ) {
        self.dependencies = dependencies
        self.state = State.initialState(
            threadInfo: threadInfo,
            focusedInteractionInfo: focusedInteractionInfo,
            currentUserMentionImage: currentUserMentionImage,
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
        let threadInfo: ConversationInfoViewModel
        let authMethod: EquatableAuthenticationMethod
        let currentUserMentionImage: UIImage
        let isBlindedContact: Bool
        let wasPreviouslyBlindedContact: Bool
        
        /// Used to determine where the paged data should start loading from, and which message should be focused on initial load
        let focusedInteractionInfo: Interaction.TimestampInfo?
        let focusBehaviour: FocusBehaviour
        let initialUnreadInteractionInfo: Interaction.TimestampInfo?
        
        let loadedPageInfo: PagedData.LoadedInfo<MessageViewModel.ID>
        let dataCache: ConversationDataCache
        let itemCache: [MessageViewModel.ID: MessageViewModel]
        
        let titleViewModel: ConversationTitleViewModel
        let legacyGroupsBannerIsVisible: Bool
        let reactionsSupported: Bool
        let recentReactionEmoji: [String]
        let isUserModeratorOrAdmin: Bool
        let shouldShowTypingIndicator: Bool
        
        let optimisticallyInsertedMessages: [Int64: OptimisticMessageData]
        
        // Convenience
        
        var threadId: String { threadInfo.id }
        var threadVariant: SessionThread.Variant { threadInfo.variant }
        var userSessionId: SessionId { threadInfo.userSessionId }
        
        var emptyStateText: String {
            let blocksCommunityMessageRequests: Bool = (threadInfo.profile?.blocksCommunityMessageRequests == true)
            
            switch (threadInfo.isNoteToSelf, threadInfo.canWrite, blocksCommunityMessageRequests, threadInfo.groupInfo?.wasKicked, threadInfo.groupInfo?.isDestroyed) {
                case (true, _, _, _, _): return "noteToSelfEmpty".localized()
                case (_, false, true, _, _):
                    return "messageRequestsTurnedOff"
                        .put(key: "name", value: threadInfo.displayName.deformatted())
                        .localized()
                
                case (_, _, _, _, true):
                    return "groupDeletedMemberDescription"
                        .put(key: "group_name", value: threadInfo.displayName.deformatted())
                        .localized()
                    
                case (_, _, _, true, _):
                    return "groupRemovedYou"
                        .put(key: "group_name", value: threadInfo.displayName.deformatted())
                        .localized()
                    
                case (_, false, false, _, _):
                    return "conversationsEmpty"
                        .put(key: "conversation_name", value: threadInfo.displayName.deformatted())
                        .localized()
                
                default:
                    return "groupNoMessages"
                        .put(key: "group_name", value: threadInfo.displayName.deformatted())
                        .localized()
            }
        }
        
        var legacyGroupsBannerMessage: ThemedAttributedString {
            let localizationKey: String
            
            switch threadInfo.groupInfo?.currentUserRole == .admin {
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
        
        public var messageInputState: InputView.InputState {
            guard !threadInfo.isNoteToSelf else { return InputView.InputState(inputs: .all) }
            guard !threadInfo.isBlocked else {
                return InputView.InputState(
                    inputs: .disabled,
                    message: "blockBlockedDescription".localized(),
                    messageAccessibility: Accessibility(
                        identifier: "Blocked banner"
                    )
                )
            }
            
            // TODO: [BUGFIXING] Need copy for these cases
            guard threadInfo.canWrite else {
                switch threadInfo.variant {
                    case .contact:
                        return InputView.InputState(
                            inputs: .disabled,
                            message: "You cannot send messages to this user." // TODO: [BUGFIXING] blocks community message requests or generic
                        )
                        
                    case .group:
                        return InputView.InputState(
                            inputs: .disabled,
                            message: "You cannot send messages to this group."
                        )
                        
                    case .legacyGroup:
                        return InputView.InputState(
                            inputs: .disabled,
                            message: "This group is read-only."
                        )
                        
                    case .community:
                        return InputView.InputState(
                            inputs: .disabled,
                            message: "permissionsWriteCommunity".localized()
                        )
                }
            }
            
            /// Attachments shouldn't be allowed for message requests or if uploads are disabled
            let finalInputs: InputView.Input
            
            switch (threadInfo.requiresApproval, threadInfo.isMessageRequest, threadInfo.canUpload) {
                case (false, false, true): finalInputs = .all
                default: finalInputs = [.text, .attachmentsDisabled, .voiceMessagesDisabled]
            }
            
            return InputView.InputState(
                inputs: finalInputs
            )
        }
        
        @MainActor public func sections(viewModel: ConversationViewModel) -> [SectionModel] {
            ConversationViewModel.sections(state: self, viewModel: viewModel)
        }
        
        public var observedKeys: Set<ObservableKey> {
            var result: Set<ObservableKey> = [
                .appLifecycle(.willEnterForeground),
                .databaseLifecycle(.resumed),
                .loadPage(ConversationViewModel.self),
                .updateScreen(ConversationViewModel.self),
                .conversationUpdated(threadInfo.id),
                .conversationDeleted(threadInfo.id),
                .profile(threadInfo.userSessionId.hexString),
                .typingIndicator(threadInfo.id),
                .messageCreated(threadId: threadInfo.id),
                .recentReactionsUpdated
            ]
            
            if SessionId.Prefix.isCommunityBlinded(threadInfo.id) {
                result.insert(.anyContactUnblinded)
            }
            
            result.insert(contentsOf: threadInfo.observedKeys)
            result.insert(contentsOf: Set(itemCache.values.flatMap { $0.observedKeys }))
            
            return result
        }
        
        static func initialState(
            threadInfo: ConversationInfoViewModel,
            focusedInteractionInfo: Interaction.TimestampInfo?,
            currentUserMentionImage: UIImage,
            using dependencies: Dependencies
        ) -> State {
            let dataCache: ConversationDataCache = ConversationDataCache(
                userSessionId: dependencies[cache: .general].sessionId,
                context: ConversationDataCache.Context(
                    source: .messageList(threadId: threadInfo.id),
                    requireFullRefresh: false,
                    requireAuthMethodFetch: false,
                    requiresMessageRequestCountUpdate: false,
                    requiresInitialUnreadInteractionInfo: false,
                    requireRecentReactionEmojiUpdate: false
                )
            )
            
            return State(
                viewState: .loading,
                threadInfo: threadInfo,
                authMethod: EquatableAuthenticationMethod(value: Authentication.invalid),
                currentUserMentionImage: currentUserMentionImage,
                isBlindedContact: SessionId.Prefix.isCommunityBlinded(threadInfo.id),
                wasPreviouslyBlindedContact: SessionId.Prefix.isCommunityBlinded(threadInfo.id),
                focusedInteractionInfo: focusedInteractionInfo,
                focusBehaviour: (focusedInteractionInfo == nil ? .none : .highlight),
                initialUnreadInteractionInfo: nil,
                loadedPageInfo: PagedData.LoadedInfo(
                    record: Interaction.self,
                    pageSize: ConversationViewModel.pageSize,
                    requiredJoinSQL: nil,
                    filterSQL: MessageViewModel.interactionFilterSQL(threadId: threadInfo.id),
                    groupSQL: nil,
                    orderSQL: MessageViewModel.interactionOrderSQL
                ),
                dataCache: dataCache,
                itemCache: [:],
                titleViewModel: ConversationTitleViewModel(
                    threadInfo: threadInfo,
                    dataCache: dataCache,
                    using: dependencies
                ),
                legacyGroupsBannerIsVisible: (threadInfo.variant == .legacyGroup),
                reactionsSupported: (
                    threadInfo.variant != .legacyGroup &&
                    threadInfo.isMessageRequest != true
                ),
                recentReactionEmoji: [],
                isUserModeratorOrAdmin: false,
                shouldShowTypingIndicator: false,
                optimisticallyInsertedMessages: [:]
            )
        }
        
        fileprivate static func orderedIdsIncludingOptimisticMessages(
            loadedPageInfo: PagedData.LoadedInfo<MessageViewModel.ID>,
            optimisticMessages: [Int64: OptimisticMessageData],
            dataCache: ConversationDataCache
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
                let nextPaged: Interaction? = remainingPagedIds.first.map { dataCache.interaction(for: $0) }
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
            dataCache: ConversationDataCache
        ) -> Interaction? {
            guard index >= 0, index < orderedIds.count else { return nil }
            guard orderedIds[index] >= 0 else {
                /// If the `id` is less than `0` then it's an optimistic message
                return optimisticMessages[orderedIds[index]]?.interaction
            }
            
            return dataCache.interaction(for: orderedIds[index])
        }
    }
    
    @Sendable private static func queryState(
        previousState: State,
        events: [ObservedEvent],
        isInitialQuery: Bool,
        using dependencies: Dependencies
    ) async -> State {
        var threadId: String = previousState.threadInfo.id
        var threadInfo: ConversationInfoViewModel = previousState.threadInfo
        var authMethod: EquatableAuthenticationMethod = previousState.authMethod
        var focusedInteractionInfo: Interaction.TimestampInfo? = previousState.focusedInteractionInfo
        var initialUnreadInteractionInfo: Interaction.TimestampInfo? = previousState.initialUnreadInteractionInfo
        var loadResult: PagedData.LoadResult = previousState.loadedPageInfo.asResult
        var dataCache: ConversationDataCache = previousState.dataCache
        var itemCache: [MessageViewModel.ID: MessageViewModel] = previousState.itemCache
        var reactionsSupported: Bool = previousState.reactionsSupported
        var recentReactionEmoji: [String] = previousState.recentReactionEmoji
        var isUserModeratorOrAdmin: Bool = previousState.isUserModeratorOrAdmin
        var shouldShowTypingIndicator: Bool = false
        var optimisticallyInsertedMessages: [Int64: OptimisticMessageData] = previousState.optimisticallyInsertedMessages
        
        /// Store a local copy of the events so we can manipulate it based on the state changes
        var eventsToProcess: [ObservedEvent] = events
        var shouldFetchInitialUnreadInteractionInfo: Bool = false
        var shouldFetchInitialRecentReactions: Bool = false
        
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
            switch threadInfo.variant {
                case .legacyGroup:
                    reactionsSupported = false
                    isUserModeratorOrAdmin = (threadInfo.groupInfo?.currentUserRole == .admin)
                
                case .contact:
                    reactionsSupported = !threadInfo.isMessageRequest
                    shouldShowTypingIndicator = await dependencies[singleton: .typingIndicators]
                        .isRecipientTyping(threadId: threadInfo.id)
                    
                case .group:
                    reactionsSupported = !threadInfo.isMessageRequest
                    isUserModeratorOrAdmin = (threadInfo.groupInfo?.currentUserRole == .admin)
                
                case .community:
                    reactionsSupported = await dependencies[singleton: .communityManager].doesOpenGroupSupport(
                        capability: .reactions,
                        on: threadInfo.communityInfo?.server
                    )
            }
            
            /// Determine whether we need to fetch the initial unread interaction info
            shouldFetchInitialUnreadInteractionInfo = (initialUnreadInteractionInfo == nil)
            
            /// We need to fetch the recent reactions if they are supported
            shouldFetchInitialRecentReactions = reactionsSupported
            
            /// Check if the typing indicator should be visible
            shouldShowTypingIndicator = await dependencies[singleton: .typingIndicators].isRecipientTyping(
                threadId: threadId
            )
        }
        
        /// If there are no events we want to process then just return the current state
        guard isInitialQuery || !eventsToProcess.isEmpty else { return previousState }
        
        /// Split the events between those that need database access and those that don't
        var changes: EventChangeset = eventsToProcess.split(by: { $0.handlingStrategy })
        var loadPageEvent: LoadPageEvent? = changes.latestGeneric(.loadPage, as: LoadPageEvent.self)
        
        /// Need to handle a potential "unblinding" event first since it changes the `threadId` (and then we reload the messages
        /// based on the initial paged data query just in case - there isn't a perfect solution to capture the current messages plus any
        /// others that may have been added by the merge so do the best we can)
        if let event: ContactEvent = changes.latest(.anyContactUnblinded, as: ContactEvent.self) {
            switch event.change {
                case .unblinded(let blindedId, let unblindedId):
                    /// Need to handle a potential "unblinding" event first since it changes the `threadId` (and then
                    /// we reload the messages based on the initial paged data query just in case - there isn't a perfect
                    /// solution to capture the current messages plus any others that may have been added by the
                    /// merge so do the best we can)
                    guard blindedId == threadId else { break }
                    
                    threadId = unblindedId
                    loadResult = loadResult.info
                        .with(filterSQL: MessageViewModel.interactionFilterSQL(threadId: unblindedId))
                        .asResult
                    loadPageEvent = .initial
                    eventsToProcess = eventsToProcess
                        .filter { $0.key.generic != .loadPage }
                        .appending(
                            ObservedEvent(
                                key: .loadPage(ConversationViewModel.self),
                                value: LoadPageEvent.initial
                            )
                        )
                    changes = eventsToProcess.split(by: { $0.handlingStrategy })
                    
                default: break
            }
        }
        
        /// Update the context
        dataCache.withContext(
            source: .messageList(threadId: threadId),
            requireFullRefresh: (
                isInitialQuery ||
                threadInfo.id != threadId ||
                changes.containsAny(
                    .appLifecycle(.willEnterForeground),
                    .databaseLifecycle(.resumed)
                )
            ),
            requireAuthMethodFetch: authMethod.value.isInvalid,
            requiresInitialUnreadInteractionInfo: shouldFetchInitialUnreadInteractionInfo,
            requireRecentReactionEmojiUpdate: (
                shouldFetchInitialRecentReactions ||
                changes.contains(.recentReactionsUpdated)
            )
        )
        
        /// Handle thread specific changes first (as this could include a conversation being unblinded)
        switch threadInfo.variant {
            case .community:
                /// Handle community changes (users could change to mods which would need all of their interaction data updated)
                changes.forEach(.communityUpdated, as: CommunityEvent.self) { event in
                    switch event.change {
                        case .receivedInitialMessages:
                            /// If we already have a `loadPageEvent` then that takes prescedence, otherwise we should load
                            /// the initial page once we've received the initial messages for a community
                            guard loadPageEvent == nil else { break }
                            
                            loadPageEvent = .initial
                        
                        case .role, .moderatorsAndAdmins, .capabilities, .permissions: break
                    }
                }
                
            default: break
        }
        
        /// Then process cache updates
        dataCache = await ConversationDataHelper.applyNonDatabaseEvents(
            changes,
            currentCache: dataCache,
            using: dependencies
        )
        
        /// Then determine the fetch requirements
        let fetchRequirements: ConversationDataHelper.FetchRequirements = ConversationDataHelper.determineFetchRequirements(
            for: changes,
            currentCache: dataCache,
            itemCache: itemCache,
            loadPageEvent: loadPageEvent
        )
        
        /// Peform any database changes
        if !dependencies[singleton: .storage].isSuspended, fetchRequirements.needsAnyFetch {
            do {
                try await dependencies[singleton: .storage].readAsync { db in
                    /// Fetch the `authMethod` if needed
                    ///
                    /// **Note:** It's possible that we won't be able to fetch the `authMethod` (eg. if a group was destroyed or
                    /// the user was kicked from a group), in that case just fail silently (it's an expected behaviour - won't be able to
                    /// send requests anymore)
                    if fetchRequirements.requireAuthMethodFetch {
                        // TODO: [Database Relocation] Should be able to remove the database requirement now we have the CommunityManager
                        let maybeAuthMethod: AuthenticationMethod? = try? Authentication.with(
                            db,
                            threadId: threadInfo.id,
                            threadVariant: threadInfo.variant,
                            using: dependencies
                        )
                        
                        authMethod = EquatableAuthenticationMethod(
                            value: (maybeAuthMethod ?? Authentication.invalid)
                        )
                    }
                    
                    /// Fetch the `initialUnreadInteractionInfo` if needed
                    if fetchRequirements.requiresInitialUnreadInteractionInfo {
                        initialUnreadInteractionInfo = try Interaction
                            .select(.id, .timestampMs)
                            .filter(Interaction.Columns.wasRead == false)
                            .filter(Interaction.Columns.threadId == threadId)
                            .order(Interaction.Columns.timestampMs.asc)
                            .asRequest(of: Interaction.TimestampInfo.self)
                            .fetchOne(db)
                    }
                    
                    if fetchRequirements.requireRecentReactionEmojiUpdate {
                        recentReactionEmoji = try Emoji.getRecent(db, withDefaultEmoji: true)
                    }
                    
                    /// If we don't have an initial `focusedInteractionInfo` (as determined by the `loadPageEvent.target`
                    /// being `initial`) then we should default to loading data around the `initialUnreadInteractionInfo`
                    /// and focusing on it
                    if
                        loadPageEvent?.target == .initial,
                        let initialUnreadInteractionInfo: Interaction.TimestampInfo = initialUnreadInteractionInfo
                    {
                        loadPageEvent = .initialPageAround(id: initialUnreadInteractionInfo.id)
                        focusedInteractionInfo = initialUnreadInteractionInfo
                    }
                    
                    /// Fetch any required data from the cache
                    (loadResult, dataCache) = try ConversationDataHelper.fetchFromDatabase(
                        db,
                        requirements: fetchRequirements,
                        currentCache: dataCache,
                        loadResult: loadResult,
                        loadPageEvent: loadPageEvent,
                        using: dependencies
                    )
                }
            } catch {
                let eventList: String = changes.databaseEvents.map { $0.key.rawValue }.joined(separator: ", ")
                Log.critical(.conversation, "Failed to fetch state for events [\(eventList)], due to error: \(error)")
            }
        }
        else if !changes.databaseEvents.isEmpty {
            Log.warn(.conversation, "Ignored \(changes.databaseEvents.count) database event(s) sent while storage was suspended.")
        }
        
        /// Peform any `libSession` changes
        if fetchRequirements.needsAnyFetch {
            do {
                dataCache = try ConversationDataHelper.fetchFromLibSession(
                    requirements: fetchRequirements,
                    cache: dataCache,
                    using: dependencies
                )
            }
            catch {
                Log.warn(.conversation, "Failed to handle \(changes.libSessionEvents.count) libSession event(s) due to error: \(error).")
            }
        }
        
        /// Update the typing indicator state if needed
        changes.forEach(.typingIndicator, as: TypingIndicatorEvent.self) { event in
            shouldShowTypingIndicator = (event.change == .started)
        }
        
        /// Handle optimistic messages
        changes.forEach(.updateScreen, as: ConversationViewModelEvent.self) { event in
            switch event {
                case .sendMessage(let data):
                    optimisticallyInsertedMessages[data.temporaryId] = data
                    
                    if let attachments: [Attachment] = data.attachmentData {
                        dataCache.insert(attachments: attachments)
                        dataCache.insert(
                            attachmentMap: [
                                data.temporaryId: Set(attachments.enumerated().map { index, attachment in
                                    InteractionAttachment(
                                        albumIndex: index,
                                        interactionId: data.temporaryId,
                                        attachmentId: attachment.id
                                    )
                                })
                            ]
                        )
                    }
                    
                    if let viewModel: LinkPreviewViewModel = data.linkPreviewViewModel {
                        dataCache.insert(linkPreviews: [
                            LinkPreview(
                                url: viewModel.urlString,
                                title: viewModel.title,
                                attachmentId: nil,    /// Can't save to db optimistically
                                using: dependencies
                            )
                        ])
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
                        linkPreviewViewModel: data.linkPreviewViewModel,
                        linkPreviewPreparedAttachment: data.linkPreviewPreparedAttachment,
                        quoteViewModel: data.quoteViewModel
                    )
                
                case .resolveOptimisticMessage(let temporaryId, let databaseId):
                    guard dataCache.interaction(for: databaseId) != nil else {
                        Log.warn(.conversation, "Attempted to resolve an optimistic message but it was missing from the cache")
                        return
                    }
                    
                    optimisticallyInsertedMessages.removeValue(forKey: temporaryId)
                    dataCache.removeAttachmentMap(for: temporaryId)
                    itemCache.removeValue(forKey: temporaryId)
            }
        }
        
        /// Update the `threadInfo` with the latest `dataCache`
        if let thread: SessionThread = dataCache.thread(for: threadId) {
            threadInfo = ConversationInfoViewModel(
                thread: thread,
                dataCache: dataCache,
                using: dependencies
            )
        }
        
        /// Update the flag indicating whether reactions are supproted
        switch threadInfo.variant {
            case .legacyGroup: reactionsSupported = false
            case .contact, .group: reactionsSupported = !threadInfo.isMessageRequest
            case .community:
                reactionsSupported = (threadInfo.communityInfo?.capabilities.contains(.reactions) == true)
                isUserModeratorOrAdmin = !dataCache.communityModAdminIds(for: threadId).isDisjoint(
                    with: dataCache.currentUserSessionIds(for: threadId)
                )
        }
        
        /// Generating the `MessageViewModel` requires both the "preview" and "next" messages that will appear on
        /// the screen in order to be generated correctly so we need to iterate over the interactions again - additionally since
        /// modifying interactions could impact this clustering behaviour (or ever other cached content), and we add messages
        /// optimistically, it's simplest to just fully regenerate the entire `itemCache` and rely on diffing to prevent incorrect changes
        let orderedIds: [Int64] = State.orderedIdsIncludingOptimisticMessages(
            loadedPageInfo: loadResult.info,
            optimisticMessages: optimisticallyInsertedMessages,
            dataCache: dataCache
        )
        
        itemCache = orderedIds.enumerated().reduce(into: [:]) { result, next in
            let optimisticMessageId: Int64?
            let interaction: Interaction
            let reactionInfo: [MessageViewModel.ReactionInfo]?
            let maybeUnresolvedQuotedInfo: MessageViewModel.MaybeUnresolvedQuotedInfo?
            
            /// Source the interaction data from the appropriate location
            switch next.element {
                case ..<0:  /// If the `id` is less than `0` then it's an optimistic message
                    guard let data: OptimisticMessageData = optimisticallyInsertedMessages[next.element] else {
                        return
                    }
                    
                    optimisticMessageId = data.temporaryId
                    interaction = data.interaction
                    reactionInfo = nil  /// Can't react to an optimistic message
                    maybeUnresolvedQuotedInfo = data.quoteViewModel.map { model -> MessageViewModel.MaybeUnresolvedQuotedInfo? in
                        guard let interactionId: Int64 = model.quotedInfo?.interactionId else { return nil }
                        
                        return MessageViewModel.MaybeUnresolvedQuotedInfo(
                            foundQuotedInteractionId: interactionId,
                            resolvedQuotedInteraction: dataCache.interaction(for: interactionId)
                        )
                    }
                    
                default:
                    guard let targetInteraction: Interaction = dataCache.interaction(for: next.element) else {
                        return
                    }
                    
                    optimisticMessageId = nil
                    interaction = targetInteraction
                    
                    let reactions: [Reaction] = dataCache.reactions(for: next.element)
                    
                    if !reactions.isEmpty {
                        reactionInfo = reactions.map { reaction in
                            /// If the reactor is the current user then use the proper profile from the cache (instead of a random
                            /// blinded one)
                            let targetId: String = (threadInfo.currentUserSessionIds.contains(reaction.authorId) ?
                                previousState.userSessionId.hexString :
                                reaction.authorId
                            )
                            
                            return MessageViewModel.ReactionInfo(
                                reaction: reaction,
                                profile: dataCache.profile(for: targetId)
                            )
                        }
                    }
                    else {
                        reactionInfo = nil
                    }
                    
                    maybeUnresolvedQuotedInfo = dataCache.quoteInfo(for: next.element).map { info in
                        MessageViewModel.MaybeUnresolvedQuotedInfo(
                            foundQuotedInteractionId: info.foundQuotedInteractionId,
                            resolvedQuotedInteraction: info.foundQuotedInteractionId.map {
                                dataCache.interaction(for: $0)
                            }
                        )
                    }
            }
            
            result[next.element] = MessageViewModel(
                optimisticMessageId: optimisticMessageId,
                interaction: interaction,
                reactionInfo: reactionInfo,
                maybeUnresolvedQuotedInfo: maybeUnresolvedQuotedInfo,
                userSessionId: previousState.userSessionId,
                threadInfo: threadInfo,
                dataCache: dataCache,
                previousInteraction: State.interaction(
                    at: next.offset + 1,  /// Order is inverted so `previousInteraction` is the next element
                    orderedIds: orderedIds,
                    optimisticMessages: optimisticallyInsertedMessages,
                    dataCache: dataCache
                ),
                nextInteraction: State.interaction(
                    at: next.offset - 1,  /// Order is inverted so `nextInteraction` is the previous element
                    orderedIds: orderedIds,
                    optimisticMessages: optimisticallyInsertedMessages,
                    dataCache: dataCache
                ),
                isLast: (
                    /// Order is inverted so we need to check the start of the list
                    next.offset == 0 &&
                    !loadResult.info.hasPrevPage
                ),
                isLastOutgoing: (
                    /// Order is inverted so we need to check the start of the list
                    next.element == orderedIds
                        .prefix(next.offset + 1)  /// Want to include the value for `index` in the result
                        .enumerated()
                        .compactMap { prefixIndex, _ in
                            State.interaction(
                                at: prefixIndex,
                                orderedIds: orderedIds,
                                optimisticMessages: optimisticallyInsertedMessages,
                                dataCache: dataCache
                            )
                        }
                        .first(where: { threadInfo.currentUserSessionIds.contains($0.authorId) })?
                        .id
                ),
                currentUserMentionImage: previousState.currentUserMentionImage,
                using: dependencies
            )
        }
        
        return State(
            viewState: (loadResult.info.totalCount == 0 ? .empty : .loaded),
            threadInfo: threadInfo,
            authMethod: authMethod,
            currentUserMentionImage: previousState.currentUserMentionImage,
            isBlindedContact: SessionId.Prefix.isCommunityBlinded(threadId),
            wasPreviouslyBlindedContact: SessionId.Prefix.isCommunityBlinded(previousState.threadId),
            focusedInteractionInfo: focusedInteractionInfo,
            focusBehaviour: previousState.focusBehaviour,
            initialUnreadInteractionInfo: initialUnreadInteractionInfo,
            loadedPageInfo: loadResult.info,
            dataCache: dataCache,
            itemCache: itemCache,
            titleViewModel: ConversationTitleViewModel(
                threadInfo: threadInfo,
                dataCache: dataCache,
                using: dependencies
            ),
            legacyGroupsBannerIsVisible: previousState.legacyGroupsBannerIsVisible,
            reactionsSupported: reactionsSupported,
            recentReactionEmoji: recentReactionEmoji,
            isUserModeratorOrAdmin: isUserModeratorOrAdmin,
            shouldShowTypingIndicator: shouldShowTypingIndicator,
            optimisticallyInsertedMessages: optimisticallyInsertedMessages
        )
    }
    
    private static func sections(state: State, viewModel: ConversationViewModel) -> [SectionModel] {
        let orderedIds: [Int64] = State.orderedIdsIncludingOptimisticMessages(
            loadedPageInfo: state.loadedPageInfo,
            optimisticMessages: state.optimisticallyInsertedMessages,
            dataCache: state.dataCache
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
        linkPreviewViewModel: LinkPreviewViewModel?,
        quoteViewModel: QuoteViewModel?
    ) async throws -> OptimisticMessageData {
        // Generate the optimistic data
        let optimisticMessageId: Int64 = (-Int64.max + sentTimestampMs) /// Unique but avoids collisions with messages
        let currentState: State = await self.state
        let proMessageFeatures: SessionPro.MessageFeatures = try {
            let result: SessionPro.FeaturesForMessage = dependencies[singleton: .sessionProManager].messageFeatures(
                for: (text ?? "")
            )
            
            switch result.status {
                case .success: return result.features
                case .utfDecodingError:
                    Log.warn(.messageSender, "Failed to extract features for message, falling back to manual handling")
                    guard (text ?? "").utf16.count > SessionPro.CharacterLimit else {
                        return .none
                    }
                    
                    return .largerCharacterLimit
                    
                case .exceedsCharacterLimit: throw MessageError.messageTooLarge
            }
        }()
        let proProfileFeatures: SessionPro.ProfileFeatures = dependencies[singleton: .sessionProManager]
            .currentUserCurrentProState
            .profileFeatures
        let interaction: Interaction = Interaction(
            threadId: currentState.threadId,
            threadVariant: currentState.threadVariant,
            authorId: currentState.threadInfo.currentUserSessionIds
                .first { $0.hasPrefix(SessionId.Prefix.blinded15.rawValue) }
                .defaulting(to: currentState.userSessionId.hexString),
            variant: .standardOutgoing,
            body: text,
            timestampMs: sentTimestampMs,
            hasMention: Interaction.isUserMentioned(
                publicKeysToCheck: currentState.threadInfo.currentUserSessionIds,
                body: text
            ),
            expiresInSeconds: currentState.threadInfo.disappearingMessagesConfiguration?.expiresInSeconds(),
            linkPreviewUrl: linkPreviewViewModel?.urlString,
            proMessageFeatures: proMessageFeatures,
            proProfileFeatures: proProfileFeatures,
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
        
        if let draft: LinkPreviewViewModel = linkPreviewViewModel {
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
            linkPreviewViewModel: linkPreviewViewModel,
            linkPreviewPreparedAttachment: linkPreviewPreparedAttachment,
            quoteViewModel: quoteViewModel
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
    
    // MARK: - Profiles
    
    @MainActor public func displayName(for sessionId: String, inMessageBody: Bool) -> String? {
        return state.dataCache.profile(for: sessionId)?.displayName(
            includeSessionIdSuffix: (state.threadVariant == .community && inMessageBody)
        )
    }
    
    public func mentions(for query: String = "") async throws -> [MentionSelectionView.ViewModel] {
        let state: State = await self.state
        
        return try await MentionSelectionView.ViewModel.mentions(
            for: query,
            threadId: state.threadId,
            threadVariant: state.threadVariant,
            currentUserSessionIds: state.threadInfo.currentUserSessionIds,
            communityInfo: state.threadInfo.communityInfo.map { info in
                (server: info.server, roomToken: info.roomToken)
            },
            using: dependencies
        )
    }
    
    @MainActor public func draftQuote(for viewModel: MessageViewModel) -> QuoteViewModel {
        let targetAttachment: Attachment? = (
            viewModel.attachments.first ??
            viewModel.linkPreviewAttachment
        )
        
        return QuoteViewModel(
            mode: .draft,
            direction: (viewModel.variant == .standardOutgoing ? .outgoing : .incoming),
            quotedInfo: QuoteViewModel.QuotedInfo(
                interactionId: viewModel.id,
                authorId: viewModel.authorId,
                authorName: viewModel.authorName(),
                timestampMs: viewModel.timestampMs,
                body: viewModel.bubbleBody,
                attachmentInfo: targetAttachment?.quoteAttachmentInfo(using: dependencies)
            ),
            showProBadge: viewModel.profile.proFeatures.contains(.proBadge), /// Quote pro badge is profile data
            currentUserSessionIds: viewModel.currentUserSessionIds,
            displayNameRetriever: state.dataCache.displayNameRetriever(
                for: viewModel.threadId,
                includeSessionIdSuffixWhenInMessageBody: (viewModel.threadVariant == .community)
            ),
            currentUserMentionImage: viewModel.currentUserMentionImage
        )
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
        Task.detached(priority: .userInitiated) { [threadInfo = state.threadInfo, dependencies] in
            do { try await threadInfo.updateDraft(draft, using: dependencies) }
            catch { Log.error(.conversation, "Failed to update draft due to error: \(error)") }
        }
    }
    
    public func markThreadAsRead() async {
        let threadInfo: ConversationInfoViewModel = await state.threadInfo
        try? await threadInfo.markAsRead(target: .thread, using: dependencies)
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
                state.threadInfo.unreadCount > 0 ||
                state.threadInfo.wasMarkedUnread
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
        let (threadInfo, pendingInfo): (ConversationInfoViewModel, Interaction.TimestampInfo?) = await MainActor.run {
            (
                state.threadInfo,
                pendingMarkAsReadInfo
            )
        }
        
        guard let info: Interaction.TimestampInfo = pendingInfo else { return }
        
        try? await threadInfo.markAsRead(
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
    
    @MainActor public func deletionActions(for cellViewModels: [MessageViewModel]) throws -> MessageViewModel.DeletionBehaviours? {
        return try MessageViewModel.DeletionBehaviours.deletionActions(
            for: cellViewModels,
            threadInfo: state.threadInfo,
            authMethod: state.authMethod.value,
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

private extension ObservedEvent {
    var handlingStrategy: EventHandlingStrategy {
        let threadInfoStrategy: EventHandlingStrategy? = ConversationInfoViewModel.handlingStrategy(for: self)
        let messageStrategy: EventHandlingStrategy? = MessageViewModel.handlingStrategy(for: self)
        let localStrategy: EventHandlingStrategy = {
            switch (key, key.generic) {
                case (_, .loadPage): return .databaseQuery
                case (.anyMessageCreatedInAnyConversation, _): return .databaseQuery
                case (.anyContactBlockedStatusChanged, _): return .databaseQuery
                case (.anyContactUnblinded, _): return [.databaseQuery, .directCacheUpdate]
                case (.recentReactionsUpdated, _): return .databaseQuery
                case (_, .conversationUpdated), (_, .conversationDeleted): return .databaseQuery
                case (_, .messageCreated), (_, .messageUpdated), (_, .messageDeleted): return .databaseQuery
                case (_, .attachmentCreated), (_, .attachmentUpdated), (_, .attachmentDeleted): return .databaseQuery
                case (_, .reactionsChanged): return .databaseQuery
                case (_, .communityUpdated): return [.databaseQuery, .directCacheUpdate]
                case (_, .contact): return [.databaseQuery, .directCacheUpdate]
                case (_, .profile): return [.databaseQuery, .directCacheUpdate]
                case (_, .typingIndicator): return .directCacheUpdate
                default: return .directCacheUpdate
            }
        }()
        
        return localStrategy
            .union(threadInfoStrategy ?? .none)
            .union(messageStrategy ?? .none)
    }
}

private extension ConversationTitleViewModel {
    init(
        threadInfo: ConversationInfoViewModel,
        dataCache: ConversationDataCache,
        using dependencies: Dependencies
    ) {
        self.threadVariant = threadInfo.variant
        self.displayName = threadInfo.displayName.deformatted()
        self.isNoteToSelf = threadInfo.isNoteToSelf
        self.isMessageRequest = threadInfo.isMessageRequest
        self.showProBadge = (dataCache.profile(for: threadInfo.id)?.proFeatures.contains(.proBadge) == true)
        self.isMuted = (dependencies.dateNow.timeIntervalSince1970 <= (threadInfo.mutedUntilTimestamp ?? 0))
        self.onlyNotifyForMentions = threadInfo.onlyNotifyForMentions
        self.userCount = threadInfo.userCount
        self.disappearingMessagesConfig = threadInfo.disappearingMessagesConfiguration
    }
}

public extension ConversationViewModel {
    static func fetchConversationInfo(
        threadId: String,
        using dependencies: Dependencies
    ) async throws -> ConversationInfoViewModel {
        return try await dependencies[singleton: .storage].readAsync { [dependencies] db in
            try ConversationViewModel.fetchConversationInfo(
                db,
                threadId: threadId,
                using: dependencies
            )
        }
    }
    
    static func fetchConversationInfo(
        _ db: ObservingDatabase,
        threadId: String,
        using dependencies: Dependencies
    ) throws -> ConversationInfoViewModel {
        var dataCache: ConversationDataCache = ConversationDataCache(
            userSessionId: dependencies[cache: .general].sessionId,
            context: ConversationDataCache.Context(
                source: .messageList(threadId: threadId),
                requireFullRefresh: true,
                requireAuthMethodFetch: false,
                requiresMessageRequestCountUpdate: false,
                requiresInitialUnreadInteractionInfo: false,
                requireRecentReactionEmojiUpdate: false
            )
        )
        let fetchRequirements: ConversationDataHelper.FetchRequirements = ConversationDataHelper.FetchRequirements(
            requireAuthMethodFetch: false,
            requiresMessageRequestCountUpdate: false,
            requiresInitialUnreadInteractionInfo: false,
            requireRecentReactionEmojiUpdate: false,
            threadIdsNeedingFetch: [threadId]
        )
        
        dataCache = try ConversationDataHelper.fetchFromDatabase(
            db,
            requirements: fetchRequirements,
            currentCache: dataCache,
            using: dependencies
        )
        dataCache = try ConversationDataHelper.fetchFromLibSession(
            requirements: fetchRequirements,
            cache: dataCache,
            using: dependencies
        )
        
        guard let thread: SessionThread = dataCache.thread(for: threadId) else {
            Log.error(.conversation, "Unable to fetch conversation info for thread: \(threadId).")
            throw StorageError.objectNotFound
        }
        
        return ConversationInfoViewModel(
            thread: thread,
            dataCache: dataCache,
            using: dependencies
        )
    }
}
