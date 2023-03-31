// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import DifferenceKit
import SignalUtilitiesKit

public class MessageRequestsViewModel {
    public typealias SectionModel = ArraySection<Section, SessionThreadViewModel>
    
    // MARK: - Section
    
    public enum Section: Differentiable {
        case threads
        case loadMore
    }
    
    // MARK: - Variables
    
    public static let pageSize: Int = 15
    
    // MARK: - Initialization
    
    init() {
        self.pagedDataObserver = nil
        
        // Note: Since this references self we need to finish initializing before setting it, we
        // also want to skip the initial query and trigger it async so that the push animation
        // doesn't stutter (it should load basically immediately but without this there is a
        // distinct stutter)
        let userPublicKey: String = getUserHexEncodedPublicKey()
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
                        .wasRead
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
                ),
                PagedData.ObservedChanges(
                    table: RecipientState.self,
                    columns: [.state],
                    joinToPagedType: {
                        let interaction: TypedTableAlias<Interaction> = TypedTableAlias()
                        let recipientState: TypedTableAlias<RecipientState> = TypedTableAlias()
                        
                        return """
                            JOIN \(Interaction.self) ON \(interaction[.threadId]) = \(thread[.id])
                            JOIN \(RecipientState.self) ON \(recipientState[.interactionId]) = \(interaction[.id])
                        """
                    }()
                )
            ],
            /// **Note:** This `optimisedJoinSQL` value includes the required minimum joins needed for the query but differs
            /// from the JOINs that are actually used for performance reasons as the basic logic can be simpler for where it's used
            joinSQL: SessionThreadViewModel.optimisedJoinSQL,
            filterSQL: SessionThreadViewModel.messageRequestsFilterSQL(userPublicKey: userPublicKey),
            groupSQL: SessionThreadViewModel.groupSQL,
            orderSQL: SessionThreadViewModel.messageRequetsOrderSQL,
            dataQuery: SessionThreadViewModel.baseQuery(
                userPublicKey: userPublicKey,
                groupSQL: SessionThreadViewModel.groupSQL,
                orderSQL: SessionThreadViewModel.messageRequetsOrderSQL
            ),
            onChangeUnsorted: { [weak self] updatedData, updatedPageInfo in
                PagedData.processAndTriggerUpdates(
                    updatedData: self?.process(data: updatedData, for: updatedPageInfo),
                    currentDataRetriever: { self?.threadData },
                    onDataChange: self?.onThreadChange,
                    onUnobservedDataChange: { updatedData, changeset in
                        self?.unobservedThreadDataChanges = (changeset.isEmpty ?
                            nil :
                            (updatedData, changeset)
                        )
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
    
    // MARK: - Thread Data
    
    public private(set) var unobservedThreadDataChanges: ([SectionModel], StagedChangeset<[SectionModel]>)?
    public private(set) var threadData: [SectionModel] = []
    public private(set) var pagedDataObserver: PagedDatabaseObserver<SessionThread, SessionThreadViewModel>?
    
    public var onThreadChange: (([SectionModel], StagedChangeset<[SectionModel]>) -> ())? {
        didSet {
            // When starting to observe interaction changes we want to trigger a UI update just in case the
            // data was changed while we weren't observing
            if let unobservedThreadDataChanges: ([SectionModel], StagedChangeset<[SectionModel]>) = self.unobservedThreadDataChanges {
                self.onThreadChange?(unobservedThreadDataChanges.0, unobservedThreadDataChanges.1)
                self.unobservedThreadDataChanges = nil
            }
        }
    }
    
    private func process(data: [SessionThreadViewModel], for pageInfo: PagedData.PageInfo) -> [SectionModel] {
        let groupedOldData: [String: [SessionThreadViewModel]] = (self.threadData
            .first(where: { $0.model == .threads })?
            .elements)
            .defaulting(to: [])
            .grouped(by: \.threadId)
        
        return [
            [
                SectionModel(
                    section: .threads,
                    elements: data
                        .sorted { lhs, rhs -> Bool in lhs.lastInteractionDate > rhs.lastInteractionDate }
                        .map { viewModel -> SessionThreadViewModel in
                            viewModel.populatingCurrentUserBlindedKey(
                                currentUserBlindedPublicKeyForThisThread: groupedOldData[viewModel.threadId]?
                                    .first?
                                    .currentUserBlindedPublicKey
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
    
    public func updateThreadData(_ updatedData: [SectionModel]) {
        self.threadData = updatedData
    }
    
    // MARK: - Functions
    
    static func deleteMessageRequest(
        threadId: String,
        threadVariant: SessionThread.Variant,
        viewController: UIViewController?,
        completion: (() -> Void)? = nil
    ) {
        let modal: ConfirmationModal = ConfirmationModal(
            info: ConfirmationModal.Info(
                title: "MESSAGE_REQUESTS_DELETE_CONFIRMATION_ACTON".localized(),
                confirmTitle: "TXT_DELETE_TITLE".localized(),
                confirmStyle: .danger,
                cancelStyle: .alert_text
            ) { _ in
                Storage.shared.write { db in
                    try SessionThread.deleteOrLeave(
                        db,
                        threadId: threadId,
                        threadVariant: threadVariant,
                        shouldSendLeaveMessageForGroups: false,
                        calledFromConfigHandling: false
                    )
                }
                
                completion?()
            }
        )
        
        viewController?.present(modal, animated: true, completion: nil)
    }
    
    static func blockMessageRequest(
        threadId: String,
        threadVariant: SessionThread.Variant,
        viewController: UIViewController?,
        completion: (() -> Void)? = nil
    ) {
        guard threadVariant == .contact else { return }
        
        let modal: ConfirmationModal = ConfirmationModal(
            info: ConfirmationModal.Info(
                title: "MESSAGE_REQUESTS_BLOCK_CONFIRMATION_ACTON".localized(),
                confirmTitle: "BLOCK_LIST_BLOCK_BUTTON".localized(),
                confirmStyle: .danger,
                cancelStyle: .alert_text
            ) { _ in
                Storage.shared.writeAsync(
                    updates: { db in
                        // Update the contact
                        try Contact
                            .fetchOrCreate(db, id: threadId)
                            .save(db)
                        try Contact
                            .filter(id: threadId)
                            .updateAllAndConfig(
                                db,
                                Contact.Columns.isApproved.set(to: false),
                                Contact.Columns.isBlocked.set(to: true),
                                
                                // Note: We set this to true so the current user will be able to send a
                                // message to the person who originally sent them the message request in
                                // the future if they unblock them
                                Contact.Columns.didApproveMe.set(to: true)
                            )
                        
                        try SessionThread.deleteOrLeave(
                            db,
                            threadId: threadId,
                            threadVariant: .contact,
                            shouldSendLeaveMessageForGroups: false,
                            calledFromConfigHandling: false
                        )
                    },
                    completion: { _, _ in completion?() }
                )
            }
        )
        
        viewController?.present(modal, animated: true, completion: nil)
    }
    
    static func clearAllRequests(
        contactThreadIds: [String],
        groupThreadIds: [String]
    ) {
        // Clear the requests
        Storage.shared.write { db in
            // Remove the one-to-one requests
            try SessionThread.deleteOrLeave(
                db,
                threadIds: contactThreadIds,
                threadVariant: .contact,
                shouldSendLeaveMessageForGroups: false,
                calledFromConfigHandling: false
            )
            
            // Remove the group requests
            try SessionThread.deleteOrLeave(
                db,
                threadIds: groupThreadIds,
                threadVariant: .group,
                shouldSendLeaveMessageForGroups: false,
                calledFromConfigHandling: false
            )
        }
    }
}
