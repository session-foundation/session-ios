// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import DifferenceKit
import SignalUtilitiesKit
import SessionMessagingKit
import SessionUtilitiesKit

// MARK: - Log.Category

public extension Log.Category {
    static let homeViewModel: Log.Category = .create("HomeViewModel", defaultLevel: .warn)
}

// MARK: - HomeViewModel

public class HomeViewModel: NavigatableStateHolder {
    public let navigatableState: NavigatableState = NavigatableState()
    
    public typealias SectionModel = ArraySection<Section, SessionThreadViewModel>
    
    // MARK: - Section
    
    public enum Section: Differentiable {
        case messageRequests
        case threads
        case loadMore
    }
    
    // MARK: - Variables
    
    public static let pageSize: Int = (UIDevice.current.isIPad ? 20 : 15)
    
    public struct State: Equatable {
        let userSessionId: SessionId
        let showViewedSeedBanner: Bool
        let hasHiddenMessageRequests: Bool
        let unreadMessageRequestThreadCount: Int
        let userProfile: Profile
    }
    
    public let dependencies: Dependencies
    
    // MARK: - Initialization
    
    init(using dependencies: Dependencies) {
        self.dependencies = dependencies
        self.state = dependencies.mutate(cache: .libSession) { cache in
            HomeViewModel.retrieveState(cache: KeyCollector(store: cache), using: dependencies)
        }
        self.pagedDataObserver = nil
        
        // Note: Since this references self we need to finish initializing before setting it, we
        // also want to skip the initial query and trigger it async so that the push animation
        // doesn't stutter (it should load basically immediately but without this there is a
        // distinct stutter)
        let userSessionId: SessionId = self.state.userSessionId
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
                    columns: [.name, .nickname, .displayPictureUrl],
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
                                                \(groupMember[.profileId]) != \(userSessionId.hexString)
                                            )
                                        ) OR
                                        profile.id = (  -- Back profile
                                            SELECT MAX(\(groupMember[.profileId]))
                                            FROM \(GroupMember.self)
                                            JOIN \(Profile.self) ON \(profile[.id]) = \(groupMember[.profileId])
                                            WHERE (
                                                \(groupMember[.groupId]) = \(thread[.id]) AND
                                                \(SQL("\(groupMember[.role]) = \(targetRole)")) AND
                                                \(groupMember[.profileId]) != \(userSessionId.hexString)
                                            )
                                        ) OR (  -- Fallback profile
                                            profile.id = \(userSessionId.hexString) AND
                                            (
                                                SELECT COUNT(\(groupMember[.profileId]))
                                                FROM \(GroupMember.self)
                                                JOIN \(Profile.self) ON \(profile[.id]) = \(groupMember[.profileId])
                                                WHERE (
                                                    \(groupMember[.groupId]) = \(thread[.id]) AND
                                                    \(SQL("\(groupMember[.role]) = \(targetRole)")) AND
                                                    \(groupMember[.profileId]) != \(userSessionId.hexString)
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
                    columns: [.name, .invited, .displayPictureUrl],
                    joinToPagedType: {
                        let closedGroup: TypedTableAlias<ClosedGroup> = TypedTableAlias()
                        
                        return SQL("JOIN \(ClosedGroup.self) ON \(closedGroup[.threadId]) = \(thread[.id])")
                    }()
                ),
                PagedData.ObservedChanges(
                    table: OpenGroup.self,
                    columns: [.name, .displayPictureOriginalUrl],
                    joinToPagedType: {
                        let openGroup: TypedTableAlias<OpenGroup> = TypedTableAlias()
                        
                        return SQL("JOIN \(OpenGroup.self) ON \(openGroup[.threadId]) = \(thread[.id])")
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
            filterSQL: SessionThreadViewModel.homeFilterSQL(userSessionId: userSessionId),
            groupSQL: SessionThreadViewModel.groupSQL,
            orderSQL: SessionThreadViewModel.homeOrderSQL,
            dataQuery: SessionThreadViewModel.baseQuery(
                userSessionId: userSessionId,
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
            },
            using: dependencies
        )
        
        // Run the initial query on a background thread so we don't block the main thread
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // The `.pageBefore` will query from a `0` offset loading the first page
            self?.pagedDataObserver?.load(.pageBefore)
        }
    }
    
    // MARK: - State
    
    /// This value is the current state of the view
    public private(set) var state: State
    public func createStateStream() -> AsyncThrowingStream<State, Error> {
        return ObservationBuilder
            .libSessionObservation(dependencies) { [dependencies] cache -> State in
                HomeViewModel.retrieveState(cache: cache, using: dependencies)
            }
            .map { [dependencies] state in
                /// We don't want to block `libSession` by making a database query during it's mutation so fetch the count outside
                /// of the observation closure
                let unreadMessageRequestThreadCount: Int = dependencies[singleton: .storage].read { db -> Int? in
                    try SessionThread
                        .unreadMessageRequestsCountQuery(userSessionId: state.userSessionId)
                        .fetchOne(db)
                }
                .defaulting(to: 0)
                
                return State(
                    userSessionId: state.userSessionId,
                    showViewedSeedBanner: state.showViewedSeedBanner,
                    hasHiddenMessageRequests: state.hasHiddenMessageRequests,
                    unreadMessageRequestThreadCount: unreadMessageRequestThreadCount,
                    userProfile: state.userProfile
                )
            }
            .removeDuplicates()
    }
    
    private static func retrieveState(
        cache: KeyCollector,
        using dependencies: Dependencies
    ) -> State {
        /// Register to also be updated when receiving an unread message request message
        cache.register(.unreadMessageRequestMessageReceived)
        
        return State(
            userSessionId: cache.userSessionId,
            showViewedSeedBanner: !cache.get(.hasViewedSeed),
            hasHiddenMessageRequests: cache.get(.hasHiddenMessageRequests),
            unreadMessageRequestThreadCount: 0,
            userProfile: cache.profile
        )
    }
    
    public func updateState(_ updatedState: State) {
        let oldState: State = self.state
        self.state = updatedState
        
        // If the messageRequest content changed then we need to re-process the thread data (assuming
        // we've received the initial thread data)
        guard
            self.hasReceivedInitialThreadData,
            (
                oldState.hasHiddenMessageRequests != updatedState.hasHiddenMessageRequests ||
                oldState.unreadMessageRequestThreadCount != updatedState.unreadMessageRequestThreadCount
            ),
            let currentPageInfo: PagedData.PageInfo = self.pagedDataObserver?.pageInfo
        else { return }
        
        /// **MUST** have the same logic as in the 'PagedDataObserver.onChangeUnsorted' above
        let currentData: [SectionModel] = (self.unobservedThreadDataChanges ?? self.threadData)
        let updatedThreadData: [SectionModel] = self.process(
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
    public private(set) var unobservedThreadDataChanges: [SectionModel]?
    public private(set) var threadData: [SectionModel] = []
    public private(set) var pagedDataObserver: PagedDatabaseObserver<SessionThread, SessionThreadViewModel>?
    
    public var onThreadChange: (([SectionModel], StagedChangeset<[SectionModel]>) -> ())? {
        didSet {
            guard onThreadChange != nil else { return }
            
            // When starting to observe interaction changes we want to trigger a UI update just in case the
            // data was changed while we weren't observing
            if let changes: [SectionModel] = self.unobservedThreadDataChanges {
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
    
    private func process(data: [SessionThreadViewModel], for pageInfo: PagedData.PageInfo) -> [SectionModel] {
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
                [SectionModel(
                    section: .messageRequests,
                    elements: [
                        SessionThreadViewModel(
                            threadId: SessionThreadViewModel.messageRequestsSectionId,
                            unreadCount: UInt(finalUnreadMessageRequestCount),
                            using: dependencies
                        )
                    ]
                )]
            ),
            [
                SectionModel(
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
                            viewModel.populatingPostQueryData(
                                recentReactionEmoji: nil,
                                openGroupCapabilities: nil,
                                currentUserSessionIds: (groupedOldData[viewModel.threadId]?
                                    .first?
                                    .currentUserSessionIds)
                                .defaulting(to: [dependencies[cache: .general].sessionId.hexString]),
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
                                threadCanWrite: false  // Irrelevant for the HomeViewModel
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
}
