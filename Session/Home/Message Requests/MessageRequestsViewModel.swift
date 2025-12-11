// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import DifferenceKit
import SessionUIKit
import SessionMessagingKit
import SessionUtilitiesKit
import SignalUtilitiesKit

// MARK: - Log.Category

public extension Log.Category {
    static let messageRequestsViewModel: Log.Category = .create("MessageRequestsViewModel", defaultLevel: .warn)
}

// MARK: - MessageRequestsViewModel

class MessageRequestsViewModel: SessionTableViewModel, NavigatableStateHolder, ObservableTableSource, PagedObservationSource {
    typealias TableItem = ConversationInfoViewModel
    typealias PagedTable = SessionThread
    typealias PagedDataModel = ConversationInfoViewModel
    
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
    public let observableState: ObservableTableSourceState<Section, ConversationInfoViewModel> = ObservableTableSourceState()
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
        
        self.observationTask = ObservationBuilder
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
    
    // MARK: - Content
    
    public let title: String = "sessionMessageRequests".localized()
    public let initialLoadMessage: String? = "loading".localized()
    public let emptyStateTextPublisher: AnyPublisher<String?, Never> = Just("messageRequestsNonePending".localized())
        .eraseToAnyPublisher()
    public let cellType: SessionTableViewCellType = .fullConversation
    
    @available(*, deprecated, message: "No longer used now that we have updated this ViewModel to use the new ObservationBuilder mechanism")
    var pagedDataObserver: PagedDatabaseObserver<SessionThread, ConversationInfoViewModel>? = nil
    
    // MARK: - State

    public struct State: ObservableKeyProvider {
        enum ViewState: Equatable {
            case loading
            case empty
            case loaded
        }
        
        let viewState: ViewState
        let loadedPageInfo: PagedData.LoadedInfo<ConversationInfoViewModel.ID>
        let dataCache: ConversationDataCache
        let itemCache: [ConversationInfoViewModel.ID: ConversationInfoViewModel]
        
        @MainActor public func sections(viewModel: MessageRequestsViewModel) -> [SectionModel] {
            MessageRequestsViewModel.sections(state: self, viewModel: viewModel)
        }
        
        public var observedKeys: Set<ObservableKey> {
            var result: Set<ObservableKey> = [
                .appLifecycle(.willEnterForeground),
                .databaseLifecycle(.resumed),
                .loadPage(MessageRequestsViewModel.self),
                .messageRequestUnreadMessageReceived,
                .messageRequestAccepted,
                .messageRequestDeleted,
                .conversationCreated,
                .anyMessageCreatedInAnyConversation
            ]
            
            result.insert(contentsOf: Set(itemCache.values.flatMap { $0.observedKeys }))
            
            return result
        }
        
