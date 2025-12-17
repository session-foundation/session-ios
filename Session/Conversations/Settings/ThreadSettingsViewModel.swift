// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI
import Foundation
import PhotosUI
import Combine
import Lucide
import GRDB
import DifferenceKit
import SessionUIKit
import SessionMessagingKit
import SignalUtilitiesKit
import SessionUtilitiesKit
import SessionNetworkingKit

// MARK: - Log.Category

public extension Log.Category {
    static let threadSettingsViewModel: Log.Category = .create("ThreadSettingsViewModel", defaultLevel: .warn)
}

// MARK: - ThreadSettingsViewModel

class ThreadSettingsViewModel: SessionTableViewModel, NavigationItemSource, NavigatableStateHolder, ObservableTableSource {
    public let dependencies: Dependencies
    public let navigatableState: NavigatableState = NavigatableState()
    public let state: TableDataState<Section, TableItem> = TableDataState()
    public let observableState: ObservableTableSourceState<Section, TableItem> = ObservableTableSourceState()
    
    private let didTriggerSearch: () -> ()
    private var updatedName: String?
    private var updatedDescription: String?
    private var onDisplayPictureSelected: ((ImageDataManager.DataSource, CGRect?) -> Void)?
    private lazy var imagePickerHandler: ImagePickerHandler = ImagePickerHandler(
        onTransition: { [weak self] in self?.transitionToScreen($0, transitionType: $1) },
        onImagePicked: { [weak self] source, cropRect in
            self?.onDisplayPictureSelected?(source, cropRect)
        },
        using: dependencies
    )
    
    /// This value is the current state of the view
    @MainActor @Published private(set) var internalState: State
    private var observationTask: Task<Void, Never>?
    
    // MARK: - Initialization
    
    @MainActor init(
        threadInfo: ConversationInfoViewModel,
        didTriggerSearch: @escaping () -> (),
        using dependencies: Dependencies
    ) {
        self.dependencies = dependencies
        self.didTriggerSearch = didTriggerSearch
        self.internalState = State.initialState(threadInfo: threadInfo, using: dependencies)
        self.observationTask = nil
        
        /// Bind the state
        self.observationTask = ObservationBuilder
            .initialValue(self.internalState)
            .debounce(for: .milliseconds(10))   /// Changes trigger multiple events at once so debounce them
            .using(dependencies: dependencies)
            .query(ThreadSettingsViewModel.queryState)
            .assign { [weak self] updatedState in
                guard let self = self else { return }
                
                // FIXME: To slightly reduce the size of the changes this new observation mechanism is currently wired into the old SessionTableViewController observation mechanism, we should refactor it so everything uses the new mechanism
                self.internalState = updatedState
                self.pendingTableDataSubject.send(updatedState.sections(viewModel: self))
            }
    }
    
    // MARK: - Config
    
    enum ProfileImageStatus: Equatable, Hashable {
        case image(expanded: Bool)
        case qrCode(expanded: Bool)
        
        var isQRCode: Bool {
            switch self {
                case .image: return false
                case .qrCode: return true
            }
        }
        
        var isExpanded: Bool {
            switch self {
                case .image(let expanded), .qrCode(let expanded): return expanded
            }
        }
        
        func toggleState() -> ProfileImageStatus {
            switch self {
                case .image(let expanded): return .qrCode(expanded: expanded)
                case .qrCode(let expanded): return .image(expanded: expanded)
            }
        }
        
        func toggleExpansion() -> ProfileImageStatus {
            switch self {
                case .image(let expanded): return .image(expanded: !expanded)
                case .qrCode(let expanded): return .qrCode(expanded: !expanded)
            }
        }
    }
    
    enum NavItem: Equatable {
        case edit
    }
    
    public enum Section: SessionTableSection {
        case conversationInfo
        case sessionId
        case sessionIdNoteToSelf
        case content
        case adminActions
        case destructiveActions
        
        public var title: String? {
            switch self {
                case .sessionId: return "accountId".localized()
                case .sessionIdNoteToSelf: return "accountIdYours".localized()
                case .adminActions: return "adminSettings".localized()
                default: return nil
            }
        }
        
        public var style: SessionTableSectionStyle {
            switch self {
                case .sessionId, .sessionIdNoteToSelf: return .titleSeparator
                case .destructiveActions: return .padding
                case .adminActions: return .titleRoundedContent
                default: return .none
            }
        }
    }
    
    public enum TableItem: Differentiable {
        case avatar
        case qrCode
        case displayName
        case contactName
        case threadDescription
        case sessionId
        
        case copyThreadId
        case searchConversation
        case disappearingMessages
        case pinConversation
        case notifications
        case addToOpenGroup
        case groupMembers
        case attachments
        
        case editGroup
        case promoteAdmins
        
        case blockUser
        case hideNoteToSelf
        case clearAllMessages
        case leaveCommunity
        case leaveGroup
        case deleteConversation
        case deleteContact
        
        case debugDeleteAttachmentsBeforeNow
    }
    
    public struct ThreadSettingsViewModelEvent: Hashable {
        let profileImageStatus: ProfileImageStatus
    }
    
    // MARK: - State

    public struct State: ObservableKeyProvider {
        let profileImageStatus: ProfileImageStatus
        
        let threadInfo: ConversationInfoViewModel
        let dataCache: ConversationDataCache
        
        @MainActor public func sections(viewModel: ThreadSettingsViewModel) -> [SectionModel] {
            ThreadSettingsViewModel.sections(state: self, viewModel: viewModel)
        }
        
        public var observedKeys: Set<ObservableKey> {
            var result: Set<ObservableKey> = [
                .appLifecycle(.willEnterForeground),
                .databaseLifecycle(.resumed),
                .updateScreen(ThreadSettingsViewModel.self),
                .conversationUpdated(threadInfo.id),
                .conversationDeleted(threadInfo.id),
                .profile(threadInfo.userSessionId.hexString),
                .typingIndicator(threadInfo.id),
                .messageCreated(threadId: threadInfo.id),
                .recentReactionsUpdated
            ]
            
            if SessionId.Prefix.isCommunityBlinded(threadInfo.id) {
                result.insert(.anyContactUnblinded)
            }
            
            result.insert(contentsOf: threadInfo.observedKeys)
            
            return result
        }
        
        static func initialState(
            threadInfo: ConversationInfoViewModel,
            using dependencies: Dependencies
        ) -> State {
            let dataCache: ConversationDataCache = ConversationDataCache(
                userSessionId: dependencies[cache: .general].sessionId,
                context: ConversationDataCache.Context(
                    source: .conversationSettings(threadId: threadInfo.id),
                    requireFullRefresh: false,
                    requireAuthMethodFetch: false,
                    requiresMessageRequestCountUpdate: false,
                    requiresInitialUnreadInteractionInfo: false,
                    requireRecentReactionEmojiUpdate: false
                )
            )
            
            return State(
                profileImageStatus: .image(expanded: false),
                threadInfo: threadInfo,
                dataCache: dataCache
            )
        }
    }
    
    lazy var rightNavItems: AnyPublisher<[SessionNavItem<NavItem>], Never> = $internalState
        .map { [weak self] state -> [SessionNavItem<NavItem>] in
            let canEditDisplayName: Bool = (
                !state.threadInfo.isNoteToSelf &&
                (
                    state.threadInfo.variant == .contact ||
                    state.threadInfo.groupInfo?.currentUserRole == .admin
                )
            )
            
            guard canEditDisplayName else { return [] }
            
            return [
                SessionNavItem(
                    id: .edit,
                    image: Lucide.image(icon: .pencil, size: 22)?
                        .withRenderingMode(.alwaysTemplate),
                    style: .plain,
                    accessibilityIdentifier: "Edit Nickname",
                    action: { [weak self] in
                        guard let info: ConfirmationModal.Info = self?.updateDisplayNameModal(state: state) else {
                            return
                        }
                        
                        self?.transitionToScreen(ConfirmationModal(info: info), transitionType: .present)
                    }
                )
            ]
        }
        .eraseToAnyPublisher()
    
    // MARK: - Content
    
    @MainActor var title: String {
        switch internalState.threadInfo.variant {
            case .contact: return "sessionSettings".localized()
            case .legacyGroup, .group, .community: return "deleteAfterGroupPR1GroupSettings".localized()
        }
    }
    
    @Sendable private static func queryState(
        previousState: State,
        events: [ObservedEvent],
        isInitialQuery: Bool,
        using dependencies: Dependencies
    ) async -> State {
        var profileImageStatus: ProfileImageStatus = previousState.profileImageStatus
        var threadInfo: ConversationInfoViewModel = previousState.threadInfo
        var dataCache: ConversationDataCache = previousState.dataCache
        
        /// If there are no events we want to process then just return the current state
        guard isInitialQuery || !events.isEmpty else { return previousState }
        
        /// Split the events between those that need database access and those that don't
        let changes: EventChangeset = events.split(by: { $0.handlingStrategy })
        
        /// Update the context
        dataCache.withContext(
            source: .conversationSettings(threadId: threadInfo.id),
            requireFullRefresh: (
                isInitialQuery ||
                changes.containsAny(
                    .appLifecycle(.willEnterForeground),
                    .databaseLifecycle(.resumed)
                )
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
            itemCache: [threadInfo.id: threadInfo],
            loadPageEvent: nil
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
                Log.warn(.threadSettingsViewModel, "Failed to handle \(changes.libSessionEvents.count) libSession event(s) due to error: \(error).")
            }
        }
        
        /// Peform any database changes
        if !dependencies[singleton: .storage].isSuspended, fetchRequirements.needsAnyFetch {
            do {
                try await dependencies[singleton: .storage].readAsync { db in
                    /// Fetch any required data from the cache
                    dataCache = try ConversationDataHelper.fetchFromDatabase(
                        db,
                        requirements: fetchRequirements,
                        currentCache: dataCache,
                        using: dependencies
                    )
                }
            } catch {
                let eventList: String = changes.databaseEvents.map { $0.key.rawValue }.joined(separator: ", ")
                Log.critical(.threadSettingsViewModel, "Failed to fetch state for events [\(eventList)], due to error: \(error)")
            }
        }
        else if !changes.databaseEvents.isEmpty {
            Log.warn(.threadSettingsViewModel, "Ignored \(changes.databaseEvents.count) database event(s) sent while storage was suspended.")
        }
        
        if let updatedValue: ThreadSettingsViewModelEvent = changes.latestGeneric(.updateScreen, as: ThreadSettingsViewModelEvent.self) {
            profileImageStatus = updatedValue.profileImageStatus
        }
        
        /// Regenerate the `threadInfo` now that the `dataCache` is updated
        if let thread: SessionThread = dataCache.thread(for: threadInfo.id) {
            threadInfo = ConversationInfoViewModel(
                thread: thread,
                dataCache: dataCache,
                using: dependencies
            )
        }

        /// Generate the new state
        return State(
            profileImageStatus: profileImageStatus,
            threadInfo: threadInfo,
            dataCache: dataCache
        )
    }
    
