// Copyright © 2024 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SwiftUI
import GRDB
import DifferenceKit
import SignalUtilitiesKit
import SessionMessagingKit
import SessionUtilitiesKit

extension HomeScreen {
    public protocol ViewModelDelegate: AnyObject {
        func ensureRootViewController()
    }
    public class ViewModel: ObservableObject {
        public let dependencies: Dependencies
        public var onReceivedInitialChange: (() -> ())? = nil
        private var dataChangeObservable: DatabaseCancellable? {
            didSet { oldValue?.cancel() }   // Cancel the old observable if there was one
        }
        private var hasLoadedInitialStateData: Bool = false
        private var hasLoadedInitialThreadData: Bool = false
        private var isLoadingMore: Bool = false
        private var isAutoLoadingNextPage: Bool = false
        private var viewHasAppeared: Bool = false
        @State var shouldLoadMore: Bool = false
        
        // MARK: - Initialization
        
        init(using dependencies: Dependencies, onReceivedInitialChange: (() -> ())? = nil) {
            typealias InitialData = (
                showViewedSeedBanner: Bool,
                hasHiddenMessageRequests: Bool,
                profile: Profile
            )
            
            let initialData: InitialData? = dependencies.storage.read { db -> InitialData in
                (
                    !db[.hasViewedSeed],
                    db[.hasHiddenMessageRequests],
                    Profile.fetchOrCreateCurrentUser(db)
                )
            }
            
            self.dependencies = dependencies
            self.onReceivedInitialChange = onReceivedInitialChange
            
            self.state = DataModel.State(
                showViewedSeedBanner: (initialData?.showViewedSeedBanner ?? true),
                hasHiddenMessageRequests: (initialData?.hasHiddenMessageRequests ?? false),
                unreadMessageRequestThreadCount: 0,
                userProfile: (initialData?.profile ?? Profile.fetchOrCreateCurrentUser())
            )
            self.pagedDataObserver = nil
            
            // Note: Since this references self we need to finish initializing before setting it, we
            // also want to skip the initial query and trigger it async so that the push animation
            // doesn't stutter (it should load basically immediately but without this there is a
            // distinct stutter)
            let userPublicKey: String = self.state.userProfile.id
            let thread: TypedTableAlias<SessionThread> = TypedTableAlias()
            self.pagedDataObserver = PagedDatabaseObserver(
                pagedTable: SessionThread.self,
                pageSize: HomeViewModel.pageSize,
                idColumn: .id,
                observedChanges: [
                    PagedData.ObservedChanges(
                        table: SessionThread.self,
                        columns: [
                            .id,
                            .shouldBeVisible,
                            .pinnedPriority,
                            .mutedUntilTimestamp,
                            .onlyNotifyForMentions,
                            .markedAsUnread
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
                            let groupMember: TypedTableAlias<GroupMember> = TypedTableAlias()
                            let threadVariants: [SessionThread.Variant] = [.legacyGroup, .group]
                            let targetRole: GroupMember.Role = GroupMember.Role.standard
                            
                            return SQL("""
                                JOIN \(Profile.self) ON (
                                    (   -- Contact profile change
                                        \(profile[.id]) = \(thread[.id]) AND
                                        \(SQL("\(thread[.variant]) = \(SessionThread.Variant.contact)"))
                                    ) OR ( -- Closed group profile change
                                        \(SQL("\(thread[.variant]) IN \(threadVariants)")) AND (
                                            profile.id = (  -- Front profile
                                                SELECT MIN(\(groupMember[.profileId]))
                                                FROM \(GroupMember.self)
                                                JOIN \(Profile.self) ON \(profile[.id]) = \(groupMember[.profileId])
                                                WHERE (
                                                    \(groupMember[.groupId]) = \(thread[.id]) AND
                                                    \(SQL("\(groupMember[.role]) = \(targetRole)")) AND
                                                    \(groupMember[.profileId]) != \(userPublicKey)
                                                )
                                            ) OR
                                            profile.id = (  -- Back profile
                                                SELECT MAX(\(groupMember[.profileId]))
                                                FROM \(GroupMember.self)
                                                JOIN \(Profile.self) ON \(profile[.id]) = \(groupMember[.profileId])
                                                WHERE (
                                                    \(groupMember[.groupId]) = \(thread[.id]) AND
                                                    \(SQL("\(groupMember[.role]) = \(targetRole)")) AND
                                                    \(groupMember[.profileId]) != \(userPublicKey)
                                                )
                                            ) OR (  -- Fallback profile
                                                profile.id = \(userPublicKey) AND
                                                (
                                                    SELECT COUNT(\(groupMember[.profileId]))
                                                    FROM \(GroupMember.self)
                                                    JOIN \(Profile.self) ON \(profile[.id]) = \(groupMember[.profileId])
                                                    WHERE (
                                                        \(groupMember[.groupId]) = \(thread[.id]) AND
                                                        \(SQL("\(groupMember[.role]) = \(targetRole)")) AND
                                                        \(groupMember[.profileId]) != \(userPublicKey)
                                                    )
                                                ) = 1
                                            )
                                        )
                                    )
                                )
                            """)
                        }()
                    ),
                    PagedData.ObservedChanges(
                        table: ClosedGroup.self,
                        columns: [.name],
                        joinToPagedType: {
                            let closedGroup: TypedTableAlias<ClosedGroup> = TypedTableAlias()
                            
                            return SQL("JOIN \(ClosedGroup.self) ON \(closedGroup[.threadId]) = \(thread[.id])")
                        }()
                    ),
                    PagedData.ObservedChanges(
                        table: OpenGroup.self,
                        columns: [.name, .imageData],
                        joinToPagedType: {
                            let openGroup: TypedTableAlias<OpenGroup> = TypedTableAlias()
                            
                            return SQL("JOIN \(OpenGroup.self) ON \(openGroup[.threadId]) = \(thread[.id])")
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
                    ),
                    PagedData.ObservedChanges(
                        table: ThreadTypingIndicator.self,
                        columns: [.threadId],
                        joinToPagedType: {
                            let typingIndicator: TypedTableAlias<ThreadTypingIndicator> = TypedTableAlias()
                            
                            return SQL("JOIN \(ThreadTypingIndicator.self) ON \(typingIndicator[.threadId]) = \(thread[.id])")
                        }()
                    )
                ],
                /// **Note:** This `optimisedJoinSQL` value includes the required minimum joins needed for the query but differs
                /// from the JOINs that are actually used for performance reasons as the basic logic can be simpler for where it's used
                joinSQL: SessionThreadViewModel.optimisedJoinSQL,
                filterSQL: SessionThreadViewModel.homeFilterSQL(userPublicKey: userPublicKey),
                groupSQL: SessionThreadViewModel.groupSQL,
                orderSQL: SessionThreadViewModel.homeOrderSQL,
                dataQuery: SessionThreadViewModel.baseQuery(
                    userPublicKey: userPublicKey,
                    groupSQL: SessionThreadViewModel.groupSQL,
                    orderSQL: SessionThreadViewModel.homeOrderSQL
                ),
                onChangeUnsorted: { [weak self] updatedData, updatedPageInfo in
                    PagedData.processAndTriggerUpdates(
                        updatedData: self?.process(data: updatedData, for: updatedPageInfo),
                        currentDataRetriever: { self?.threadData },
                        onDataChangeRetriever: { self?.onThreadChange },
                        onUnobservedDataChange: { updatedData in
                            self?.unobservedThreadDataChanges = updatedData
                        }
                    )
                    
                    self?.hasReceivedInitialThreadData = true
                }
            )
            
            dependencies.storage.addObserver(self.pagedDataObserver)
            
            self.registerForNotifications()
            
            // Run the initial query on a background thread so we don't block the main thread
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.startObservingChanges(onReceivedInitialChange: self?.onReceivedInitialChange)
                // The `.pageBefore` will query from a `0` offset loading the first page
                self?.pagedDataObserver?.load(.pageBefore)
            }
        }
        
