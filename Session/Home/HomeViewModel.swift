// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import DifferenceKit
import SignalUtilitiesKit
import SessionMessagingKit
import SessionUtilitiesKit

// MARK: - Log.Category

public extension Log.Category {
    static let homeViewModel: Log.Category = .create("HomeViewModel", defaultLevel: .warn)
}

// MARK: - HomeViewModel

public class HomeViewModel: NavigatableStateHolder {
    public let navigatableState: NavigatableState = NavigatableState()
    
    public typealias SectionModel = ArraySection<Section, SessionThreadViewModel>
    
    // MARK: - Section
    
    public enum Section: Differentiable {
        case messageRequests
        case threads
        case loadMore
    }
    
    // MARK: - Variables
    
    private static let pageSize: Int = (UIDevice.current.isIPad ? 20 : 15)
    
    public let dependencies: Dependencies
    private let userSessionId: SessionId

    /// This value is the current state of the view
    @MainActor @Published private(set) var state: State
    private var observationTask: Task<Void, Never>?
    
    // MARK: - Initialization
    
    @MainActor init(using dependencies: Dependencies) {
        self.dependencies = dependencies
        self.userSessionId = dependencies[cache: .general].sessionId
        self.state = State.initialState(using: dependencies)
        
        /// Bind the state
        self.observationTask = ObservationBuilder
            .initialValue(self.state)
            .debounce(for: .milliseconds(250))
            .using(dependencies: dependencies)
            .query(HomeViewModel.queryState)
            .assign { [weak self] updatedState in self?.state = updatedState }
    }
    
    // MARK: - State

    public struct State: ObservableKeyProvider {
        enum ViewState: Equatable {
            case loading
            case empty(isNewUser: Bool)
            case loaded
        }
        
        let viewState: ViewState
        let userProfile: Profile
        let serviceNetwork: ServiceNetwork
        let forceOffline: Bool
        let hasSavedThread: Bool
        let hasSavedMessage: Bool
        let showViewedSeedBanner: Bool
        let hasHiddenMessageRequests: Bool
        let unreadMessageRequestThreadCount: Int
        let loadedPageInfo: PagedData.LoadedInfo<SessionThreadViewModel.ID>
        let itemCache: [String: SessionThreadViewModel]
        
        @MainActor public func sections(viewModel: HomeViewModel) -> [SectionModel] {
            HomeViewModel.sections(state: self, viewModel: viewModel)
        }
        
        public var observedKeys: Set<ObservableKey> {
            var result: Set<ObservableKey> = [
                .loadPage(HomeViewModel.self),
                .messageRequestAccepted,
                .messageRequestDeleted,
                .messageRequestMessageRead,
                .messageRequestUnreadMessageReceived,
                .profile(userProfile.id),
                .feature(.serviceNetwork),
                .feature(.forceOffline),
                .setting(.hasSavedThread),
                .setting(.hasSavedMessage),
                .setting(.hasViewedSeed),
                .setting(.hasHiddenMessageRequests),
                .conversationCreated,
                .anyMessageCreatedInAnyConversation,
                .anyContactBlockedStatusChanged
            ]
            
            itemCache.values.forEach { threadViewModel in
                result.insert(contentsOf: [
                    .conversationUpdated(threadViewModel.threadId),
                    .conversationDeleted(threadViewModel.threadId),
                    .messageCreated(threadId: threadViewModel.threadId),
                    .messageUpdated(
                        id: threadViewModel.interactionId,
                        threadId: threadViewModel.threadId
                    ),
                    .messageDeleted(
                        id: threadViewModel.interactionId,
                        threadId: threadViewModel.threadId
                    ),
                    .typingIndicator(threadViewModel.threadId)
                ])
                
                if let authorId: String = threadViewModel.authorId {
                    result.insert(.profile(authorId))
                }
            }
            
            return result
        }
        