    private static func sections(state: State, viewModel: ThreadSettingsViewModel) -> [SectionModel] {
        let threadDisplayName: String = state.threadInfo.displayName.deformatted()
        let isThreadHidden: Bool = (
            !state.threadInfo.shouldBeVisible ||
            state.threadInfo.pinnedPriority == LibSession.hiddenPriority
        )
        let showThreadPubkey: Bool = (
            state.threadInfo.variant == .contact || (
                state.threadInfo.variant == .group &&
                viewModel.dependencies[feature: .groupsShowPubkeyInConversationSettings]
            )
        )
        // MARK: - Conversation Info
        
        let conversationInfoSection: SectionModel = SectionModel(
            model: .conversationInfo,
            elements: [
                (state.profileImageStatus.isQRCode ?
                    SessionCell.Info(
                        id: .qrCode,
                        accessory: .qrCode(
                            for: state.threadInfo.qrCodeString,
                            hasBackground: false,
                            logo: "SessionWhite40", // stringlint:ignore
                            themeStyle: ThemeManager.currentTheme.interfaceStyle
                        ),
                        styling: SessionCell.StyleInfo(
                            alignment: .centerHugging,
                            customPadding: SessionCell.Padding(bottom: Values.smallSpacing),
                            backgroundStyle: .noBackground
                        ),
                        onTapView: { [weak viewModel, dependencies = viewModel.dependencies] targetView in
                            let didTapProfileIcon: Bool = !(targetView is UIImageView)
                            
                            if didTapProfileIcon {
                                dependencies.notifyAsync(
                                    priority: .immediate,
                                    key: .updateScreen(ThreadSettingsViewModel.self),
                                    value: ThreadSettingsViewModelEvent(
                                        profileImageStatus: state.profileImageStatus.toggleState()
                                    )
                                )
                            } else {
                                viewModel?.showQRCodeLightBox(for: state.threadInfo)
                            }
                        }
                    )
                :
                    SessionCell.Info(
                        id: .avatar,
                        accessory: .profile(
                            id: state.threadInfo.id,
                            size: (state.profileImageStatus.isExpanded ? .expanded : .hero),
                            threadVariant: state.threadInfo.variant,
                            displayPictureUrl: state.threadInfo.displayPictureUrl,
                            profile: state.threadInfo.profile,
                            profileIcon: (state.threadInfo.isNoteToSelf || state.threadInfo.variant == .group ? .none : .qrCode),
                            additionalProfile: state.threadInfo.additionalProfile,
                            accessibility: nil
                        ),
                        styling: SessionCell.StyleInfo(
                            alignment: .centerHugging,
                            customPadding: SessionCell.Padding(
                                leading: 0,
                                bottom: Values.smallSpacing
                            ),
                            backgroundStyle: .noBackground
                        ),
                        onTapView: { [dependencies = viewModel.dependencies] targetView in
                            let didTapQRCodeIcon: Bool = !(targetView is ProfilePictureView)
                            
                            if didTapQRCodeIcon {
                                dependencies.notifyAsync(
                                    priority: .immediate,
                                    key: .updateScreen(ThreadSettingsViewModel.self),
                                    value: ThreadSettingsViewModelEvent(
                                        profileImageStatus: state.profileImageStatus.toggleState()
                                    )
                                )
                            } else {
                                dependencies.notifyAsync(
                                    priority: .immediate,
                                    key: .updateScreen(ThreadSettingsViewModel.self),
                                    value: ThreadSettingsViewModelEvent(
                                        profileImageStatus: state.profileImageStatus.toggleExpansion()
                                    )
                                )
                            }
                        }
                    )
                ),
                SessionCell.Info(
                    id: .displayName,
                    title: SessionCell.TextInfo(
                        threadDisplayName,
                        font: .titleLarge,
                        alignment: .center,
                        trailingImage: {
                            guard
                                state.threadInfo.shouldShowProBadge &&
                                !state.threadInfo.isNoteToSelf
                            else { return nil }
                            
                            return SessionProBadge.trailingImage(
                                size: .medium,
                                themeBackgroundColor: .primary
                            )
                        }()
                    ),
                    styling: SessionCell.StyleInfo(
                        alignment: .centerHugging,
                        customPadding: SessionCell.Padding(
                            top: Values.smallSpacing,
                            bottom: {
                                guard state.threadInfo.variant != .contact else { return Values.mediumSpacing }
                                guard state.threadInfo.conversationDescription == nil else {
                                    return Values.smallSpacing
                                }
                                
                                return Values.largeSpacing
                            }(),
                            interItem: 0
                        ),
                        backgroundStyle: .noBackground
                    ),
                    accessibility: Accessibility(
                        identifier: "Username",
                        label: threadDisplayName
                    ),
                    onTapView: { [weak viewModel, dependencies = viewModel.dependencies] targetView in
                        guard
                            targetView is SessionProBadge,
                            !dependencies[singleton: .sessionProManager].currentUserIsCurrentlyPro
                        else {
                            guard let info: ConfirmationModal.Info = viewModel?.updateDisplayNameModal(state: state) else {
                                return
                            }
                            
                            viewModel?.transitionToScreen(ConfirmationModal(info: info), transitionType: .present)
                            return
                        }
                        
                        let proCTAModalVariant: ProCTAModal.Variant = {
                            switch state.threadInfo.variant {
                                case .group:
                                    return .groupLimit(
                                        isAdmin: (state.threadInfo.groupInfo?.currentUserRole == .admin),
                                        isSessionProActivated: (state.threadInfo.groupInfo?.isProGroup == true),
                                        proBadgeImage: UIView.image(
                                            for: .themedKey(
                                                SessionProBadge.Size.mini.cacheKey,
                                                themeBackgroundColor: .primary
                                            ),
                                            generator: { SessionProBadge(size: .mini) }
                                        )
                                    )
                                default:
                                    return .generic(
                                        renew: dependencies[singleton: .sessionProManager]
                                            .currentUserCurrentProState
                                            .status == .expired
                                    )
                            }
                        }()
                        
                        dependencies[singleton: .sessionProManager].showSessionProCTAIfNeeded(
                            proCTAModalVariant,
                            onConfirm: {
                                dependencies[singleton: .sessionProManager].showSessionProBottomSheetIfNeeded(
                                    presenting: { [weak viewModel] bottomSheet in
                                        viewModel?.transitionToScreen(bottomSheet, transitionType: .present)
                                    }
                                )
                            },
                            presenting: { [weak viewModel] modal in
                                viewModel?.transitionToScreen(modal, transitionType: .present)
                            }
                        )
                    }
                ),
                
                (state.threadInfo.contactInfo == nil || threadDisplayName == state.threadInfo.contactInfo?.displayName ? nil :
                    SessionCell.Info(
                        id: .contactName,
                        subtitle: SessionCell.TextInfo(
                            "(\(state.threadInfo.contactInfo?.displayName ?? ""))", // stringlint:ignore
                            font: .subtitle,
                            alignment: .center
                        ),
                        styling: SessionCell.StyleInfo(
                            tintColor: .textSecondary,
                            customPadding: SessionCell.Padding(
                                top: 0,
                                bottom: Values.largeSpacing
                            ),
                            backgroundStyle: .noBackground
                        )
                    )
                ),
                
                state.threadInfo.conversationDescription.map { conversationDescription in
                    SessionCell.Info(
                        id: .threadDescription,
                        description: SessionCell.TextInfo(
                            conversationDescription,
                            font: .subtitle,
                            alignment: .center,
                            interaction: .expandable
                        ),
                        styling: SessionCell.StyleInfo(
                            tintColor: .textSecondary,
                            customPadding: SessionCell.Padding(
                                top: 0,
                                bottom: (state.threadInfo.variant != .contact ? Values.largeSpacing : nil)
                            ),
                            backgroundStyle: .noBackground
                        ),
                        accessibility: Accessibility(
                            identifier: "Description",
                            label: conversationDescription
                        )
                    )
                }
            ].compactMap { $0 }
        )
        
        // MARK: - Session Id
        
        let sessionIdSection: SectionModel = SectionModel(
            model: (state.threadInfo.isNoteToSelf ? .sessionIdNoteToSelf : .sessionId),
            elements: [
                SessionCell.Info(
                    id: .sessionId,
                    subtitle: SessionCell.TextInfo(
                        state.threadInfo.id,
                        font: .monoLarge,
                        alignment: .center,
                        interaction: .copy
                    ),
                    styling: SessionCell.StyleInfo(
                        customPadding: SessionCell.Padding(bottom: Values.smallSpacing),
                        backgroundStyle: .noBackground
                    ),
                    accessibility: Accessibility(
                        identifier: "Session ID",
                        label: state.threadInfo.id
                    )
                )
            ]
        )
        
        // MARK: - Users kicked from groups
        
        guard state.threadInfo.groupInfo?.wasKicked != true else {
            return [
                conversationInfoSection,
                SectionModel(
                    model: .destructiveActions,
                    elements: [
                        SessionCell.Info(
                            id: .leaveGroup,
                            leadingAccessory: .icon(.trash2),
                            title: "groupDelete".localized(),
                            styling: SessionCell.StyleInfo(tintColor: .danger),
                            accessibility: Accessibility(
                                identifier: "Leave group",
                                label: "Leave group"
                            ),
                            confirmationInfo: ConfirmationModal.Info(
                                title: "groupDelete".localized(),
                                body: .attributedText(
                                    "groupDeleteDescriptionMember"
                                        .put(key: "group_name", value: threadDisplayName)
                                        .localizedFormatted(baseFont: ConfirmationModal.explanationFont)
                                ),
                                confirmTitle: "delete".localized(),
                                confirmStyle: .danger,
                                cancelStyle: .alert_text
                            ),
                            onTap: { [weak viewModel, dependencies = viewModel.dependencies] in
                                viewModel?.dismissScreen(type: .popToRoot) {
                                    dependencies[singleton: .storage].writeAsync { db in
                                        try SessionThread.deleteOrLeave(
                                            db,
                                            type: .leaveGroupAsync,
                                            threadId: state.threadInfo.id,
                                            threadVariant: state.threadInfo.variant,
                                            using: dependencies
                                        )
                                    }
                                }
                            }
                        )
                    ]
                )
            ]
        }
        
        // MARK: - Standard Actions
        
        let standardActionsSection: SectionModel = SectionModel(
            model: .content,
            elements: [
                (state.threadInfo.variant == .legacyGroup || state.threadInfo.variant == .group ? nil :
                    SessionCell.Info(
                        id: .copyThreadId,
                        leadingAccessory: .icon(.copy),
                        title: (state.threadInfo.variant == .community ?
                            "communityUrlCopy".localized() :
                            "accountIDCopy".localized()
                        ),
                        accessibility: Accessibility(
                            identifier: "\(ThreadSettingsViewModel.self).copy_thread_id",
                            label: "Copy Session ID"
                        ),
                        onTap: { [weak viewModel] in
                            switch state.threadInfo.variant {
                                case .contact, .legacyGroup, .group:
                                    UIPasteboard.general.string = state.threadInfo.id

                                case .community:
                                    guard
                                        let communityInfo: ConversationInfoViewModel.CommunityInfo = state.threadInfo.communityInfo,
                                        let urlString: String = LibSession.communityUrlFor(
                                            server: communityInfo.server,
                                            roomToken: communityInfo.roomToken,
                                            publicKey: communityInfo.publicKey
                                        )
                                    else { return }

                                    UIPasteboard.general.string = urlString
                            }

                            viewModel?.showToast(
                                text: "copied".localized(),
                                backgroundColor: .backgroundSecondary
                            )
                        }
                    )
                ),

                SessionCell.Info(
                    id: .searchConversation,
                    leadingAccessory: .icon(.search),
                    title: "searchConversation".localized(),
                    accessibility: Accessibility(
                        identifier: "\(ThreadSettingsViewModel.self).search",
                        label: "Search"
                    ),
                    onTap: { [weak viewModel] in viewModel?.didTriggerSearch() }
                ),
                
                (
                    state.threadInfo.variant == .community ||
                    state.threadInfo.isBlocked ||
                    state.threadInfo.groupInfo?.currentUserRole == .admin ? nil :
                    SessionCell.Info(
                        id: .disappearingMessages,
                        leadingAccessory: .icon(.timer),
                        title: "disappearingMessages".localized(),
                        subtitle: {
                            guard
                                let config: DisappearingMessagesConfiguration = state.threadInfo.disappearingMessagesConfiguration,
                                config.isEnabled
                            else { return "off".localized() }
                            
                            return (config.type ?? .unknown).localizedState(
                                durationString: config.durationString
                            )
                        }(),
                        accessibility: Accessibility(
                            identifier: "Disappearing messages",
                            label: "\(ThreadSettingsViewModel.self).disappearing_messages"
                        ),
                        onTap: { [weak viewModel, dependencies = viewModel.dependencies] in
                            viewModel?.transitionToScreen(
                                SessionTableViewController(
                                    viewModel: ThreadDisappearingMessagesSettingsViewModel(
                                        threadId: state.threadInfo.id,
                                        threadVariant: state.threadInfo.variant,
                                        currentUserRole: state.threadInfo.groupInfo?.currentUserRole,
                                        config: (
                                            state.threadInfo.disappearingMessagesConfiguration ??
                                            DisappearingMessagesConfiguration.defaultWith(state.threadInfo.id)
                                        ),
                                        using: dependencies
                                    )
                                )
                            )
                        }
                    )
                ),
                
                (state.threadInfo.isBlocked ? nil :
                    SessionCell.Info(
                        id: .pinConversation,
                        leadingAccessory: .icon(
                            (state.threadInfo.pinnedPriority > 0 ?
                                .pinOff :
                                .pin
                            )
                        ),
                        title: (state.threadInfo.pinnedPriority > 0 ?
                                "pinUnpinConversation".localized() :
                                "pinConversation".localized()
                            ),
                        accessibility: Accessibility(
                            identifier: "\(ThreadSettingsViewModel.self).pin_conversation",
                            label: "Pin Conversation"
                        ),
                        onTap: { [weak viewModel] in
                            Task {
                                await viewModel?.toggleConversationPinnedStatus(
                                    threadInfo: state.threadInfo
                                )
                            }
                        }
                    )
                 ),
                
                (state.threadInfo.isNoteToSelf || state.threadInfo.isBlocked ? nil :
                    SessionCell.Info(
                        id: .notifications,
                        leadingAccessory: .icon(
                            {
                                if state.threadInfo.onlyNotifyForMentions {
                                    return .atSign
                                }
                                
                                if state.threadInfo.mutedUntilTimestamp != nil {
                                    return .volumeOff
                                }
                                
                                return .volume2
                            }()
                        ),
                        title: "sessionNotifications".localized(),
                        subtitle: {
                            if state.threadInfo.onlyNotifyForMentions {
                                return "notificationsMentionsOnly".localized()
                            }
                            
                            if state.threadInfo.mutedUntilTimestamp != nil {
                                return "notificationsMuted".localized()
                            }
                            
                            return "notificationsAllMessages".localized()
                        }(),
                        accessibility: Accessibility(
                            identifier: "\(ThreadSettingsViewModel.self).notifications",
                            label: "Notifications"
                        ),
                        onTap: { [weak viewModel, dependencies = viewModel.dependencies] in
                            viewModel?.transitionToScreen(
                                SessionTableViewController(
                                    viewModel: ThreadNotificationSettingsViewModel(
                                        threadId: state.threadInfo.id,
                                        threadVariant: state.threadInfo.variant,
                                        threadOnlyNotifyForMentions: state.threadInfo.onlyNotifyForMentions,
                                        threadMutedUntilTimestamp: state.threadInfo.mutedUntilTimestamp,
                                        using: dependencies
                                    )
                                )
                            )
                        }
                    )
                ),
                
                (state.threadInfo.variant != .community ? nil :
                    SessionCell.Info(
                        id: .addToOpenGroup,
                        leadingAccessory: .icon(.userRoundPlus),
                        title: "membersInvite".localized(),
                        accessibility: Accessibility(
                            identifier: "\(ThreadSettingsViewModel.self).add_to_open_group"
                        ),
                        onTap: { [weak viewModel] in viewModel?.inviteUsersToCommunity(threadInfo: state.threadInfo) }
                    )
                ),
                
                (state.threadInfo.groupInfo?.currentUserRole == nil ? nil :
                    SessionCell.Info(
                        id: .groupMembers,
                        leadingAccessory: .icon(.usersRound),
                        title: "groupMembers".localized(),
                        accessibility: Accessibility(
                            identifier: "Group members",
                            label: "Group members"
                        ),
                        onTap: { [weak viewModel] in viewModel?.viewMembers(state: state) }
                    )
                ),
                
                SessionCell.Info(
                    id: .attachments,
                    leadingAccessory: .icon(.file),
                    title: "attachments".localized(),
                    accessibility: Accessibility(
                        identifier: "\(ThreadSettingsViewModel.self).all_media",
                        label: "All media"
                    ),
                    onTap: { [weak viewModel, dependencies = viewModel.dependencies] in
                        viewModel?.transitionToScreen(
                            MediaGalleryViewModel.createAllMediaViewController(
                                threadId: state.threadInfo.id,
                                threadVariant: state.threadInfo.variant,
                                threadTitle: threadDisplayName,
                                focusedAttachmentId: nil,
                                using: dependencies
                            )
                        )
                    }
                )
            ].compactMap { $0 }
        )
        
        // MARK: - Admin Actions
        
        let adminActionsSection: SectionModel? = (
            state.threadInfo.groupInfo?.currentUserRole != .admin ? nil :
                SectionModel(
                    model: .adminActions,
                    elements: [
                        SessionCell.Info(
                            id: .editGroup,
                            leadingAccessory: .icon(.userRoundPen),
                            title: "manageMembers".localized(),
                            accessibility: Accessibility(
                                identifier: "Edit group",
                                label: "Edit group"
                            ),
                            onTap: { [weak viewModel, dependencies = viewModel.dependencies] in
                                viewModel?.transitionToScreen(
                                    SessionTableViewController(
                                        viewModel: EditGroupViewModel(
                                            threadId: state.threadInfo.id,
                                            using: dependencies
                                        )
                                    )
                                )
                            }
                        ),
                        
                        (!viewModel.dependencies[feature: .updatedGroupsAllowPromotions] ? nil :
                            SessionCell.Info(
                                id: .promoteAdmins,
                                leadingAccessory: .icon(
                                    UIImage(named: "table_ic_group_edit")?
                                        .withRenderingMode(.alwaysTemplate)
                                ),
                                title: "adminPromote".localized(),
                                accessibility: Accessibility(
                                    identifier: "Promote admins",
                                    label: "Promote admins"
                                ),
                                onTap: { [weak viewModel] in
                                    viewModel?.promoteAdmins(state: state)
                                }
                            )
                        ),
                        
                        SessionCell.Info(
                            id: .disappearingMessages,
                            leadingAccessory: .icon(.timer),
                            title: "disappearingMessages".localized(),
                            subtitle: {
                                guard
                                    let config: DisappearingMessagesConfiguration = state.threadInfo.disappearingMessagesConfiguration,
                                    config.isEnabled
                                else { return "off".localized() }
                                
                                return (config.type ?? .unknown)
                                    .localizedState(durationString: config.durationString)
                            }(),
                            accessibility: Accessibility(
                                identifier: "Disappearing messages",
                                label: "\(ThreadSettingsViewModel.self).disappearing_messages"
                            ),
                            onTap: { [weak viewModel, dependencies = viewModel.dependencies] in
                                viewModel?.transitionToScreen(
                                    SessionTableViewController(
                                        viewModel: ThreadDisappearingMessagesSettingsViewModel(
                                            threadId: state.threadInfo.id,
                                            threadVariant: state.threadInfo.variant,
                                            currentUserRole: state.threadInfo.groupInfo?.currentUserRole,
                                            config: (
                                                state.threadInfo.disappearingMessagesConfiguration ??
                                                DisappearingMessagesConfiguration.defaultWith(state.threadInfo.id)
                                            ),
                                            using: dependencies
                                        )
                                    )
                                )
                            }
                        )
                    ].compactMap { $0 }
                )
        )
        
        // MARK: - Destructive Actions
        
        let destructiveActionsSection: SectionModel = SectionModel(
            model: .destructiveActions,
            elements: [
                (state.threadInfo.isNoteToSelf || state.threadInfo.variant != .contact ? nil :
                    SessionCell.Info(
                        id: .blockUser,
                        leadingAccessory: (state.threadInfo.isBlocked ?
                            .icon(.userRoundCheck) :
                            .icon(UIImage(named: "ic_user_round_ban")?.withRenderingMode(.alwaysTemplate))
                        ),
                        title: (state.threadInfo.isBlocked ?
                            "blockUnblock".localized() :
                            "block".localized()
                        ),
                        styling: SessionCell.StyleInfo(tintColor: .danger),
                        accessibility: Accessibility(
                            identifier: "\(ThreadSettingsViewModel.self).block",
                            label: "Block"
                        ),
                        confirmationInfo: ConfirmationModal.Info(
                            title: (state.threadInfo.isBlocked ?
                                "blockUnblock".localized() :
                                "block".localized()
                            ),
                            body: (state.threadInfo.isBlocked ?
                                .attributedText(
                                    "blockUnblockName"
                                        .put(key: "name", value: threadDisplayName)
                                        .localizedFormatted(baseFont: ConfirmationModal.explanationFont)
                                ) :
                                .attributedText(
                                    "blockDescription"
                                        .put(key: "name", value: threadDisplayName)
                                        .localizedFormatted(baseFont: ConfirmationModal.explanationFont)
                                )
                            ),
                            confirmTitle: (state.threadInfo.isBlocked ?
                                "blockUnblock".localized() :
                                "block".localized()
                            ),
                            confirmStyle: .danger,
                            cancelStyle: .alert_text
                        ),
                        onTap: { [weak viewModel] in
                            viewModel?.updateBlockedState(
                                from: state.threadInfo.isBlocked,
                                isBlocked: !state.threadInfo.isBlocked,
                                threadId: state.threadInfo.id,
                                displayName: threadDisplayName
                            )
                        }
                    )
                ),
                
                (!state.threadInfo.isNoteToSelf ? nil :
                    SessionCell.Info(
                        id: .hideNoteToSelf,
                        leadingAccessory: .icon(isThreadHidden ? .eye : .eyeOff),
                        title: isThreadHidden ? "showNoteToSelf".localized() : "noteToSelfHide".localized(),
                        styling: SessionCell.StyleInfo(tintColor: isThreadHidden ? .textPrimary : .danger),
                        accessibility: Accessibility(
                            identifier: "\(ThreadSettingsViewModel.self).hide_note_to_self",
                            label: "Hide Note to Self"
                        ),
                        confirmationInfo: ConfirmationModal.Info(
                            title: isThreadHidden ? "showNoteToSelf".localized() : "noteToSelfHide".localized(),
                            body: .attributedText(
                                isThreadHidden ?
                                "showNoteToSelfDescription"
                                    .localizedFormatted(baseFont: ConfirmationModal.explanationFont) :
                                "hideNoteToSelfDescription"
                                    .localizedFormatted(baseFont: ConfirmationModal.explanationFont)
                            ),
                            confirmTitle: isThreadHidden ? "show".localized() : "hide".localized(),
                            confirmStyle: isThreadHidden ? .alert_text : .danger,
                            cancelStyle: .alert_text
                        ),
                        onTap: { [dependencies = viewModel.dependencies] in
                            dependencies[singleton: .storage].writeAsync { db in
                                if isThreadHidden {
                                    try SessionThread.updateVisibility(
                                        db,
                                        threadId: state.threadInfo.id,
                                        threadVariant: state.threadInfo.variant,
                                        isVisible: true,
                                        using: dependencies
                                    )
                                } else {
                                    try SessionThread.deleteOrLeave(
                                        db,
                                        type: .hideContactConversation,
                                        threadId: state.threadInfo.id,
                                        threadVariant: state.threadInfo.variant,
                                        using: dependencies
                                    )
                                }
                            }
                        }
                    )
                ),
                
                SessionCell.Info(
                    id: .clearAllMessages,
                    leadingAccessory: .icon(
                        UIImage(named: "ic_message_trash")?.withRenderingMode(.alwaysTemplate)
                    ),
                    title: "clearMessages".localized(),
                    styling: SessionCell.StyleInfo(tintColor: .danger),
                    accessibility: Accessibility(
                        identifier: "\(ThreadSettingsViewModel.self).clear_all_messages",
                        label: "Clear All Messages"
                    ),
                    confirmationInfo: ConfirmationModal.Info(
                        title: "clearMessages".localized(),
                        body: {
                            guard !state.threadInfo.isNoteToSelf else {
                                return .attributedText(
                                    "clearMessagesNoteToSelfDescriptionUpdated"
                                        .localizedFormatted(baseFont: ConfirmationModal.explanationFont)
                                )
                            }
                            
                            switch state.threadInfo.variant {
                                case .contact:
                                    return .attributedText(
                                        "clearMessagesChatDescriptionUpdated"
                                            .put(key: "name", value: threadDisplayName)
                                            .localizedFormatted(baseFont: ConfirmationModal.explanationFont)
                                    )
                                case .legacyGroup:
                                    return .attributedText(
                                        "clearMessagesGroupDescriptionUpdated"
                                            .put(key: "group_name", value: threadDisplayName)
                                            .localizedFormatted(baseFont: ConfirmationModal.explanationFont)
                                    )
                                case .community:
                                    return .attributedText(
                                        "clearMessagesCommunityUpdated"
                                            .put(key: "community_name", value: threadDisplayName)
                                            .localizedFormatted(baseFont: ConfirmationModal.explanationFont)
                                    )
                                case .group:
                                    if state.threadInfo.groupInfo?.currentUserRole == .admin {
                                        return .radio(
                                            explanation: "clearMessagesGroupAdminDescriptionUpdated"
                                                .put(key: "group_name", value: threadDisplayName)
                                                .localizedFormatted(baseFont: ConfirmationModal.explanationFont),
                                            warning: nil,
                                            options: [
                                                ConfirmationModal.Info.Body.RadioOptionInfo(
                                                    title: "clearOnThisDevice".localized(),
                                                    enabled: true,
                                                    selected: true,
                                                    accessibility: Accessibility(
                                                        identifier: "",
                                                        label: ""
                                                    )
                                                ),
                                                ConfirmationModal.Info.Body.RadioOptionInfo(
                                                    title: "clearMessagesForEveryone".localized(),
                                                    enabled: true,
                                                    selected: false,
                                                    accessibility: Accessibility(
                                                        identifier: "",
                                                        label: ""
                                                    )
                                                )
                                            ]
                                        )
                                    } else {
                                        return .attributedText(
                                            "clearMessagesGroupDescriptionUpdated"
                                                .put(key: "group_name", value: threadDisplayName)
                                                .localizedFormatted(baseFont: ConfirmationModal.explanationFont)
                                        )
                                    }
                            }
                        }(),
                        confirmTitle: "clear".localized(),
                        confirmStyle: .danger,
                        cancelStyle: .alert_text,
                        dismissOnConfirm: false,
                        onConfirm: { [weak viewModel, dependencies = viewModel.dependencies] modal in
                            if state.threadInfo.variant == .group && state.threadInfo.groupInfo?.currentUserRole == .admin {
                                /// Determine the selected action index
                                let selectedIndex: Int = {
                                    switch modal.info.body {
                                        case .radio(_, _, let options):
                                            return options
                                                .enumerated()
                                                .first(where: { _, value in value.selected })
                                                .map { index, _ in index }
                                                .defaulting(to: 0)
                                        
                                        default: return 0
                                    }
                                }()
                                
                                // Don't update the group if the selected option is `Clear on this device`
                                if selectedIndex != 0 {
                                    viewModel?.deleteAllMessagesBeforeNow(state: state)
                                }
                            }
                            
                            dependencies[singleton: .storage].writeAsync(
                                updates: { db in
                                    try Interaction.markAllAsDeleted(
                                        db,
                                        threadId: state.threadInfo.id,
                                        threadVariant: state.threadInfo.variant,
                                        options: [.local, .noArtifacts],
                                        using: dependencies
                                    )
                                },
                                completion: { [weak viewModel] result in
                                    switch result {
                                        case .failure(let error):
                                            Log.error("Failed to clear messages due to error: \(error)")
                                            DispatchQueue.main.async {
                                                modal.dismiss(animated: true) {
                                                    viewModel?.showToast(
                                                        text: "deleteMessageFailed"
                                                            .putNumber(0)
                                                            .localized(),
                                                        backgroundColor: .backgroundSecondary
                                                    )
                                                }
                                            }
                                            
                                        case .success:
                                            DispatchQueue.main.async {
                                                modal.dismiss(animated: true) {
                                                    viewModel?.showToast(
                                                        text: "deleteMessageDeleted"
                                                            .putNumber(0)
                                                            .localized(),
                                                        backgroundColor: .backgroundSecondary
                                                    )
                                                }
                                            }
                                            
                                    }
                                }
                            )
                        }
                    )
                ),
                
                (state.threadInfo.variant != .community ? nil :
                    SessionCell.Info(
                        id: .leaveCommunity,
                        leadingAccessory: .icon(.logOut),
                        title: "communityLeave".localized(),
                        styling: SessionCell.StyleInfo(tintColor: .danger),
                        accessibility: Accessibility(
                            identifier: "\(ThreadSettingsViewModel.self).leave_community",
                            label: "Leave Community"
                        ),
                        confirmationInfo: ConfirmationModal.Info(
                            title: "communityLeave".localized(),
                            body: .attributedText(
                                "groupLeaveDescription"
                                    .put(key: "group_name", value: threadDisplayName)
                                    .localizedFormatted(baseFont: ConfirmationModal.explanationFont)
                            ),
                            confirmTitle: "leave".localized(),
                            confirmStyle: .danger,
                            cancelStyle: .alert_text
                        ),
                        onTap: { [weak viewModel, dependencies = viewModel.dependencies] in
                            viewModel?.dismissScreen(type: .popToRoot) {
                                dependencies[singleton: .storage].writeAsync { db in
                                    try SessionThread.deleteOrLeave(
                                        db,
                                        type: .deleteCommunityAndContent,
                                        threadId: state.threadInfo.id,
                                        threadVariant: state.threadInfo.variant,
                                        using: dependencies
                                    )
                                }
                            }
                        }
                    )
                ),
                
                (state.threadInfo.groupInfo?.currentUserRole == nil ? nil :
                    SessionCell.Info(
                        id: .leaveGroup,
                        leadingAccessory: .icon(state.threadInfo.groupInfo?.currentUserRole == .admin ?
                            .trash2 :
                            .logOut
                        ),
                        title: (state.threadInfo.groupInfo?.currentUserRole == .admin ?
                            "groupDelete".localized() :
                            "groupLeave".localized()
                        ),
                        styling: SessionCell.StyleInfo(tintColor: .danger),
                        accessibility: Accessibility(
                            identifier: "Leave group",
                            label: "Leave group"
                        ),
                        confirmationInfo: ConfirmationModal.Info(
                            title: (state.threadInfo.groupInfo?.currentUserRole == .admin ?
                                "groupDelete".localized() :
                                "groupLeave".localized()
                            ),
                            body: (state.threadInfo.groupInfo?.currentUserRole == .admin ?
                                .attributedText(
                                    "groupDeleteDescription"
                                        .put(key: "group_name", value: threadDisplayName)
                                        .localizedFormatted(baseFont: ConfirmationModal.explanationFont)
                                ) :
                                .attributedText(
                                    "groupLeaveDescription"
                                        .put(key: "group_name", value: threadDisplayName)
                                        .localizedFormatted(baseFont: ConfirmationModal.explanationFont)
                                )
                            ),
                            confirmTitle: (state.threadInfo.groupInfo?.currentUserRole == .admin ?
                                "delete".localized() :
                                "leave".localized()
                            ),
                            confirmStyle: .danger,
                            cancelStyle: .alert_text
                        ),
                        onTap: { [weak viewModel, dependencies = viewModel.dependencies] in
                            viewModel?.dismissScreen(type: .popToRoot) {
                                dependencies[singleton: .storage].writeAsync { db in
                                    try SessionThread.deleteOrLeave(
                                        db,
                                        type: .leaveGroupAsync,
                                        threadId: state.threadInfo.id,
                                        threadVariant: state.threadInfo.variant,
                                        using: dependencies
                                    )
                                }
                            }
                        }
                    )
                ),
                
                (state.threadInfo.variant != .contact || state.threadInfo.isNoteToSelf ? nil :
                    SessionCell.Info(
                        id: .deleteConversation,
                        leadingAccessory: .icon(.trash2),
                        title: "conversationsDelete".localized(),
                        styling: SessionCell.StyleInfo(tintColor: .danger),
                        accessibility: Accessibility(
                            identifier: "\(ThreadSettingsViewModel.self).delete_conversation",
                            label: "Delete Conversation"
                        ),
                        confirmationInfo: ConfirmationModal.Info(
                            title: "conversationsDelete".localized(),
                            body: .attributedText(
                                "deleteConversationDescription"
                                    .put(key: "name", value: threadDisplayName)
                                    .localizedFormatted(baseFont: ConfirmationModal.explanationFont)
                            ),
                            confirmTitle: "delete".localized(),
                            confirmStyle: .danger,
                            cancelStyle: .alert_text
                        ),
                        onTap: { [weak viewModel, dependencies = viewModel.dependencies] in
                            viewModel?.dismissScreen(type: .popToRoot) {
                                dependencies[singleton: .storage].writeAsync { db in
                                    try SessionThread.deleteOrLeave(
                                        db,
                                        type: .deleteContactConversationAndMarkHidden,
                                        threadId: state.threadInfo.id,
                                        threadVariant: state.threadInfo.variant,
                                        using: dependencies
                                    )
                                }
                            }
                        }
                    )
                 ),
                
                (state.threadInfo.variant != .contact || state.threadInfo.isNoteToSelf ? nil :
                    SessionCell.Info(
                        id: .deleteContact,
                        leadingAccessory: .icon(
                            UIImage(named: "ic_user_round_trash")?.withRenderingMode(.alwaysTemplate)
                        ),
                        title: "contactDelete".localized(),
                        styling: SessionCell.StyleInfo(tintColor: .danger),
                        accessibility: Accessibility(
                            identifier: "\(ThreadSettingsViewModel.self).delete_contact",
                            label: "Delete Contact"
                        ),
                        confirmationInfo: ConfirmationModal.Info(
                            title: "contactDelete".localized(),
                            body: .attributedText(
                                "deleteContactDescription"
                                    .put(key: "name", value: threadDisplayName)
                                    .localizedFormatted(baseFont: ConfirmationModal.explanationFont),
                                scrollMode: .never
                            ),
                            confirmTitle: "delete".localized(),
                            confirmStyle: .danger,
                            cancelStyle: .alert_text
                        ),
                        onTap: { [weak viewModel, dependencies = viewModel.dependencies] in
                            viewModel?.dismissScreen(type: .popToRoot) {
                                dependencies[singleton: .storage].writeAsync { db in
                                    try SessionThread.deleteOrLeave(
                                        db,
                                        type: .deleteContactConversationAndContact,
                                        threadId: state.threadInfo.id,
                                        threadVariant: state.threadInfo.variant,
                                        using: dependencies
                                    )
                                }
                            }
                        }
                    )
                ),
                
                // FIXME: [GROUPS REBUILD] Need to build this properly in a future release
                (!viewModel.dependencies[feature: .updatedGroupsDeleteAttachmentsBeforeNow] || state.threadInfo.variant != .group ? nil :
                    SessionCell.Info(
                        id: .debugDeleteAttachmentsBeforeNow,
                        leadingAccessory: .icon(
                            Lucide.image(icon: .trash2, size: 24)?
                                .withRenderingMode(.alwaysTemplate),
                            customTint: .danger
                        ),
                        title: "[DEBUG] Delete all arrachments before now",    // stringlint:disable
                        styling: SessionCell.StyleInfo(
                            tintColor: .danger
                        ),
                        confirmationInfo: ConfirmationModal.Info(
                            title: "delete".localized(),
                            body: .text("Are you sure you want to delete all attachments (and their associated messages) sent before now for all group members?"),   // stringlint:disable
                            confirmTitle: "delete".localized(),
                            confirmStyle: .danger,
                            cancelStyle: .alert_text
                        ),
                        onTap: { [weak viewModel] in viewModel?.deleteAllAttachmentsBeforeNow(state: state) }
                    )
                )
            ].compactMap { $0 }
        )
        
        return [
            conversationInfoSection,
            (!showThreadPubkey ? nil : sessionIdSection),
            standardActionsSection,
            adminActionsSection,
            destructiveActionsSection
        ].compactMap { $0 }
    }
    