        // MARK: - State
        
        /// This value is the current state of the view
        @Published public private(set) var state: DataModel.State
        
        /// This is all the data the screen needs to populate itself, please see the following link for tips to help optimise
        /// performance https://github.com/groue/GRDB.swift#valueobservation-performance
        ///
        /// **Note:** This observation will be triggered twice immediately (and be de-duped by the `removeDuplicates`)
        /// this is due to the behaviour of `ValueConcurrentObserver.asyncStartObservation` which triggers it's own
        /// fetch (after the ones in `ValueConcurrentObserver.asyncStart`/`ValueConcurrentObserver.syncStart`)
        /// just in case the database has changed between the two reads - unfortunately it doesn't look like there is a way to prevent this
        public lazy var observableState = ValueObservation
            .trackingConstantRegion { db -> DataModel.State in try DataModel.retrieveState(db) }
            .removeDuplicates()
            .handleEvents(didFail: { SNLog("[HomeViewModel] Observation failed with error: \($0)") })
        
        public func updateState(_ updatedState: DataModel.State) {
            let oldState: DataModel.State = self.state
            self.state = updatedState
            
            // If the messageRequest content changed then we need to re-process the thread data (assuming
            // we've received the initial thread data)
            guard
                self.hasReceivedInitialThreadData,
                (
                    oldState.hasHiddenMessageRequests != updatedState.hasHiddenMessageRequests ||
                    oldState.unreadMessageRequestThreadCount != updatedState.unreadMessageRequestThreadCount
                ),
                let currentPageInfo: PagedData.PageInfo = self.pagedDataObserver?.pageInfo.wrappedValue
            else { return }
            
            /// **MUST** have the same logic as in the 'PagedDataObserver.onChangeUnsorted' above
            let currentData: [DataModel.SectionModel] = (self.unobservedThreadDataChanges ?? self.threadData)
            let updatedThreadData: [DataModel.SectionModel] = self.process(
                data: (currentData.first(where: { $0.model == .threads })?.elements ?? []),
                for: currentPageInfo
            )
            
            PagedData.processAndTriggerUpdates(
                updatedData: updatedThreadData,
                currentDataRetriever: { [weak self] in (self?.unobservedThreadDataChanges ?? self?.threadData) },
                onDataChangeRetriever: { [weak self] in self?.onThreadChange },
                onUnobservedDataChange: { [weak self] updatedData in
                    self?.unobservedThreadDataChanges = updatedData
                }
            )
        }
        