        static func initialState(using dependencies: Dependencies) -> State {
            return State(
                viewState: .loading,
                userProfile: Profile(id: dependencies[cache: .general].sessionId.hexString, name: ""),
                serviceNetwork: dependencies[feature: .serviceNetwork],
                forceOffline: dependencies[feature: .forceOffline],
                hasSavedThread: false,
                hasSavedMessage: false,
                showViewedSeedBanner: true,
                hasHiddenMessageRequests: false,
                unreadMessageRequestThreadCount: 0,
                loadedPageInfo: PagedData.LoadedInfo(
                    record: SessionThreadViewModel.self,
                    pageSize: HomeViewModel.pageSize,
                    /// **Note:** This `optimisedJoinSQL` value includes the required minimum joins needed
                    /// for the query but differs from the JOINs that are actually used for performance reasons as the
                    /// basic logic can be simpler for where it's used
                    requiredJoinSQL: SessionThreadViewModel.optimisedJoinSQL,
                    filterSQL: SessionThreadViewModel.homeFilterSQL(
                        userSessionId: dependencies[cache: .general].sessionId
                    ),
                    groupSQL: SessionThreadViewModel.groupSQL,
                    orderSQL: SessionThreadViewModel.homeOrderSQL
                ),
                itemCache: [:]
            )
        }
    }
    