    // MARK: - Functions
    
    private func inviteUsersToCommunity(threadInfo: ConversationInfoViewModel) {
        guard
            let communityInfo: ConversationInfoViewModel.CommunityInfo = threadInfo.communityInfo,
            let communityUrl: String = LibSession.communityUrlFor(
                server: communityInfo.server,
                roomToken: communityInfo.roomToken,
                publicKey: communityInfo.publicKey
            )
        else { return }
        
        let contact: TypedTableAlias<Contact> = TypedTableAlias()
        let groupMember: TypedTableAlias<GroupMember> = TypedTableAlias()
        
        self.transitionToScreen(
            SessionTableViewController(
                viewModel: UserListViewModel<Contact>(
                    title: "membersInvite".localized(),
                    emptyState: "contactNone".localized(),
                    showProfileIcons: false,
                    request: SQLRequest("""
                        SELECT \(contact.allColumns)
                        FROM \(contact)
                        LEFT JOIN \(groupMember) ON (
                            \(groupMember[.groupId]) = \(threadInfo.id) AND
                            \(groupMember[.profileId]) = \(contact[.id])
                        )
                        WHERE (
                            \(groupMember[.profileId]) IS NULL AND
                            \(contact[.isApproved]) = TRUE AND
                            \(contact[.didApproveMe]) = TRUE AND
                            \(contact[.isBlocked]) = FALSE AND
                            \(contact[.id]) NOT IN \(threadInfo.currentUserSessionIds)
                        )
                    """),
                    footerTitle: "membersInviteTitle".localized(),
                    footerAccessibility: Accessibility(
                        identifier: "Invite contacts button"
                    ),
                    onSubmit: .callback { [dependencies] viewModel, selectedUserInfo in
                        viewModel?.showToast(
                            text: "groupInviteSending"
                                .putNumber(selectedUserInfo.count)
                                .localized(),
                            backgroundColor: .backgroundSecondary
                        )
                        dependencies[singleton: .storage].writeAsync { db in
                            try selectedUserInfo.forEach { userInfo in
                                let sentTimestampMs: Int64 = dependencies[cache: .snodeAPI].currentOffsetTimestampMs()
                                let thread: SessionThread = try SessionThread.upsert(
                                    db,
                                    id: userInfo.profileId,
                                    variant: .contact,
                                    values: SessionThread.TargetValues(
                                        creationDateTimestamp: .useExistingOrSetTo(TimeInterval(sentTimestampMs) / 1000),
                                        shouldBeVisible: .useExisting
                                    ),
                                    using: dependencies
                                )
                                
                                try LinkPreview(
                                    url: communityUrl,
                                    variant: .openGroupInvitation,
                                    title: communityInfo.name,
                                    using: dependencies
                                )
                                .upsert(db)
                                
                                let destinationDisappearingMessagesConfiguration: DisappearingMessagesConfiguration? = try? DisappearingMessagesConfiguration
                                    .filter(id: userInfo.profileId)
                                    .filter(DisappearingMessagesConfiguration.Columns.isEnabled == true)
                                    .fetchOne(db)
                                let interaction: Interaction = try Interaction(
                                    threadId: thread.id,
                                    threadVariant: thread.variant,
                                    authorId: threadInfo.userSessionId.hexString,
                                    variant: .standardOutgoing,
                                    timestampMs: sentTimestampMs,
                                    expiresInSeconds: destinationDisappearingMessagesConfiguration?.expiresInSeconds(),
                                    expiresStartedAtMs: destinationDisappearingMessagesConfiguration?.initialExpiresStartedAtMs(
                                        sentTimestampMs: Double(sentTimestampMs)
                                    ),
                                    linkPreviewUrl: communityUrl,
                                    using: dependencies
                                )
                                .inserted(db)
                                
                                try MessageSender.send(
                                    db,
                                    interaction: interaction,
                                    threadId: thread.id,
                                    threadVariant: thread.variant,
                                    using: dependencies
                                )
                                
                                // Trigger disappear after read
                                dependencies[singleton: .jobRunner].upsert(
                                    db,
                                    job: DisappearingMessagesJob.updateNextRunIfNeeded(
                                        db,
                                        interaction: interaction,
                                        startedAtMs: Double(sentTimestampMs),
                                        using: dependencies
                                    ),
                                    canStartJob: true
                                )
                            }
                        }
                    },
                    using: dependencies
                )
            ),
            transitionType: .push
        )
    }
    
