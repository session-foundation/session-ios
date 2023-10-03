// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import DifferenceKit
import SessionUIKit
import SignalUtilitiesKit
import SessionUtilitiesKit

class BlockedContactsViewModel: SessionTableViewModel<NoNav, BlockedContactsViewModel.Section, BlockedContactsViewModel.DataModel> {
    // MARK: - Section
    
    public enum Section: SessionTableSection {
        case contacts
        case loadMore
        
        var style: SessionTableSectionStyle {
            switch self {
                case .contacts: return .none
                case .loadMore: return .loadMore
            }
        }
    }
    
    // MARK: - Variables
    
    public static let pageSize: Int = 30
    
    // MARK: - Initialization
    
    override init() {
        _pagedDataObserver = nil
        
        super.init()
        
        // Note: Since this references self we need to finish initializing before setting it, we
        // also want to skip the initial query and trigger it async so that the push animation
        // doesn't stutter (it should load basically immediately but without this there is a
        // distinct stutter)
        _pagedDataObserver = PagedDatabaseObserver(
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
            joinSQL: DataModel.optimisedJoinSQL,
            filterSQL: DataModel.filterSQL,
            orderSQL: DataModel.orderSQL,
            dataQuery: DataModel.query(
                filterSQL: DataModel.filterSQL,
                orderSQL: DataModel.orderSQL
            ),
            onChangeUnsorted: { [weak self] updatedData, updatedPageInfo in
                PagedData.processAndTriggerUpdates(
                    updatedData: self?.process(data: updatedData, for: updatedPageInfo)
                        .mapToSessionTableViewData(for: self),
                    currentDataRetriever: { self?.tableData },
                    onDataChange: { updatedData, changeset in
                        self?.contactDataSubject.send((updatedData, changeset))
                    },
                    onUnobservedDataChange: { _, _ in }
                )
            }
        )
        
        // Run the initial query on a background thread so we don't block the push transition
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // The `.pageBefore` will query from a `0` offset loading the first page
            self?._pagedDataObserver?.load(.pageBefore)
        }
    }
    
    // MARK: - Contact Data
    
    override var title: String { "CONVERSATION_SETTINGS_BLOCKED_CONTACTS_TITLE".localized() }
    override var emptyStateTextPublisher: AnyPublisher<String?, Never> {
        Just("CONVERSATION_SETTINGS_BLOCKED_CONTACTS_EMPTY_STATE".localized())
            .eraseToAnyPublisher()
    }
    
    private let contactDataSubject: CurrentValueSubject<([SectionModel], StagedChangeset<[SectionModel]>), Never> = CurrentValueSubject(([], StagedChangeset()))
    private let selectedContactIdsSubject: CurrentValueSubject<Set<String>, Never> = CurrentValueSubject([])
    private var _pagedDataObserver: PagedDatabaseObserver<Contact, DataModel>?
    public override var pagedDataObserver: TransactionObserver? { _pagedDataObserver }
    
    public override var observableTableData: ObservableData { _observableTableData }

    private lazy var _observableTableData: ObservableData = contactDataSubject
        .setFailureType(to: Error.self)
        .eraseToAnyPublisher()
    
    override var footerButtonInfo: AnyPublisher<SessionButton.Info?, Never> {
        selectedContactIdsSubject
            .prepend([])
            .map { selectedContactIds in
                SessionButton.Info(
                    style: .destructive,
                    title: "CONVERSATION_SETTINGS_BLOCKED_CONTACTS_UNBLOCK".localized(),
                    isEnabled: !selectedContactIds.isEmpty,
                    onTap: { [weak self] in self?.unblockTapped() }
                )
            }
            .eraseToAnyPublisher()
    }
    
    // MARK: - Functions
    
    override func loadPageAfter() { _pagedDataObserver?.load(.pageAfter) }
    
    private func process(
        data: [DataModel],
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
                        .map { [weak self] model -> SessionCell.Info<DataModel> in
                            SessionCell.Info(
                                id: model,
                                leftAccessory: .profile(id: model.id, profile: model.profile),
                                title: (
                                    model.profile?.displayName() ??
                                    Profile.truncated(id: model.id, truncating: .middle)
                                ),
                                rightAccessory: .radio(
                                    isSelected: {
                                        self?.selectedContactIdsSubject.value.contains(model.id) == true
                                    }
                                ),
                                onTap: {
                                    var updatedSelectedIds: Set<String> = (self?.selectedContactIdsSubject.value ?? [])
                                    
                                    if !updatedSelectedIds.contains(model.id) {
                                        updatedSelectedIds.insert(model.id)
                                    }
                                    else {
                                        updatedSelectedIds.remove(model.id)
                                    }
                                    
                                    self?.selectedContactIdsSubject.send(updatedSelectedIds)
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
    
    private func unblockTapped(using dependencies: Dependencies = Dependencies()) {
        guard !selectedContactIdsSubject.value.isEmpty else { return }
        
        let contactIds: Set<String> = selectedContactIdsSubject.value
        let contactNames: [String] = contactIds
            .compactMap { contactId in
                guard
                    let section: BlockedContactsViewModel.SectionModel = self.tableData
                        .first(where: { section in section.model == .contacts }),
                    let info: SessionCell.Info<DataModel> = section.elements
                        .first(where: { info in info.id.id == contactId })
                else { return contactId }
                
                return info.title?.text
            }
        let confirmationTitle: String = {
            guard contactNames.count > 1 else {
                // Show a single users name
                return String(
                    format: "CONVERSATION_SETTINGS_BLOCKED_CONTACTS_UNBLOCK_CONFIRMATION_TITLE_SINGLE".localized(),
                    (
                        contactNames.first ??
                        "CONVERSATION_SETTINGS_BLOCKED_CONTACTS_UNBLOCK_CONFIRMATION_TITLE_FALLBACK".localized()
                    )
                )
            }
            guard contactNames.count > 3 else {
                // Show up to three users names
                let initialNames: [String] = Array(contactNames.prefix(upTo: (contactNames.count - 1)))
                let lastName: String = contactNames[contactNames.count - 1]
                
                return [
                    String(
                        format: "CONVERSATION_SETTINGS_BLOCKED_CONTACTS_UNBLOCK_CONFIRMATION_TITLE_MULTIPLE_1".localized(),
                        initialNames.joined(separator: ", ")
                    ),
                    String(
                        format: "CONVERSATION_SETTINGS_BLOCKED_CONTACTS_UNBLOCK_CONFIRMATION_TITLE_MULTIPLE_2_SINGLE".localized(),
                        lastName
                    )
                ]
                .reversed(if: CurrentAppContext().isRTL)
                .joined(separator: " ")
            }
            
            // If we have exactly 4 users, show the first two names followed by 'and X others', for
            // more than 4 users, show the first 3 names followed by 'and X others'
            let numNamesToShow: Int = (contactNames.count == 4 ? 2 : 3)
            let initialNames: [String] = Array(contactNames.prefix(upTo: numNamesToShow))
            
            return [
                String(
                    format: "CONVERSATION_SETTINGS_BLOCKED_CONTACTS_UNBLOCK_CONFIRMATION_TITLE_MULTIPLE_1".localized(),
                    initialNames.joined(separator: ", ")
                ),
                String(
                    format: "CONVERSATION_SETTINGS_BLOCKED_CONTACTS_UNBLOCK_CONFIRMATION_TITLE_MULTIPLE_3".localized(),
                    (contactNames.count - numNamesToShow)
                )
            ]
            .reversed(if: CurrentAppContext().isRTL)
            .joined(separator: " ")
        }()
        let confirmationModal: ConfirmationModal = ConfirmationModal(
            info: ConfirmationModal.Info(
                title: confirmationTitle,
                confirmTitle: "CONVERSATION_SETTINGS_BLOCKED_CONTACTS_UNBLOCK_CONFIRMATION_ACTON".localized(),
                confirmStyle: .danger,
                cancelStyle: .alert_text
            ) { [weak self] _ in
                // Unblock the contacts
                dependencies[singleton: .storage].write { db in
                    _ = try Contact
                        .filter(ids: contactIds)
                        .updateAllAndConfig(db, Contact.Columns.isBlocked.set(to: false), using: dependencies)
                }
                
                self?.selectedContactIdsSubject.send([])
            }
        )
        self.transitionToScreen(confirmationModal, transitionType: .present)
    }
    
    // MARK: - DataModel

    public struct DataModel: FetchableRecordWithRowId, Decodable, Equatable, Hashable, Identifiable, Differentiable, ColumnExpressible {
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
        ) -> (([Int64]) -> any FetchRequest<DataModel>) {
            return { rowIds -> any FetchRequest<DataModel> in
                let contact: TypedTableAlias<Contact> = TypedTableAlias()
                let profile: TypedTableAlias<Profile> = TypedTableAlias()
                
                /// **Note:** The `numColumnsBeforeProfile` value **MUST** match the number of fields before
                /// the `DataModel.profileKey` entry below otherwise the query will fail to
                /// parse and might throw
                ///
                /// Explicitly set default values for the fields ignored for search results
                let numColumnsBeforeProfile: Int = 2
                
                let request: SQLRequest<DataModel> = """
                    SELECT
                        \(contact[.rowId]) AS \(DataModel.Columns.rowId),
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
                    
                    return ScopeAdapter.with(DataModel.self, [
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