    @Sendable private static func queryState(
        previousState: State,
        events: [ObservedEvent],
        isInitialQuery: Bool,
        using dependencies: Dependencies
    ) async -> State {
        let startedAsNewUser: Bool = (dependencies[cache: .onboarding].initialFlow == .register)
        var userProfile: Profile = previousState.userProfile
        var serviceNetwork: ServiceNetwork = previousState.serviceNetwork
        var forceOffline: Bool = previousState.forceOffline
        var hasSavedThread: Bool = previousState.hasSavedThread
        var hasSavedMessage: Bool = previousState.hasSavedMessage
        var showViewedSeedBanner: Bool = previousState.showViewedSeedBanner
        var hasHiddenMessageRequests: Bool = previousState.hasHiddenMessageRequests
        var unreadMessageRequestThreadCount: Int = previousState.unreadMessageRequestThreadCount
        var loadResult: PagedData.LoadResult = previousState.loadedPageInfo.asResult
        var itemCache: [String: SessionThreadViewModel] = previousState.itemCache
        
        /// Store a local copy of the events so we can manipulate it based on the state changes
        var eventsToProcess: [ObservedEvent] = events
        
        /// If this is the initial query then we need to properly fetch the initial state
        if isInitialQuery {
            /// Insert a fake event to force the initial page load
            eventsToProcess.append(ObservedEvent(
                key: .loadPage(HomeViewModel.self),
                value: LoadPageEvent.initial
            ))
            
            /// Load the values needed from `libSession`
            dependencies.mutate(cache: .libSession) { libSession in
                userProfile = libSession.profile
                showViewedSeedBanner = !libSession.get(.hasViewedSeed)
                hasHiddenMessageRequests = libSession.get(.hasHiddenMessageRequests)
            }
            
            /// If we haven't hidden the message requests banner then we should include that in the initial fetch
            if !hasHiddenMessageRequests {
                eventsToProcess.append(ObservedEvent(
                    key: .messageRequestUnreadMessageReceived,
                    value: nil
                ))
            }
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
        
        /// Handle database events first
        if let databaseEvents: Set<ObservedEvent> = splitEvents[.databaseQuery], !databaseEvents.isEmpty {
            do {
                var fetchedConversations: [SessionThreadViewModel] = []
                let idsNeedingRequery: Set<String> = self.extractIdsNeedingRequery(
                    events: databaseEvents,
                    cache: itemCache
                )
                let loadPageEvent: LoadPageEvent? = databaseEvents
                    .first(where: { $0.key.generic == .loadPage })?
                    .value as? LoadPageEvent
                
                /// Identify any inserted/deleted records
                var insertedIds: Set<String> = []
                var deletedIds: Set<String> = []
                
                databaseEvents.forEach { event in
                    switch (event.key.generic, event.value) {
                        case (GenericObservableKey(.messageRequestAccepted), let threadId as String):
                            insertedIds.insert(threadId)
                            
                        case (GenericObservableKey(.conversationCreated), let event as ConversationEvent):
                            insertedIds.insert(event.id)
                            
                        case (GenericObservableKey(.anyMessageCreatedInAnyConversation), let event as MessageEvent):
                            insertedIds.insert(event.threadId)
                            
                        case (.conversationDeleted, let event as ConversationEvent):
                            deletedIds.insert(event.id)
                            
                        case (GenericObservableKey(.anyContactBlockedStatusChanged), let event as ContactEvent):
                            if case .isBlocked(true) = event.change {
                                deletedIds.insert(event.id)
                            }
                            else if case .isBlocked(false) = event.change {
                                insertedIds.insert(event.id)
                            }
                            
                        default: break
                    }
                }
                
                try await dependencies[singleton: .storage].readAsync { db in
                    /// Update the `unreadMessageRequestThreadCount` if needed (since multiple events need this)
                    if databaseEvents.contains(where: { $0.requiresMessageRequestCountUpdate }) {
                        // TODO: [Database Relocation] Should be able to clean this up by getting the conversation list and filtering
                        struct ThreadIdVariant: Decodable, Hashable, FetchableRecord {
                            let id: String
                            let variant: SessionThread.Variant
                        }
                        
                        let potentialMessageRequestThreadInfo: Set<ThreadIdVariant> = try SessionThread
                            .select(.id, .variant)
                            .filter(
                                SessionThread.Columns.variant == SessionThread.Variant.contact ||
                                SessionThread.Columns.variant == SessionThread.Variant.group
                            )
                            .asRequest(of: ThreadIdVariant.self)
                            .fetchSet(db)
                        let messageRequestThreadIds: Set<String> = Set(
                            dependencies.mutate(cache: .libSession) { libSession in
                                potentialMessageRequestThreadInfo.compactMap {
                                    guard libSession.isMessageRequest(threadId: $0.id, threadVariant: $0.variant) else {
                                        return nil
                                    }
                                    
                                    return $0.id
                                }
                            }
                        )
                        
                        unreadMessageRequestThreadCount = try SessionThread
                            .unreadMessageRequestsQuery(messageRequestThreadIds: messageRequestThreadIds)
                            .fetchCount(db)
                    }
                    
                    /// Update loaded page info as needed
                    if loadPageEvent != nil || !insertedIds.isEmpty || !deletedIds.isEmpty {
                        loadResult = try loadResult.load(
                            db,
                            target: (
                                loadPageEvent?.target(with: loadResult) ??
                                .reloadCurrent(insertedIds: insertedIds, deletedIds: deletedIds)
                            )
                        )
                    }
                    
                    /// Fetch any records needed
                    fetchedConversations.append(
                        contentsOf: try SessionThreadViewModel
                            .query(
                                userSessionId: dependencies[cache: .general].sessionId,
                                groupSQL: SessionThreadViewModel.groupSQL,
                                orderSQL: SessionThreadViewModel.homeOrderSQL,
                                ids: Array(idsNeedingRequery) + loadResult.newIds
                            )
                            .fetchAll(db)
                    )
                }
                
                /// Update the `itemCache` with the newly fetched values
                fetchedConversations.forEach { itemCache[$0.threadId] = $0 }
                
                /// Remove any deleted values
                deletedIds.forEach { id in itemCache.removeValue(forKey: id) }
            } catch {
                let eventList: String = databaseEvents.map { $0.key.rawValue }.joined(separator: ", ")
                Log.critical(.homeViewModel, "Failed to fetch state for events [\(eventList)], due to error: \(error)")
            }
        }
        
        /// Then handle non-database events
        let groupedOtherEvents: [GenericObservableKey: Set<ObservedEvent>]? = splitEvents[.other]?
            .reduce(into: [:]) { result, event in
                result[event.key.generic, default: []].insert(event)
            }
        groupedOtherEvents?[.profile]?.forEach { event in
            guard
                let eventValue: ProfileEvent = event.value as? ProfileEvent,
                eventValue.id == userProfile.id
            else { return }
            
            switch eventValue.change {
                case .name(let name): userProfile = userProfile.with(name: name)
                case .nickname(let nickname): userProfile = userProfile.with(nickname: nickname)
                case .displayPictureUrl(let url): userProfile = userProfile.with(displayPictureUrl: url)
            }
        }
        groupedOtherEvents?[.setting]?.forEach { event in
            guard let updatedValue: Bool = event.value as? Bool else { return }
            
            switch event.key {
                case .setting(.hasSavedThread): hasSavedThread = (updatedValue || hasSavedThread)
                case .setting(.hasSavedMessage): hasSavedMessage = (updatedValue || hasSavedMessage)
                case .setting(.hasViewedSeed): showViewedSeedBanner = !updatedValue // Inverted
                case .setting(.hasHiddenMessageRequests): hasHiddenMessageRequests = updatedValue
                default: break
            }
        }
        groupedOtherEvents?[.feature]?.forEach { event in
            if event.key == .feature(.serviceNetwork), let updatedValue = event.value as? ServiceNetwork {
                serviceNetwork = updatedValue
            }
            else if event.key == .feature(.forceOffline), let updatedValue = event.value as? Bool {
                forceOffline = updatedValue
            }
        }
        
        /// Generate the new state
        return State(
            viewState: (loadResult.info.totalCount == 0 ?
                .empty(isNewUser: (startedAsNewUser && !hasSavedThread && !hasSavedMessage)) :
                .loaded
            ),
            userProfile: userProfile,
            serviceNetwork: serviceNetwork,
            forceOffline: forceOffline,
            hasSavedThread: hasSavedThread,
            hasSavedMessage: hasSavedMessage,
            showViewedSeedBanner: showViewedSeedBanner,
            hasHiddenMessageRequests: hasHiddenMessageRequests,
            unreadMessageRequestThreadCount: unreadMessageRequestThreadCount,
            loadedPageInfo: loadResult.info,
            itemCache: itemCache
        )
    }
    
    private static func extractIdsNeedingRequery(
        events: Set<ObservedEvent>,
        cache: [String: SessionThreadViewModel]
    ) -> Set<String> {
        return events.reduce(into: []) { result, event in
            switch (event.key.generic, event.value) {
                case (.conversationUpdated, let event as ConversationEvent): result.insert(event.id)
                case (.typingIndicator, let event as TypingIndicatorEvent): result.insert(event.threadId)
                    
                case (.messageCreated, let event as MessageEvent),
                    (.messageUpdated, let event as MessageEvent),
                    (.messageDeleted, let event as MessageEvent):
                    result.insert(event.threadId)
                    
                case (.profile, let event as ProfileEvent):
                    result.insert(
                        contentsOf: Set(cache.values
                            .filter { threadViewModel -> Bool in
                                threadViewModel.threadId == event.id ||
                                threadViewModel.allProfileIds.contains(event.id)
                            }
                            .map { $0.threadId })
                    )
                
                case (.contact, let event as ContactEvent):
                    result.insert(
                        contentsOf: Set(cache.values
                            .filter { threadViewModel -> Bool in
                                threadViewModel.threadId == event.id ||
                                threadViewModel.allProfileIds.contains(event.id)
                            }
                            .map { $0.threadId })
                    )
                    
                default: break
            }
        }
    }
    
    private static func sections(state: State, viewModel: HomeViewModel) -> [SectionModel] {
        return [
            /// If the message request section is hidden or there are no unread message requests then hide the message request banner
            (state.hasHiddenMessageRequests || state.unreadMessageRequestThreadCount == 0 ?
                [] :
                [SectionModel(
                    section: .messageRequests,
                    elements: [
                        SessionThreadViewModel(
                            threadId: SessionThreadViewModel.messageRequestsSectionId,
                            unreadCount: UInt(state.unreadMessageRequestThreadCount),
                            using: viewModel.dependencies
                        )
                    ]
                )]
            ),
            [
                SectionModel(
                    section: .threads,
                    elements: state.loadedPageInfo.currentIds
                        .compactMap { state.itemCache[$0] }
                        .map { conversation -> SessionThreadViewModel in
                            conversation.populatingPostQueryData(
                                recentReactionEmoji: nil,
                                openGroupCapabilities: nil,
                                // TODO: [Database Relocation] Do we need all of these????
                                currentUserSessionIds: [viewModel.dependencies[cache: .general].sessionId.hexString],
                                wasKickedFromGroup: (
                                    conversation.threadVariant == .group &&
                                    viewModel.dependencies.mutate(cache: .libSession) { cache in
                                        cache.wasKickedFromGroup(
                                            groupSessionId: SessionId(.group, hex: conversation.threadId)
                                        )
                                    }
                                ),
                                groupIsDestroyed: (
                                    conversation.threadVariant == .group &&
                                    viewModel.dependencies.mutate(cache: .libSession) { cache in
                                        cache.groupIsDestroyed(
                                            groupSessionId: SessionId(.group, hex: conversation.threadId)
                                        )
                                    }
                                ),
                                threadCanWrite: false,  // Irrelevant for the HomeViewModel
                                threadCanUpload: false  // Irrelevant for the HomeViewModel
                            )
                        }
                )
            ],
            (!state.loadedPageInfo.currentIds.isEmpty && state.loadedPageInfo.hasNextPage ?
                [SectionModel(section: .loadMore)] :
                []
            )
        ].flatMap { $0 }
    }
    
    // MARK: - Functions
    
    @MainActor func loadPageBefore() {
        dependencies.notifyAsync(
            key: .loadPage(HomeViewModel.self),
            value: LoadPageEvent.previousPage(firstIndex: state.loadedPageInfo.firstIndex)
        )
    }
    
    @MainActor public func loadNextPage() {
        dependencies.notifyAsync(
            key: .loadPage(HomeViewModel.self),
            value: LoadPageEvent.nextPage(lastIndex: state.loadedPageInfo.lastIndex)
        )
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
        switch (key, key.generic) {
            case (.setting(.hasHiddenMessageRequests), _): return .bothDatabaseQueryAndOther
                
            case (_, .profile): return .bothDatabaseQueryAndOther
            case (.feature(.serviceNetwork), _): return .other
            case (.feature(.forceOffline), _): return .other
            case (.setting(.hasViewedSeed), _): return .other
                
            case (.messageRequestUnreadMessageReceived, _), (.messageRequestAccepted, _),
                (.messageRequestDeleted, _), (.messageRequestMessageRead, _):
                return .databaseQuery
            case (_, .loadPage): return .databaseQuery
            case (.conversationCreated, _): return .databaseQuery
            case (.anyMessageCreatedInAnyConversation, _): return .databaseQuery
            case (.anyContactBlockedStatusChanged, _): return .databaseQuery
            case (_, .typingIndicator): return .databaseQuery
            case (_, .conversationUpdated), (_, .conversationDeleted): return .databaseQuery
            case (_, .messageCreated), (_, .messageUpdated), (_, .messageDeleted): return .databaseQuery
            default: return .other
        }
    }
    
    var requiresMessageRequestCountUpdate: Bool {
        switch self.key {
            case .messageRequestUnreadMessageReceived, .messageRequestAccepted, .messageRequestDeleted,
                .messageRequestMessageRead:
                return true
                
            default: return false
        }
    }
}