    public static func createMemberListViewController(
        threadId: String,
        transitionToConversation: @escaping @MainActor (ConversationInfoViewModel?) -> Void,
        using dependencies: Dependencies
    ) -> UIViewController {
        return SessionTableViewController(
            viewModel: UserListViewModel(
                title: "groupMembers".localized(),
                showProfileIcons: true,
                request: GroupMember
                    .select(
                        GroupMember.Columns.groupId,
                        GroupMember.Columns.profileId,
                        max(GroupMember.Columns.role).forKey(GroupMember.Columns.role.name),
                        GroupMember.Columns.roleStatus,
                        GroupMember.Columns.isHidden
                    )
                    .filter(GroupMember.Columns.groupId == threadId)
                    .group(GroupMember.Columns.profileId),
                onTap: .callback { _, memberInfo in
                    let maybeThreadInfo: ConversationInfoViewModel? = try? await dependencies[singleton: .storage].writeAsync { db in
                        try SessionThread.upsert(
                            db,
                            id: memberInfo.profileId,
                            variant: .contact,
                            values: SessionThread.TargetValues(
                                creationDateTimestamp: .useExistingOrSetTo(
                                    dependencies[cache: .snodeAPI].currentOffsetTimestampMs() / 1000
                                ),
                                shouldBeVisible: .useExisting,
                                isDraft: .useExistingOrSetTo(true)
                            ),
                            using: dependencies
                        )
                        
                        return try ConversationViewModel.fetchConversationInfo(
                            db,
                            threadId: memberInfo.profileId,
                            using: dependencies
                        )
                    }
                    
                    await MainActor.run {
                        transitionToConversation(maybeThreadInfo)
                    }
                },
                using: dependencies
            )
        )
    }
    
