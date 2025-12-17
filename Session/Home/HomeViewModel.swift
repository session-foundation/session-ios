// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import DifferenceKit
import SignalUtilitiesKit
import SessionNetworkingKit
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
    
    public typealias SectionModel = ArraySection<Section, ConversationInfoViewModel>
    
    // MARK: - Section
    
    public enum Section: Differentiable {
        case messageRequests
        case threads
        case loadMore
    }
    
    // MARK: - Variables
    
    private static let pageSize: Int = (UIDevice.current.isIPad ? 20 : 15)
    
    // Reusable OS version check for initial and updated state check
    // Check if the current device is running a version LESS THAN iOS 16.0
    private static func isOSVersionDeprecated(using dependencies: Dependencies) -> Bool {
        let systemVersion = ProcessInfo.processInfo.operatingSystemVersion
        return systemVersion.majorVersion < dependencies[feature: .versionDeprecationMinimum]
    }
    
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
                .checkIfAppWasInstalledPriorToAppReviewRelease(using: dependencies),
            showVersionSupportBanner: Self.isOSVersionDeprecated(using: dependencies) && dependencies[feature: .versionDeprecationWarning]
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
        observationTask?.cancel()
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
        
        let loadedPageInfo: PagedData.LoadedInfo<ConversationInfoViewModel.ID>
        let dataCache: ConversationDataCache
        let itemCache: [ConversationInfoViewModel.ID: ConversationInfoViewModel]
        
        let appReviewPromptState: AppReviewPromptState?
        let pendingAppReviewPromptState: AppReviewPromptState?
        let appWasInstalledPriorToAppReviewRelease: Bool
        let showVersionSupportBanner: Bool
        let showDonationsCTAModal: Bool
        
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
                .anyMessageCreatedInAnyConversation,
                .anyContactBlockedStatusChanged,
                .profile(userProfile.id),
                .feature(.serviceNetwork),
                .feature(.forceOffline),
                .setting(.hasSavedThread),
                .setting(.hasSavedMessage),
                .setting(.hasViewedSeed),
                .setting(.hasHiddenMessageRequests),
                .userDefault(.hasVisitedPathScreen),
                .userDefault(.hasPressedDonateButton),
                .userDefault(.hasChangedTheme),
                .updateScreen(HomeViewModel.self),
                .feature(.versionDeprecationWarning),
                .feature(.versionDeprecationMinimum),
                .showDonationsCTAModal
            ]
            
            result.insert(contentsOf: Set(itemCache.values.flatMap { $0.observedKeys }))
            
            return result
        }
        
        static func initialState(
            using dependencies: Dependencies,
            appReviewPromptState: AppReviewPromptState?,
            appWasInstalledPriorToAppReviewRelease: Bool,
            showVersionSupportBanner: Bool
        ) -> State {
            let userSessionId: SessionId = dependencies[cache: .general].sessionId
            
            return State(
                viewState: .loading,
                userProfile: Profile.with(id: userSessionId.hexString, name: ""),
                serviceNetwork: dependencies[feature: .serviceNetwork],
                forceOffline: dependencies[feature: .forceOffline],
                hasSavedThread: false,
                hasSavedMessage: false,
                showViewedSeedBanner: true,
                hasHiddenMessageRequests: false,
                unreadMessageRequestThreadCount: 0,
                loadedPageInfo: PagedData.LoadedInfo(
                    record: SessionThread.self,
                    pageSize: HomeViewModel.pageSize,
                    requiredJoinSQL: ConversationInfoViewModel.requiredJoinSQL,
                    filterSQL: ConversationInfoViewModel.homeFilterSQL(userSessionId: userSessionId),
                    groupSQL: nil,
                    orderSQL: ConversationInfoViewModel.homeOrderSQL
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
                itemCache: [:],
                appReviewPromptState: nil,
                pendingAppReviewPromptState: appReviewPromptState,
                appWasInstalledPriorToAppReviewRelease: appWasInstalledPriorToAppReviewRelease,
                showVersionSupportBanner: showVersionSupportBanner,
                showDonationsCTAModal: false
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
        var dataCache: ConversationDataCache = previousState.dataCache
        var itemCache: [ConversationInfoViewModel.ID: ConversationInfoViewModel] = previousState.itemCache
        
        var appReviewPromptState: AppReviewPromptState? = previousState.appReviewPromptState
        var pendingAppReviewPromptState: AppReviewPromptState? = previousState.pendingAppReviewPromptState
        let appWasInstalledPriorToAppReviewRelease: Bool = previousState.appWasInstalledPriorToAppReviewRelease
        var showVersionSupportBanner: Bool = previousState.showVersionSupportBanner
        var showDonationsCTAModal: Bool = previousState.showDonationsCTAModal
        
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
            
            dataCache.insert(userProfile)
            
            /// If we haven't hidden the message requests banner then we should include that in the initial fetch
            if !hasHiddenMessageRequests {
                eventsToProcess.append(ObservedEvent(
                    key: .messageRequestUnreadMessageReceived,
                    value: nil
                ))
            }
        }
        
        /// If there are no events we want to process then just return the current state
        guard isInitialQuery || !eventsToProcess.isEmpty else { return previousState }
        
        /// Split the events between those that need database access and those that don't
        let changes: EventChangeset = eventsToProcess.split(by: { $0.handlingStrategy })
        let loadPageEvent: LoadPageEvent? = changes.latestGeneric(.loadPage, as: LoadPageEvent.self)
        
        /// Update the context
        dataCache.withContext(
            source: .conversationList,
            requireFullRefresh: (
                isInitialQuery ||
                changes.containsAny(
                    .appLifecycle(.willEnterForeground),
                    .databaseLifecycle(.resumed)
                )
            ),
            requiresMessageRequestCountUpdate: changes.containsAny(
                .messageRequestUnreadMessageReceived,
                .messageRequestAccepted,
                .messageRequestDeleted,
                .messageRequestMessageRead
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
                Log.warn(.homeViewModel, "Failed to handle \(changes.libSessionEvents.count) libSession event(s) due to error: \(error).")
            }
        }
        
        /// Peform any database changes
        if !dependencies[singleton: .storage].isSuspended, fetchRequirements.needsAnyFetch {
            do {
                try await dependencies[singleton: .storage].readAsync { db in
                    /// Update the `unreadMessageRequestThreadCount` if needed (since multiple events need this)
                    if fetchRequirements.requiresMessageRequestCountUpdate {
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
                Log.critical(.homeViewModel, "Failed to fetch state for events [\(eventList)], due to error: \(error)")
            }
        }
        else if !changes.databaseEvents.isEmpty {
            Log.warn(.homeViewModel, "Ignored \(changes.databaseEvents.count) database event(s) sent while storage was suspended.")
        }
        
        /// Then handle remaining non-database events
        changes.forEachEvent(.setting, as: Bool.self) { event, updatedValue in
            switch event.key {
                case .setting(.hasSavedThread): hasSavedThread = (updatedValue || hasSavedThread)
                case .setting(.hasSavedMessage): hasSavedMessage = (updatedValue || hasSavedMessage)
                case .setting(.hasViewedSeed): showViewedSeedBanner = !updatedValue // Inverted
                case .setting(.hasHiddenMessageRequests): hasHiddenMessageRequests = updatedValue
                default: break
            }
        }
        
        if let updatedValue: ServiceNetwork = changes.latest(.feature(.serviceNetwork), as: ServiceNetwork.self) {
            serviceNetwork = updatedValue
        }
        
        if let updatedValue: Bool = changes.latest(.feature(.forceOffline), as: Bool.self) {
            forceOffline = updatedValue
        }
        
        // FIXME: Should be able to consolodate these two into a single value
        if let updatedValue: Bool = changes.latest(.feature(.versionDeprecationWarning), as: Bool.self) {
            showVersionSupportBanner = (isOSVersionDeprecated(using: dependencies) && updatedValue)
        }
        
        if changes.latest(.feature(.versionDeprecationMinimum), as: Int.self) != nil {
            showVersionSupportBanner = (isOSVersionDeprecated(using: dependencies) && dependencies[feature: .versionDeprecationWarning])
        }
        
        /// Next trigger should be ignored if `didShowAppReviewPrompt` is true
        if dependencies[defaults: .standard, key: .didShowAppReviewPrompt] == true {
            pendingAppReviewPromptState = nil
        } else {
            changes.forEachEvent(.userDefault, as: Bool.self) { event, updatedValue in
                switch (event.key, updatedValue, appWasInstalledPriorToAppReviewRelease) {
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
        
        if let updatedValue: HomeViewModelEvent = changes.latestGeneric(.updateScreen, as: HomeViewModelEvent.self) {
            pendingAppReviewPromptState = updatedValue.pendingAppReviewPromptState
            appReviewPromptState = updatedValue.appReviewPromptState
        }
        
        /// If this update has an event indicating we should show the donations modal then do so, the next change will result in the flag
        /// being reset so we don't unintentionally show it again
        if changes.contains(.showDonationsCTAModal) {
            showDonationsCTAModal = true
        }
        else if showDonationsCTAModal {
            showDonationsCTAModal = false
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
            dataCache: dataCache,
            itemCache: itemCache,
            appReviewPromptState: appReviewPromptState,
            pendingAppReviewPromptState: pendingAppReviewPromptState,
            appWasInstalledPriorToAppReviewRelease: appWasInstalledPriorToAppReviewRelease,
            showVersionSupportBanner: showVersionSupportBanner,
            showDonationsCTAModal: showDonationsCTAModal
        )
    }
    
    private static func sections(state: State, viewModel: HomeViewModel) -> [SectionModel] {
        return [
            /// If the message request section is hidden or there are no unread message requests then hide the message request banner
            (state.hasHiddenMessageRequests || state.unreadMessageRequestThreadCount == 0 ?
                [] :
                [SectionModel(
                    section: .messageRequests,
                    elements: [
                        ConversationInfoViewModel.unreadMessageRequestsBanner(
                            unreadCount: state.unreadMessageRequestThreadCount
                        )
                    ]
                )]
            ),
            [
                SectionModel(
                    section: .threads,
                    elements: state.loadedPageInfo.currentIds.compactMap { state.itemCache[$0] }
                )
            ],
            (!state.loadedPageInfo.currentIds.isEmpty && state.loadedPageInfo.hasNextPage ?
                [SectionModel(section: .loadMore)] :
                []
            )
        ].flatMap { $0 }
    }
    
    // MARK: - Handle App review
    
    @MainActor func viewDidAppear() {
        dependencies[singleton: .donationsManager].conversationListDidAppear()
        
        if state.pendingAppReviewPromptState != nil {
            // Handle App review
            DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(1)) { [weak self, dependencies] in
                guard let updatedState: AppReviewPromptState = self?.state.pendingAppReviewPromptState else { return }
                
                dependencies[defaults: .standard, key: .didActionAppReviewPrompt] = false
                
                self?.handlePromptChangeState(updatedState)
            }
        }
        
        // Camera reminder
        willShowCameraPermissionReminder()
        
        // Pro expiring/expired CTA
        Task { await showSessionProCTAIfNeeded() }
    }

    func scheduleAppReviewRetry() {
        /// Wait 2 weeks before trying again
        dependencies[defaults: .standard, key: .rateAppRetryDate] = dependencies.dateNow
            .addingTimeInterval(2 * 7 * 24 * 60 * 60)
    }
    
    @MainActor func showSessionProCTAIfNeeded() async {
        guard let info = await dependencies[singleton: .sessionProManager].sessionProExpiringCTAInfo() else {
            return
        }
        
        try? await Task.sleep(for: .seconds(1)) /// Cooperative suspension, so safe to call on main thread
        
        dependencies[singleton: .sessionProManager].showSessionProCTAIfNeeded(
            info.variant,
            onConfirm: { [weak self, dependencies] in
                let viewController: SessionHostingViewController = SessionHostingViewController(
                    rootView: SessionProPaymentScreen(
                        viewModel: SessionProPaymentScreenContent.ViewModel(
                            dataModel: SessionProPaymentScreenContent.DataModel(
                                flow: info.paymentFlow,
                                plans: info.planInfo
                            ),
                            isFromBottomSheet: false,
                            using: dependencies
                        )
                    )
                )
                self?.transitionToScreen(viewController)
            },
            presenting: { [weak self, dependencies] modal in
                dependencies[defaults: .standard, key: .hasShownProExpiringCTA] = true
                self?.transitionToScreen(modal, transitionType: .present)
            }
        )
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
        guard let url: URL = URL(string: Constants.urls.feedback) else { return }
        
        // stringlint:disable
        let surveyUrl: URL = url.appending(queryItems: [
            .init(name: "platform", value: Constants.PaymentProvider.appStore.device),
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
    
    @MainActor func handlePrimaryTappedForState(_ state: AppReviewPromptState) {
        dependencies[defaults: .standard, key: .didActionAppReviewPrompt] = true
        
        switch state {
            case .enjoyingSession: handlePromptChangeState(.feedback)
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
    
    @MainActor func handleSecondayTappedForState(_ state: AppReviewPromptState) {
        dependencies[defaults: .standard, key: .didActionAppReviewPrompt] = true
        
        switch state {
            case .feedback, .rateSession: handlePromptChangeState(nil)
            case .enjoyingSession:
                handlePromptChangeState(.rateSession)
                scheduleAppReviewRetry()
                dependencies[singleton: .donationsManager].positiveReviewChosen()
                
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
    
    @MainActor public func loadPageAfter() {
        dependencies.notifyAsync(
            key: .loadPage(HomeViewModel.self),
            value: LoadPageEvent.nextPage(lastIndex: state.loadedPageInfo.lastIndex)
        )
    }
}

// MARK: - Convenience

private extension ObservedEvent {
    var handlingStrategy: EventHandlingStrategy {
        let threadInfoStrategy: EventHandlingStrategy? = ConversationInfoViewModel.handlingStrategy(for: self)
        let localStrategy: EventHandlingStrategy = {
            switch (key, key.generic) {
                case (.setting(.hasHiddenMessageRequests), _): return [.databaseQuery, .directCacheUpdate]
                case (ObservableKey.feature(.serviceNetwork), _): return .directCacheUpdate
                case (ObservableKey.feature(.forceOffline), _): return .directCacheUpdate
                case (.setting(.hasViewedSeed), _): return .directCacheUpdate
                    
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