        // MARK: - Thread Data
        
        private var hasReceivedInitialThreadData: Bool = false
        public private(set) var unobservedThreadDataChanges: [DataModel.SectionModel]?
        @Published public private(set) var threadData: [DataModel.SectionModel] = []
        public private(set) var pagedDataObserver: PagedDatabaseObserver<SessionThread, SessionThreadViewModel>?
        
        public var onThreadChange: (([DataModel.SectionModel], StagedChangeset<[DataModel.SectionModel]>) -> ())? {
            didSet {
                guard onThreadChange != nil else { return }
                
                // When starting to observe interaction changes we want to trigger a UI update just in case the
                // data was changed while we weren't observing
                if let changes: [DataModel.SectionModel] = self.unobservedThreadDataChanges {
                    PagedData.processAndTriggerUpdates(
                        updatedData: changes,
                        currentDataRetriever: { [weak self] in self?.threadData },
                        onDataChangeRetriever: { [weak self] in self?.onThreadChange },
                        onUnobservedDataChange: { [weak self] updatedData in
                            self?.unobservedThreadDataChanges = updatedData
                        }
                    )
                    self.unobservedThreadDataChanges = nil
                }
            }
        }
        
        private func process(data: [SessionThreadViewModel], for pageInfo: PagedData.PageInfo) -> [DataModel.SectionModel] {
            let finalUnreadMessageRequestCount: Int = (self.state.hasHiddenMessageRequests ?
                0 :
                self.state.unreadMessageRequestThreadCount
            )
            let groupedOldData: [String: [SessionThreadViewModel]] = (self.threadData
                .first(where: { $0.model == .threads })?
                .elements)
                .defaulting(to: [])
                .grouped(by: \.threadId)
            
            return [
                // If there are no unread message requests then hide the message request banner
                (finalUnreadMessageRequestCount == 0 ?
                    [] :
                    [DataModel.SectionModel(
                        section: .messageRequests,
                        elements: [
                            SessionThreadViewModel(
                                threadId: SessionThreadViewModel.messageRequestsSectionId,
                                unreadCount: UInt(finalUnreadMessageRequestCount)
                            )
                        ]
                    )]
                ),
                [
                    DataModel.SectionModel(
                        section: .threads,
                        elements: data
                            .filter { threadViewModel in
                                threadViewModel.id != SessionThreadViewModel.invalidId &&
                                threadViewModel.id != SessionThreadViewModel.messageRequestsSectionId
                            }
                            .sorted { lhs, rhs -> Bool in
                                guard lhs.threadPinnedPriority == rhs.threadPinnedPriority else {
                                    return lhs.threadPinnedPriority > rhs.threadPinnedPriority
                                }
                                
                                return lhs.lastInteractionDate > rhs.lastInteractionDate
                            }
                            .map { viewModel -> SessionThreadViewModel in
                                viewModel.populatingCurrentUserBlindedKeys(
                                    currentUserBlinded15PublicKeyForThisThread: groupedOldData[viewModel.threadId]?
                                        .first?
                                        .currentUserBlinded15PublicKey,
                                    currentUserBlinded25PublicKeyForThisThread: groupedOldData[viewModel.threadId]?
                                        .first?
                                        .currentUserBlinded25PublicKey
                                )
                            }
                    )
                ],
                (!data.isEmpty && (pageInfo.pageOffset + pageInfo.currentCount) < pageInfo.totalCount ?
                    [DataModel.SectionModel(section: .loadMore)] :
                    []
                )
            ].flatMap { $0 }
        }
        