    private func viewMembers(state: State) {
        self.transitionToScreen(
            ThreadSettingsViewModel.createMemberListViewController(
                threadId: state.threadInfo.id,
                transitionToConversation: { [weak self, dependencies] maybeThreadInfo in
                    guard let threadInfo: ConversationInfoViewModel = maybeThreadInfo else {
                        self?.transitionToScreen(
                            ConfirmationModal(
                                info: ConfirmationModal.Info(
                                    title: "theError".localized(),
                                    body: .text("errorUnknown".localized()),
                                    cancelTitle: "okay".localized(),
                                    cancelStyle: .alert_text
                                )
                            ),
                            transitionType: .present
                        )
                        return
                    }
                    
                    self?.transitionToScreen(
                        ConversationVC(
                            threadInfo: threadInfo,
                            focusedInteractionInfo: nil,
                            using: dependencies
                        ),
                        transitionType: .push
                    )
                },
                using: dependencies
            )
        )
    }
    
    private func promoteAdmins(state: State) {
        guard dependencies[feature: .updatedGroupsAllowPromotions] else { return }
        
        let groupMember: TypedTableAlias<GroupMember> = TypedTableAlias()
        
        /// Submitting and resending using the same logic
        func send(
            _ viewModel: UserListViewModel<GroupMember>?,
            _ memberInfo: [(id: String, profile: Profile?)],
            isResend: Bool
        ) {
            /// Show a toast immediately that we are sending invitations
            viewModel?.showToast(
                text: "adminSendingPromotion"
                    .putNumber(memberInfo.count)
                    .localized(),
                backgroundColor: .backgroundSecondary
            )
            
            /// Actually trigger the sending process
            MessageSender
                .promoteGroupMembers(
                    groupSessionId: SessionId(.group, hex: state.threadInfo.id),
                    members: memberInfo,
                    isResend: isResend,
                    using: dependencies
                )
                .subscribe(on: DispatchQueue.global(qos: .userInitiated), using: dependencies)
                .receive(on: DispatchQueue.main, using: dependencies)
                .sinkUntilComplete(
                    receiveCompletion: { [dependencies] result in
                        switch result {
                            case .finished: break
                            case .failure:
                                let memberIds: [String] = memberInfo.map(\.id)
                                
                                /// Flag the members as failed
                                dependencies[singleton: .storage].writeAsync { db in
                                    try? GroupMember
                                        .filter(GroupMember.Columns.groupId == state.threadInfo.id)
                                        .filter(memberIds.contains(GroupMember.Columns.profileId))
                                        .updateAllAndConfig(
                                            db,
                                            GroupMember.Columns.roleStatus.set(to: GroupMember.RoleStatus.failed),
                                            using: dependencies
                                        )
                                }
                                
                                /// Show a toast that the promotions failed to send
                                viewModel?.showToast(
                                    text: GroupPromoteMemberJob.failureMessage(
                                        groupName: (state.threadInfo.groupInfo?.name ?? "groupUnknown".localized()),
                                        memberIds: memberIds,
                                        profileInfo: memberInfo.reduce(into: [:]) { result, next in
                                            result[next.id] = next.profile
                                        }
                                    ),
                                    backgroundColor: .backgroundSecondary
                                )
                        }
                    }
                )
        }
        
        /// Show the selection list
        self.transitionToScreen(
            SessionTableViewController(
                viewModel: UserListViewModel<GroupMember>(
                    title: "promote".localized(),
                    // FIXME: Localise this
                    emptyState: "There are no group members which can be promoted.",
                    showProfileIcons: true,
                    request: SQLRequest("""
                        SELECT \(groupMember.allColumns)
                        FROM \(groupMember)
                        WHERE (
                            \(groupMember[.groupId]) == \(state.threadInfo.id) AND (
                                \(groupMember[.role]) == \(GroupMember.Role.admin) OR
                                (
                                    \(groupMember[.role]) != \(GroupMember.Role.admin) AND
                                    \(groupMember[.roleStatus]) == \(GroupMember.RoleStatus.accepted)
                                )
                            )
                        )
                        GROUP BY \(groupMember[.profileId])
                    """),
                    footerTitle: "promote".localized(),
                    onTap: .conditionalAction(
                        action: { memberInfo in
                            guard memberInfo.profileId != memberInfo.currentUserSessionId.hexString else {
                                return .none
                            }
                            
                            switch (memberInfo.value.role, memberInfo.value.roleStatus) {
                                case (.standard, _): return .radio
                                default:
                                    return .custom(
                                        trailingAccessory: { _ in
                                            .highlightingBackgroundLabel(
                                                title: "resend".localized()
                                            )
                                        },
                                        onTap: { viewModel, info in
                                            send(viewModel, [(info.profileId, info.profile)], isResend: true)
                                        }
                                    )
                            }
                        }
                    ),
                    onSubmit: .callback { viewModel, selectedInfo in
                        send(viewModel, selectedInfo.map { ($0.profileId, $0.profile) }, isResend: false)
                    },
                    using: dependencies
                )
            ),
            transitionType: .push
        )
    }
    
