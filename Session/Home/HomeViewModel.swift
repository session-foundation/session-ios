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

@MainActor
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
    
    nonisolated fileprivate static let observationName: String = "HomeViewModel"    // stringlint:ignore
    @MainActor public static let pageSize: Int = (UIDevice.current.isIPad ? 20 : 15)
    
    public let dependencies: Dependencies
    private let userSessionId: SessionId
    
    /// This flag acts as a lock on the page loading logic, while it's weird to modify state within the `query` that isn't on the `State`
    /// type, this is a primarily an optimisation to prevent the `loadPage` events from triggering multiple times since that can happen
    /// due to how the UI is setup
    private var currentlyHandlingPageLoad: Bool = false
    
    /// This is a cache of the observed data before any processing is done for the UI state to allow us to more easily do diffs
    private var itemCache: [String: SessionThreadViewModel] = [:]

    
    // MARK: - Initialization
    
    init(using dependencies: Dependencies) {
        self.dependencies = dependencies
        self.userSessionId = dependencies[cache: .general].sessionId
        self.state = State.initialState(using: dependencies)
        
        self.bindState()
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
        let showViewedSeedBanner: Bool
        let hasHiddenMessageRequests: Bool
        let unreadMessageRequestThreadCount: Int
        let loadedPageInfo: PagedData.LoadedInfo<SessionThreadViewModel.ID>
        let sections: [SectionModel]
        
        public var observedKeys: Set<ObservableKey> {
            var result: Set<ObservableKey> = [
                .messageRequestAccepted,
                .messageRequestDeleted,
                .messageRequestMessageRead,
                .messageRequestUnreadMessageReceived,
                .loadPage(HomeViewModel.observationName),
                .profile(userProfile.id),
                .setting(.hasViewedSeed),
                .setting(.hasHiddenMessageRequests),
                .conversationCreated,
                .messageCreatedInAnyConversation
            ]
            
            sections.filter { $0.model == .threads }.first?.elements.forEach { threadViewModel in
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
            }
            
            return result
        }
        
        @MainActor static func initialState(using dependencies: Dependencies) -> State {
            return State(
                viewState: .loading,
                userProfile: Profile(id: dependencies[cache: .general].sessionId.hexString, name: ""),
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
                sections: []
            )
        }
    }

    /// This value is the current state of the view
    @Published private(set) var state: State
    private var observationTask: Task<Void, Never>?
    private var previousSections: [SectionModel] = []

    private func bindState() {
        let startedAsNewUser: Bool = (dependencies[cache: .onboarding].initialFlow == .register)
        let initialState: State = State.initialState(using: dependencies)
        
        observationTask = ObservationBuilder
            .debounce(for: .milliseconds(250))
            .using(manager: dependencies[singleton: .observationManager])
            .query { [weak self, userSessionId, dependencies] previousState, events in
                guard let self = self else { return initialState }
                
                /// Store mutable copies of the data to update
                let currentState: State = (previousState ?? initialState)
                var userProfile: Profile = currentState.userProfile
                var showViewedSeedBanner: Bool = currentState.showViewedSeedBanner
                var hasHiddenMessageRequests: Bool = currentState.hasHiddenMessageRequests
                var unreadMessageRequestThreadCount: Int = currentState.unreadMessageRequestThreadCount
                var loadResult: PagedData.LoadResult = currentState.loadedPageInfo.asResult
                
                /// Store a local copy of the events so we can manipulate it based on the state changes
                var eventsToProcess: [ObservedEvent] = events
                
                /// If we have no previous state then we need to fetch the initial state
                if previousState == nil {
                    /// Insert a fake event to force the initial page load
                    eventsToProcess.append(ObservedEvent(
                        key: .loadPage(HomeViewModel.observationName),
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
                
                /// If we have a `loadPage` event then we need to toggle the lock to prevent duplicate page loads from triggering
                /// queries (if we are already loading a page elsewhere then just remove this event)
                if eventsToProcess.contains(where: { $0.key.generic == .loadPage }) {
                    if self.currentlyHandlingPageLoad {
                        eventsToProcess = eventsToProcess.filter { $0.key.generic != .loadPage }
                    }
                    else {
                        self.currentlyHandlingPageLoad = true
                    }
                }
                defer {
                    if self.currentlyHandlingPageLoad {
                        self.currentlyHandlingPageLoad = false
                    }
                }
                
                /// If there are no events we want to process then just return the current state
                guard !eventsToProcess.isEmpty else { return currentState }
                
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
                            cache: self.itemCache
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
                                    
                                case (GenericObservableKey(.messageCreatedInAnyConversation), let event as MessageEvent):
                                    insertedIds.insert(event.threadId)
                                    
                                case (.conversationDeleted, let event as ConversationEvent):
                                    deletedIds.insert(event.id)
                                    
                                default: break
                            }
                        }
                        
                        try await dependencies[singleton: .storage].readAsync { db in
                            /// Update the `unreadMessageRequestThreadCount` if needed (since multiple events need this)
                            if databaseEvents.contains(where: { $0.requiresMessageRequestCountUpdate }) {
                                unreadMessageRequestThreadCount = try SessionThread
                                    .unreadMessageRequestsCountQuery(userSessionId: userSessionId)
                                    .fetchOne(db)
                                    .defaulting(to: 0)
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
                                        userSessionId: userSessionId,
                                        groupSQL: SessionThreadViewModel.groupSQL,
                                        orderSQL: SessionThreadViewModel.homeOrderSQL,
                                        ids: Array(idsNeedingRequery) + loadResult.newIds
                                    )
                                    .fetchAll(db)
                            )
                        }
                        
                        /// Update the `itemCache` with the newly fetched values
                        fetchedConversations.forEach { self.itemCache[$0.threadId] = $0 }
                        
                        /// Remove any deleted values
                        deletedIds.forEach { id in self.itemCache.removeValue(forKey: id) }
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
                    switch (event.value as? ProfileEvent)?.change {
                        case .name(let name): userProfile = userProfile.with(name: name)
                        case .nickname(let nickname): userProfile = userProfile.with(nickname: nickname)
                        case .displayPictureUrl(let url): userProfile = userProfile.with(displayPictureUrl: url)
                        default: break
                    }
                }
                groupedOtherEvents?[.setting]?.forEach { event in
                    switch event.key {
                        case .setting(.hasViewedSeed):
                            showViewedSeedBanner = (
                                (event.value as? Bool).map { hasViewedSeed in !hasViewedSeed } ??
                                currentState.showViewedSeedBanner
                            )
                            
                        case .setting(.hasHiddenMessageRequests):
                            hasHiddenMessageRequests = (
                                (event.value as? Bool) ??
                                currentState.hasHiddenMessageRequests
                            )
                            
                        default: break
                    }
                }
                
                /// Generate the new state
                let updatedState: State = State(
                    viewState: (loadResult.info.totalCount == 0 ?
                        .empty(isNewUser: (startedAsNewUser && previousState == nil)) :
                        .loaded
                    ),
                    userProfile: userProfile,
                    showViewedSeedBanner: showViewedSeedBanner,
                    hasHiddenMessageRequests: hasHiddenMessageRequests,
                    unreadMessageRequestThreadCount: unreadMessageRequestThreadCount,
                    loadedPageInfo: loadResult.info,
                    sections: HomeViewModel.process(
                        hasHiddenMessageRequests: hasHiddenMessageRequests,
                        unreadMessageRequestThreadCount: unreadMessageRequestThreadCount,
                        conversations: loadResult.info.currentIds.compactMap { self.itemCache[$0] },
                        loadedInfo: loadResult.info,
                        using: dependencies
                    )
                )
                
                return updatedState
            }
            .assign { [weak self] updatedValue in self?.state = updatedValue }
    }
    
    internal func extractIdsNeedingRequery(
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
    
    private static func process(
        hasHiddenMessageRequests: Bool,
        unreadMessageRequestThreadCount: Int,
        conversations: [SessionThreadViewModel],
        loadedInfo: PagedData.LoadedInfo<SessionThreadViewModel.ID>,
        using dependencies: Dependencies
    ) -> [SectionModel] {
        return [
            /// If the message request section is hidden or there are no unread message requests then hide the message request banner
            (hasHiddenMessageRequests || unreadMessageRequestThreadCount == 0 ?
                [] :
                [SectionModel(
                    section: .messageRequests,
                    elements: [
                        SessionThreadViewModel(
                            threadId: SessionThreadViewModel.messageRequestsSectionId,
                            unreadCount: UInt(unreadMessageRequestThreadCount),
                            using: dependencies
                        )
                    ]
                )]
            ),
            [
                SectionModel(
                    section: .threads,
                    elements: conversations.map { viewModel -> SessionThreadViewModel in
                        viewModel.populatingPostQueryData(
                            recentReactionEmoji: nil,
                            openGroupCapabilities: nil,
                            // TODO: [Database Relocation] Do we need all of these????
                            currentUserSessionIds: [dependencies[cache: .general].sessionId.hexString],
                            wasKickedFromGroup: (
                                viewModel.threadVariant == .group &&
                                dependencies.mutate(cache: .libSession) { cache in
                                    cache.wasKickedFromGroup(groupSessionId: SessionId(.group, hex: viewModel.threadId))
                                }
                            ),
                            groupIsDestroyed: (
                                viewModel.threadVariant == .group &&
                                dependencies.mutate(cache: .libSession) { cache in
                                    cache.groupIsDestroyed(groupSessionId: SessionId(.group, hex: viewModel.threadId))
                                }
                            ),
                            threadCanWrite: false  // Irrelevant for the HomeViewModel
                        )
                    }
                )
            ],
            (!conversations.isEmpty && loadedInfo.hasNextPage ?
                [SectionModel(section: .loadMore)] :
                []
            )
        ].flatMap { $0 }
    }
    
    // MARK: - Functions
    
    public func loadNextPage() {
        Task { [loadedPageInfo = state.loadedPageInfo, observationManager = dependencies[singleton: .observationManager]] in
            await observationManager.notify(
                .loadPage(HomeViewModel.observationName),
                value: LoadPageEvent.nextPage(lastIndex: loadedPageInfo.lastIndex)
            )
        }
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
                
            case (_, .profile): return .other
            case (.setting(.hasViewedSeed), _): return .other
                
            case (.messageRequestUnreadMessageReceived, _), (.messageRequestAccepted, _),
                (.messageRequestDeleted, _), (.messageRequestMessageRead, _):
                return .databaseQuery
            case (_, .loadPage): return .databaseQuery
            case (.conversationCreated, _): return .databaseQuery
            case (.messageCreatedInAnyConversation, _): return .databaseQuery
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
