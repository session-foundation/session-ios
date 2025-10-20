// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import DifferenceKit
import SessionUIKit
import SessionMessagingKit
import SessionUtilitiesKit
import SignalUtilitiesKit

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
    
    public static let pageSize: Int = (UIDevice.current.isIPad ? 20 : 15)
    
    public let dependencies: Dependencies
    public let state: TableDataState<Section, TableItem> = TableDataState()
    public let observableState: ObservableTableSourceState<Section, SessionThreadViewModel> = ObservableTableSourceState()
    public let navigatableState: NavigatableState = NavigatableState()
    private let userSessionId: SessionId
    
    /// This value is the current state of the view
    @MainActor @Published private(set) var internalState: State
    private var observationTask: Task<Void, Never>?
    
    // MARK: - Initialization
    
    @MainActor init(using dependencies: Dependencies) {
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
        let itemCache: [String: SessionThreadViewModel]
        
        @MainActor public func sections(viewModel: MessageRequestsViewModel) -> [SectionModel] {
            MessageRequestsViewModel.sections(state: self, viewModel: viewModel)
        }
        
        public var observedKeys: Set<ObservableKey> {
            var result: Set<ObservableKey> = [
                .loadPage(MessageRequestsViewModel.self),
                .messageRequestUnreadMessageReceived,
                .messageRequestAccepted,
                .messageRequestDeleted,
                .conversationCreated,
                .anyMessageCreatedInAnyConversation
            ]
            
            itemCache.values.forEach { item in
                result.insert(contentsOf: [
                    .conversationUpdated(item.threadId),
                    .conversationDeleted(item.threadId),
                    .messageCreated(threadId: item.threadId),
                    .messageUpdated(
                        id: item.interactionId,
                        threadId: item.threadId
                    ),
                    .messageDeleted(
                        id: item.interactionId,
                        threadId: item.threadId
                    )
                ])
            }
            
            return result
        }
        
        static func initialState(using dependencies: Dependencies) -> State {
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
                itemCache: [:]
            )
        }
    }
    
    @MainActor private func bindState() {
        observationTask = ObservationBuilder
            .initialValue(self.internalState)
            .debounce(for: .milliseconds(250))
            .using(dependencies: dependencies)
            .query(MessageRequestsViewModel.queryState)
            .assign { [weak self] updatedState in
                guard let self = self else { return }
                
                // FIXME: To slightly reduce the size of the changes this new observation mechanism is currently wired into the old SessionTableViewController observation mechanism, we should refactor it so everything uses the new mechanism
                self.internalState = updatedState
                self.pendingTableDataSubject.send(updatedState.sections(viewModel: self))
            }
    }
    
    @Sendable private static func queryState(
        previousState: State,
        events: [ObservedEvent],
        isInitialQuery: Bool,
        using dependencies: Dependencies
    ) async -> State {
        var loadResult: PagedData.LoadResult = previousState.loadedPageInfo.asResult
        var itemCache: [String: SessionThreadViewModel] = previousState.itemCache
        
        /// Store a local copy of the events so we can manipulate it based on the state changes
        var eventsToProcess: [ObservedEvent] = events
        
        if isInitialQuery {
            /// Insert a fake event to force the initial page load
            eventsToProcess.append(ObservedEvent(
                key: .loadPage(MessageRequestsViewModel.self),
                value: LoadPageEvent.initial
            ))
        }
        
        /// If there are no events we want to process then just return the current state
        guard !eventsToProcess.isEmpty else { return previousState }
        
        /// Split the events between those that need database access and those that don't
        let splitEvents: [Bool: [ObservedEvent]] = eventsToProcess
            .grouped(by: \.requiresDatabaseQueryForMessageRequestsViewModel)
        
        /// Handle database events first
        if let databaseEvents: Set<ObservedEvent> = splitEvents[true].map({ Set($0) }) {
            do {
                var fetchedConversations: [SessionThreadViewModel] = []
                let idsNeedingRequery: Set<String> = extractIdsNeedingRequery(
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
                                userSessionId: dependencies[cache: .general].sessionId,
                                groupSQL: SessionThreadViewModel.groupSQL,
                                orderSQL: SessionThreadViewModel.messageRequestsOrderSQL,
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
        
        /// Generate the new state
        return State(
            viewState: (loadResult.info.totalCount == 0 ? .empty : .loaded),
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
    
    private static func sections(state: State, viewModel: MessageRequestsViewModel) -> [SectionModel] {
        return [
            [
                SectionModel(
                    section: .threads,
                    elements: state.loadedPageInfo.currentIds
                        .compactMap { state.itemCache[$0] }
                        .map { conversation -> SessionCell.Info<SessionThreadViewModel> in
                            // TODO: [Database Relocation] Source profile data via a separate query for efficiency
                            var customProfile: Profile?
                            
                            if conversation.id == viewModel.dependencies[cache: .general].sessionId.hexString {
                                customProfile = viewModel.dependencies.mutate(cache: .libSession) { $0.profile }
                            }
                            
                            return SessionCell.Info(
                                id: conversation.populatingPostQueryData(
                                    threadDisplayPictureUrl: customProfile?.displayPictureUrl,
                                    contactProfile: customProfile,
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
                                    threadCanWrite: false,  // Irrelevant for the MessageRequestsViewModel
                                    threadCanUpload: false  // Irrelevant for the MessageRequestsViewModel
                                ),
                                accessibility: Accessibility(
                                    identifier: "Message request"
                                ),
                                onTap: { [weak viewModel, dependencies = viewModel.dependencies] in
                                    let viewController: ConversationVC = ConversationVC(
                                        threadId: conversation.threadId,
                                        threadVariant: conversation.threadVariant,
                                        using: dependencies
                                    )
                                    viewModel?.transitionToScreen(viewController, transitionType: .push)
                                }
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
    
    lazy var footerButtonInfo: AnyPublisher<SessionButton.Info?, Never> = $internalState
        .map { [dependencies] state in
            // TODO: [Database Relocation] Looks like there is a bug where where the `clear all` button will only clear currently loaded message requests (so if there are more than 15 it'll only clear one page at a time)
            let threadInfo: [(id: String, variant: SessionThread.Variant)] = state.itemCache.values
                .map { ($0.threadId, $0.threadVariant) }
            
            return SessionButton.Info(
                style: .destructive,
                title: "clearAll".localized(),
                isEnabled: !state.itemCache.isEmpty,
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
                                dependencies[singleton: .storage].writeAsync { db in
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
    
    @MainActor func loadPageBefore() {
        dependencies.notifyAsync(
            key: .loadPage(MessageRequestsViewModel.self),
            value: LoadPageEvent.previousPage(firstIndex: internalState.loadedPageInfo.firstIndex)
        )
    }
    
    @MainActor func loadPageAfter() {
        dependencies.notifyAsync(
            key: .loadPage(MessageRequestsViewModel.self),
            value: LoadPageEvent.nextPage(lastIndex: internalState.loadedPageInfo.lastIndex)
        )
    }
}

// MARK: - Convenience

private extension ObservedEvent {
    var requiresDatabaseQueryForMessageRequestsViewModel: Bool {
        /// Any event requires a database query
        switch (key, key.generic) {
            case (_, .loadPage): return true
            case (.messageRequestUnreadMessageReceived, _): return true
            case (.messageRequestAccepted, _): return true
            case (.messageRequestDeleted, _): return true
            case (.conversationCreated, _): return true
            case (.anyMessageCreatedInAnyConversation, _): return true
                
            /// We only observe events from records we have explicitly fetched so if we get an event for one of these then we need to
            /// trigger an update
            case (_, .conversationUpdated), (_, .conversationDeleted): return true
            case (_, .messageCreated), (_, .messageUpdated), (_, .messageDeleted): return true
            default: return false
        }
    }
}