    private func updateNickname(
        state: State,
        current: String?,
        displayName: String
    ) -> ConfirmationModal.Info {
        /// Set `updatedName` to `current` so we can disable the "save" button when there are no changes and don't need to worry about retrieving them in the confirmation closure
        self.updatedName = current
        let currentUserSessionId: SessionId = dependencies[cache: .general].sessionId
        
        return ConfirmationModal.Info(
            title: "nicknameSet".localized(),
            body: .input(
                explanation: "nicknameDescription"
                    .put(key: "name", value: displayName)
                    .localizedFormatted(baseFont: ConfirmationModal.explanationFont),
                info: ConfirmationModal.Info.Body.InputInfo(
                    placeholder: "nicknameEnter".localized(),
                    initialValue: current,
                    accessibility: Accessibility(
                        identifier: "Username input"
                    ),
                    inputChecker: { text in
                        let nickname: String = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        
                        guard !Profile.isTooLong(profileName: nickname) else {
                            return "nicknameErrorShorter".localized()
                        }
                        
                        return nil
                    }
                ),
                onChange: { [weak self] updatedName in self?.updatedName = updatedName }
            ),
            confirmTitle: "save".localized(),
            confirmEnabled: .afterChange { [weak self] _ in
                self?.updatedName != current &&
                self?.updatedName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            },
            cancelTitle: "remove".localized(),
            cancelStyle: .danger,
            cancelEnabled: .bool(current?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false),
            hasCloseButton: true,
            dismissOnConfirm: false,
            onConfirm: { [weak self, dependencies] modal in
                guard
                    let finalNickname: String = (self?.updatedName ?? "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .nullIfEmpty
                else { return }
                
                /// Check if the data violates the size constraints
                guard !Profile.isTooLong(profileName: finalNickname) else {
                    modal.updateContent(withError: "nicknameErrorShorter".localized())
                    return
                }
                
                /// Update the nickname
                dependencies[singleton: .storage].writeAsync(
                    updates: { db in
                        try Profile.updateIfNeeded(
                            db,
                            publicKey: state.threadInfo.id,
                            nicknameUpdate: .set(to: finalNickname),
                            profileUpdateTimestamp: nil,                              /// Not set for `nickname`
                            currentUserSessionIds: [currentUserSessionId.hexString],  /// Contact thread
                            using: dependencies
                        )
                    },
                    completion: { _ in
                        DispatchQueue.main.async {
                            modal.dismiss(animated: true)
                        }
                    }
                )
            },
            onCancel: { [dependencies] modal in
                /// Remove the nickname
                dependencies[singleton: .storage].writeAsync(
                    updates: { db in
                        try Profile.updateIfNeeded(
                            db,
                            publicKey: state.threadInfo.id,
                            nicknameUpdate: .set(to: nil),
                            profileUpdateTimestamp: nil,                              /// Not set for `nickname`
                            currentUserSessionIds: [currentUserSessionId.hexString],  /// Contact thread
                            using: dependencies
                        )
                    },
                    completion: { _ in
                        DispatchQueue.main.async {
                            modal.dismiss(animated: true)
                        }
                    }
                )
            }
        )
    }
    
    private func updateGroupNameAndDescription(
        state: State,
        currentName: String,
        currentDescription: String?,
        isUpdatedGroup: Bool
    ) -> ConfirmationModal.Info {
        /// Set the `updatedName` and `updatedDescription` values to the current values so we can disable the "save" button when there are
        /// no changes and don't need to worry about retrieving them in the confirmation closure
        self.updatedName = currentName
        self.updatedDescription = currentDescription
        return ConfirmationModal.Info(
            title: "updateGroupInformation".localized(),
            body: { [weak self] in
                return .dualInput(
                    explanation: "updateGroupInformationDescription"
                        .localizedFormatted(baseFont: ConfirmationModal.explanationFont),
                    firstInfo: ConfirmationModal.Info.Body.InputInfo(
                        placeholder: "groupNameEnter".localized(),
                        initialValue: currentName,
                        clearButton: true,
                        accessibility: Accessibility(
                            identifier: "Group name text field"
                        ),
                        inputChecker: { text in
                            let groupName: String = text.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !LibSession.isTooLong(groupName: groupName) else {
                                return "groupNameEnterShorter".localized()
                            }
                            return nil
                        }
                    ),
                    secondInfo: ConfirmationModal.Info.Body.InputInfo(
                        placeholder: "groupDescriptionEnter".localized(),
                        initialValue: currentDescription,
                        clearButton: true,
                        accessibility: Accessibility(
                            identifier: "Group description text field"
                        ),
                        inputChecker: { text in
                            let groupDescription: String = text.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !LibSession.isTooLong(groupDescription: groupDescription) else {
                                return "updateGroupInformationEnterShorterDescription".localized()
                            }
                            return nil
                        }
                    ),
                    onChange: { updatedName, updatedDescription in
                        self?.updatedName = updatedName
                        self?.updatedDescription = updatedDescription
                    }
                )
            }(),
            confirmTitle: "save".localized(),
            confirmEnabled: .afterChange { [weak self] _ in
                self?.updatedName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false && (
                    self?.updatedName != currentName ||
                    self?.updatedDescription != currentDescription
                )
            },
            cancelStyle: .danger,
            dismissOnConfirm: false,
            onConfirm: { [weak self, dependencies] modal in
                guard
                    let finalName: String = (self?.updatedName ?? "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .nullIfEmpty
                else { return }
                
                let finalDescription: String? = self?.updatedDescription
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                
                /// Check if the data violates any of the size constraints
                let maybeNameError: String? = LibSession.isTooLong(groupName: finalName) ?
                    "groupNameEnterShorter".localized() : nil
                let maybeDescriptionError: String? = LibSession.isTooLong(groupDescription: (finalDescription ?? "")) ?
                    "updateGroupInformationEnterShorterDescription".localized() : nil
                
                guard maybeNameError == nil && maybeDescriptionError == nil else {
                    modal.updateContent(withError: maybeNameError, additionalError: maybeDescriptionError)
                    return
                }
                
                /// Update the group appropriately
                MessageSender
                    .updateGroup(
                        groupSessionId: state.threadInfo.id,
                        name: finalName,
                        groupDescription: finalDescription,
                        using: dependencies
                    )
                    .subscribe(on: DispatchQueue.global(qos: .userInitiated), using: dependencies)
                    .receive(on: DispatchQueue.main, using: dependencies)
                    .sinkUntilComplete()
                
                modal.dismiss(animated: true)
            }
        )
    }
    
    private func updateGroupDisplayPicture(state: State, currentUrl: String?) {
        guard dependencies[feature: .updatedGroupsAllowDisplayPicture] else { return }
        
        let iconName: String = "profile_placeholder" // stringlint:ignore
        var hasSetNewProfilePicture: Bool = false
        let currentSource: ImageDataManager.DataSource? = {
            let source: ImageDataManager.DataSource? = currentUrl
                .map { try? dependencies[singleton: .displayPictureManager].path(for: $0) }
                .map { ImageDataManager.DataSource.url(URL(fileURLWithPath: $0)) }
            
            return (source?.contentExists == true ? source : nil)
        }()
        let body: ConfirmationModal.Info.Body = .image(
            source: nil,
            placeholder: (
                currentSource ??
                Lucide.image(icon: .image, size: 40).map { image in
                    ImageDataManager.DataSource.image(
                        iconName,
                        image
                            .withTintColor(#colorLiteral(red: 0.631372549, green: 0.6352941176, blue: 0.631372549, alpha: 1), renderingMode: .alwaysTemplate)
                            .withCircularBackground(backgroundColor: #colorLiteral(red: 0.1764705882, green: 0.1764705882, blue: 0.1764705882, alpha: 1))
                    )
                }
            ),
            icon: (currentUrl != nil ? .pencil : .rightPlus),
            style: .circular,
            description: nil,   // FIXME: Need to add Group Pro display pic description
            accessibility: Accessibility(
                identifier: "Upload",
                label: "Upload"
            ),
            dataManager: dependencies[singleton: .imageDataManager],
            onProBageTapped: nil,   // FIXME: Need to add Group Pro display pic CTA
            onClick: { [weak self] onDisplayPictureSelected in
                self?.onDisplayPictureSelected = { source, cropRect in
                    onDisplayPictureSelected(.image(
                        source: source,
                        cropRect: cropRect,
                        replacementIcon: .pencil,
                        replacementCancelTitle: "clear".localized()
                    ))
                    hasSetNewProfilePicture = true
                }
                self?.showPhotoLibraryForAvatar()
            }
        )
        
        self.transitionToScreen(
            ConfirmationModal(
                info: ConfirmationModal.Info(
                    title: "groupSetDisplayPicture".localized(),
                    body: body,
                    confirmTitle: "save".localized(),
                    confirmEnabled: .afterChange { info in
                        switch info.body {
                            case .image(.some(let source), _, _, _, _, _, _, _, _): return source.contentExists
                            default: return false
                        }
                    },
                    cancelTitle: "remove".localized(),
                    cancelEnabled: (currentUrl != nil ? .bool(true) : .afterChange { info in
                        switch info.body {
                            case .image(.some(let source), _, _, _, _, _, _, _, _): return source.contentExists
                            default: return false
                        }
                    }),
                    hasCloseButton: true,
                    dismissOnConfirm: false,
                    onConfirm: { [weak self] modal in
                        switch modal.info.body {
                            case .image(.some(let source), _, _, let style, _, _, _, _, _):
                                // FIXME: Need to add Group Pro display pic CTA
                                self?.updateGroupDisplayPicture(
                                    state: state,
                                    displayPictureUpdate: .groupUploadImage(
                                        source: source,
                                        cropRect: style.cropRect
                                    ),
                                    onUploadComplete: { [weak modal] in
                                        Task { @MainActor in modal?.close() }
                                    }
                                )
                                
                            default: modal.close()
                        }
                    },
                    onCancel: { [weak self] modal in
                        if hasSetNewProfilePicture {
                            modal.updateContent(
                                with: modal.info.with(
                                    body: body,
                                    cancelTitle: "remove".localized()
                                )
                            )
                            hasSetNewProfilePicture = false
                        } else {
                            self?.updateGroupDisplayPicture(
                                state: state,
                                displayPictureUpdate: .groupRemove,
                                onUploadComplete: { [weak modal] in
                                    Task { @MainActor in modal?.close() }
                                }
                            )
                        }
                    }
                )
            ),
            transitionType: .present
        )
    }
    
    @MainActor private func showPhotoLibraryForAvatar() {
        Permissions.requestLibraryPermissionIfNeeded(isSavingMedia: false, using: dependencies) { [weak self] in
            DispatchQueue.main.async {
                var configuration: PHPickerConfiguration = PHPickerConfiguration()
                configuration.selectionLimit = 1
                configuration.filter = .any(of: [.images, .livePhotos])
                
                let picker: PHPickerViewController = PHPickerViewController(configuration: configuration)
                picker.delegate = self?.imagePickerHandler
                
                self?.transitionToScreen(picker, transitionType: .present)
            }
        }
    }
    
    private func updateGroupDisplayPicture(
        state: State,
        displayPictureUpdate: DisplayPictureManager.Update,
        onUploadComplete: @escaping () -> ()
    ) {
        switch displayPictureUpdate {
            case .none: onUploadComplete()
            default: break
        }
        
        Task.detached(priority: .userInitiated) { [weak self, dependencies] in
            var targetUpdate: DisplayPictureManager.Update = displayPictureUpdate
            var indicator: ModalActivityIndicatorViewController?
            
            do {
                switch displayPictureUpdate {
                    case .none, .currentUserRemove, .currentUserUpdateTo, .contactRemove,
                        .contactUpdateTo:
                        throw AttachmentError.invalidStartState
                        
                    case .groupRemove, .groupUpdateTo: break
                    case .groupUploadImage(let source, let cropRect):
                        /// Show a blocking loading indicator while uploading but not while updating or syncing the group configs
                        indicator = await MainActor.run { [weak self] in
                            let indicator: ModalActivityIndicatorViewController = ModalActivityIndicatorViewController(onAppear: { _ in })
                            self?.transitionToScreen(indicator, transitionType: .present)
                            return indicator
                        }
                        
                        let pendingAttachment: PendingAttachment = PendingAttachment(
                            source: .media(source),
                            using: dependencies
                        )
                        let preparedAttachment: PreparedAttachment = try await dependencies[singleton: .displayPictureManager]
                            .prepareDisplayPicture(
                                attachment: pendingAttachment,
                                fallbackIfConversionTakesTooLong: true,
                                cropRect: cropRect
                            )
                        let result = try await dependencies[singleton: .displayPictureManager]
                            .uploadDisplayPicture(preparedAttachment: preparedAttachment)
                        await MainActor.run { onUploadComplete() }
                        
                        targetUpdate = .groupUpdateTo(
                            url: result.downloadUrl,
                            key: result.encryptionKey
                        )
                }
            }
            catch {
                let message: String = {
                    switch (displayPictureUpdate, error) {
                        case (.groupRemove, _): return "profileDisplayPictureRemoveError".localized()
                        case (_, AttachmentError.fileSizeTooLarge):
                            return "profileDisplayPictureSizeError".localized()
                            
                        default: return "errorConnection".localized()
                    }
                }()
                
                await indicator?.dismiss { [weak self] in
                    self?.transitionToScreen(
                        ConfirmationModal(
                            info: ConfirmationModal.Info(
                                title: "deleteAfterLegacyGroupsGroupUpdateErrorTitle".localized(),
                                body: .text(message),
                                cancelTitle: "okay".localized(),
                                cancelStyle: .alert_text,
                                dismissType: .single
                            )
                        ),
                        transitionType: .present
                    )
                }
                return
            }
            
            let existingDownloadUrl: String? = try? await dependencies[singleton: .storage].readAsync { db in
                try? ClosedGroup
                    .filter(id: state.threadInfo.id)
                    .select(.displayPictureUrl)
                    .asRequest(of: String.self)
                    .fetchOne(db)
            }
            
            do {
                try await MessageSender.updateGroup(
                    groupSessionId: state.threadInfo.id,
                    displayPictureUpdate: targetUpdate,
                    using: dependencies
                )
                
                /// Remove any cached avatar image value (only want to do so if the above update succeeded)
                if
                    let existingDownloadUrl: String = existingDownloadUrl,
                    let existingFilePath: String = try? dependencies[singleton: .displayPictureManager]
                        .path(for: existingDownloadUrl)
                {
                    Task { [dependencies] in
                        await dependencies[singleton: .imageDataManager].removeImage(
                            identifier: existingFilePath
                        )
                        try? dependencies[singleton: .fileManager].removeItem(atPath: existingFilePath)
                    }
                }
            }
            catch {}
            
            await indicator?.dismiss()
        }
    }
    
    private func updateBlockedState(
        from oldBlockedState: Bool,
        isBlocked: Bool,
        threadId: String,
        displayName: String
    ) {
        guard oldBlockedState != isBlocked else { return }
        
        dependencies[singleton: .storage].writeAsync { [dependencies] db in
            try Contact
                .filter(id: threadId)
                .updateAllAndConfig(
                    db,
                    Contact.Columns.isBlocked.set(to: isBlocked),
                    using: dependencies
                )
            db.addContactEvent(id: threadId, change: .isBlocked(isBlocked))
        }
    }
    
    private func toggleConversationPinnedStatus(threadInfo: ConversationInfoViewModel) async {
        let isCurrentlyPinned: Bool = (threadInfo.pinnedPriority > LibSession.visiblePriority)
        let sessionProState: SessionPro.State = await dependencies[singleton: .sessionProManager]
            .state
            .first(defaultValue: .invalid)
        
        if sessionProState.sessionProEnabled && !isCurrentlyPinned && sessionProState.status != .active {
            // TODO: [Database Relocation] Retrieve the full conversation list from lib session and check the pinnedPriority that way instead of using the database
            do {
                let numPinnedConversations: Int = try await dependencies[singleton: .storage].writeAsync { [dependencies] db in
                    let numPinnedConversations: Int = try SessionThread
                        .filter(SessionThread.Columns.pinnedPriority > LibSession.visiblePriority)
                        .fetchCount(db)
                    
                    guard numPinnedConversations < SessionPro.PinnedConversationLimit else {
                        return numPinnedConversations
                    }
                    
                    /// We have the space to pin the conversation, so do so
                    try SessionThread.updateVisibility(
                        db,
                        threadId: threadInfo.id,
                        threadVariant: threadInfo.variant,
                        isVisible: true,
                        customPriority: (threadInfo.pinnedPriority <= LibSession.visiblePriority ? 1 : LibSession.visiblePriority),
                        using: dependencies
                    )
                    
                    return -1
                }
                
                /// If we already have too many conversations pinned then we need to show the CTA modal
                guard numPinnedConversations > 0 else { return }
                
                _ = await MainActor.run { [weak self, dependencies] in
                    dependencies[singleton: .sessionProManager].showSessionProCTAIfNeeded(
                        .morePinnedConvos(
                            isGrandfathered: (numPinnedConversations > SessionPro.PinnedConversationLimit),
                            renew: (sessionProState.status == .expired)
                        ),
                        onConfirm: { [weak self] in
                            dependencies[singleton: .sessionProManager].showSessionProBottomSheetIfNeeded(
                                presenting: { [weak self] bottomSheet in
                                    self?.transitionToScreen(bottomSheet, transitionType: .present)
                                }
                            )
                        },
                        presenting: { [weak self] modal in
                            self?.transitionToScreen(modal, transitionType: .present)
                        }
                    )
                }
            }
            catch {}
            return
        }
        
        // If we are unpinning then no need to check the current count, just unpin immediately
        try? await dependencies[singleton: .storage].writeAsync { [dependencies] db in
            try SessionThread.updateVisibility(
                db,
                threadId: threadInfo.id,
                threadVariant: threadInfo.variant,
                isVisible: true,
                customPriority: (threadInfo.pinnedPriority <= LibSession.visiblePriority ? 1 : LibSession.visiblePriority),
                using: dependencies
            )
        }
    }
    
    private func deleteAllMessagesBeforeNow(state: State) {
        guard state.threadInfo.variant == .group else { return }
        
        dependencies[singleton: .storage].writeAsync { [dependencies] db in
            try LibSession.deleteMessagesBefore(
                db,
                groupSessionId: SessionId(.group, hex: state.threadInfo.id),
                timestamp: (dependencies[cache: .snodeAPI].currentOffsetTimestampMs() / 1000),
                using: dependencies
            )
        }
    }
    
    private func deleteAllAttachmentsBeforeNow(state: State) {
        guard state.threadInfo.variant == .group else { return }
        
        dependencies[singleton: .storage].writeAsync { [dependencies] db in
            try LibSession.deleteAttachmentsBefore(
                db,
                groupSessionId: SessionId(.group, hex: state.threadInfo.id),
                timestamp: (dependencies[cache: .snodeAPI].currentOffsetTimestampMs() / 1000),
                using: dependencies
            )
        }
    }
    
    // MARK: - Confirmation Modals
    
    private func updateDisplayNameModal(state: State) -> ConfirmationModal.Info? {
        guard !state.threadInfo.isNoteToSelf else { return nil }
        
        switch (state.threadInfo.variant, state.threadInfo.groupInfo?.currentUserRole) {
            case (.contact, _):
                return self.updateNickname(
                    state: state,
                    current: state.threadInfo.profile?.nickname,
                    displayName: (
                        /// **Note:** We want to use the `profile` directly rather than `threadViewModel.displayName`
                        /// as the latter would use the `nickname` here which is incorrect
                        state.threadInfo.profile?.displayName(ignoreNickname: true) ??
                        state.threadInfo.displayName.deformatted()
                    )
                )
            
            case (.group, .admin), (.legacyGroup, .admin):
                return self.updateGroupNameAndDescription(
                    state: state,
                    currentName: state.threadInfo.displayName.deformatted(),
                    currentDescription: state.threadInfo.conversationDescription,
                    isUpdatedGroup: (state.threadInfo.variant == .group)
                )
            
            case (.community, _), (.legacyGroup, _), (.group, _): return nil
        }
    }
    
    private func showQRCodeLightBox(for threadInfo: ConversationInfoViewModel) {
        let qrCodeImage: UIImage = QRCode.generate(
            for: threadInfo.qrCodeString,
            hasBackground: false,
            iconName: "SessionWhite40" // stringlint:ignore
        )
        .withRenderingMode(.alwaysTemplate)
        
        let viewController = SessionHostingViewController(
            rootView: LightBox(
                itemsToShare: [
                    QRCode.qrCodeImageWithBackground(
                        image: qrCodeImage,
                        size: CGSize(width: 400, height: 400),
                        insets: UIEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
                    )
                ]
            ) {
                VStack {
                    Spacer()
                    
                    QRCodeView(
                        qrCodeImage: qrCodeImage,
                        themeStyle: ThemeManager.currentTheme.interfaceStyle
                    )
                    .aspectRatio(1, contentMode: .fit)
                    .frame(
                        maxWidth: .infinity,
                        maxHeight: .infinity
                    )
                    
                    Spacer()
                }
                .backgroundColor(themeColor: .newConversation_background)
            },
            customizedNavigationBackground: .backgroundSecondary
        )
        viewController.modalPresentationStyle = .fullScreen
        self.transitionToScreen(viewController, transitionType: .present)
    }
}

// MARK: - Convenience

private extension ObservedEvent {
    var handlingStrategy: EventHandlingStrategy {
        let threadInfoStrategy: EventHandlingStrategy? = ConversationInfoViewModel.handlingStrategy(for: self)
        let localStrategy: EventHandlingStrategy = {
            switch (key, key.generic) {
                case (.appLifecycle(.willEnterForeground), _): return .databaseQuery
                case (.databaseLifecycle(.resumed), _): return .databaseQuery
                
                default: return .directCacheUpdate
            }
        }()
        
        return localStrategy.union(threadInfoStrategy ?? .none)
    }
}

private extension ConversationInfoViewModel {
    var qrCodeString: String {
        switch self.variant {
            case .contact, .legacyGroup, .group: return id
            case .community:
                guard
                    let communityInfo: CommunityInfo = self.communityInfo,
                    let urlString: String = LibSession.communityUrlFor(
                        server: communityInfo.server,
                        roomToken: communityInfo.roomToken,
                        publicKey: communityInfo.publicKey
                    )
                else { return "" }

                return urlString
        }
    }
}