        public func updateThreadData(_ updatedData: [DataModel.SectionModel]) {
            self.threadData = updatedData
        }
        
        // MARK: - Updating
        
        public func startObservingChanges(didReturnFromBackground: Bool = false, onReceivedInitialChange: (() -> ())? = nil) {
            guard dataChangeObservable == nil else { return }
            
            var runAndClearInitialChangeCallback: (() -> ())? = nil
            
            runAndClearInitialChangeCallback = { [weak self] in
                guard self?.hasLoadedInitialStateData == true && self?.hasLoadedInitialThreadData == true else { return }
                
                onReceivedInitialChange?()
                runAndClearInitialChangeCallback = nil
            }
            
            dataChangeObservable = dependencies.storage.start(
                self.observableState,
                onError: { _ in print("Error observing data") },
                onChange: { [weak self] state in
                    // The default scheduler emits changes on the main thread
                    self?.handleStateUpdates(state)
                    runAndClearInitialChangeCallback?()
                }
            )
            
            self.onThreadChange = { [weak self] updatedThreadData, changeset in
                self?.handleThreadUpdates(updatedThreadData)
                runAndClearInitialChangeCallback?()
            }
            
            // Note: When returning from the background we could have received notifications but the
            // PagedDatabaseObserver won't have them so we need to force a re-fetch of the current
            // data to ensure everything is up to date
            if didReturnFromBackground {
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    self?.pagedDataObserver?.reload()
                }
            }
        }
        
        private func stopObservingChanges() {
            // Stop observing database changes
            self.dataChangeObservable = nil
            self.onThreadChange = nil
        }
        
        private func handleStateUpdates(_ updatedState: DataModel.State, animated: Bool = true) {
            // Ensure the first load runs without animations (if we don't do this the cells will animate
            // in from a frame of CGRect.zero)
            guard hasLoadedInitialStateData else {
                hasLoadedInitialStateData = true
                handleStateUpdates(updatedState, animated: false)
                return
            }
            
            if animated {
                withAnimation(.easeInOut) {
                    self.updateState(updatedState)
                }
            } else {
                self.updateState(updatedState)
            }
        }
        
        private func handleThreadUpdates(_ updatedData: [DataModel.SectionModel]) {
            // Ensure the first load runs without animations (if we don't do this the cells will animate
            // in from a frame of CGRect.zero)
            guard hasLoadedInitialThreadData else {
                self.updateThreadData(updatedData)
                self.hasLoadedInitialThreadData = true
                return
            }
            
            withAnimation(.easeInOut) {
                self.updateThreadData(updatedData)
                self.isLoadingMore = false
                self.autoLoadNextPageIfNeeded()
            }
        }
        
        private func autoLoadNextPageIfNeeded() {
            guard
                self.hasLoadedInitialThreadData &&
                !self.isAutoLoadingNextPage &&
                !self.isLoadingMore
            else { return }
            
            self.isAutoLoadingNextPage = true
            
            DispatchQueue.main.asyncAfter(deadline: .now() + PagedData.autoLoadNextPageDelay) { [weak self] in
                self?.isAutoLoadingNextPage = false
                
                // Note: We sort the headers as we want to prioritise loading newer pages over older ones
                let sections: [DataModel.Section] = (self?.threadData
                    .enumerated()
                    .map { _, section in section.model })
                    .defaulting(to: [])

                guard sections.contains(.loadMore) && (self?.shouldLoadMore == true) else { return }
                
                self?.isLoadingMore = true
                
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    self?.pagedDataObserver?.load(.pageAfter)
                }
            }
        }
        
        // MARK: Notification
        
        func registerForNotifications() {
            // Notifications
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(applicationDidBecomeActive(_:)),
                name: UIApplication.didBecomeActiveNotification,
                object: nil
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(applicationDidResignActive(_:)),
                name: UIApplication.didEnterBackgroundNotification, object: nil
            )
        }
        
        @objc func applicationDidBecomeActive(_ notification: Notification) {
            /// Need to dispatch to the next run loop to prevent a possible crash caused by the database resuming mid-query
            DispatchQueue.main.async { [weak self] in
                self?.startObservingChanges(didReturnFromBackground: true)
            }
        }
        
        @objc func applicationDidResignActive(_ notification: Notification) {
            self.stopObservingChanges()
        }
    }
}