        static func initialState(using dependencies: Dependencies) -> State {
            let userSessionId: SessionId = dependencies[cache: .general].sessionId
            
            return State(
                viewState: .loading,
                loadedPageInfo: PagedData.LoadedInfo(
                    record: SessionThread.self,
                    pageSize: MessageRequestsViewModel.pageSize,
                    requiredJoinSQL: ConversationInfoViewModel.requiredJoinSQL,
                    filterSQL: ConversationInfoViewModel.messageRequestsFilterSQL(userSessionId: userSessionId),
                    groupSQL: nil,
                    orderSQL: ConversationInfoViewModel.messageRequestsOrderSQL
                ),
                dataCache: ConversationDataCache(
                    userSessionId: userSessionId,
                    context: ConversationDataCache.Context(
                        source: .conversationList,
                        requireFullRefresh: false,
                        requireAuthMethodFetch: false,
                        requiresMessageRequestCountUpdate: false,
                        requiresInitialUnreadInteractionInfo: false,
                        requireRecentReactionEmojiUpdate: false
                    )
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
        var loadResult: PagedData.LoadResult = previousState.loadedPageInfo.asResult
        var dataCache: ConversationDataCache = previousState.dataCache
        var itemCache: [ConversationInfoViewModel.ID: ConversationInfoViewModel] = previousState.itemCache
        
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
        guard isInitialQuery || !eventsToProcess.isEmpty else { return previousState }
        
        /// Split the events between those that need database access and those that don't
        let changes: EventChangeset = eventsToProcess.split(by: { $0.handlingStrategy })
        let loadPageEvent: LoadPageEvent? = changes.latestGeneric(.loadPage, as: LoadPageEvent.self)
        
        /// Update the context
        dataCache.withContext(
            source: .conversationList,
            requireFullRefresh: changes.containsAny(
                .appLifecycle(.willEnterForeground),
                .databaseLifecycle(.resumed)
            )
        )
        
        /// Process cache updates first
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
                Log.warn(.messageRequestsViewModel, "Failed to handle \(changes.libSessionEvents.count) libSession event(s) due to error: \(error).")
            }
        }
        
        /// Peform any database changes
        if !dependencies[singleton: .storage].isSuspended, fetchRequirements.needsAnyFetch {
            do {
                try await dependencies[singleton: .storage].readAsync { db in
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
                Log.critical(.messageRequestsViewModel, "Failed to fetch state for events [\(eventList)], due to error: \(error)")
            }
        }
        else if !changes.databaseEvents.isEmpty {
            Log.warn(.messageRequestsViewModel, "Ignored \(changes.databaseEvents.count) database event(s) sent while storage was suspended.")
        }
        
        /// Regenerate the `itemCache` now that the `dataCache` is updated
        itemCache = loadResult.info.currentIds.reduce(into: [:]) { result, id in
            guard let thread: SessionThread = dataCache.thread(for: id) else { return }
            
            result[id] = ConversationInfoViewModel(
                thread: thread,
                dataCache: dataCache,
                using: dependencies
            )
        }
        
        /// Generate the new state
        return State(
            viewState: (loadResult.info.totalCount == 0 ? .empty : .loaded),
            loadedPageInfo: loadResult.info,
            dataCache: dataCache,
            itemCache: itemCache,
        )
    }
    
    private static func sections(state: State, viewModel: MessageRequestsViewModel) -> [SectionModel] {
        return [
            [
                SectionModel(
                    section: .threads,
                    elements: state.loadedPageInfo.currentIds
                        .compactMap { state.itemCache[$0] }
                        .map { threadInfo -> SessionCell.Info<ConversationInfoViewModel> in
                            return SessionCell.Info(
                                id: threadInfo,
                                accessibility: Accessibility(
                                    identifier: "Message request"
                                ),
                                onTap: { [weak viewModel, dependencies = viewModel.dependencies] in
                                    let viewController: ConversationVC = ConversationVC(
                                        threadInfo: threadInfo,
                                        focusedInteractionInfo: nil,
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
                .map { ($0.id, $0.variant) }
            
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
                let threadInfo: ConversationInfoViewModel = section.elements[indexPath.row].id
                
                return UIContextualAction.configuration(
                    for: UIContextualAction.generateSwipeActions(
                        [.block, .delete],
                        for: .trailing,
                        indexPath: indexPath,
                        tableView: tableView,
                        threadInfo: threadInfo,
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
    var handlingStrategy: EventHandlingStrategy {
        let threadInfoStrategy: EventHandlingStrategy? = ConversationInfoViewModel.handlingStrategy(for: self)
        let localStrategy: EventHandlingStrategy = {
            switch (key, key.generic) {
                case (.appLifecycle(.willEnterForeground), _): return .databaseQuery
                case (.messageRequestUnreadMessageReceived, _), (.messageRequestAccepted, _),
                    (.messageRequestDeleted, _), (.messageRequestMessageRead, _):
                    return .databaseQuery
                case (_, .loadPage): return .databaseQuery
                
                default: return .directCacheUpdate
            }
        }()
        
        return localStrategy.union(threadInfoStrategy ?? .none)
    }
}

// FIXME: Remove this when we ditch `PagedDataObservable`
extension ConversationInfoViewModel: @retroactive FetchableRecordWithRowId {
    public var rowId: Int64 { -1 }
    public init(row: GRDB.Row) throws { throw StorageError.objectNotFound }
}
