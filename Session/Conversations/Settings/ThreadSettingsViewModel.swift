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

class ThreadSettingsViewModel: SessionListScreenContent.ViewModelType, NavigationItemSource, NavigatableStateHolder {
    public let dependencies: Dependencies
    public let navigatableState: NavigatableState = NavigatableState()
    public let state: SessionListScreenContent.ListItemDataState<Section, ListItem> = SessionListScreenContent.ListItemDataState()
    
    /// This value is the current state of the view
    @MainActor @Published private(set) var internalState: ViewModelState
    private var observationTask: Task<Void, Never>?
    
    private let threadId: String
    private let threadVariant: SessionThread.Variant
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
    
    // MARK: - Initialization
    
    @MainActor init(
        threadId: String,
        threadVariant: SessionThread.Variant,
        didTriggerSearch: @escaping () -> (),
        using dependencies: Dependencies
    ) {
        self.dependencies = dependencies
        self.threadId = threadId
        self.threadVariant = threadVariant
        self.didTriggerSearch = didTriggerSearch
        self.internalState = ViewModelState.initialState(threadId: threadId)
        
        self.observationTask = ObservationBuilder
            .initialValue(self.internalState)
            .debounce(for: .never)
            .using(dependencies: dependencies)
            .query(ThreadSettingsViewModel.queryState)
            .assign { [weak self] updatedState in
                guard let self = self else { return }
                
                self.state.updateTableData(updatedState.sections(viewModel: self, previousState: self.internalState))
                self.internalState = updatedState
            }
    }
    
    // MARK: - Config
    
    enum ProfileImageStatus: Equatable {
        case normal
        case expanded
        case qrCode
    }
    
    enum NavItem: Equatable {
        case edit
    }
    
    public enum Section: SessionListScreenContent.ListSection {
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
        
        public var style: SessionListScreenContent.ListSectionStyle {
            switch self {
                case .sessionId, .sessionIdNoteToSelf: return .titleSeparator
                case .destructiveActions: return .padding
                case .adminActions: return .titleRoundedContent
                default: return .none
            }
        }
        
        public var divider: Bool { return true }
        
        public var footer: String? { return nil }
    }
    
    public enum ListItem: Differentiable {
        case avatar
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
    
    lazy var rightNavItems: AnyPublisher<[SessionNavItem<NavItem>], Never> = $internalState
        .map { [weak self] state -> [SessionNavItem<NavItem>] in
            guard let threadViewModel: SessionThreadViewModel = state.threadViewModel else { return [] }
           
            let currentUserIsClosedGroupAdmin: Bool = (
                [.legacyGroup, .group].contains(threadViewModel.threadVariant) &&
                threadViewModel.currentUserIsClosedGroupAdmin == true
            )
            
            let canEditDisplayName: Bool = (
                threadViewModel.threadIsNoteToSelf != true &&
                (
                    threadViewModel.threadVariant == .contact ||
                    currentUserIsClosedGroupAdmin
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
                        guard
                            let info: ConfirmationModal.Info = self?.updateDisplayNameModal(
                                threadViewModel: threadViewModel,
                                currentUserIsClosedGroupAdmin: currentUserIsClosedGroupAdmin
                            )
                        else { return }
                        
                        self?.transitionToScreen(ConfirmationModal(info: info), transitionType: .present)
                    }
                )
            ]
        }
        .eraseToAnyPublisher()
    
    // MARK: - Content
    
    public struct ViewModelState: ObservableKeyProvider {
        let threadId: String
        let threadViewModel: SessionThreadViewModel?
        let disappearingMessagesConfig: DisappearingMessagesConfiguration
        
        @MainActor public func sections(viewModel: ThreadSettingsViewModel, previousState: ViewModelState) -> [SectionModel] {
            ThreadSettingsViewModel.sections(
                current: self,
                viewModel: viewModel
            )
        }
        
        public var observedKeys: Set<ObservableKey> {
            var result: Set<ObservableKey> = [
                .updateScreen(ThreadSettingsViewModel.self),
                .profile(threadId),
                .contact(threadId),
                .conversationUpdated(threadId),
                .disappearingMessagesConfigUpdated(threadId)
            ]
            
            return result
        }
        
        static func initialState(threadId: String) -> ViewModelState {
            return ViewModelState(
                threadId: threadId,
                threadViewModel: nil,
                disappearingMessagesConfig: DisappearingMessagesConfiguration.defaultWith(threadId)
            )
        }
    }
    
    var title: String {
        switch threadVariant {
            case .contact: return "sessionSettings".localized()
            case .legacyGroup, .group, .community: return "deleteAfterGroupPR1GroupSettings".localized()
        }
    }
    
