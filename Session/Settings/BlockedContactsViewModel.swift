// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import DifferenceKit
import SessionUIKit
import SignalUtilitiesKit
import SessionMessagingKit
import SessionUtilitiesKit

// MARK: - Log.Category

private extension Log.Category {
    static let cat: Log.Category = .create("BlockedContactsViewModel", defaultLevel: .warn)
}

// MARK: - BlockedContactsViewModel

public class BlockedContactsViewModel: SessionTableViewModel, NavigatableStateHolder, ObservableTableSource, PagedObservationSource {
    public static let pageSize: Int = 30
    
    public let dependencies: Dependencies
    public let navigatableState: NavigatableState = NavigatableState()
    public let state: TableDataState<Section, TableItem> = TableDataState()
    public let observableState: ObservableTableSourceState<Section, TableItem> = ObservableTableSourceState()
    
    @available(*, deprecated, message: "No longer used now that we have updated this ViewModel to use the new ObservationBuilder mechanism")
    var pagedDataObserver: PagedDatabaseObserver<Contact, TableItem>? = nil
    
    /// This value is the current state of the view
    @MainActor @Published private(set) var internalState: State
    private var observationTask: Task<Void, Never>?
    
    // MARK: - Initialization
    
    @MainActor init(using dependencies: Dependencies) {
        self.dependencies = dependencies
        self.internalState = State.initialState(using: dependencies)
        
        self.bindState()
    }
    
    // MARK: - Section
    
    public enum Section: SessionTableSection {
        case contacts
        case loadMore
        
        public var style: SessionTableSectionStyle {
            switch self {
                case .contacts: return .none
                case .loadMore: return .loadMore
            }
        }
    }
    
    // MARK: - Content
    
    let title: String = "conversationsBlockedContacts".localized()
    let emptyStateTextPublisher: AnyPublisher<String?, Never> = Just("blockBlockedNone".localized())
            .eraseToAnyPublisher()
    
    lazy var footerButtonInfo: AnyPublisher<SessionButton.Info?, Never> = $internalState
        .map { state in
            SessionButton.Info(
                style: .destructive,
                title: "blockUnblock".localized(),
                isEnabled: !state.selectedIds.isEmpty,
                onTap: { [weak self] in self?.unblockTapped() }
            )
        }
        .eraseToAnyPublisher()
    
    // MARK: - State

    public struct State: ObservableKeyProvider {
        enum ViewState: Equatable {
            case loading
            case empty
            case loaded
        }
        
        let viewState: ViewState
        let selectedIds: Set<String>
        let loadedPageInfo: PagedData.LoadedInfo<TableItem.ID>
        let itemCache: [String: TableItem]
        
        @MainActor public func sections(viewModel: BlockedContactsViewModel) -> [SectionModel] {
            BlockedContactsViewModel.sections(state: self, viewModel: viewModel)
        }
        
        public var observedKeys: Set<ObservableKey> {
            var result: Set<ObservableKey> = [
                .loadPage(BlockedContactsViewModel.self),
                .clearSelection(BlockedContactsViewModel.self),
                .anyContactBlockedStatusChanged
            ]
            
            itemCache.values.forEach { item in
                result.insert(contentsOf: [
                    .contact(item.id),
                    .profile(item.id),
                    .updateSelection(BlockedContactsViewModel.self, item.id)
                ])
            }
            
            return result
        }
        
        static func initialState(using dependencies: Dependencies) -> State {
            return State(
                viewState: .loading,
                selectedIds: [],
                loadedPageInfo: PagedData.LoadedInfo(
                    record: Contact.self,
                    pageSize: BlockedContactsViewModel.pageSize,
                    /// **Note:** This `optimisedJoinSQL` value includes the required minimum joins needed
                    /// for the query but differs from the JOINs that are actually used for performance reasons as the
                    /// basic logic can be simpler for where it's used
                    requiredJoinSQL: TableItem.optimisedJoinSQL,
                    filterSQL: TableItem.filterSQL,
                    groupSQL: nil,
                    orderSQL: TableItem.orderSQL
                ),
                itemCache: [:]
            )
        }
    }
    
