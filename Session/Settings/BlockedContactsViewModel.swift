// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import DifferenceKit
import SignalUtilitiesKit

public class BlockedContactsViewModel {
    public typealias SectionModel = ArraySection<Section, SessionCell.Info<Profile>>
    
    // MARK: - Section
    
    public enum Section: Differentiable {
        case contacts
        case loadMore
    }
    
    // MARK: - Variables
    
    public static let pageSize: Int = 30
    
    // MARK: - Initialization
    
    init() {
        self.pagedDataObserver = nil
        
        // Note: Since this references self we need to finish initializing before setting it, we
        // also want to skip the initial query and trigger it async so that the push animation
        // doesn't stutter (it should load basically immediately but without this there is a
        // distinct stutter)
        self.pagedDataObserver = PagedDatabaseObserver(
            pagedTable: Profile.self,
            pageSize: BlockedContactsViewModel.pageSize,
            idColumn: .id,
            observedChanges: [
                PagedData.ObservedChanges(
                    table: Profile.self,
                    columns: [
                        .id,
                        .name,
                        .nickname,
                        .profilePictureFileName
                    ]
                ),
                PagedData.ObservedChanges(
                    table: Contact.self,
                    columns: [.isBlocked],
                    joinToPagedType: {
                        let profile: TypedTableAlias<Profile> = TypedTableAlias()
                        let contact: TypedTableAlias<Contact> = TypedTableAlias()
                        
                        return SQL("JOIN \(Contact.self) ON \(contact[.id]) = \(profile[.id])")
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
                    updatedData: self?.process(data: updatedData, for: updatedPageInfo),
                    currentDataRetriever: { self?.contactData },
                    onDataChange: self?.onContactChange,
                    onUnobservedDataChange: { updatedData, changeset in
                        self?.unobservedContactDataChanges = (updatedData, changeset)
                    }
                )
            }
        )
        
        // Run the initial query on a background thread so we don't block the push transition
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // The `.pageBefore` will query from a `0` offset loading the first page
            self?.pagedDataObserver?.load(.pageBefore)
        }
    }
    
    // MARK: - Contact Data
    
    public private(set) var selectedContactIds: Set<String> = []
    public private(set) var unobservedContactDataChanges: ([SectionModel], StagedChangeset<[SectionModel]>)?
    public private(set) var contactData: [SectionModel] = []
    public private(set) var pagedDataObserver: PagedDatabaseObserver<Profile, DataModel>?
    
    public var onContactChange: (([SectionModel], StagedChangeset<[SectionModel]>) -> ())? {
        didSet {
            // When starting to observe interaction changes we want to trigger a UI update just in case the
            // data was changed while we weren't observing
            if let unobservedContactDataChanges: ([SectionModel], StagedChangeset<[SectionModel]>) = self.unobservedContactDataChanges {
                onContactChange?(unobservedContactDataChanges.0 , unobservedContactDataChanges.1)
                self.unobservedContactDataChanges = nil
            }
        }
    }
    