    @Sendable private static func queryState(
        previousState: ViewModelState,
        events: [ObservedEvent],
        isInitialQuery: Bool,
        using dependencies: Dependencies
    ) async -> ViewModelState {
        let userSessionId: SessionId = dependencies[cache: .general].sessionId
        let threadId: String = previousState.threadId
        var threadViewModel: SessionThreadViewModel? = previousState.threadViewModel
        var disappearingMessagesConfig: DisappearingMessagesConfiguration = previousState.disappearingMessagesConfig
        
        /// If we have no previous state then we need to fetch the initial state
        if isInitialQuery {
            dependencies[singleton: .storage].read { db in
                threadViewModel = try SessionThreadViewModel
                    .conversationSettingsQuery(threadId: threadId, userSessionId: userSessionId)
                    .fetchOne(db)
                disappearingMessagesConfig = try DisappearingMessagesConfiguration
                    .fetchOne(db, id: threadId)
                    .defaulting(to: DisappearingMessagesConfiguration.defaultWith(threadId))
            }
        }
        
        /// Process any event changes
        events.forEach { event in
            switch event.key.generic {
                case .disappearingMessagesConfigUpdate:
                    if threadId == id, let newValue = event.value as? DisappearingMessagesConfiguration {
                        disappearingMessagesConfig = newValue
                    }
                default:
                    dependencies[singleton: .storage].read { db in
                        threadViewModel = try SessionThreadViewModel
                            .conversationSettingsQuery(threadId: threadId, userSessionId: userSessionId)
                            .fetchOne(db)
                    }
            }
        }
        
        return ViewModelState(
            threadId: threadId,
            threadViewModel: threadViewModel,
            disappearingMessagesConfig: disappearingMessagesConfig
        )
    }
    