    @MainActor private func bindState() {
        observationTask = ObservationBuilder
            .initialValue(self.internalState)
            .debounce(for: .milliseconds(10))
            .using(dependencies: dependencies)
            .query(BlockedContactsViewModel.queryState)
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
        var selectedIds: Set<String> = previousState.selectedIds
        var itemCache: [String: TableItem] = previousState.itemCache
        
        /// Store a local copy of the events so we can manipulate it based on the state changes
        var eventsToProcess: [ObservedEvent] = events
        
        if isInitialQuery {
            /// Insert a fake event to force the initial page load
            eventsToProcess.append(ObservedEvent(
                key: .loadPage(BlockedContactsViewModel.self),
                value: LoadPageEvent.initial
            ))
        }
        
        /// If there are no events we want to process then just return the current state
        guard !eventsToProcess.isEmpty else { return previousState }
        
        /// Split the events between those that need database access and those that don't
        let splitEvents: [Bool: [ObservedEvent]] = eventsToProcess
            .grouped(by: \.requiresDatabaseQueryForBlockedContactsViewModel)
        
        /// Handle database events first
        if let databaseEvents: Set<ObservedEvent> = splitEvents[true].map({ Set($0) }) {
            do {
                var fetchedItems: [TableItem] = []
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
                        case (.contact, let event as ContactEvent),
                            (GenericObservableKey(.anyContactBlockedStatusChanged), let event as ContactEvent):
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
                    fetchedItems.append(
                        contentsOf: try TableItem
                            .query(
                                filterSQL: TableItem.filterSQL,
                                orderSQL: TableItem.orderSQL,
                                ids: Array(idsNeedingRequery) + loadResult.newIds
                            )
                            .fetchAll(db)
                    )
                }
                
                /// Update the `itemCache` with the newly fetched values
                fetchedItems.forEach { itemCache[$0.id] = $0 }
                
                /// Remove any deleted values
                deletedIds.forEach { id in itemCache.removeValue(forKey: id) }
            } catch {
                let eventList: String = databaseEvents.map { $0.key.rawValue }.joined(separator: ", ")
                Log.critical(.cat, "Failed to fetch state for events [\(eventList)], due to error: \(error)")
            }
        }
        
        /// Then handle non-database events
        let groupedOtherEvents: [GenericObservableKey: Set<ObservedEvent>]? = splitEvents[false]?
            .reduce(into: [:]) { result, event in
                result[event.key.generic, default: []].insert(event)
            }
        groupedOtherEvents?[.updateSelection]?.forEach { event in
            guard let value: UpdateSelectionEvent = event.value as? UpdateSelectionEvent else { return }
            
            if value.isSelected {
                selectedIds.insert(value.id)
            }
            else {
                selectedIds.remove(value.id)
            }
        }
        if groupedOtherEvents?[.clearSelection]?.isEmpty == false {
            selectedIds.removeAll()
        }
        
