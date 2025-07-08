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
    private var itemCache: [Int64: SessionThreadViewModel] = [:]

    
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
                .unreadMessageRequestMessageReceived,
                .messageRequestAccepted,
                .loadPage(HomeViewModel.observationName),
                .profile(userProfile.id),
                .setting(Setting.BoolKey.hasViewedSeed),
                .conversationCreated
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
                            key: .unreadMessageRequestMessageReceived,
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
                let splitEvents: [Bool: [ObservedEvent]] = eventsToProcess
                    .grouped(by: \.requiresDatabaseQueryForHomeViewModel)
                
                /// Handle database events first
                if let databaseEvents: Set<ObservedEvent> = splitEvents[true].map({ Set($0) }) {
                    do {
                        var fetchedConversations: [SessionThreadViewModel] = []
                        let rowIdsNeedingRequery: Set<Int64> = self.extractRowIdsNeedingRequery(
                            events: databaseEvents,
                            cache: self.itemCache
                        )
                        
                        try await dependencies[singleton: .storage].readAsync { db in
                            /// Update the `unreadMessageRequestThreadCount` if needed (since multiple events need this)
                            if databaseEvents.contains(where: { $0.key == .unreadMessageRequestMessageReceived || $0.key == .messageRequestAccepted }) {
                                unreadMessageRequestThreadCount = try SessionThread
                                    .unreadMessageRequestsCountQuery(userSessionId: userSessionId)
                                    .fetchOne(db)
                                    .defaulting(to: 0)
                            }
                            
                            /// Handle individual events
                            try databaseEvents.forEach { event in
                                switch (event.key.generic, event.value) {
                                    case (GenericObservableKey(.messageRequestAccepted), let threadId as String):
                                        loadResult = try loadResult.insertIfVisible(db, id: threadId)
                                        
                                    case (.loadPage, let value as LoadPageEvent):
                                        loadResult = try value.load(db, current: loadResult)
                                        
                                    default: break
                                }
                            }
                            
                            /// Fetch any records needed
                            fetchedConversations.append(
                                contentsOf: try SessionThreadViewModel
                                    .query(
                                        userSessionId: userSessionId,
                                        groupSQL: SessionThreadViewModel.groupSQL,
                                        orderSQL: SessionThreadViewModel.homeOrderSQL,
                                        rowIds: Array(rowIdsNeedingRequery) + loadResult.newRowIds
                                    )
                                    .fetchAll(db)
                            )
                        }
                        
                        /// Update the `itemCache` with the newly fetched values
                        fetchedConversations.forEach { self.itemCache[$0.rowId] = $0 }
                    } catch {
                        let eventList: String = databaseEvents.map { $0.key.rawValue }.joined(separator: ", ")
                        Log.critical(.homeViewModel, "Failed to fetch state for events [\(eventList)], due to error: \(error)")
                    }
                }
                
                /// Then handle non-database events
                splitEvents[false]?.forEach { event in
                    switch (event.key.generic, (event.value as? ProfileEvent)?.change) {
                        case (.profile, .name(let name)):
                            userProfile = userProfile.with(name: name)
                            
                        case (.profile, .nickname(let nickname)):
                            userProfile = userProfile.with(nickname: nickname)
                            
                        case (.profile, .displayPictureUrl(let url)):
                            userProfile = userProfile.with(displayPictureUrl: url)
                            
                        case (.setting, _) where Setting.BoolKey(rawValue: event.key.rawValue) == .hasViewedSeed:
                            showViewedSeedBanner = (
                                (event.value as? Bool).map { hasViewedSeed in !hasViewedSeed } ??
                                currentState.showViewedSeedBanner
                            )
                            
                        case (.setting, _) where Setting.BoolKey(rawValue: event.key.rawValue) == .hasHiddenMessageRequests:
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
                        conversations: loadResult.info.currentRowIds.compactMap { self.itemCache[$0] },
                        loadedInfo: loadResult.info,
                        using: dependencies
                    )
                )
                
                return updatedState
            }
            .assign { [weak self] updatedValue in self?.state = updatedValue }
    }
    
    internal func extractRowIdsNeedingRequery(
        events: Set<ObservedEvent>,
        cache: [Int64: SessionThreadViewModel]
    ) -> Set<Int64> {
        let conversationIds: Set<String> = events.reduce(into: []) { result, event in
            switch event.key.generic {
                case .conversationUpdated, .conversationDeleted:
                    guard let id: String = (event.value as? ConversationEvent)?.id else {
                        return
                    }
                    
                    result.insert(id)
                
                case .typingIndicator:
                    guard let id: String = (event.value as? TypingIndicatorEvent)?.threadId else {
                        return
                    }
                    
                    result.insert(id)
                    
                case .messageCreated, .messageUpdated, .messageDeleted:
                    guard let id: String = (event.value as? MessageEvent)?.threadId else {
                        return
                    }
                    
                    result.insert(id)
                    
                case .profile:
                    guard let id: String = (event.value as? ProfileEvent)?.id else {
                        return
                    }
                    
                    result.insert(
                        contentsOf: Set(cache.values
                            .filter { threadViewModel -> Bool in
                                threadViewModel.threadId == id ||
                                threadViewModel.allProfileIds.contains(id)
                            }
                            .map { $0.threadId })
                    )
                
                case .contact:
                    guard let id: String = (event.value as? ContactEvent)?.id else {
                        return
                    }
                    
                    result.insert(
                        contentsOf: Set(cache.values
                            .filter { threadViewModel -> Bool in
                                threadViewModel.threadId == id ||
                                threadViewModel.allProfileIds.contains(id)
                            }
                            .map { $0.threadId })
                    )
                    
                default: break
            }
        }
        
        return Set(conversationIds.compactMap { conversationId in
            cache.values.first { $0.threadId == conversationId }?.rowId
        })
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
                    elements: conversations
                        .sorted { lhs, rhs -> Bool in
                            guard lhs.threadPinnedPriority == rhs.threadPinnedPriority else {
                                return lhs.threadPinnedPriority > rhs.threadPinnedPriority
                            }
                            
                            return lhs.lastInteractionDate > rhs.lastInteractionDate
                        }
                        .map { viewModel -> SessionThreadViewModel in
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

private extension ObservedEvent {
    var requiresDatabaseQueryForHomeViewModel: Bool {
        /// Any event requires a database query
        switch self.key.generic {
            case .loadPage: return true
            case GenericObservableKey(.unreadMessageRequestMessageReceived): return true
            case GenericObservableKey(.messageRequestAccepted): return true
            case GenericObservableKey(.conversationCreated): return true
            case .typingIndicator: return true
                
            /// We only observe events from records we have explicitly fetched so if we get an event for one of these then we need to
            /// trigger an update
            case .conversationUpdated, .conversationDeleted: return true
            case .messageCreated, .messageUpdated, .messageDeleted: return true
            case .profile: return true
            case .contact: return true
            default: return false
        }
    }
}
