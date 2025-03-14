// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import DifferenceKit
import SessionUIKit
import SignalUtilitiesKit
import SessionMessagingKit
import SessionUtilitiesKit

public class BlockedContactsViewModel: SessionTableViewModel, NavigatableStateHolder, ObservableTableSource, PagedObservationSource {
    public static let pageSize: Int = 30
    
    public let dependencies: Dependencies
    public let navigatableState: NavigatableState = NavigatableState()
    public let state: TableDataState<Section, TableItem> = TableDataState()
    public let observableState: ObservableTableSourceState<Section, TableItem> = ObservableTableSourceState()
    private let selectedIdsSubject: CurrentValueSubject<Set<String>, Never> = CurrentValueSubject([])
    public private(set) var pagedDataObserver: PagedDatabaseObserver<Contact, TableItem>?
    
    // MARK: - Initialization
    
    init(using dependencies: Dependencies) {
        self.dependencies = dependencies
        self.pagedDataObserver = nil
        
        // Note: Since this references self we need to finish initializing before setting it, we
        // also want to skip the initial query and trigger it async so that the push animation
        // doesn't stutter (it should load basically immediately but without this there is a
        // distinct stutter)
        self.pagedDataObserver = PagedDatabaseObserver(
            pagedTable: Contact.self,
            pageSize: BlockedContactsViewModel.pageSize,
            idColumn: .id,
            observedChanges: [
                PagedData.ObservedChanges(
                    table: Contact.self,
                    columns: [.id, .isBlocked]
                ),
                PagedData.ObservedChanges(
                    table: Profile.self,
                    columns: [
                        .id,
                        .name,
                        .nickname,
                        .profilePictureFileName
                    ],
                    joinToPagedType: {
                        let contact: TypedTableAlias<Contact> = TypedTableAlias()
                        let profile: TypedTableAlias<Profile> = TypedTableAlias()
                        
                        return SQL("JOIN \(Profile.self) ON \(profile[.id]) = \(contact[.id])")
                    }()
                )
            ],
            /// **Note:** This `optimisedJoinSQL` value includes the required minimum joins needed for the query
            joinSQL: TableItem.optimisedJoinSQL,
            filterSQL: TableItem.filterSQL,
            orderSQL: TableItem.orderSQL,
            dataQuery: TableItem.query(
                filterSQL: TableItem.filterSQL,
                orderSQL: TableItem.orderSQL
            ),
            onChangeUnsorted: { [weak self] updatedData, updatedPageInfo in
                guard
                    let data: [SectionModel] = self?.process(data: updatedData, for: updatedPageInfo)
                        .mapToSessionTableViewData(for: self)  // Update the cell positions for background rounding
                else { return }
                
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
    
    lazy var footerButtonInfo: AnyPublisher<SessionButton.Info?, Never> = selectedIdsSubject
        .prepend([])
        .map { selectedContactIds in
            SessionButton.Info(
                style: .destructive,
                title: "blockUnblock".localized(),
                isEnabled: !selectedContactIds.isEmpty,
                onTap: { [weak self] in self?.unblockTapped() }
            )
        }
        .eraseToAnyPublisher()
    
    // MARK: - Functions
    
    private func process(
        data: [TableItem],
        for pageInfo: PagedData.PageInfo
    ) -> [SectionModel] {
        return [
            [
                SectionModel(
                    section: .contacts,
                    elements: data
                        .sorted { lhs, rhs -> Bool in
                            let lhsValue: String = (lhs.profile?.displayName() ?? lhs.id)
                            let rhsValue: String = (rhs.profile?.displayName() ?? rhs.id)
                            
                            return (lhsValue < rhsValue)
                        }
                        .map { [selectedIdsSubject] model -> SessionCell.Info<TableItem> in
                            SessionCell.Info(
                                id: model,
                                leadingAccessory: .profile(id: model.id, profile: model.profile),
                                title: (
                                    model.profile?.displayName() ??
                                    Profile.truncated(id: model.id, truncating: .middle)
                                ),
                                trailingAccessory: .radio(
                                    liveIsSelected: { selectedIdsSubject.value.contains(model.id) == true }
                                ),
                                accessibility: Accessibility(
                                    identifier: "Contact"
                                ),
                                onTap: {
                                    if !selectedIdsSubject.value.contains(model.id) {
                                        selectedIdsSubject.send(selectedIdsSubject.value.inserting(model.id))
                                    }
                                    else {
                                        selectedIdsSubject.send(selectedIdsSubject.value.removing(model.id))
                                    }
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
    
    private func unblockTapped() {
        guard !selectedIdsSubject.value.isEmpty else { return }
        
        let contactIds: Set<String> = selectedIdsSubject.value
        let contactNames: [String] = contactIds
            .compactMap { contactId in
                guard
                    let section: SectionModel = self.tableData
                        .first(where: { section in section.model == .contacts }),
                    let info: SessionCell.Info<TableItem> = section.elements
                        .first(where: { info in info.id.id == contactId })
                else {
                    return Profile.truncated(id: contactId, truncating: .middle)
                }
                
                return info.title?.text
            }
        let confirmationBody: NSAttributedString = {
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
            ) { [weak self, dependencies] _ in
                // Unblock the contacts
                dependencies[singleton: .storage].write { db in
                    _ = try Contact
                        .filter(ids: contactIds)
                        .updateAllAndConfig(
                            db,
                            Contact.Columns.isBlocked.set(to: false),
                            using: dependencies
                        )
                }
                
                self?.selectedIdsSubject.send([])
            }
        )
        self.transitionToScreen(confirmationModal, transitionType: .present)
    }
    
    // MARK: - TableItem

    public struct TableItem: FetchableRecordWithRowId, Decodable, Equatable, Hashable, Identifiable, Differentiable, ColumnExpressible {
        public typealias Columns = CodingKeys
        public enum CodingKeys: String, CodingKey, ColumnExpression, CaseIterable {
            case rowId
            case id
            case profile
        }
        
        public var differenceIdentifier: String { id }
        
        public let rowId: Int64
        public let id: String
        public let profile: Profile?
    
        static func query(
            filterSQL: SQL,
            orderSQL: SQL
        ) -> (([Int64]) -> any FetchRequest<TableItem>) {
            return { rowIds -> any FetchRequest<TableItem> in
                let contact: TypedTableAlias<Contact> = TypedTableAlias()
                let profile: TypedTableAlias<Profile> = TypedTableAlias()
                
                /// **Note:** The `numColumnsBeforeProfile` value **MUST** match the number of fields before
                /// the `TableItem.profileKey` entry below otherwise the query will fail to
                /// parse and might throw
                ///
                /// Explicitly set default values for the fields ignored for search results
                let numColumnsBeforeProfile: Int = 2
                
                let request: SQLRequest<TableItem> = """
                    SELECT
                        \(contact[.rowId]) AS \(TableItem.Columns.rowId),
                        \(contact[.id]),
                        \(profile.allColumns)
                    
                    FROM \(Contact.self)
                    LEFT JOIN \(Profile.self) ON \(profile[.id]) = \(contact[.id])
                    WHERE \(contact[.rowId]) IN \(rowIds)
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