        /// Generate the new state
        return State(
            viewState: (loadResult.info.totalCount == 0 ? .empty : .loaded),
            selectedIds: selectedIds,
            loadedPageInfo: loadResult.info,
            itemCache: itemCache
        )
    }
    
    private static func extractIdsNeedingRequery(
        events: Set<ObservedEvent>,
        cache: [String: TableItem]
    ) -> Set<String> {
        return events.reduce(into: []) { result, event in
            switch (event.key.generic, event.value) {
                case (.profile, let event as ProfileEvent):
                    guard cache[event.id] != nil else { return }
                    
                    result.insert(event.id)
                
                case (.contact, let event as ContactEvent):
                    guard cache[event.id] != nil else { return }
                    
                    result.insert(event.id)
                    
                default: break
            }
        }
    }
    
    private static func sections(state: State, viewModel: BlockedContactsViewModel) -> [SectionModel] {
        return [
            [
                SectionModel(
                    section: .contacts,
                    elements: state.loadedPageInfo.currentIds
                        .compactMap { state.itemCache[$0] }
                        .map { model -> SessionCell.Info<TableItem> in
                            SessionCell.Info(
                                id: model,
                                leadingAccessory: .profile(id: model.id, profile: model.profile),
                                title: (
                                    model.profile?.displayName() ??
                                    model.id.truncated()
                                ),
                                trailingAccessory: .radio(
                                    isSelected: state.selectedIds.contains(model.id)
                                ),
                                accessibility: Accessibility(
                                    identifier: "Contact"
                                ),
                                onTap: { [dependencies = viewModel.dependencies] in
                                    dependencies.notifyAsync(
                                        key: .updateSelection(BlockedContactsViewModel.self, model.id),
                                        value: UpdateSelectionEvent(
                                            id: model.id,
                                            isSelected: !state.selectedIds.contains(model.id)
                                        )
                                    )
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
    
    // MARK: - Functions
    
    @MainActor private func unblockTapped() {
        guard !internalState.selectedIds.isEmpty else { return }
        
        let contactIds: Set<String> = internalState.selectedIds
        let contactNames: [String] = contactIds
            .compactMap { contactId in
                guard
                    let section: SectionModel = self.tableData
                        .first(where: { section in section.model == .contacts }),
                    let info: SessionCell.Info<TableItem> = section.elements
                        .first(where: { info in info.id.id == contactId })
                else { return contactId.truncated() }
                
                return info.title?.text
            }
        let confirmationBody: ThemedAttributedString = {
            let name: String = contactNames.first ?? ""
            switch contactNames.count {
                case 1:
                    return "blockUnblockName"
                        .put(key: "name", value: name)
                        .localizedFormatted(baseFont: .systemFont(ofSize: Values.smallFontSize))
                
                case 2:
                    return "blockUnblockNameTwo"
                        .put(key: "name", value: name)
                        .localizedFormatted(baseFont: .systemFont(ofSize: Values.smallFontSize))
                
                default:
                    return "blockUnblockNameMultiple"
                        .put(key: "name", value: name)
                        .put(key: "count", value: contactNames.count - 1)
                        .localizedFormatted(baseFont: .systemFont(ofSize: Values.smallFontSize))
            }
        }()
        let confirmationModal: ConfirmationModal = ConfirmationModal(
            info: ConfirmationModal.Info(
                title: "blockUnblock".localized(),
                body: .attributedText(confirmationBody),
                confirmTitle: "blockUnblock".localized(),
                confirmStyle: .danger,
                cancelStyle: .alert_text
            ) { [dependencies] _ in
                // Unblock the contacts
                dependencies[singleton: .storage].writeAsync(
                    updates: { db in
                        _ = try Contact
                            .filter(ids: contactIds)
                            .updateAllAndConfig(
                                db,
                                Contact.Columns.isBlocked.set(to: false),
                                using: dependencies
                            )
                        contactIds.forEach { id in
                            db.addContactEvent(id: id, change: .isBlocked(false))
                        }
                    },
                    completion: { _ in
                        dependencies.notifyAsync(key: .clearSelection(BlockedContactsViewModel.self))
                    }
                )
            }
        )
        self.transitionToScreen(confirmationModal, transitionType: .present)
    }
    
    @MainActor func loadPageBefore() {
        dependencies.notifyAsync(
            key: .loadPage(BlockedContactsViewModel.self),
            value: LoadPageEvent.previousPage(firstIndex: internalState.loadedPageInfo.firstIndex)
        )
    }
    
    @MainActor func loadPageAfter() {
        dependencies.notifyAsync(
            key: .loadPage(BlockedContactsViewModel.self),
            value: LoadPageEvent.nextPage(lastIndex: internalState.loadedPageInfo.lastIndex)
        )
    }
    
    // MARK: - TableItem

    public struct TableItem: FetchableRecordWithRowId, Sendable, Decodable, Equatable, Hashable, Identifiable, Differentiable, ColumnExpressible {
        public typealias Columns = CodingKeys
        public enum CodingKeys: String, CodingKey, ColumnExpression, CaseIterable {
            case id
            case profile
        }
        
        public var differenceIdentifier: String { id }
        
        @available(*, deprecated, message: "This is required for the `PagedDatabaseObserver` but we are no longer using it, this can be removed once the `SessionTableViewController` is refactored")
        public let rowId: Int64 = 0
        public let id: String
        public let profile: Profile?
    
        static func query(
            filterSQL: SQL,
            orderSQL: SQL,
            ids: [String]
        ) -> any FetchRequest<TableItem> {
            let contact: TypedTableAlias<Contact> = TypedTableAlias()
            let profile: TypedTableAlias<Profile> = TypedTableAlias()
            
            /// **Note:** The `numColumnsBeforeProfile` value **MUST** match the number of fields before
            /// the `TableItem.profileKey` entry below otherwise the query will fail to
            /// parse and might throw
            ///
            /// Explicitly set default values for the fields ignored for search results
            let numColumnsBeforeProfile: Int = 1
            
            let request: SQLRequest<TableItem> = """
                SELECT
                    \(contact[.id]),
                    \(profile.allColumns)
                
                FROM \(Contact.self)
                LEFT JOIN \(Profile.self) ON \(profile[.id]) = \(contact[.id])
                WHERE \(contact[.id]) IN \(ids)
                ORDER BY \(orderSQL)
            """
            
            return request.adapted { db in
                let adapters = try splittingRowAdapters(columnCounts: [
                    numColumnsBeforeProfile,
                    Profile.numberOfSelectedColumns(db)
                ])
                
                return ScopeAdapter.with(TableItem.self, [
                    .profile: adapters[1]
                ])
            }
        }
        
        static var optimisedJoinSQL: SQL = {
            let contact: TypedTableAlias<Contact> = TypedTableAlias()
            let profile: TypedTableAlias<Profile> = TypedTableAlias()
            
            return SQL("LEFT JOIN \(Profile.self) ON \(profile[.id]) = \(contact[.id])")
        }()
        
        static var filterSQL: SQL = {
            let contact: TypedTableAlias<Contact> = TypedTableAlias()
            
            return SQL("\(contact[.isBlocked]) = true")
        }()
        
        static let orderSQL: SQL = {
            let contact: TypedTableAlias<Contact> = TypedTableAlias()
            let profile: TypedTableAlias<Profile> = TypedTableAlias()
            
            return SQL("IFNULL(IFNULL(\(profile[.nickname]), \(profile[.name])), \(contact[.id])) ASC")
        }()
    }
}

// MARK: - Convenience

private extension ObservedEvent {
    var requiresDatabaseQueryForBlockedContactsViewModel: Bool {
        /// Any event requires a database query
        switch (key, key.generic) {
            case (_, .loadPage): return true
            case (_, .contact): return true
            case (_, .profile): return true
            case (.anyContactBlockedStatusChanged, _): return true
            case (_, .updateSelection): return false
            case (_, .clearSelection): return false
            default: return false
        }
    }
}
