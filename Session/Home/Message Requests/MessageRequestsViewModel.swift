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
    
    // MARK: - Variables
    
    public static let pageSize: Int = (UIDevice.current.isIPad ? 20 : 15)
    public let dependencies: Dependencies
    public let state: TableDataState<Section, TableItem> = TableDataState()
    public let observableState: ObservableTableSourceState<Section, SessionThreadViewModel> = ObservableTableSourceState()
    public let navigatableState: NavigatableState = NavigatableState()
    
    // MARK: - Initialization
    
    init(using dependencies: Dependencies) {
        self.dependencies = dependencies
        self.pagedDataObserver = nil
        
        // Note: Since this references self we need to finish initializing before setting it, we
        // also want to skip the initial query and trigger it async so that the push animation
        // doesn't stutter (it should load basically immediately but without this there is a
        // distinct stutter)
        let userSessionId: SessionId = dependencies[cache: .general].sessionId
        let thread: TypedTableAlias<SessionThread> = TypedTableAlias()
        
        self.pagedDataObserver = PagedDatabaseObserver(
            pagedTable: SessionThread.self,
            pageSize: MessageRequestsViewModel.pageSize,
            idColumn: .id,
            observedChanges: [
                PagedData.ObservedChanges(
                    table: SessionThread.self,
                    columns: [
                        .id,
                        .shouldBeVisible
                    ]
                ),
                PagedData.ObservedChanges(
                    table: Interaction.self,
                    columns: [
                        .body,
                        .wasRead,
                        .state
                    ],
                    joinToPagedType: {
                        let interaction: TypedTableAlias<Interaction> = TypedTableAlias()
                        
                        return SQL("JOIN \(Interaction.self) ON \(interaction[.threadId]) = \(thread[.id])")
                    }()
                ),
                PagedData.ObservedChanges(
                    table: Contact.self,
                    columns: [.isBlocked],
                    joinToPagedType: {
                        let contact: TypedTableAlias<Contact> = TypedTableAlias()
                        
                        return SQL("JOIN \(Contact.self) ON \(contact[.id]) = \(thread[.id])")
                    }()
                ),
                PagedData.ObservedChanges(
                    table: Profile.self,
                    columns: [.name, .nickname, .profilePictureFileName],
                    joinToPagedType: {
                        let profile: TypedTableAlias<Profile> = TypedTableAlias()
                        
                        return SQL("JOIN \(Profile.self) ON \(profile[.id]) = \(thread[.id])")
                    }()
                )
            ],
            /// **Note:** This `optimisedJoinSQL` value includes the required minimum joins needed for the query but differs
            /// from the JOINs that are actually used for performance reasons as the basic logic can be simpler for where it's used
            joinSQL: SessionThreadViewModel.optimisedJoinSQL,
            filterSQL: SessionThreadViewModel.messageRequestsFilterSQL(userSessionId: userSessionId),
            groupSQL: SessionThreadViewModel.groupSQL,
            orderSQL: SessionThreadViewModel.messageRequetsOrderSQL,
            dataQuery: SessionThreadViewModel.baseQuery(
                userSessionId: userSessionId,
                groupSQL: SessionThreadViewModel.groupSQL,
                orderSQL: SessionThreadViewModel.messageRequetsOrderSQL
            ),
            onChangeUnsorted: { [weak self] updatedData, updatedPageInfo in
                guard let data: [SectionModel] = self?.process(data: updatedData, for: updatedPageInfo) else {
                    return
                }
                
                self?.pendingTableDataSubject.send(data)
            },
            using: dependencies
        )
        
        // Run the initial query on a background thread so we don't block the push transition
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // The `.pageBefore` will query from a `0` offset loading the first page
            self?.pagedDataObserver?.load(.pageBefore)
        }
    }
    
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
    
    // MARK: - Content
    
    public let title: String = "sessionMessageRequests".localized()
    public let initialLoadMessage: String? = "loading".localized()
    public let emptyStateTextPublisher: AnyPublisher<String?, Never> = Just("messageRequestsNonePending".localized())
        .eraseToAnyPublisher()
    public let cellType: SessionTableViewCellType = .fullConversation
    public private(set) var pagedDataObserver: PagedDatabaseObserver<SessionThread, SessionThreadViewModel>?
    
    private func process(data: [SessionThreadViewModel], for pageInfo: PagedData.PageInfo) -> [SectionModel] {
        let groupedOldData: [String: [SessionCell.Info<SessionThreadViewModel>]] = (self.tableData
            .first(where: { $0.model == .threads })?
            .elements)
            .defaulting(to: [])
            .grouped(by: \.id.threadId)
        
        return [
            [
                SectionModel(
                    section: .threads,
                    elements: data
                        .sorted { lhs, rhs -> Bool in lhs.lastInteractionDate > rhs.lastInteractionDate }
                        .map { [dependencies] viewModel -> SessionCell.Info<SessionThreadViewModel> in
                            SessionCell.Info(
                                id: viewModel.populatingPostQueryData(
                                    currentUserBlinded15SessionIdForThisThread: groupedOldData[viewModel.threadId]?
                                        .first?
                                        .id
                                        .currentUserBlinded15SessionId,
                                    currentUserBlinded25SessionIdForThisThread: groupedOldData[viewModel.threadId]?
                                        .first?
                                        .id
                                        .currentUserBlinded25SessionId,
                                    wasKickedFromGroup: (
                                        viewModel.threadVariant == .group &&
                                        LibSession.wasKickedFromGroup(
                                            groupSessionId: SessionId(.group, hex: viewModel.threadId),
                                            using: dependencies
                                        )
                                    ),
                                    groupIsDestroyed: (
                                        viewModel.threadVariant == .group &&
                                        LibSession.groupIsDestroyed(
                                            groupSessionId: SessionId(.group, hex: viewModel.threadId),
                                            using: dependencies
                                        )
                                    ),
                                    threadCanWrite: false,  // Irrelevant for the MessageRequestsViewModel
                                    using: dependencies
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
            (!data.isEmpty && (pageInfo.pageOffset + pageInfo.currentCount) < pageInfo.totalCount ?
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
}
