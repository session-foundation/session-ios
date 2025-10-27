// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import DifferenceKit
import SignalUtilitiesKit
import SessionMessagingKit
import SessionUtilitiesKit
import StoreKit
import SessionUIKit

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
    
    private static let pageSize: Int = (UIDevice.current.isIPad ? 20 : 15)
    
    public let dependencies: Dependencies
    private let userSessionId: SessionId
    private var didPresentAppReviewPrompt: Bool = false

    /// This value is the current state of the view
    @MainActor @Published private(set) var state: State
    private var observationTask: Task<Void, Never>?
    
    // MARK: - Initialization
    @MainActor init(using dependencies: Dependencies) {
        self.dependencies = dependencies
        self.userSessionId = dependencies[cache: .general].sessionId

        self.state = State.initialState(
            using: dependencies,
            appReviewPromptState: AppReviewPromptModel
                .loadInitialAppReviewPromptState(using: dependencies),
            appWasInstalledPriorToAppReviewRelease: AppReviewPromptModel
                .checkIfAppWasInstalledPriorToAppReviewRelease(using: dependencies)
        )
        
        /// Bind the state
        self.observationTask = ObservationBuilder
            .initialValue(self.state)
            .debounce(for: .milliseconds(250))
            .using(dependencies: dependencies)
            .query(HomeViewModel.queryState)
            .assign { [weak self] updatedState in self?.state = updatedState }
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    public struct HomeViewModelEvent: Hashable {
        let pendingAppReviewPromptState: AppReviewPromptState?
        let appReviewPromptState: AppReviewPromptState?
    }
    
    // MARK: - State

    public struct State: ObservableKeyProvider {
        enum ViewState: Equatable {
            case loading
            case empty(isNewUser: Bool)
            case loaded
        }
        
        let viewState: ViewState
        let userProfile: Profile
        let serviceNetwork: ServiceNetwork
        let forceOffline: Bool
        let hasSavedThread: Bool
        let hasSavedMessage: Bool
        let showViewedSeedBanner: Bool
        let hasHiddenMessageRequests: Bool
        let unreadMessageRequestThreadCount: Int
        let loadedPageInfo: PagedData.LoadedInfo<SessionThreadViewModel.ID>
        let itemCache: [String: SessionThreadViewModel]
        let profileCache: [String: Profile]
        let appReviewPromptState: AppReviewPromptState?
        let pendingAppReviewPromptState: AppReviewPromptState?
        let appWasInstalledPriorToAppReviewRelease: Bool
        
        @MainActor public func sections(viewModel: HomeViewModel) -> [SectionModel] {
            HomeViewModel.sections(state: self, viewModel: viewModel)
        }
        
        public var observedKeys: Set<ObservableKey> {
            var result: Set<ObservableKey> = [
                .appLifecycle(.willEnterForeground),
                .databaseLifecycle(.resumed),
                .loadPage(HomeViewModel.self),
                .messageRequestAccepted,
                .messageRequestDeleted,
                .messageRequestMessageRead,
                .messageRequestUnreadMessageReceived,
                .profile(userProfile.id),
                .feature(.serviceNetwork),
                .feature(.forceOffline),
                .setting(.hasSavedThread),
                .setting(.hasSavedMessage),
                .setting(.hasViewedSeed),
                .setting(.hasHiddenMessageRequests),
                .conversationCreated,
                .anyMessageCreatedInAnyConversation,
                .anyContactBlockedStatusChanged,
                .userDefault(.hasVisitedPathScreen),
                .userDefault(.hasPressedDonateButton),
                .userDefault(.hasChangedTheme),
                .updateScreen(HomeViewModel.self)
            ]
            
            itemCache.values.forEach { threadViewModel in
                result.insert(contentsOf: [
                    .conversationUpdated(threadViewModel.threadId),
                    .conversationDeleted(threadViewModel.threadId),
                    .messageCreated(threadId: threadViewModel.threadId),
                    .messageUpdated(
                        id: threadViewModel.interactionId,
                        threadId: threadViewModel.threadId
                    ),
                    .messageDeleted(
                        id: threadViewModel.interactionId,
                        threadId: threadViewModel.threadId
                    ),
                    .typingIndicator(threadViewModel.threadId)
                ])
                
                if let authorId: String = threadViewModel.authorId {
                    result.insert(.profile(authorId))
                }
            }
            
            return result
        }
        
        static func initialState(using dependencies: Dependencies, appReviewPromptState: AppReviewPromptState?, appWasInstalledPriorToAppReviewRelease: Bool) -> State {
            return State(
                viewState: .loading,
                userProfile: Profile(id: dependencies[cache: .general].sessionId.hexString, name: ""),
                serviceNetwork: dependencies[feature: .serviceNetwork],
                forceOffline: dependencies[feature: .forceOffline],
                hasSavedThread: false,
                hasSavedMessage: false,
                showViewedSeedBanner: true,
                hasHiddenMessageRequests: false,
                unreadMessageRequestThreadCount: 0,
                loadedPageInfo: PagedData.LoadedInfo(
                    record: SessionThreadViewModel.self,
                    pageSize: HomeViewModel.pageSize,
                    /// **Note:** This `optimisedJoinSQL` value includes the required minimum joins needed
                    /// for the query but differs from the JOINs that are actually used for performance reasons as the
                    /// basic logic can be simpler for where it's used
                    requiredJoinSQL: SessionThreadViewModel.optimisedJoinSQL,
                    filterSQL: SessionThreadViewModel.homeFilterSQL(
                        userSessionId: dependencies[cache: .general].sessionId
                    ),
                    groupSQL: SessionThreadViewModel.groupSQL,
                    orderSQL: SessionThreadViewModel.homeOrderSQL
                ),
                itemCache: [:],
                profileCache: [:],
                appReviewPromptState: nil,
                pendingAppReviewPromptState: appReviewPromptState,
                appWasInstalledPriorToAppReviewRelease: appWasInstalledPriorToAppReviewRelease
            )
        }
    }
    
    @Sendable private static func queryState(
        previousState: State,
        events: [ObservedEvent],
        isInitialQuery: Bool,
        using dependencies: Dependencies
    ) async -> State {
        let startedAsNewUser: Bool = (dependencies[cache: .onboarding].initialFlow == .register)
        var userProfile: Profile = previousState.userProfile
        var serviceNetwork: ServiceNetwork = previousState.serviceNetwork
        var forceOffline: Bool = previousState.forceOffline
        var hasSavedThread: Bool = previousState.hasSavedThread
        var hasSavedMessage: Bool = previousState.hasSavedMessage
        var showViewedSeedBanner: Bool = previousState.showViewedSeedBanner
        var hasHiddenMessageRequests: Bool = previousState.hasHiddenMessageRequests
        var unreadMessageRequestThreadCount: Int = previousState.unreadMessageRequestThreadCount
        var loadResult: PagedData.LoadResult = previousState.loadedPageInfo.asResult
        var itemCache: [String: SessionThreadViewModel] = previousState.itemCache
        var profileCache: [String: Profile] = previousState.profileCache
        var appReviewPromptState: AppReviewPromptState? = previousState.appReviewPromptState
        var pendingAppReviewPromptState: AppReviewPromptState? = previousState.pendingAppReviewPromptState
        let appWasInstalledPriorToAppReviewRelease: Bool = previousState.appWasInstalledPriorToAppReviewRelease
        
        /// Store a local copy of the events so we can manipulate it based on the state changes
        var eventsToProcess: [ObservedEvent] = events
        
        /// If this is the initial query then we need to properly fetch the initial state
        if isInitialQuery {
            /// Insert a fake event to force the initial page load
            eventsToProcess.append(ObservedEvent(
                key: .loadPage(HomeViewModel.self),
                value: LoadPageEvent.initial
            ))
            
            /// Load the values needed from `libSession`
            dependencies.mutate(cache: .libSession) { libSession in
                userProfile = libSession.profile
                showViewedSeedBanner = !libSession.get(.hasViewedSeed)
                hasHiddenMessageRequests = libSession.get(.hasHiddenMessageRequests)
            }
            
            /// If the users profile picture doesn't exist on disk then clear out the value (that way if we get events after downloading
            /// it then then there will be a diff in the `State` and the UI will update
            if
                let displayPictureUrl: String = userProfile.displayPictureUrl,
                let filePath: String = try? dependencies[singleton: .displayPictureManager]
                    .path(for: displayPictureUrl),
                !dependencies[singleton: .fileManager].fileExists(atPath: filePath)
            {
                userProfile = userProfile.with(displayPictureUrl: .set(to: nil))
            }
            
            // TODO: [Database Relocation] All profiles should be stored in the `profileCache`
            profileCache[userProfile.id] = userProfile
            
            /// If we haven't hidden the message requests banner then we should include that in the initial fetch
            if !hasHiddenMessageRequests {
                eventsToProcess.append(ObservedEvent(
                    key: .messageRequestUnreadMessageReceived,
                    value: nil
                ))
            }
        }
        
        /// If there are no events we want to process then just return the current state
        guard !eventsToProcess.isEmpty else { return previousState }
        
        /// Split the events between those that need database access and those that don't
        let splitEvents: [EventDataRequirement: Set<ObservedEvent>] = eventsToProcess
            .reduce(into: [:]) { result, next in
                switch next.dataRequirement {
                    case .databaseQuery: result[.databaseQuery, default: []].insert(next)
                    case .other: result[.other, default: []].insert(next)
                    case .bothDatabaseQueryAndOther:
                        result[.databaseQuery, default: []].insert(next)
                        result[.other, default: []].insert(next)
                }
            }
        let groupedOtherEvents: [GenericObservableKey: Set<ObservedEvent>]? = splitEvents[.other]?
            .reduce(into: [:]) { result, event in
                result[event.key.generic, default: []].insert(event)
            }
        
        /// Handle profile events first
        groupedOtherEvents?[.profile]?.forEach { event in
            guard
                let eventValue: ProfileEvent = event.value as? ProfileEvent,
                eventValue.id == userProfile.id
            else { return }
            
            switch eventValue.change {
                case .name(let name): userProfile = userProfile.with(name: name)
                case .nickname(let nickname): userProfile = userProfile.with(nickname: .set(to: nickname))
                case .displayPictureUrl(let url): userProfile = userProfile.with(displayPictureUrl: .set(to: url))
            }
            
            // TODO: [Database Relocation] All profiles should be stored in the `profileCache`
            profileCache[eventValue.id] = userProfile
        }
        
        
        /// Then handle database events
        if !dependencies[singleton: .storage].isSuspended, let databaseEvents: Set<ObservedEvent> = splitEvents[.databaseQuery], !databaseEvents.isEmpty {
            do {
                var fetchedConversations: [SessionThreadViewModel] = []
                let idsNeedingRequery: Set<String> = self.extractIdsNeedingRequery(
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
                            
                        case (GenericObservableKey(.anyContactBlockedStatusChanged), let event as ContactEvent):
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
                    /// Update the `unreadMessageRequestThreadCount` if needed (since multiple events need this)
                    if databaseEvents.contains(where: { $0.requiresMessageRequestCountUpdate }) {
                        // TODO: [Database Relocation] Should be able to clean this up by getting the conversation list and filtering
                        struct ThreadIdVariant: Decodable, Hashable, FetchableRecord {
                            let id: String
                            let variant: SessionThread.Variant
                        }
                        
                        let potentialMessageRequestThreadInfo: Set<ThreadIdVariant> = try SessionThread
                            .select(.id, .variant)
                            .filter(
                                SessionThread.Columns.variant == SessionThread.Variant.contact ||
                                SessionThread.Columns.variant == SessionThread.Variant.group
                            )
                            .asRequest(of: ThreadIdVariant.self)
                            .fetchSet(db)
                        let messageRequestThreadIds: Set<String> = Set(
                            dependencies.mutate(cache: .libSession) { libSession in
                                potentialMessageRequestThreadInfo.compactMap {
                                    guard libSession.isMessageRequest(threadId: $0.id, threadVariant: $0.variant) else {
                                        return nil
                                    }
                                    
                                    return $0.id
                                }
                            }
                        )
                        
                        unreadMessageRequestThreadCount = try SessionThread
                            .unreadMessageRequestsQuery(messageRequestThreadIds: messageRequestThreadIds)
                            .fetchCount(db)
                    }
                    
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
                                orderSQL: SessionThreadViewModel.homeOrderSQL,
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
        else if let databaseEvents: Set<ObservedEvent> = splitEvents[.databaseQuery], !databaseEvents.isEmpty {
            Log.warn(.homeViewModel, "Ignored \(databaseEvents.count) database event(s) sent while storage was suspended.")
        }
        
        /// Then handle remaining non-database events
        groupedOtherEvents?[.setting]?.forEach { event in
            guard let updatedValue: Bool = event.value as? Bool else { return }
            
            switch event.key {
                case .setting(.hasSavedThread): hasSavedThread = (updatedValue || hasSavedThread)
                case .setting(.hasSavedMessage): hasSavedMessage = (updatedValue || hasSavedMessage)
                case .setting(.hasViewedSeed): showViewedSeedBanner = !updatedValue // Inverted
                case .setting(.hasHiddenMessageRequests): hasHiddenMessageRequests = updatedValue
                default: break
            }
        }
        groupedOtherEvents?[.feature]?.forEach { event in
            if event.key == .feature(.serviceNetwork), let updatedValue = event.value as? ServiceNetwork {
                serviceNetwork = updatedValue
            }
            else if event.key == .feature(.forceOffline), let updatedValue = event.value as? Bool {
                forceOffline = updatedValue
            }
        }
        
        /// Next trigger should be ignored if `didShowAppReviewPrompt` is true
        if dependencies[defaults: .standard, key: .didShowAppReviewPrompt] == true {
            pendingAppReviewPromptState = nil
        } else {
            groupedOtherEvents?[.userDefault]?.forEach { event in
                guard let value: Bool = event.value as? Bool else { return }
                
                switch (event.key, value, appWasInstalledPriorToAppReviewRelease) {
                    case (.userDefault(.hasVisitedPathScreen), true, false):
                        pendingAppReviewPromptState = .enjoyingSession
                        
                    case (.userDefault(.hasPressedDonateButton), true, _):
                        pendingAppReviewPromptState = .enjoyingSession
                        
                    case (.userDefault(.hasChangedTheme), true, false):
                        pendingAppReviewPromptState = .enjoyingSession
                        
                    default: break
                }
            }
        }
        
        if let event: HomeViewModelEvent = events.first?.value as? HomeViewModelEvent {
            pendingAppReviewPromptState = event.pendingAppReviewPromptState
            appReviewPromptState = event.appReviewPromptState
        }

        /// Generate the new state
        return State(
            viewState: (loadResult.info.totalCount == 0 && unreadMessageRequestThreadCount == 0 ?
                .empty(isNewUser: (startedAsNewUser && !hasSavedThread && !hasSavedMessage)) :
                .loaded
            ),
            userProfile: userProfile,
            serviceNetwork: serviceNetwork,
            forceOffline: forceOffline,
            hasSavedThread: hasSavedThread,
            hasSavedMessage: hasSavedMessage,
            showViewedSeedBanner: showViewedSeedBanner,
            hasHiddenMessageRequests: hasHiddenMessageRequests,
            unreadMessageRequestThreadCount: unreadMessageRequestThreadCount,
            loadedPageInfo: loadResult.info,
            itemCache: itemCache,
            profileCache: profileCache,
            appReviewPromptState: appReviewPromptState,
            pendingAppReviewPromptState: pendingAppReviewPromptState,
            appWasInstalledPriorToAppReviewRelease: appWasInstalledPriorToAppReviewRelease
        )
    }
    
    private static func extractIdsNeedingRequery(
        events: Set<ObservedEvent>,
        cache: [String: SessionThreadViewModel]
    ) -> Set<String> {
        let requireFullRefresh: Bool = events.contains(where: { event in
            event.key == .appLifecycle(.willEnterForeground) ||
            event.key == .databaseLifecycle(.resumed)
        })
        
        guard !requireFullRefresh else {
            return Set(cache.keys)
        }
        
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
    
    private static func sections(state: State, viewModel: HomeViewModel) -> [SectionModel] {
        let userSessionId: SessionId = viewModel.dependencies[cache: .general].sessionId
        
        return [
            /// If the message request section is hidden or there are no unread message requests then hide the message request banner
            (state.hasHiddenMessageRequests || state.unreadMessageRequestThreadCount == 0 ?
                [] :
                [SectionModel(
                    section: .messageRequests,
                    elements: [
                        SessionThreadViewModel(
                            threadId: SessionThreadViewModel.messageRequestsSectionId,
                            unreadCount: UInt(state.unreadMessageRequestThreadCount),
                            using: viewModel.dependencies
                        )
                    ]
                )]
            ),
            [
                SectionModel(
                    section: .threads,
                    elements: state.loadedPageInfo.currentIds
                        .compactMap { state.itemCache[$0] }
                        .map { conversation -> SessionThreadViewModel in
                            conversation.populatingPostQueryData(
                                recentReactionEmoji: nil,
                                openGroupCapabilities: nil,
                                // TODO: [Database Relocation] Do we need all of these????
                                currentUserSessionIds: [userSessionId.hexString],
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
                                threadCanWrite: false,  // Irrelevant for the HomeViewModel
                                threadCanUpload: false  // Irrelevant for the HomeViewModel
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
    
    // MARK: - Handle App review
    @MainActor
    func viewDidAppear() {
        if state.pendingAppReviewPromptState != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(1)) { [weak self, dependencies] in
                guard let updatedState: AppReviewPromptState = self?.state.pendingAppReviewPromptState else { return }
                
                dependencies[defaults: .standard, key: .didActionAppReviewPrompt] = false
                
                self?.handlePromptChangeState(updatedState)
            }
        }
        
        // Camera reminder
        willShowCameraPermissionReminder()
    }

    func scheduleAppReviewRetry() {
        /// Wait 2 weeks before trying again
        dependencies[defaults: .standard, key: .rateAppRetryDate] = dependencies.dateNow
            .addingTimeInterval(2 * 7 * 24 * 60 * 60)
    }
    
    func handlePromptChangeState(_ state: AppReviewPromptState?) {
        // Set`didActionAppReviewPrompt` to true when closed from `x` button of prompt
        // or in show rate limit prompt so it does not show again on relaunch
        if state == nil || state == .rateLimit { dependencies[defaults: .standard, key: .didActionAppReviewPrompt] = true }
        
        // Set `didShowAppReviewPrompt` when a new state is presented
        if state != nil { dependencies[defaults: .standard, key: .didShowAppReviewPrompt] = true }
        
        dependencies.notifyAsync(
            priority: .immediate,
            key: .updateScreen(HomeViewModel.self),
            value: HomeViewModelEvent(
                pendingAppReviewPromptState: nil,
                appReviewPromptState: state
            )
        )
    }

    @MainActor
    func submitAppStoreReview() {
        dependencies[defaults: .standard, key: .rateAppRetryDate] = nil
        dependencies[defaults: .standard, key: .rateAppRetryAttemptCount] = 0
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(self.windowBecameVisibleAfterTriggeringAppStoreReview(notification:)),
            name: UIWindow.didBecomeVisibleNotification, object: nil
        )
        
        if !dependencies[feature: .simulateAppReviewLimit] {
            requestAppReview()
        }

        // Added 2 sec delay to give time for requet review to proc
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(2)) { [weak self] in
            guard let this = self else { return }
            
            NotificationCenter.default.removeObserver(this, name: UIWindow.didBecomeVisibleNotification, object: nil)
            
            guard this.didPresentAppReviewPrompt else {
                // Show rate limit prompt
                this.handlePromptChangeState(.rateLimit)
                return
            }
            
            // Reset flag just in case it will be triggered again
            this.didPresentAppReviewPrompt = false
        }
    }
    
    @MainActor
    private func requestAppReview() {
        guard let scene = UIApplication.shared.connectedScenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene else {
            return
        }
        
        if #available(iOS 16.0, *) {
            AppStore.requestReview(in: scene)
        } else {
            SKStoreReviewController.requestReview(in: scene)
        }
    }
    
    @objc
    private func windowBecameVisibleAfterTriggeringAppStoreReview(notification: Notification) {
        didPresentAppReviewPrompt = true
    }
    
    @MainActor
    func submitFeedbackSurvery() {
        guard let url: URL = URL(string: Constants.session_feedback_url) else { return }
        
        // stringlint:disable
        let surveyUrl: URL = url.appending(queryItems: [
            .init(name: "platform", value: Constants.platform_name),
            .init(name: "version", value: dependencies[cache: .appVersion].appVersion)
        ])
        
        let modal: ConfirmationModal = ConfirmationModal(
            info: ConfirmationModal.Info(
                title: "urlOpen".localized(),
                body: .attributedText(
                    "urlOpenDescription"
                        .put(key: "url", value: surveyUrl.absoluteString)
                        .localizedFormatted(baseFont: .systemFont(ofSize: Values.smallFontSize))
                ),
                confirmTitle: "open".localized(),
                confirmStyle: .danger,
                cancelTitle: "urlCopy".localized(),
                cancelStyle: .alert_text,
                hasCloseButton: true,
                onConfirm: { modal in
                    UIApplication.shared.open(surveyUrl, options: [:], completionHandler: nil)
                    modal.dismiss(animated: true)
                },
                onCancel: { modal in
                    UIPasteboard.general.string = surveyUrl.absoluteString
                    
                    modal.dismiss(animated: true)
                }
            )
        )
        
        self.transitionToScreen(modal, transitionType: .present)
    }
    
    @MainActor
    func handlePrimaryTappedForState(_ state: AppReviewPromptState) {
        dependencies[defaults: .standard, key: .didActionAppReviewPrompt] = true
        
        switch state {
            case .enjoyingSession:
                handlePromptChangeState(.rateSession)
                scheduleAppReviewRetry()
            case .feedback:
                // Close prompt before showing survery
                handlePromptChangeState(nil)
                submitFeedbackSurvery()
            case .rateSession:
                // Close prompt before showing app review
                handlePromptChangeState(nil)
                submitAppStoreReview()
            default: break
        }
    }
    
    func handleSecondayTappedForState(_ state: AppReviewPromptState) {
        dependencies[defaults: .standard, key: .didActionAppReviewPrompt] = true
        
        switch state {
            case .feedback, .rateSession: handlePromptChangeState(nil)
            case .enjoyingSession: handlePromptChangeState(.feedback)
            default: break
        }
    }
    
    // Camera permission
    func willShowCameraPermissionReminder() {
        guard
            dependencies[singleton: .screenLock].checkIfScreenIsUnlocked(), // Show camera access reminder when app has been unlocked
            !dependencies[defaults: .appGroup, key: .isCallOngoing] // Checks if there is still an ongoing call
        else {
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(1)) { [dependencies] in
            Permissions.remindCameraAccessRequirement(using: dependencies)
        }
    }
    
    @MainActor
    @objc func didReturnFromBackground() {
        // Observe changes to app state retry and flags when app goes to bg to fg
        if AppReviewPromptModel.checkAndRefreshAppReviewState(using: dependencies) {
            // state.appReviewPromptState check so it does not replace existing prompt if there is any
            let updatedState = state.appReviewPromptState ?? .rateSession
            
            // Handles scenario where app is in background -> foreground when the retry date is hit
            DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(1)) { [weak self] in
                self?.handlePromptChangeState(updatedState)
            }
        }
        
        // Camera reminder
        willShowCameraPermissionReminder()
    }

    // MARK: - Functions
    
    @MainActor func loadPageBefore() {
        dependencies.notifyAsync(
            key: .loadPage(HomeViewModel.self),
            value: LoadPageEvent.previousPage(firstIndex: state.loadedPageInfo.firstIndex)
        )
    }
    
    @MainActor public func loadNextPage() {
        dependencies.notifyAsync(
            key: .loadPage(HomeViewModel.self),
            value: LoadPageEvent.nextPage(lastIndex: state.loadedPageInfo.lastIndex)
        )
    }
}

// MARK: - Convenience

private enum EventDataRequirement {
    case databaseQuery
    case other
    case bothDatabaseQueryAndOther
}

private extension ObservedEvent {
    var dataRequirement: EventDataRequirement {
        switch (key, key.generic) {
            case (.setting(.hasHiddenMessageRequests), _): return .bothDatabaseQueryAndOther
                
            case (_, .profile): return .bothDatabaseQueryAndOther
            case (.feature(.serviceNetwork), _): return .other
            case (.feature(.forceOffline), _): return .other
            case (.setting(.hasViewedSeed), _): return .other
                
            case (.appLifecycle(.willEnterForeground), _): return .databaseQuery
            case (.messageRequestUnreadMessageReceived, _), (.messageRequestAccepted, _),
                (.messageRequestDeleted, _), (.messageRequestMessageRead, _):
                return .databaseQuery
            case (_, .loadPage): return .databaseQuery
            case (.conversationCreated, _): return .databaseQuery
            case (.anyMessageCreatedInAnyConversation, _): return .databaseQuery
            case (.anyContactBlockedStatusChanged, _): return .databaseQuery
            case (_, .typingIndicator): return .databaseQuery
            case (_, .conversationUpdated), (_, .conversationDeleted): return .databaseQuery
            case (_, .messageCreated), (_, .messageUpdated), (_, .messageDeleted): return .databaseQuery
            default: return .other
        }
    }
    
    var requiresMessageRequestCountUpdate: Bool {
        switch self.key {
            case .messageRequestUnreadMessageReceived, .messageRequestAccepted, .messageRequestDeleted,
                .messageRequestMessageRead:
                return true
                
            default: return false
        }
    }
}

private extension URL {
    @available(iOS, introduced: 13.0, obsoleted: 16.0)
    func appending(queryItems: [URLQueryItem]) -> URL {
        guard var components = URLComponents(url: self, resolvingAgainstBaseURL: false) else {
            return self
        }
        
        var existingItems = components.queryItems ?? []
        existingItems.append(contentsOf: queryItems)
        components.queryItems = existingItems

        return components.url ?? self
    }
}