    private static func sections(
        current: ViewModelState,
        viewModel: ThreadSettingsViewModel
    ) -> [SectionModel] {
        // If we don't get a `SessionThreadViewModel` then it means the thread was probably deleted
        // so dismiss the screen
        guard let threadViewModel: SessionThreadViewModel = current.threadViewModel else {
            viewModel.dismissScreen(type: .popToRoot)
            return []
        }
        
        let isGroup: Bool = (
            threadViewModel.threadVariant == .legacyGroup ||
            threadViewModel.threadVariant == .group
        )
        let currentUserKickedFromGroup: Bool = (
            isGroup &&
            threadViewModel.currentUserIsClosedGroupMember != true
        )
        
        let currentUserIsClosedGroupMember: Bool = (
            isGroup &&
            threadViewModel.currentUserIsClosedGroupMember == true
        )
        let currentUserIsClosedGroupAdmin: Bool = (
            isGroup &&
            threadViewModel.currentUserIsClosedGroupAdmin == true
        )
        let isThreadHidden: Bool = (
            threadViewModel.threadShouldBeVisible != true &&
            threadViewModel.threadPinnedPriority == LibSession.hiddenPriority
        )

        let showThreadPubkey: Bool = (
            threadViewModel.threadVariant == .contact || (
                threadViewModel.threadVariant == .group &&
                viewModel.dependencies[feature: .groupsShowPubkeyInConversationSettings]
            )
        )
        // MARK: - Conversation Info
        
        let conversationInfoSection: SectionModel = SectionModel(
            model: .conversationInfo,
            elements: [
                SessionListScreenContent.ListItemInfo(
                    id: .avatar,
                    variant: .profilePicture(
                        info: .init(
                            sessionId: threadViewModel.id,
                            qrCodeImage: {
                                guard let sessionId: String = threadViewModel.id else { return nil }
                                return QRCode.generate(
                                    for: sessionId,
                                    hasBackground: false,
                                    iconName: "SessionWhite40" // stringlint:ignore
                                )
                            }(),
                            profileInfo: {
                                let (info, _) = ProfilePictureView.Info.generateInfoFrom(
                                    size: .hero,
                                    publicKey: threadViewModel.id,
                                    threadVariant: threadViewModel.threadVariant,
                                    displayPictureUrl: nil,
                                    profile: threadViewModel.profile,
                                    using: viewModel.dependencies
                                )
                                
                                return info
                            }()
                        )
                    )
                ),
                SessionListScreenContent.ListItemInfo(
                    id: .displayName,
                    variant: .cell(
                        info: .init(
                            title: .init(
                                threadViewModel.displayName,
                                font: .Headings.H4,
                                alignment: .center,
                                accessory: {
                                    guard !threadViewModel.threadIsNoteToSelf else { return nil }
                                    guard (dependencies.mutate(cache: .libSession) { $0.validateSessionProState(for: threadId) }) else { return nil }
                                    
                                    return (
                                        .themedKey(
                                            SessionProBadge.Size.medium.cacheKey,
                                            themeBackgroundColor: .primary
                                        ),
                                        { SessionProBadge(size: .medium) }
                                    )
                                }()
                            )
                        )
                    ),
                    accessibility: Accessibility(
                        identifier: "Username",
                        label: threadViewModel.displayName
                    ),
                    onTap: { [threadId, dependencies = viewModel.dependencies] target in
                        guard targetView is SessionProBadge, !dependencies[cache: .libSession].isSessionPro else {
                            guard
                                let info: ConfirmationModal.Info = self?.updateDisplayNameModal(
                                    threadViewModel: threadViewModel,
                                    currentUserIsClosedGroupAdmin: currentUserIsClosedGroupAdmin
                                )
                            else { return }
                            
                            self?.transitionToScreen(ConfirmationModal(info: info), transitionType: .present)
                            return
                        }
                        
                        let proCTAModalVariant: ProCTAModal.Variant = {
                            switch threadViewModel.threadVariant {
                                case .group:
                                    return .groupLimit(
                                        isAdmin: currentUserIsClosedGroupAdmin,
                                        isSessionProActivated: (dependencies.mutate(cache: .libSession) { $0.validateSessionProState(for: threadId) }),
                                        proBadgeImage: UIView.image(
                                            for: .themedKey(
                                                SessionProBadge.Size.mini.cacheKey,
                                                themeBackgroundColor: .primary
                                            ),
                                            generator: { SessionProBadge(size: .mini) }
                                        )
                                    )
                                default: return .generic
                            }
                        }()
                        
                        dependencies[singleton: .sessionProState].showSessionProCTAIfNeeded(
                            proCTAModalVariant,
                            onConfirm: {},
                            presenting: { modal in
                                viewModel.transitionToScreen(modal, transitionType: .present)
                            }
                        )
                    }
                ),
                
                (threadViewModel.displayName == threadViewModel.contactDisplayName ? nil :
                    SessionListScreenContent.ListItemInfo(
                        id: .contactName,
                        variant: .cell(
                            info: .init(
                                title: .init(
                                    "(\(threadViewModel.contactDisplayName))", // stringlint:ignore
                                    font: .Body.baseRegular,
                                    alignment: .center,
                                    color: .textSecondary
                                )
                            )
                        ),
                    )
                ),
                
                threadViewModel.threadDescription.map { threadDescription in
                    SessionListScreenContent.ListItemInfo(
                        id: .threadDescription,
                        variant: .cell(
                            info: .init(
                                title: .init(
                                    threadDescription,
                                    font: .Body.baseRegular,
                                    alignment: .center,
                                    color: .textSecondary,
                                    interaction: .expandable
                                )
                            )
                        ),
                        accessibility: Accessibility(
                            identifier: "Description",
                            label: threadDescription
                        )
                    )
                }
            ].compactMap { $0 }
        )
        
        // MARK: - Session Id
        
        let sessionIdSection: SectionModel = SectionModel(
            model: (threadViewModel.threadIsNoteToSelf == true ? .sessionIdNoteToSelf : .sessionId),
            elements: [
                SessionListScreenContent.ListItemInfo(
                    id: .sessionId,
                    variant: .cell(
                        info: .init(
                            title: .init(
                                threadViewModel.id,
                                font: .Display.extraLarge,
                                alignment: .center,
                                interaction: .copy
                            )
                        )
                    ),
                    accessibility: Accessibility(
                        identifier: "Session ID",
                        label: threadViewModel.id
                    )
                )
            ]
        )
        
        // MARK: - Users kicked from groups
        
        guard !currentUserKickedFromGroup else {
            return [
                conversationInfoSection,
                SectionModel(
                    model: .destructiveActions,
                    elements: [
                        SessionListScreenContent.ListItemInfo(
                            id: .leaveGroup,
                            variant: .cell(
                                info: .init(
                                    leadingAccessory: .icon(.trash2),
                                    title: .init(
                                        "groupDelete".localized(),
                                        font: .Headings.H8,
                                        color: .danger
                                    )
                                )
                            ),
                            accessibility: Accessibility(
                                identifier: "Leave group",
                                label: "Leave group"
                            ),
                            confirmationInfo: ConfirmationModal.Info(
                                title: "groupDelete".localized(),
                                body: .attributedText(
                                    "groupDeleteDescriptionMember"
                                        .put(key: "group_name", value: threadViewModel.displayName)
                                        .localizedFormatted(baseFont: ConfirmationModal.explanationFont)
                                ),
                                confirmTitle: "delete".localized(),
                                confirmStyle: .danger,
                                cancelStyle: .alert_text
                            ),
                            onTap: { [dependencies = viewModel.dependencies] in
                                viewModel.dismissScreen(type: .popToRoot) {
                                    dependencies[singleton: .storage].writeAsync { db in
                                        try SessionThread.deleteOrLeave(
                                            db,
                                            type: .leaveGroupAsync,
                                            threadId: threadViewModel.threadId,
                                            threadVariant: threadViewModel.threadVariant,
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
                (threadViewModel.threadVariant == .legacyGroup || threadViewModel.threadVariant == .group ? nil :
                    SessionListScreenContent.ListItemInfo(
                        id: .copyThreadId,
                        variant: .cell(
                            info: .init(
                                leadingAccessory: .icon(.copy),
                                title: .init(
                                    (threadViewModel.threadVariant == .community ?
                                        "communityUrlCopy".localized() :
                                        "accountIDCopy".localized()
                                    ),
                                    font: .Headings.H8
                                )
                            )
                        ),
                        accessibility: Accessibility(
                            identifier: "\(ThreadSettingsViewModel.self).copy_thread_id",
                            label: "Copy Session ID"
                        ),
                        onTap: {
                            switch threadViewModel.threadVariant {
                                case .contact, .legacyGroup, .group:
                                    UIPasteboard.general.string = threadViewModel.threadId

                                case .community:
                                    guard
                                        let urlString: String = LibSession.communityUrlFor(
                                            server: threadViewModel.openGroupServer,
                                            roomToken: threadViewModel.openGroupRoomToken,
                                            publicKey: threadViewModel.openGroupPublicKey
                                        )
                                    else { return }

                                    UIPasteboard.general.string = urlString
                            }

                            viewModel.showToast(
                                text: "copied".localized(),
                                backgroundColor: .backgroundSecondary
                            )
                        }
                    )
                ),

                SessionListScreenContent.ListItemInfo(
                    id: .searchConversation,
                    variant: .cell(
                        info: .init(
                            leadingAccessory: .icon(.search),
                            title: .init(
                                "searchConversation".localized(),
                                font: .Headings.H8
                            )
                        )
                    ),
                    accessibility: Accessibility(
                        identifier: "\(ThreadSettingsViewModel.self).search",
                        label: "Search"
                    ),
                    onTap: { viewModel.didTriggerSearch() }
                ),
                
                (
                    threadViewModel.threadVariant == .community ||
                    threadViewModel.threadIsBlocked == true ||
                    currentUserIsClosedGroupAdmin ? nil :
                    SessionCell.Info(
                        id: .disappearingMessages,
                        leadingAccessory: .icon(.timer),
                        title: "disappearingMessages".localized(),
                        subtitle: {
                            guard current.disappearingMessagesConfig.isEnabled else {
                                return "off".localized()
                            }
                            
                            return (current.disappearingMessagesConfig.type ?? .unknown)
                                .localizedState(
                                    durationString: current.disappearingMessagesConfig.durationString
                                )
                        }(),
                        accessibility: Accessibility(
                            identifier: "Disappearing messages",
                            label: "\(ThreadSettingsViewModel.self).disappearing_messages"
                        ),
                        onTap: { [weak self, dependencies] in
                            self?.transitionToScreen(
                                SessionTableViewController(
                                    viewModel: ThreadDisappearingMessagesSettingsViewModel(
                                        threadId: threadViewModel.threadId,
                                        threadVariant: threadViewModel.threadVariant,
                                        currentUserIsClosedGroupMember: threadViewModel.currentUserIsClosedGroupMember,
                                        currentUserIsClosedGroupAdmin: threadViewModel.currentUserIsClosedGroupAdmin,
                                        config: current.disappearingMessagesConfig,
                                        using: dependencies
                                    )
                                )
                            )
                        }
                    )
                ),
                
                (threadViewModel.threadIsBlocked == true ? nil :
                    SessionCell.Info(
                        id: .pinConversation,
                        leadingAccessory: .icon(
                            (threadViewModel.threadPinnedPriority > 0 ?
                                .pinOff :
                                .pin
                            )
                        ),
                        title: (threadViewModel.threadPinnedPriority > 0 ?
                                "pinUnpinConversation".localized() :
                                "pinConversation".localized()
                            ),
                        accessibility: Accessibility(
                            identifier: "\(ThreadSettingsViewModel.self).pin_conversation",
                            label: "Pin Conversation"
                        ),
                        onTap: { [weak self] in
                            self?.toggleConversationPinnedStatus(
                                currentPinnedPriority: threadViewModel.threadPinnedPriority
                            )
                        }
                    )
                 ),
                
                ((threadViewModel.threadIsNoteToSelf == true || threadViewModel.threadIsBlocked == true) ? nil :
                    SessionCell.Info(
                        id: .notifications,
                        leadingAccessory: .icon(
                            {
                                if threadViewModel.threadOnlyNotifyForMentions == true {
                                    return .atSign
                                }
                                
                                if threadViewModel.threadMutedUntilTimestamp != nil {
                                    return .volumeOff
                                }
                                
                                return .volume2
                            }()
                        ),
                        title: "sessionNotifications".localized(),
                        subtitle: {
                            if threadViewModel.threadOnlyNotifyForMentions == true {
                                return "notificationsMentionsOnly".localized()
                            }
                            
                            if threadViewModel.threadMutedUntilTimestamp != nil {
                                return "notificationsMuted".localized()
                            }
                            
                            return "notificationsAllMessages".localized()
                        }(),
                        accessibility: Accessibility(
                            identifier: "\(ThreadSettingsViewModel.self).notifications",
                            label: "Notifications"
                        ),
                        onTap: { [weak self, dependencies] in
                            self?.transitionToScreen(
                                SessionTableViewController(
                                    viewModel: ThreadNotificationSettingsViewModel(
                                        threadId: threadViewModel.threadId,
                                        threadVariant: threadViewModel.threadVariant,
                                        threadOnlyNotifyForMentions: threadViewModel.threadOnlyNotifyForMentions,
                                        threadMutedUntilTimestamp: threadViewModel.threadMutedUntilTimestamp,
                                        using: dependencies
                                    )
                                )
                            )
                        }
                    )
                ),
                
                (threadViewModel.threadVariant != .community ? nil :
                    SessionCell.Info(
                        id: .addToOpenGroup,
                        leadingAccessory: .icon(.userRoundPlus),
                        title: "membersInvite".localized(),
                        accessibility: Accessibility(
                            identifier: "\(ThreadSettingsViewModel.self).add_to_open_group"
                        ),
                        onTap: { [weak self] in self?.inviteUsersToCommunity(threadViewModel: threadViewModel) }
                    )
                ),
                
                (!currentUserIsClosedGroupMember ? nil :
                    SessionCell.Info(
                        id: .groupMembers,
                        leadingAccessory: .icon(.usersRound),
                        title: "groupMembers".localized(),
                        accessibility: Accessibility(
                            identifier: "Group members",
                            label: "Group members"
                        ),
                        onTap: { [weak self] in self?.viewMembers() }
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
                    onTap: { [weak self, dependencies] in
                        self?.transitionToScreen(
                            MediaGalleryViewModel.createAllMediaViewController(
                                threadId: threadViewModel.threadId,
                                threadVariant: threadViewModel.threadVariant,
                                threadTitle: threadViewModel.displayName,
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
            !currentUserIsClosedGroupAdmin ? nil :
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
                            onTap: { [weak self, dependencies] in
                                self?.transitionToScreen(
                                    SessionTableViewController(
                                        viewModel: EditGroupViewModel(
                                            threadId: threadViewModel.threadId,
                                            using: dependencies
                                        )
                                    )
                                )
                            }
                        ),
                        
                        (!dependencies[feature: .updatedGroupsAllowPromotions] ? nil :
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
                                onTap: { [weak self] in
                                    self?.promoteAdmins(currentGroupName: threadViewModel.closedGroupName)
                                }
                            )
                        ),
                        
                        SessionCell.Info(
                            id: .disappearingMessages,
                            leadingAccessory: .icon(.timer),
                            title: "disappearingMessages".localized(),
                            subtitle: {
                                guard current.disappearingMessagesConfig.isEnabled else {
                                    return "off".localized()
                                }
                                
                                return (current.disappearingMessagesConfig.type ?? .unknown)
                                    .localizedState(
                                        durationString: current.disappearingMessagesConfig.durationString
                                    )
                            }(),
                            accessibility: Accessibility(
                                identifier: "Disappearing messages",
                                label: "\(ThreadSettingsViewModel.self).disappearing_messages"
                            ),
                            onTap: { [weak self, dependencies] in
                                self?.transitionToScreen(
                                    SessionTableViewController(
                                        viewModel: ThreadDisappearingMessagesSettingsViewModel(
                                            threadId: threadViewModel.threadId,
                                            threadVariant: threadViewModel.threadVariant,
                                            currentUserIsClosedGroupMember: threadViewModel.currentUserIsClosedGroupMember,
                                            currentUserIsClosedGroupAdmin: threadViewModel.currentUserIsClosedGroupAdmin,
                                            config: current.disappearingMessagesConfig,
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
                (threadViewModel.threadIsNoteToSelf || threadViewModel.threadVariant != .contact ? nil :
                    SessionCell.Info(
                        id: .blockUser,
                        leadingAccessory: (
                            threadViewModel.threadIsBlocked == true ?
                                .icon(.userRoundCheck) :
                                .icon(UIImage(named: "ic_user_round_ban")?.withRenderingMode(.alwaysTemplate))
                        ),
                        title: (
                            threadViewModel.threadIsBlocked == true ?
                                "blockUnblock".localized() :
                                "block".localized()
                        ),
                        styling: SessionCell.StyleInfo(tintColor: .danger),
                        accessibility: Accessibility(
                            identifier: "\(ThreadSettingsViewModel.self).block",
                            label: "Block"
                        ),
                        confirmationInfo: ConfirmationModal.Info(
                            title: (threadViewModel.threadIsBlocked == true ?
                                "blockUnblock".localized() :
                                "block".localized()
                            ),
                            body: (threadViewModel.threadIsBlocked == true ?
                                .attributedText(
                                    "blockUnblockName"
                                        .put(key: "name", value: threadViewModel.displayName)
                                        .localizedFormatted(baseFont: ConfirmationModal.explanationFont)
                                ) :
                                .attributedText(
                                    "blockDescription"
                                        .put(key: "name", value: threadViewModel.displayName)
                                        .localizedFormatted(baseFont: ConfirmationModal.explanationFont)
                                )
                            ),
                            confirmTitle: (threadViewModel.threadIsBlocked == true ?
                                "blockUnblock".localized() :
                                "block".localized()
                            ),
                            confirmStyle: .danger,
                            cancelStyle: .alert_text
                        ),
                        onTap: { [weak self] in
                            let isBlocked: Bool = (threadViewModel.threadIsBlocked == true)
                            
                            self?.updateBlockedState(
                                from: isBlocked,
                                isBlocked: !isBlocked,
                                threadId: threadViewModel.threadId,
                                displayName: threadViewModel.displayName
                            )
                        }
                    )
                ),
                
                (threadViewModel.threadIsNoteToSelf != true ? nil :
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
                        onTap: { [dependencies] in
                            dependencies[singleton: .storage].writeAsync { db in
                                if isThreadHidden {
                                    try SessionThread.updateVisibility(
                                        db,
                                        threadId: threadViewModel.threadId,
                                        isVisible: true,
                                        using: dependencies
                                    )
                                } else {
                                    try SessionThread.deleteOrLeave(
                                        db,
                                        type: .hideContactConversation,
                                        threadId: threadViewModel.threadId,
                                        threadVariant: threadViewModel.threadVariant,
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
                            guard threadViewModel.threadIsNoteToSelf != true else {
                                return .attributedText(
                                    "clearMessagesNoteToSelfDescriptionUpdated"
                                        .localizedFormatted(baseFont: ConfirmationModal.explanationFont)
                                )
                            }
                            switch threadVariant {
                                case .contact:
                                    return .attributedText(
                                        "clearMessagesChatDescriptionUpdated"
                                            .put(key: "name", value: threadViewModel.displayName)
                                            .localizedFormatted(baseFont: ConfirmationModal.explanationFont)
                                    )
                                case .legacyGroup:
                                    return .attributedText(
                                        "clearMessagesGroupDescriptionUpdated"
                                            .put(key: "group_name", value: threadViewModel.displayName)
                                            .localizedFormatted(baseFont: ConfirmationModal.explanationFont)
                                    )
                                case .community:
                                    return .attributedText(
                                        "clearMessagesCommunityUpdated"
                                            .put(key: "community_name", value: threadViewModel.displayName)
                                            .localizedFormatted(baseFont: ConfirmationModal.explanationFont)
                                    )
                                case .group:
                                    if currentUserIsClosedGroupAdmin {
                                        return .radio(
                                            explanation: "clearMessagesGroupAdminDescriptionUpdated"
                                                .put(key: "group_name", value: threadViewModel.displayName)
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
                                                .put(key: "group_name", value: threadViewModel.displayName)
                                                .localizedFormatted(baseFont: ConfirmationModal.explanationFont)
                                        )
                                    }
                            }
                        }(),
                        confirmTitle: "clear".localized(),
                        confirmStyle: .danger,
                        cancelStyle: .alert_text,
                        dismissOnConfirm: false,
                        onConfirm: { [weak self, threadVariant, dependencies] modal in
                            if threadVariant == .group && currentUserIsClosedGroupAdmin {
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
                                
                                // Return if the selected option is `Clear on this device`
                                guard selectedIndex != 0 else { return }
                                self?.deleteAllMessagesBeforeNow()
                            }
                            dependencies[singleton: .storage].writeAsync(
                                updates: { db in
                                    try Interaction.markAllAsDeleted(
                                        db,
                                        threadId: threadViewModel.id,
                                        threadVariant: threadViewModel.threadVariant,
                                        options: [.local, .noArtifacts],
                                        using: dependencies
                                    )
                                }, completion: { [weak self] result in
                                    switch result {
                                        case .failure(let error):
                                            Log.error("Failed to clear messages due to error: \(error)")
                                            DispatchQueue.main.async {
                                                modal.dismiss(animated: true) {
                                                    self?.showToast(
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
                                                    self?.showToast(
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
                
                (threadViewModel.threadVariant != .community ? nil :
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
                                    .put(key: "group_name", value: threadViewModel.displayName)
                                    .localizedFormatted(baseFont: ConfirmationModal.explanationFont)
                            ),
                            confirmTitle: "leave".localized(),
                            confirmStyle: .danger,
                            cancelStyle: .alert_text
                        ),
                        onTap: { [weak self, dependencies] in
                            self?.dismissScreen(type: .popToRoot) {
                                dependencies[singleton: .storage].writeAsync { db in
                                    try SessionThread.deleteOrLeave(
                                        db,
                                        type: .deleteCommunityAndContent,
                                        threadId: threadViewModel.threadId,
                                        threadVariant: threadViewModel.threadVariant,
                                        using: dependencies
                                    )
                                }
                            }
                        }
                    )
                ),
                
                (!currentUserIsClosedGroupMember ? nil :
                    SessionCell.Info(
                        id: .leaveGroup,
                        leadingAccessory: .icon(currentUserIsClosedGroupAdmin ? .trash2 : .logOut),
                        title: currentUserIsClosedGroupAdmin ? "groupDelete".localized() : "groupLeave".localized(),
                        styling: SessionCell.StyleInfo(tintColor: .danger),
                        accessibility: Accessibility(
                            identifier: "Leave group",
                            label: "Leave group"
                        ),
                        confirmationInfo: ConfirmationModal.Info(
                            title: currentUserIsClosedGroupAdmin ? "groupDelete".localized() : "groupLeave".localized(),
                            body: (currentUserIsClosedGroupAdmin ?
                                .attributedText(
                                    "groupDeleteDescription"
                                        .put(key: "group_name", value: threadViewModel.displayName)
                                        .localizedFormatted(baseFont: ConfirmationModal.explanationFont)
                                ) :
                                .attributedText(
                                    "groupLeaveDescription"
                                        .put(key: "group_name", value: threadViewModel.displayName)
                                        .localizedFormatted(baseFont: ConfirmationModal.explanationFont)
                                )
                            ),
                            confirmTitle: currentUserIsClosedGroupAdmin ? "delete".localized() : "leave".localized(),
                            confirmStyle: .danger,
                            cancelStyle: .alert_text
                        ),
                        onTap: { [weak self, dependencies] in
                            self?.dismissScreen(type: .popToRoot) {
                                dependencies[singleton: .storage].writeAsync { db in
                                    try SessionThread.deleteOrLeave(
                                        db,
                                        type: .leaveGroupAsync,
                                        threadId: threadViewModel.threadId,
                                        threadVariant: threadViewModel.threadVariant,
                                        using: dependencies
                                    )
                                }
                            }
                        }
                    )
                ),
                
                (threadVariant != .contact || threadViewModel.threadIsNoteToSelf == true ? nil :
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
                                    .put(key: "name", value: threadViewModel.displayName)
                                    .localizedFormatted(baseFont: ConfirmationModal.explanationFont)
                            ),
                            confirmTitle: "delete".localized(),
                            confirmStyle: .danger,
                            cancelStyle: .alert_text
                        ),
                        onTap: { [weak self, dependencies] in
                            self?.dismissScreen(type: .popToRoot) {
                                dependencies[singleton: .storage].writeAsync { db in
                                    try SessionThread.deleteOrLeave(
                                        db,
                                        type: .deleteContactConversationAndMarkHidden,
                                        threadId: threadViewModel.threadId,
                                        threadVariant: threadViewModel.threadVariant,
                                        using: dependencies
                                    )
                                }
                            }
                        }
                    )
                 ),
                
                (threadVariant != .contact || threadViewModel.threadIsNoteToSelf == true ? nil :
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
                                    .put(key: "name", value: threadViewModel.displayName)
                                    .localizedFormatted(baseFont: ConfirmationModal.explanationFont),
                                scrollMode: .never
                            ),
                            confirmTitle: "delete".localized(),
                            confirmStyle: .danger,
                            cancelStyle: .alert_text
                        ),
                        onTap: { [weak self, dependencies] in
                            self?.dismissScreen(type: .popToRoot) {
                                dependencies[singleton: .storage].writeAsync { db in
                                    try SessionThread.deleteOrLeave(
                                        db,
                                        type: .deleteContactConversationAndContact,
                                        threadId: threadViewModel.threadId,
                                        threadVariant: threadViewModel.threadVariant,
                                        using: dependencies
                                    )
                                }
                            }
                        }
                    )
                ),
                
                // FIXME: [GROUPS REBUILD] Need to build this properly in a future release
                (!dependencies[feature: .updatedGroupsDeleteAttachmentsBeforeNow] || threadViewModel.threadVariant != .group ? nil :
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
                        onTap: { [weak self] in self?.deleteAllAttachmentsBeforeNow() }
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
    
    private func inviteUsersToCommunity(threadViewModel: SessionThreadViewModel) {
        guard
            let name: String = threadViewModel.openGroupName,
            let server: String = threadViewModel.openGroupServer,
            let roomToken: String = threadViewModel.openGroupRoomToken,
            let publicKey: String = threadViewModel.openGroupPublicKey,
            let communityUrl: String = LibSession.communityUrlFor(
                server: threadViewModel.openGroupServer,
                roomToken: threadViewModel.openGroupRoomToken,
                publicKey: threadViewModel.openGroupPublicKey
            )
        else { return }
        
        let openGroupCapabilityInfo: LibSession.OpenGroupCapabilityInfo = LibSession.OpenGroupCapabilityInfo(
            roomToken: roomToken,
            server: server,
            publicKey: publicKey,
            capabilities: (threadViewModel.openGroupCapabilities ?? [])
        )
        let currentUserSessionIds: Set<String> = Set([
            dependencies[cache: .general].sessionId.hexString,
            SessionThread.getCurrentUserBlindedSessionId(
                threadId: threadId,
                threadVariant: threadVariant,
                blindingPrefix: .blinded15,
                openGroupCapabilityInfo: openGroupCapabilityInfo,
                using: dependencies
            )?.hexString,
            SessionThread.getCurrentUserBlindedSessionId(
                threadId: threadId,
                threadVariant: threadVariant,
                blindingPrefix: .blinded25,
                openGroupCapabilityInfo: openGroupCapabilityInfo,
                using: dependencies
            )?.hexString
        ].compactMap { $0 })
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
                            \(groupMember[.groupId]) = \(threadId) AND
                            \(groupMember[.profileId]) = \(contact[.id])
                        )
                        WHERE (
                            \(groupMember[.profileId]) IS NULL AND
                            \(contact[.isApproved]) = TRUE AND
                            \(contact[.didApproveMe]) = TRUE AND
                            \(contact[.isBlocked]) = FALSE AND
                            \(contact[.id]) NOT IN \(currentUserSessionIds)
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
                                    title: name,
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
                                    authorId: threadViewModel.currentUserSessionId,
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
        transitionToConversation: @escaping @MainActor (String) -> Void,
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
                    dependencies[singleton: .storage].writeAsync(
                        updates: { db in
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
                        },
                        completion: { _ in
                            Task { @MainActor in
                                transitionToConversation(memberInfo.profileId)
                            }
                        }
                    )
                },
                using: dependencies
            )
        )
    }
    
    private func viewMembers() {
        self.transitionToScreen(
            ThreadSettingsViewModel.createMemberListViewController(
                threadId: threadId,
                transitionToConversation: { [weak self, dependencies] selectedMemberId in
                    self?.transitionToScreen(
                        ConversationVC(
                            threadId: selectedMemberId,
                            threadVariant: .contact,
                            using: dependencies
                        ),
                        transitionType: .push
                    )
                },
                using: dependencies
            )
        )
    }
    
    private func promoteAdmins(currentGroupName: String?) {
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
                    groupSessionId: SessionId(.group, hex: threadId),
                    members: memberInfo,
                    isResend: isResend,
                    using: dependencies
                )
                .subscribe(on: DispatchQueue.global(qos: .userInitiated), using: dependencies)
                .receive(on: DispatchQueue.main, using: dependencies)
                .sinkUntilComplete(
                    receiveCompletion: { [threadId, dependencies] result in
                        switch result {
                            case .finished: break
                            case .failure:
                                let memberIds: [String] = memberInfo.map(\.id)
                                
                                /// Flag the members as failed
                                dependencies[singleton: .storage].writeAsync { db in
                                    try? GroupMember
                                        .filter(GroupMember.Columns.groupId == threadId)
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
                                        groupName: (currentGroupName ?? "groupUnknown".localized()),
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
                            \(groupMember[.groupId]) == \(threadId) AND (
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
        current: String?,
        displayName: String
    ) -> ConfirmationModal.Info {
        /// Set `updatedName` to `current` so we can disable the "save" button when there are no changes and don't need to worry
        /// about retrieving them in the confirmation closure
        self.updatedName = current
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
            onConfirm: { [weak self, dependencies, threadId] modal in
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
                            publicKey: threadId,
                            nicknameUpdate: .set(to: finalNickname),
                            profileUpdateTimestamp: nil,
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
            onCancel: { [dependencies, threadId] modal in
                /// Remove the nickname
                dependencies[singleton: .storage].writeAsync(
                    updates: { db in
                        try Profile.updateIfNeeded(
                            db,
                            publicKey: threadId,
                            nicknameUpdate: .set(to: nil),
                            profileUpdateTimestamp: nil,
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
            onConfirm: { [weak self, dependencies, threadId] modal in
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
                        groupSessionId: threadId,
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
    
    private func updateGroupDisplayPicture(currentUrl: String?) {
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
        displayPictureUpdate: DisplayPictureManager.Update,
        onUploadComplete: @escaping () -> ()
    ) {
        switch displayPictureUpdate {
            case .none: onUploadComplete()
            default: break
        }
        
        Task.detached(priority: .userInitiated) { [weak self, threadId, dependencies] in
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
                    .filter(id: threadId)
                    .select(.displayPictureUrl)
                    .asRequest(of: String.self)
                    .fetchOne(db)
            }
            
            do {
                try await MessageSender.updateGroup(
                    groupSessionId: threadId,
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
    
    private func toggleConversationPinnedStatus(currentPinnedPriority: Int32) {
        let isCurrentlyPinned: Bool = (currentPinnedPriority > LibSession.visiblePriority)
        
        if !isCurrentlyPinned && !dependencies[cache: .libSession].isSessionPro {
            // TODO: [Database Relocation] Retrieve the full conversation list from lib session and check the pinnedPriority that way instead of using the database
            dependencies[singleton: .storage].writeAsync (
                updates: { [threadId, dependencies] db in
                    let numPinnedConversations: Int = try SessionThread
                        .filter(SessionThread.Columns.pinnedPriority > LibSession.visiblePriority)
                        .fetchCount(db)
                    
                    guard numPinnedConversations < LibSession.PinnedConversationLimit else {
                        return numPinnedConversations
                    }
                    
                    // We have the space to pin the conversation, so do so
                    try SessionThread.updateVisibility(
                        db,
                        threadId: threadId,
                        isVisible: true,
                        customPriority: (currentPinnedPriority <= LibSession.visiblePriority ? 1 : LibSession.visiblePriority),
                        using: dependencies
                    )
                    
                    return -1
                },
                completion: { [weak self, dependencies] result in
                    guard
                        let numPinnedConversations: Int = try? result.successOrThrow(),
                        numPinnedConversations > 0
                    else { return }
                    
                    let sessionProModal: ModalHostingViewController = ModalHostingViewController(
                        modal: ProCTAModal(
                            variant: .morePinnedConvos(
                                isGrandfathered: (numPinnedConversations > LibSession.PinnedConversationLimit)
                            ),
                            dataManager: dependencies[singleton: .imageDataManager],
                            onConfirm: { [dependencies] in
                                dependencies[singleton: .sessionProState].upgradeToPro(
                                    plan: SessionProPlan(variant: .threeMonths),
                                    originatingPlatform: .iOS,
                                    completion: nil
                                )
                            }
                        )
                    )
                    self?.transitionToScreen(sessionProModal, transitionType: .present)
                }
            )
            return
        }
        
        // If we are unpinning then no need to check the current count, just unpin immediately
        dependencies[singleton: .storage].writeAsync { [threadId, dependencies] db in
            try SessionThread.updateVisibility(
                db,
                threadId: threadId,
                isVisible: true,
                customPriority: (currentPinnedPriority <= LibSession.visiblePriority ? 1 : LibSession.visiblePriority),
                using: dependencies
            )
        }
    }
    
    private func deleteAllMessagesBeforeNow() {
        guard threadVariant == .group else { return }
        
        dependencies[singleton: .storage].writeAsync { [threadId, dependencies] db in
            try LibSession.deleteMessagesBefore(
                db,
                groupSessionId: SessionId(.group, hex: threadId),
                timestamp: (dependencies[cache: .snodeAPI].currentOffsetTimestampMs() / 1000),
                using: dependencies
            )
        }
    }
    
    private func deleteAllAttachmentsBeforeNow() {
        guard threadVariant == .group else { return }
        
        dependencies[singleton: .storage].writeAsync { [threadId, dependencies] db in
            try LibSession.deleteAttachmentsBefore(
                db,
                groupSessionId: SessionId(.group, hex: threadId),
                timestamp: (dependencies[cache: .snodeAPI].currentOffsetTimestampMs() / 1000),
                using: dependencies
            )
        }
    }
    
    // MARK: - Confirmation Modals
    
    private func updateDisplayNameModal(
        threadViewModel: SessionThreadViewModel,
        currentUserIsClosedGroupAdmin: Bool
    ) -> ConfirmationModal.Info? {
        guard !threadViewModel.threadIsNoteToSelf else { return nil }
        
        switch (threadViewModel.threadVariant, currentUserIsClosedGroupAdmin) {
            case (.contact, _):
                return self.updateNickname(
                    current: threadViewModel.profile?.nickname,
                    displayName: (
                        /// **Note:** We want to use the `profile` directly rather than `threadViewModel.displayName`
                        /// as the latter would use the `nickname` here which is incorrect
                        threadViewModel.profile?.displayName(ignoringNickname: true) ??
                        threadViewModel.threadId.truncated()
                    )
                )
            
            case (.group, true), (.legacyGroup, true):
                return self.updateGroupNameAndDescription(
                    currentName: threadViewModel.displayName,
                    currentDescription: threadViewModel.threadDescription,
                    isUpdatedGroup: (threadViewModel.threadVariant == .group)
                )
            
            case (.community, _), (.legacyGroup, false), (.group, false): return nil
        }
    }
    
    private func showQRCodeLightBox(for threadViewModel: SessionThreadViewModel) {
        let qrCodeImage: UIImage = QRCode.generate(
            for: threadViewModel.getQRCodeString(),
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
