// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import DifferenceKit
import SessionUIKit
import SessionMessagingKit
import SessionUtilitiesKit
import SignalUtilitiesKit

@MainActor
class MessageRequestsViewModel: SessionTableViewModel, NavigatableStateHolder, ObservableTableSource, PagedObservationSource {
    typealias TableItem = SessionThreadViewModel
    typealias PagedTable = SessionThread
    typealias PagedDataModel = SessionThreadViewModel
    
    // MARK: - Section
    
    public enum Section: SessionTableSection {
        case threads
        case loadMore
        
        var style: SessionTableSectionStyle {
            switch self {
                case .threads: return .none
                case .loadMore: return .loadMore
            }
        }
    }
    
    // MARK: - Variables
    
    nonisolated fileprivate static let observationName: String = "MessageRequestsViewModel"    // stringlint:ignore
    public static let pageSize: Int = (UIDevice.current.isIPad ? 20 : 15)
    
    public let dependencies: Dependencies
    public let state: TableDataState<Section, TableItem> = TableDataState()
    public let observableState: ObservableTableSourceState<Section, SessionThreadViewModel> = ObservableTableSourceState()
    public let navigatableState: NavigatableState = NavigatableState()
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
        self.internalState = State.initialState(using: dependencies)
        
        self.bindState()
    }
    
    // MARK: - Content
    
    public let title: String = "sessionMessageRequests".localized()
    public let initialLoadMessage: String? = "loading".localized()
    public let emptyStateTextPublisher: AnyPublisher<String?, Never> = Just("messageRequestsNonePending".localized())
        .eraseToAnyPublisher()
    public let cellType: SessionTableViewCellType = .fullConversation
    
    @available(*, deprecated, message: "No longer used now that we have updated this ViewModel to use the new ObservationBuilder mechanism")
    var pagedDataObserver: PagedDatabaseObserver<SessionThread, SessionThreadViewModel>? = nil
    
    // MARK: - State

    public struct State: ObservableKeyProvider {
        enum ViewState: Equatable {
            case loading
            case empty
            case loaded
        }
        
        let viewState: ViewState
        let loadedPageInfo: PagedData.LoadedInfo<SessionThreadViewModel.ID>
        let sections: [SectionModel]
        
        public var observedKeys: Set<ObservableKey> {
            var result: Set<ObservableKey> = [
                .unreadMessageRequestMessageReceived,
                .messageRequestAccepted,
                .loadPage(MessageRequestsViewModel.observationName),
                .conversationCreated,
                .messageCreatedInAnyConversation
            ]
            
            sections.filter { $0.model == .threads }.first?.elements.forEach { item in
                result.insert(contentsOf: [
                    .conversationUpdated(item.id.threadId),
                    .conversationDeleted(item.id.threadId),
                    .messageCreated(threadId: item.id.threadId),
                    .messageUpdated(
                        id: item.id.interactionId,
                        threadId: item.id.threadId
                    ),
                    .messageDeleted(
                        id: item.id.interactionId,
                        threadId: item.id.threadId
                    )
                ])
            }
            
            return result
        }
        
        @MainActor static func initialState(using dependencies: Dependencies) -> State {
            return State(
                viewState: .loading,
                loadedPageInfo: PagedData.LoadedInfo(
                    record: SessionThreadViewModel.self,
                    pageSize: MessageRequestsViewModel.pageSize,
                    /// **Note:** This `optimisedJoinSQL` value includes the required minimum joins needed
                    /// for the query but differs from the JOINs that are actually used for performance reasons as the
                    /// basic logic can be simpler for where it's used
                    requiredJoinSQL: SessionThreadViewModel.optimisedJoinSQL,
                    filterSQL: SessionThreadViewModel.messageRequestsFilterSQL(
                        userSessionId: dependencies[cache: .general].sessionId
                    ),
                    groupSQL: SessionThreadViewModel.groupSQL,
                    orderSQL: SessionThreadViewModel.messageRequestsOrderSQL
                ),
                sections: []
            )
        }
    }
    
    /// This value is the current state of the view
    private(set) var internalState: State
    private var observationTask: Task<Void, Never>?
    private var previousSections: [SectionModel] = []
    
    private func bindState() {
        let initialState: State = State.initialState(using: dependencies)
        
        observationTask = ObservationBuilder
            .debounce(for: .milliseconds(250))
            .using(manager: dependencies[singleton: .observationManager])
            .query { [weak self, userSessionId, dependencies] previousState, events in
                guard let self = self else { return initialState }
                
                /// Store mutable copies of the data to update
                let currentState: State = (previousState ?? initialState)
                var loadResult: PagedData.LoadResult = currentState.loadedPageInfo.asResult
                
                /// Store a local copy of the events so we can manipulate it based on the state changes
                var eventsToProcess: [ObservedEvent] = events
                
                /// If we have no previous state then we need to fetch the initial state
                if previousState == nil {
                    /// Insert a fake event to force the initial page load
                    eventsToProcess.append(ObservedEvent(
                        key: .loadPage(MessageRequestsViewModel.observationName),
                        value: LoadPageEvent.initial
                    ))
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
                    .grouped(by: \.requiresDatabaseQueryForMessageRequestsViewModel)
                
                /// Handle database events first
                if let databaseEvents: Set<ObservedEvent> = splitEvents[true].map({ Set($0) }) {
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
                                        orderSQL: SessionThreadViewModel.messageRequestsOrderSQL,
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
                
                /// Generate the new state
                let updatedState: State = State(
                    viewState: (loadResult.info.totalCount == 0 ? .empty : .loaded),
                    loadedPageInfo: loadResult.info,
                    sections: self.process(
                        conversations: loadResult.info.currentIds.compactMap { self.itemCache[$0] },
                        loadedInfo: loadResult.info,
                        using: dependencies
                    )
                )
                
                return updatedState
            }
            .assign { [weak self] updatedValue in
                // FIXME: To slightly reduce the size of the changes this new observation mechanism is currently wired into the old SessionTableViewController observation mechanism, we should refactor it so everything uses the new mechanism
                self?.internalState = updatedValue
                self?.pendingTableDataSubject.send(updatedValue.sections)
            }
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
    
    private func process(
        conversations: [SessionThreadViewModel],
        loadedInfo: PagedData.LoadedInfo<SessionThreadViewModel.ID>,
        using dependencies: Dependencies
    ) -> [SectionModel] {
        return [
            [
                SectionModel(
                    section: .threads,
                    elements: conversations.map { [dependencies] viewModel -> SessionCell.Info<SessionThreadViewModel> in
                        SessionCell.Info(
                            id: viewModel.populatingPostQueryData(
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
                                threadCanWrite: false  // Irrelevant for the MessageRequestsViewModel
                            ),
                            accessibility: Accessibility(
                                identifier: "Message request"
                            ),
                            onTap: { [weak self, dependencies] in
                                let viewController: ConversationVC = ConversationVC(
                                    threadId: viewModel.threadId,
                                    threadVariant: viewModel.threadVariant,
                                    using: dependencies
                                )
                                self?.transitionToScreen(viewController, transitionType: .push)
                            }
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
    
    lazy var footerButtonInfo: AnyPublisher<SessionButton.Info?, Never> = observableState
        .pendingTableDataSubject
        .map { [dependencies] (currentThreadData: [SectionModel]) in
            let threadInfo: [(id: String, variant: SessionThread.Variant)] = (currentThreadData
                .first(where: { $0.model == .threads })?
                .elements
                .map { ($0.id.id, $0.id.threadVariant) })
                .defaulting(to: [])
            
            return SessionButton.Info(
                style: .destructive,
                title: "clearAll".localized(),
                isEnabled: !threadInfo.isEmpty,
                accessibility: Accessibility(
                    identifier: "Clear all"
                ),
                onTap: { [weak self] in
                    let modal: ConfirmationModal = ConfirmationModal(
                        info: ConfirmationModal.Info(
                            title: "clearAll".localized(),
                            body: .text("messageRequestsClearAllExplanation".localized()),
                            confirmTitle: "clear".localized(),
                            confirmStyle: .danger,
                            cancelStyle: .alert_text,
                            onConfirm: { _ in
                                // Clear the requests
                                dependencies[singleton: .storage].write { db in
                                    // Remove the one-to-one requests
                                    try SessionThread.deleteOrLeave(
                                        db,
                                        type: .deleteContactConversationAndMarkHidden,
                                        threadIds: threadInfo
                                            .filter { _, variant in variant == .contact }
                                            .map { id, _ in id },
                                        threadVariant: .contact,
                                        using: dependencies
                                    )
                                    
                                    // Remove the group invites
                                    try SessionThread.deleteOrLeave(
                                        db,
                                        type: .deleteGroupAndContent,
                                        threadIds: threadInfo
                                            .filter { _, variant in variant == .legacyGroup || variant == .group }
                                            .map { id, _ in id },
                                        threadVariant: .group,
                                        using: dependencies
                                    )
                                }
                            }
                        )
                    )

                    self?.transitionToScreen(modal, transitionType: .present)
                }
            )
        }
        .eraseToAnyPublisher()
    
    // MARK: - Functions
    
    func canEditRow(at indexPath: IndexPath) -> Bool {
        let section: SectionModel = tableData[indexPath.section]
        
        return (section.model == .threads)
    }
    
    func trailingSwipeActionsConfiguration(forRowAt indexPath: IndexPath, in tableView: UITableView, of viewController: UIViewController) -> UISwipeActionsConfiguration? {
        let section: SectionModel = tableData[indexPath.section]
        
        switch section.model {
            case .threads:
                let threadViewModel: SessionThreadViewModel = section.elements[indexPath.row].id
                
                return UIContextualAction.configuration(
                    for: UIContextualAction.generateSwipeActions(
                        [.block, .delete],
                        for: .trailing,
                        indexPath: indexPath,
                        tableView: tableView,
                        threadViewModel: threadViewModel,
                        viewController: viewController,
                        navigatableStateHolder: nil,
                        using: dependencies
                    )
                )
                
            default: return nil
        }
    }
    
    func loadPageBefore() {
        Task { [loadedPageInfo = internalState.loadedPageInfo, observationManager = dependencies[singleton: .observationManager]] in
            await observationManager.notify(
                .loadPage(MessageRequestsViewModel.observationName),
                value: LoadPageEvent.previousPage(firstIndex: loadedPageInfo.firstIndex)
            )
        }
    }
    
    func loadPageAfter() {
        Task { [loadedPageInfo = internalState.loadedPageInfo, observationManager = dependencies[singleton: .observationManager]] in
            await observationManager.notify(
                .loadPage(MessageRequestsViewModel.observationName),
                value: LoadPageEvent.nextPage(lastIndex: loadedPageInfo.lastIndex)
            )
        }
    }
}

// MARK: - Convenience

private extension ObservedEvent {
    var requiresDatabaseQueryForMessageRequestsViewModel: Bool {
        /// Any event requires a database query
        switch self.key.generic {
            case .loadPage: return true
            case GenericObservableKey(.unreadMessageRequestMessageReceived): return true
            case GenericObservableKey(.messageRequestAccepted): return true
            case GenericObservableKey(.conversationCreated): return true
            case GenericObservableKey(.messageCreatedInAnyConversation): return true
                
            /// We only observe events from records we have explicitly fetched so if we get an event for one of these then we need to
            /// trigger an update
            case .conversationUpdated, .conversationDeleted: return true
            case .messageCreated, .messageUpdated, .messageDeleted: return true
            default: return false
        }
    }
}