    private func process(data: [DataModel], for pageInfo: PagedData.PageInfo) -> [SectionModel] {
        // Update the 'selectedContactIds' to only include selected contacts which are within the
        // data (ie. handle profile deletions)
        let profileIds: Set<String> = data.map { $0.id }.asSet()
        selectedContactIds = selectedContactIds.intersection(profileIds)
        
        return [
            [
                SectionModel(
                    section: .contacts,
                    elements: data
                        .sorted { lhs, rhs -> Bool in
                            lhs.profile.displayName() > rhs.profile.displayName()
                        }
                        .map { model -> SessionCell.Info<Profile> in
                            SessionCell.Info(
                                id: model.profile,
                                leftAccessory: .profile(model.profile.id, model.profile),
                                title: model.profile.displayName(),
                                rightAccessory: .radio(
                                    isSelected: { [weak self] in
                                        self?.selectedContactIds.contains(model.profile.id) == true
                                    }
                                ),
                                onTap: { [weak self] in
                                    guard self?.selectedContactIds.contains(model.profile.id) == true else {
                                        self?.selectedContactIds.insert(model.profile.id)
                                        return
                                    }
                                    
                                    self?.selectedContactIds.remove(model.profile.id)
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
        guard !selectedContactIdsSubject.value.isEmpty else { return }
        
        let contactIds: Set<String> = selectedContactIdsSubject.value
        let contactNames: [String] = contactIds
            .compactMap { contactId in
                guard
                    let section: BlockedContactsViewModel.SectionModel = self.tableData
                        .first(where: { section in section.model == .contacts }),
                    let info: SessionCell.Info<Profile> = section.elements
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
            ) { _ in
                // Unblock the contacts
                Storage.shared.write { db in
                    _ = try Contact
                        .filter(ids: contactIds)
                        .updateAll(db, Contact.Columns.isBlocked.set(to: false))
                    
                    // Force a config sync
                    try MessageSender.syncConfiguration(db, forceSyncNow: true).sinkUntilComplete()
                }
            }
        )
        self.transitionToScreen(confirmationModal, transitionType: .present)
    }
    
    // MARK: - DataModel

    public struct DataModel: FetchableRecordWithRowId, Decodable, Equatable, Hashable, Identifiable, Differentiable {
        public static let rowIdKey: SQL = SQL(stringLiteral: CodingKeys.rowId.stringValue)
        public static let profileKey: SQL = SQL(stringLiteral: CodingKeys.profile.stringValue)
        
        public static let profileString: String = CodingKeys.profile.stringValue
        
        public var differenceIdentifier: String { profile.id }
        public var id: String { profile.id }
        
        public let rowId: Int64
        public let profile: Profile
    
        static func query(
            filterSQL: SQL,
            orderSQL: SQL
        ) -> (([Int64]) -> AdaptedFetchRequest<SQLRequest<DataModel>>) {
            return { rowIds -> AdaptedFetchRequest<SQLRequest<DataModel>> in
                let profile: TypedTableAlias<Profile> = TypedTableAlias()
                
                /// **Note:** The `numColumnsBeforeProfile` value **MUST** match the number of fields before
                /// the `DataModel.profileKey` entry below otherwise the query will fail to
                /// parse and might throw
                ///
                /// Explicitly set default values for the fields ignored for search results
                let numColumnsBeforeProfile: Int = 1
                
                let request: SQLRequest<DataModel> = """
                    SELECT
                        \(profile.alias[Column.rowID]) AS \(DataModel.rowIdKey),
                        \(DataModel.profileKey).*
                    
                    FROM \(Profile.self)
                    WHERE \(profile.alias[Column.rowID]) IN \(rowIds)
                    ORDER BY \(orderSQL)
                """
                
                return request.adapted { db in
                    let adapters = try splittingRowAdapters(columnCounts: [
                        numColumnsBeforeProfile,
                        Profile.numberOfSelectedColumns(db)
                    ])
                    
                    return ScopeAdapter([
                        DataModel.profileString: adapters[1]
                    ])
                }
            }
        }
        
        static var optimisedJoinSQL: SQL = {
            let profile: TypedTableAlias<Profile> = TypedTableAlias()
            let contact: TypedTableAlias<Contact> = TypedTableAlias()
            
            return SQL("JOIN \(Contact.self) ON \(contact[.id]) = \(profile[.id])")
        }()
        
        static var filterSQL: SQL = {
            let contact: TypedTableAlias<Contact> = TypedTableAlias()
            
            return SQL("\(contact[.isBlocked]) = true")
        }()
        
        static let orderSQL: SQL = {
            let profile: TypedTableAlias<Profile> = TypedTableAlias()
            
            return SQL("IFNULL(IFNULL(\(profile[.nickname]), \(profile[.name])), \(profile[.id])) ASC")
        }()
    }

}
