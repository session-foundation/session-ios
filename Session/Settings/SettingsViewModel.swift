// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SwiftUI
import PhotosUI
import Combine
import Lucide
import GRDB
import DifferenceKit
import SessionUIKit
import SessionMessagingKit
import SessionNetworkingKit
import SessionUtilitiesKit
import SignalUtilitiesKit

class SettingsViewModel: SessionListScreenContent.ViewModelType, NavigationItemSource, NavigatableStateHolder {
    public let dependencies: Dependencies
    public let navigatableState: NavigatableState = NavigatableState()
    public let state: SessionListScreenContent.ListItemDataState<Section, ListItem> = SessionListScreenContent.ListItemDataState()
    public var imageDataManager: ImageDataManagerType { dependencies[singleton: .imageDataManager] }
    
    private var updatedName: String?
    private var onDisplayPictureSelected: ((ImageDataManager.DataSource, CGRect?) -> Void)?
    private lazy var imagePickerHandler: ImagePickerHandler = ImagePickerHandler(
        onTransition: { [weak self] in self?.transitionToScreen($0, transitionType: $1) },
        onImagePicked: { [weak self] source, cropRect in
            self?.onDisplayPictureSelected?(source, cropRect)
        },
        using: dependencies
    )
    
    /// This value is the current state of the view
    @MainActor @Published private(set) var internalState: ViewModelState
    private var observationTask: Task<Void, Never>?
    
    // MARK: - Initialization
    
    @MainActor init(using dependencies: Dependencies) {
        self.dependencies = dependencies
        self.internalState = ViewModelState.initialState(
            userSessionId: dependencies[cache: .general].sessionId,
            proState: dependencies[singleton: .sessionProManager].currentUserCurrentProState
        )
        
        bindState()
    }
    
    // MARK: - Config
    
    enum NavItem: Equatable {
        case close
        case edit
        case qrCode
    }
    
    public enum Section: SessionListScreenContent.ListSection {
        case profileInfo
        case sessionId
        
        case sessionProAndCommunity
        case donationAndNetwork
        case settings
        case helpAndData
        
        case footer
        
        var title: String? {
            switch self {
                case .sessionId: return "accountIdYours".localized()
                default: return nil
            }
        }
        
        var style: SessionListScreenContent.ListSectionStyle {
            switch self {
                case .sessionId: return .titleSeparator
                case .sessionProAndCommunity, .donationAndNetwork, .settings, .helpAndData: return .padding
                default: return .none
            }
        }
        
        public var divider: Bool {
            switch self {
                case .profileInfo, .sessionId, .footer: return false
                default: return true
            }
        }
        
        public var footer: String? { return nil }
        
        public var extraVerticalPadding: CGFloat { return 0 }
    }
    
    public enum ListItem: Differentiable {
        case avatar
        case profileName
        
        case sessionId
        case idActions
        
        case sessionPro
        case inviteAFriend
        
        case donate
        case path
        case sessionNetwork
        
        case privacy
        case notifications
        case conversations
        case appearance
        case messageRequests
        
        case recoveryPhrase
        case help
        case developerSettings
        case clearData
    }
    
    // MARK: - NavigationItemSource
    
    lazy var leftNavItems: AnyPublisher<[SessionNavItem<NavItem>], Never> = [
        SessionNavItem(
            id: .close,
            image: UIImage(named: "X")?
                .withRenderingMode(.alwaysTemplate),
            style: .plain,
            accessibilityIdentifier: "Close button"
        ) { [weak self] in self?.dismissScreen() }
    ]
    
    lazy var rightNavItems: AnyPublisher<[SessionNavItem<NavItem>], Never> = [
        SessionNavItem(
            id: .qrCode,
            image: Lucide.image(icon: .qrCode, size: 24)?
                .withRenderingMode(.alwaysTemplate),
            style: .plain,
            accessibilityIdentifier: "View QR code",
            action: { [weak self, dependencies] in
                let viewController: SessionHostingViewController = SessionHostingViewController(
                    rootView: QRCodeScreen(using: dependencies)
                )
                viewController.setNavBarTitle("qrCode".localized())
                self?.transitionToScreen(viewController)
            }
        ),
        SessionNavItem(
            id: .edit,
            image: Lucide.image(icon: .pencil, size: 22)?
                .withRenderingMode(.alwaysTemplate),
            style: .plain,
            accessibilityIdentifier: "Edit Profile Name",
            action: { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self = self else { return }
                    self.transitionToScreen(
                        ConfirmationModal(
                            info: self.updateDisplayName(current: self.internalState.profile.displayName())
                        ),
                        transitionType: .present
                    )
                }
            }
        )
    ]
    
    // MARK: - Content
    
    public struct ViewModelState: ObservableKeyProvider {
        let userSessionId: SessionId
        let profile: Profile
        let proState: SessionPro.State
        let serviceNetwork: ServiceNetwork
        let forceOffline: Bool
        let developerModeEnabled: Bool
        let hideRecoveryPasswordPermanently: Bool
        
        @MainActor public func sections(viewModel: SettingsViewModel) -> [SectionModel] {
            SettingsViewModel.sections(state: self, viewModel: viewModel)
        }
        
        /// We need `dependencies` to generate the keys in this case so set the variable `observedKeys` to an empty array to
        /// suppress the conformance warning
        public let observedKeys: Set<ObservableKey> = []
        public func observedKeys(using dependencies: Dependencies) -> Set<ObservableKey> {
            let sessionProManager: SessionProManagerType = dependencies[singleton: .sessionProManager]
            
            return [
                .profile(userSessionId.hexString),
                .currentUserProState(sessionProManager),
                .feature(.serviceNetwork),
                .feature(.forceOffline),
                .setting(.developerModeEnabled),
                .setting(.hideRecoveryPasswordPermanently)
            ]
        }
        
        static func initialState(
            userSessionId: SessionId,
            proState: SessionPro.State
        ) -> ViewModelState {
            return ViewModelState(
                userSessionId: userSessionId,
                profile: Profile.defaultFor(userSessionId.hexString),
                proState: proState,
                serviceNetwork: .mainnet,
                forceOffline: false,
                developerModeEnabled: false,
                hideRecoveryPasswordPermanently: false
            )
        }
    }
    
    let title: String = "sessionSettings".localized()
    
    @MainActor private func bindState() {
        observationTask = ObservationBuilder
            .initialValue(self.internalState)
            .debounce(for: .never)
            .using(dependencies: dependencies)
            .query(SettingsViewModel.queryState)
            .assign { [weak self] updatedState in
                guard let self = self else { return }
                
                self.state.updateTableData(updatedState.sections(viewModel: self))
                self.internalState = updatedState
            }
    }
    
    @Sendable private static func queryState(
        previousState: ViewModelState,
        events: [ObservedEvent],
        isInitialFetch: Bool,
        using dependencies: Dependencies
    ) async -> ViewModelState {
        /// Store mutable copies of the data to update
        var profile: Profile = previousState.profile
        var proState: SessionPro.State = previousState.proState
        var serviceNetwork: ServiceNetwork = previousState.serviceNetwork
        var forceOffline: Bool = previousState.forceOffline
        var developerModeEnabled: Bool = previousState.developerModeEnabled
        var hideRecoveryPasswordPermanently: Bool = previousState.hideRecoveryPasswordPermanently
        
        if isInitialFetch {
            serviceNetwork = dependencies[feature: .serviceNetwork]
            forceOffline = dependencies[feature: .forceOffline]
            proState = await dependencies[singleton: .sessionProManager].state.first(defaultValue: .invalid)
            
            dependencies.mutate(cache: .libSession) { libSession in
                profile = libSession.profile
                developerModeEnabled = libSession.get(.developerModeEnabled)
                hideRecoveryPasswordPermanently = libSession.get(.hideRecoveryPasswordPermanently)
            }
        }
        
        /// Split the events
        let changes: EventChangeset = events.split()
        
        /// If the users profile picture doesn't exist on disk then clear out the value (that way if we get events after downloading
        /// it then then there will be a diff in the `State` and the UI will update
        if
            let displayPictureUrl: String = profile.displayPictureUrl,
            let filePath: String = try? dependencies[singleton: .displayPictureManager]
                .path(for: displayPictureUrl),
            !dependencies[singleton: .fileManager].fileExists(atPath: filePath)
        {
            profile = profile.with(displayPictureUrl: .set(to: nil))
        }
        
        /// Process any event changes
        let groupedEvents: [GenericObservableKey: Set<ObservedEvent>]? = events
            .reduce(into: [:]) { result, event in
                result[event.key.generic, default: []].insert(event)
            }
        groupedEvents?[.profile]?.forEach { event in
            switch (event.value as? ProfileEvent)?.change {
                case .name(let name): profile = profile.with(name: name)
                case .nickname(let nickname): profile = profile.with(nickname: .set(to: nickname))
                case .displayPictureUrl(let url): profile = profile.with(displayPictureUrl: .set(to: url))
                default: break
            }
        }
        groupedEvents?[.setting]?.forEach { event in
            guard let updatedValue: Bool = event.value as? Bool else { return }
            
            switch event.key {
                case .setting(.developerModeEnabled): developerModeEnabled = updatedValue
                case .setting(.hideRecoveryPasswordPermanently): hideRecoveryPasswordPermanently = updatedValue
                default: break
            }
        }
        groupedEvents?[.feature]?.forEach { event in
            if event.key == .feature(.serviceNetwork) {
                guard let updatedValue: ServiceNetwork = event.value as? ServiceNetwork else { return }
                
                serviceNetwork = updatedValue
            }
            else if event.key == .feature(.forceOffline) {
                guard let updatedValue: Bool = event.value as? Bool else { return }
                
                forceOffline = updatedValue
            }
        }
        
        if let value = changes.latestGeneric(.currentUserProState, as: SessionPro.State.self) {
            proState = value
        }
        
        /// Generate the new state
        return ViewModelState(
            userSessionId: previousState.userSessionId,
            profile: profile,
            proState: proState,
            serviceNetwork: serviceNetwork,
            forceOffline: forceOffline,
            developerModeEnabled: developerModeEnabled,
            hideRecoveryPasswordPermanently: hideRecoveryPasswordPermanently
        )
    }
    
    @MainActor private static func sections(state: ViewModelState, viewModel: SettingsViewModel) -> [SectionModel] {
        let profileInfo: SectionModel = SectionModel(
            model: .profileInfo,
            elements: [
                SessionListScreenContent.ListItemInfo(
                    id: .avatar,
                    variant: .profilePicture(
                        info: .init(
                            sessionId: state.profile.id,
                            qrCodeImage: nil,
                            profileInfo: {
                                let (info, _) = ProfilePictureView.Info.generateInfoFrom(
                                    size: .hero,
                                    publicKey: state.profile.id,
                                    threadVariant: .contact,
                                    displayPictureUrl: nil,
                                    profile: state.profile,
                                    profileIcon: {
                                        switch (state.serviceNetwork, state.forceOffline) {
                                            case (.testnet, false): return .letter("T", false)     // stringlint:ignore
                                            case (.testnet, true): return .letter("T", true)       // stringlint:ignore
                                            default: return (state.profile.displayPictureUrl?.isEmpty == false) ? .pencil : .rightPlus
                                        }
                                    }(),
                                    using: viewModel.dependencies
                                )
                                
                                return info
                            }(),
                            isExpandable: false
                        )
                    ),
                    accessibility: Accessibility(
                        identifier: "User settings",
                        label: "Profile picture"
                    ),
                    onTap: { [weak viewModel] in
                        viewModel?.updateProfilePicture(
                            currentUrl: state.profile.displayPictureUrl,
                            proState: state.proState
                        )
                    }
                ),
                SessionListScreenContent.ListItemInfo(
                    id: .profileName,
                    variant: .tappableText(
                        info: ListItemTappableText.Info(
                            text: state.profile.displayName(),
                            font: Fonts.Headings.H4,
                            themeForegroundColor: .textPrimary,
                            imageAttachmentPosition: .trailing,
                            imageAttachmentGenerator: {
                                switch state.proState.status {
                                    case .neverBeenPro: return nil
                                    case .active:
                                        return {
                                            (
                                                UIView.image(
                                                    for: .themedKey(
                                                        SessionProBadge.Size.medium.cacheKey,
                                                        themeBackgroundColor: .primary
                                                    ),
                                                    generator: { SessionProBadge(size: .medium) }
                                                ),
                                                SessionProBadge.accessibilityLabel
                                            )
                                        }
                                    
                                    case .expired:
                                        return {
                                            (
                                                UIView.image(
                                                    for: .themedKey(
                                                        SessionProBadge.Size.medium.cacheKey,
                                                        themeBackgroundColor: .disabled
                                                    ),
                                                    generator: { SessionProBadge(size: .medium) }
                                                ),
                                                SessionProBadge.accessibilityLabel
                                            )
                                        }
                                }
                            }()
                        )
                    ),
                    accessibility: Accessibility(
                        identifier: "Username",
                        label: state.profile.displayName()
                    ),
                    confirmationInfo: viewModel.updateDisplayName(
                        current: state.profile.displayName()
                    )
                )
            ]
        )
        let sessionId: SectionModel = SectionModel(
            model: .sessionId,
            elements: [
                SessionListScreenContent.ListItemInfo(
                    id: .sessionId,
                    variant: .cell(
                        info: .init(
                            title: .init(
                                state.profile.id,
                                font: .Display.extraLarge,
                                alignment: .center,
                                interaction: .copy
                            )
                        )
                    ),
                    accessibility: Accessibility(
                        identifier: "Account ID",
                        label: state.profile.id
                    )
                ),
                SessionListScreenContent.ListItemInfo(
                    id: .idActions,
                    variant: .cell(
                        info: .init(
                            leadingAccessory: .button(
                                .init(
                                    title: "share".localized(),
                                    style: .bordered,
                                    accessibility: Accessibility(
                                        identifier: "Share button",
                                        label: "Share button"
                                    ),
                                    action: { [weak viewModel] _ in
                                        viewModel?.shareSessionId(state.profile.id)
                                    }
                                )
                            ),
                            trailingAccessory: .button(
                                .init(
                                    title: "copy".localized(),
                                    style: .bordered,
                                    accessibility: Accessibility(
                                        identifier: "Copy button",
                                        label: "Copy button"
                                    ),
                                    action: { [weak viewModel] buttonViewModel in
                                        viewModel?.copySessionId(state.profile.id, buttonViewModel: buttonViewModel)
                                    }
                                )
                            )
                        )
                    )
                )
            ]
        )
        
        let sessionProAndCommunity: SectionModel
        let donationAndNetwork: SectionModel
        
        // FIXME: [PRO] Should be able to remove this once pro is properly enabled
        if state.proState.sessionProEnabled {
            sessionProAndCommunity = SectionModel(
                model: .sessionProAndCommunity,
                elements: [
                    SessionListScreenContent.ListItemInfo(
                        id: .sessionPro,
                        variant: .cell(
                            info: .init(
                                leadingAccessory: .proBadge(
                                    size: .small,
                                    themeBackgroundColor: .primary
                                ),
                                title: .init(
                                    {
                                        switch state.proState.status {
                                            case .neverBeenPro:
                                                return "upgradeSession"
                                                    .put(key: "app_name", value: Constants.app_name)
                                                    .localized()

                                            case .active:
                                                return "sessionProBeta"
                                                    .put(key: "app_pro", value: Constants.app_pro)
                                                    .localized()

                                            case .expired:
                                                return "proRenewBeta"
                                                    .put(key: "pro", value: Constants.pro)
                                                    .localized()
                                        }
                                    }(),
                                    font: .Headings.H8,
                                    color: .sessionButton_text
                                )
                            )
                        ),
                        onTap: { [weak viewModel, dependencies = viewModel.dependencies] in
                            let viewController: SessionListHostingViewController = SessionListHostingViewController(
                                viewModel: SessionProSettingsViewModel(using: dependencies),
                                customizedNavigationBackground: .clear
                            )
                            viewModel?.transitionToScreen(viewController)
                        }
                    ),
                    SessionListScreenContent.ListItemInfo(
                        id: .inviteAFriend,
                        variant: .cell(
                            info: .init(
                                leadingAccessory: .icon(.userRoundPlus),
                                title: .init(
                                    "sessionInviteAFriend".localized(),
                                    font: .Headings.H8
                                )
                            )
                        ),
                        onTap: { [weak viewModel] in
                            let invitation: String = "accountIdShare"
                                .put(key: "app_name", value: Constants.app_name)
                                .put(key: "account_id", value: state.profile.id)
                                .put(key: "session_download_url", value: Constants.session_download_url)
                                .localized()
                            
                            viewModel?.transitionToScreen(
                                UIActivityViewController(
                                    activityItems: [ invitation ],
                                    applicationActivities: nil
                                ),
                                transitionType: .present
                            )
                        }
                    )
                ]
            )
            donationAndNetwork = SectionModel(
                model: .donationAndNetwork,
                elements: [
                    SessionListScreenContent.ListItemInfo(
                        id: .donate,
                        variant: .cell(
                            info: .init(
                                leadingAccessory: .icon(
                                    .heart,
                                    customTint: .sessionButton_border
                                ),
                                title: .init(
                                    "donate".localized(),
                                    font: .Headings.H8
                                ),
                            )
                        ),
                        onTap: { [weak viewModel] in viewModel?.openDonationsUrl() }
                    ),
                    SessionListScreenContent.ListItemInfo(
                        id: .path,
                        variant: .cell(
                            info: .init(
//                                leadingAccessory: .init(accessoryView: {
//                                    PathStatusViewAccessory
//                                },
                                title: .init(
                                    "onionRoutingPath".localized(),
                                    font: .Headings.H8
                                )
                            )
                        ),
                        onTap: { [weak viewModel, dependencies = viewModel.dependencies] in
                            viewModel?.transitionToScreen(PathVC(using: dependencies))
                        }
                    ),
                    SessionListScreenContent.ListItemInfo(
                        id: .sessionNetwork,
                        variant: .cell(
                            info: .init(
                                leadingAccessory: .icon(
                                    UIImage(named: "icon_session_network")?
                                        .withRenderingMode(.alwaysTemplate)
                                ),
                                title: .init(
                                    Constants.network_name,
                                    font: .Headings.H8
                                )
                            )
                        ),
                        onTap: { [weak viewModel, dependencies = viewModel.dependencies] in
                            let viewController: SessionHostingViewController = SessionHostingViewController(
                                rootView: SessionNetworkScreen(
                                    viewModel: SessionNetworkScreenContent.ViewModel(dependencies: dependencies)
                                )
                            )
                            viewController.setNavBarTitle(Constants.network_name)
                            viewModel?.transitionToScreen(viewController)
                        }
                    )
                ]
            )
        }
        else {
            sessionProAndCommunity = SectionModel(
                model: .sessionProAndCommunity,
                elements: [
                    SessionListScreenContent.ListItemInfo(
                        id: .donate,
                        variant: .cell(
                            info: .init(
                                leadingAccessory: .icon(
                                    .heart,
                                    customTint: .sessionButton_border
                                ),
                                title: .init(
                                    "donate".localized(),
                                    font: .Headings.H8
                                )
                            )
                        ),
                        onTap: { [weak viewModel] in viewModel?.openDonationsUrl() }
                    ),
                    SessionListScreenContent.ListItemInfo(
                        id: .inviteAFriend,
                        variant: .cell(
                            info: .init(
                                leadingAccessory: .icon(.userRoundPlus),
                                title: .init(
                                    "sessionInviteAFriend".localized(),
                                    font: .Headings.H8
                                )
                            )
                        ),
                        onTap: { [weak viewModel] in
                            let invitation: String = "accountIdShare"
                                .put(key: "app_name", value: Constants.app_name)
                                .put(key: "account_id", value: state.profile.id)
                                .put(key: "session_download_url", value: Constants.session_download_url)
                                .localized()
                            
                            viewModel?.transitionToScreen(
                                UIActivityViewController(
                                    activityItems: [ invitation ],
                                    applicationActivities: nil
                                ),
                                transitionType: .present
                            )
                        }
                    )
                ]
            )
            donationAndNetwork = SectionModel(
                model: .donationAndNetwork,
                elements: [
                    SessionListScreenContent.ListItemInfo(
                        id: .path,
                        variant: .cell(
                            info: .init(
//                                leadingAccessory: .init(accessoryView: {
//                                    PathStatusViewAccessory
//                                },
                                title: .init(
                                    "onionRoutingPath".localized(),
                                    font: .Headings.H8
                                )
                            )
                        ),
                        onTap: { [weak viewModel, dependencies = viewModel.dependencies] in
                            viewModel?.transitionToScreen(PathVC(using: dependencies))
                        }
                    ),
                    SessionListScreenContent.ListItemInfo(
                        id: .sessionNetwork,
                        variant: .cell(
                            info: .init(
                                leadingAccessory: .icon(
                                    UIImage(named: "icon_session_network")?
                                        .withRenderingMode(.alwaysTemplate)
                                ),
                                title: .init(
                                    Constants.network_name,
                                    font: .Headings.H8
                                )
                            )
                        ),
                        onTap: { [weak viewModel, dependencies = viewModel.dependencies] in
                            let viewController: SessionHostingViewController = SessionHostingViewController(
                                rootView: SessionNetworkScreen(
                                    viewModel: SessionNetworkScreenContent.ViewModel(dependencies: dependencies)
                                )
                            )
                            viewController.setNavBarTitle(Constants.network_name)
                            viewModel?.transitionToScreen(viewController)
                        }
                    )
                ]
            )
        }
        
        let settings: SectionModel = SectionModel(
            model: .settings,
            elements: [
                SessionListScreenContent.ListItemInfo(
                    id: .privacy,
                    variant: .cell(
                        info: .init(
                            leadingAccessory: .icon(.lockKeyhole),
                            title: .init(
                                "sessionPrivacy".localized(),
                                font: .Headings.H8
                            )
                        )
                    ),
                    onTap: { [weak viewModel, dependencies = viewModel.dependencies] in
                        viewModel?.transitionToScreen(
                            SessionTableViewController(viewModel: PrivacySettingsViewModel(using: dependencies))
                        )
                    }
                ),
                SessionListScreenContent.ListItemInfo(
                    id: .notifications,
                    variant: .cell(
                        info: .init(
                            leadingAccessory: .icon(.volume2),
                            title: .init(
                                "sessionNotifications".localized(),
                                font: .Headings.H8
                            )
                        )
                    ),
                    onTap: { [weak viewModel, dependencies = viewModel.dependencies] in
                        viewModel?.transitionToScreen(
                            SessionTableViewController(viewModel: NotificationSettingsViewModel(using: dependencies))
                        )
                    }
                ),
                SessionListScreenContent.ListItemInfo(
                    id: .conversations,
                    variant: .cell(
                        info: .init(
                            leadingAccessory: .icon(.usersRound),
                            title: .init(
                                "sessionConversations".localized(),
                                font: .Headings.H8
                            )
                        )
                    ),
                    onTap: { [weak viewModel, dependencies = viewModel.dependencies] in
                        viewModel?.transitionToScreen(
                            SessionTableViewController(viewModel: ConversationSettingsViewModel(using: dependencies))
                        )
                    }
                ),
                SessionListScreenContent.ListItemInfo(
                    id: .appearance,
                    variant: .cell(
                        info: .init(
                            leadingAccessory: .icon(.paintbrushVertical),
                            title: .init(
                                "sessionAppearance".localized(),
                                font: .Headings.H8
                            )
                        )
                    ),
                    onTap: { [weak viewModel, dependencies = viewModel.dependencies] in
                        viewModel?.transitionToScreen(
                            SessionTableViewController(viewModel: AppearanceViewModel(using: dependencies))
                        )
                    }
                ),
                SessionListScreenContent.ListItemInfo(
                    id: .messageRequests,
                    variant: .cell(
                        info: .init(
                            leadingAccessory: .icon(.messageSquareWarning),
                            title: .init(
                                "sessionMessageRequests".localized(),
                                font: .Headings.H8
                            )
                        )
                    ),
                    onTap: { [weak viewModel, dependencies = viewModel.dependencies] in
                        viewModel?.transitionToScreen(
                            SessionTableViewController(viewModel: MessageRequestsViewModel(using: dependencies))
                        )
                    }
                )
            ]
        )
        
        var helpAndDataElements: [SessionListScreenContent.ListItemInfo<ListItem>] = []
        if !state.hideRecoveryPasswordPermanently {
            helpAndDataElements.append(
                SessionListScreenContent.ListItemInfo(
                    id: .recoveryPhrase,
                    variant: .cell(
                        info: .init(
                            leadingAccessory: .icon(
                                UIImage(named: "SessionShield")?
                                    .withRenderingMode(.alwaysTemplate)
                            ),
                            title: .init(
                                "sessionRecoveryPassword".localized(),
                                font: .Headings.H8
                            )
                        )
                    ),
                    accessibility: Accessibility(
                        identifier: "Recovery password menu item",
                        label: "Recovery password menu item"
                    ),
                    onTap: { [weak viewModel, dependencies = viewModel.dependencies] in
                        guard let recoveryPasswordView: RecoveryPasswordScreen = try? RecoveryPasswordScreen(using: dependencies) else {
                            let targetViewController: UIViewController = ConfirmationModal(
                                info: ConfirmationModal.Info(
                                    title: "theError".localized(),
                                    body: .text("recoveryPasswordErrorLoad".localized()),
                                    cancelTitle: "okay".localized(),
                                    cancelStyle: .alert_text
                                )
                            )
                            viewModel?.transitionToScreen(targetViewController, transitionType: .present)
                            return
                        }
                        
                        let viewController: SessionHostingViewController = SessionHostingViewController(rootView: recoveryPasswordView)
                        viewController.setNavBarTitle("sessionRecoveryPassword".localized())
                        viewModel?.transitionToScreen(viewController)
                    }
                )
            )
        }
        
        helpAndDataElements.append(
            SessionListScreenContent.ListItemInfo(
                id: .help,
                variant: .cell(
                    info: .init(
                        leadingAccessory: .icon(
                            UIImage(named: "icon_help")?
                                .withRenderingMode(.alwaysTemplate)
                        ),
                        title: .init(
                            "sessionHelp".localized(),
                            font: .Headings.H8
                        )
                    )
                ),
                onTap: { [weak viewModel, dependencies = viewModel.dependencies] in
                    viewModel?.transitionToScreen(
                        SessionTableViewController(viewModel: HelpViewModel(using: dependencies))
                    )
                }
            )
        )
        
        if state.developerModeEnabled {
            helpAndDataElements.append(
                SessionListScreenContent.ListItemInfo(
                    id: .developerSettings,
                    variant: .cell(
                        info: .init(
                            leadingAccessory: .icon(
                                .squareCode,
                                customTint: .warning
                            ),
                            title: .init(
                                "Developer Settings",    // stringlint:ignore
                                font: .Headings.H8,
                                color: .warning
                            )
                        )
                    ),
                    onTap: { [weak viewModel, dependencies = viewModel.dependencies] in
                        viewModel?.transitionToScreen(
                            SessionTableViewController(viewModel: DeveloperSettingsViewModel(using: dependencies))
                        )
                    }
                )
            )
        }
        
        helpAndDataElements.append(
            SessionListScreenContent.ListItemInfo(
                id: .clearData,
                variant: .cell(
                    info: .init(
                        leadingAccessory: .icon(
                            .trash2,
                            customTint: .danger
                        ),
                        title: .init(
                            "sessionClearData".localized(),
                            font: .Headings.H8,
                            color: .danger
                        )
                    )
                ),
                onTap: { [weak viewModel, dependencies = viewModel.dependencies] in
                    viewModel?.transitionToScreen(NukeDataModal(using: dependencies), transitionType: .present)
                }
            )
        )
        let helpAndData: SectionModel = SectionModel(
            model: .helpAndData,
            elements: helpAndDataElements
        )
        
        return [profileInfo, sessionId, sessionProAndCommunity, donationAndNetwork, settings, helpAndData]
    }
    
    public var footerView: VersionFooterView {
        VersionFooterView(
            numVersionTapsRequired: 9,
            logoTapCallback: { [weak self] in self?.openTokenUrl() },
            versionTapCallback: { [dependencies] in
                /// Do nothing if developer mode is already enabled
                guard !dependencies.mutate(cache: .libSession, { $0.get(.developerModeEnabled) }) else { return }
                
                dependencies.setAsync(.developerModeEnabled, true)
            }
        )
    }
    
    
    // MARK: - Functions
    
    private func updateDisplayName(current: String) -> ConfirmationModal.Info {
        /// Set `updatedName` to `current` so we can disable the "save" button when there are no changes and don't need to worry
        /// about retrieving them in the confirmation closure
        self.updatedName = current
        return ConfirmationModal.Info(
            title: "displayNameSet".localized(),
            body: .input(
                explanation: ThemedAttributedString(string: "displayNameVisible".localized()),
                info: ConfirmationModal.Info.Body.InputInfo(
                    placeholder: "displayNameEnter".localized(),
                    initialValue: current,
                    accessibility: Accessibility(
                        identifier: "Username input"
                    ),
                    inputChecker: { text in
                        let displayName: String = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        
                        guard !Profile.isTooLong(profileName: displayName) else {
                            return "displayNameErrorDescriptionShorter".localized()
                        }
                        
                        return nil
                    }
                ),
                onChange: { [weak self] updatedName in self?.updatedName = updatedName }
            ),
            confirmTitle: "save".localized(),
            confirmEnabled: .afterChange { [weak self] _ in
                self?.updatedName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false &&
                self?.updatedName != current
            },
            cancelStyle: .alert_text,
            hasCloseButton: true,
            dismissOnConfirm: false,
            onConfirm: { [weak self] modal in
                guard
                    let finalDisplayName: String = (self?.updatedName ?? "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .nullIfEmpty
                else { return }
                
                /// Check if the data violates the size constraints
                guard !Profile.isTooLong(profileName: finalDisplayName) else {
                    modal.updateContent(withError: "displayNameErrorDescriptionShorter".localized())
                    return
                }
                
                /// Update the nickname
                self?.updateProfile(displayNameUpdate: .currentUserUpdate(finalDisplayName)) {
                    modal.dismiss(animated: true)
                }
            }
        )
    }
    
    @MainActor private func updateProfilePicture(
        currentUrl: String?,
        proState: SessionPro.State
    ) {
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
            description: {
                switch (proState.sessionProEnabled, proState.status) {
                    case (false, _): return nil
                    case (true, .active):
                        return SessionListScreenContent.TextInfo(
                            "proAnimatedDisplayPictureModalDescription".localized(),
                            inlineImage: SessionListScreenContent.TextInfo.InlineImageInfo(
                                image: UIView.image(
                                    for: .themedKey(
                                        SessionProBadge.Size.small.cacheKey,
                                        themeBackgroundColor: .textSecondary
                                    ),
                                    generator: {
                                        SessionProBadge(
                                            size: .mini,
                                            themeBackgroundColor: .textSecondary
                                        )
                                    }
                                ),
                                position: .leading
                            )
                        )
                        
                    case (true, _):
                        return SessionListScreenContent.TextInfo(
                            "proAnimatedDisplayPicturesNonProModalDescription".localized(),
                            inlineImage: SessionListScreenContent.TextInfo.InlineImageInfo(
                                image: UIView.image(
                                    for: .themedKey(
                                        SessionProBadge.Size.small.cacheKey,
                                        themeBackgroundColor: .textSecondary
                                    ),
                                    generator: {
                                        SessionProBadge(
                                            size: .mini,
                                            themeBackgroundColor: .textSecondary
                                        )
                                    }
                                ),
                                position: .trailing
                            )
                        )
                }
            }(),
            accessibility: Accessibility(
                identifier: "Upload",
                label: "Upload"
            ),
            dataManager: dependencies[singleton: .imageDataManager],
            onProBageTapped: { [weak self, dependencies] in
                Task { @MainActor in
                    dependencies[singleton: .sessionProManager].showSessionProCTAIfNeeded(
                        .animatedProfileImage(
                            isSessionProActivated: (proState.status == .active),
                            renew: (proState.status == .expired)
                        ),
                        onConfirm: {
                            dependencies[singleton: .sessionProManager].showSessionProBottomSheetIfNeeded(
                                presenting: { bottomSheet in
                                    self?.transitionToScreen(bottomSheet, transitionType: .present)
                                }
                            )
                        },
                        presenting: { modal in
                            self?.transitionToScreen(modal, transitionType: .present)
                        }
                    )
                }
            },
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
                    title: "profileDisplayPictureSet".localized(),
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
                    onConfirm: { [weak self, dependencies] modal in
                        switch modal.info.body {
                            case .image(.some(let source), _, _, let style, _, _, _, _, _):
                                let isAnimatedImage: Bool = ImageDataManager.isAnimatedImage(source)
                                var didShowCTAModal: Bool = false
                                
                                if isAnimatedImage && proState.sessionProEnabled {
                                    didShowCTAModal = dependencies[singleton: .sessionProManager].showSessionProCTAIfNeeded(
                                        .animatedProfileImage(
                                            isSessionProActivated: (proState.status == .active),
                                            renew: (proState.status == .expired)
                                        ),
                                        onConfirm: {
                                            dependencies[singleton: .sessionProManager].showSessionProBottomSheetIfNeeded(
                                                presenting: { bottomSheet in
                                                    self?.transitionToScreen(bottomSheet, transitionType: .present)
                                                }
                                            )
                                        },
                                        presenting: { modal in
                                            self?.transitionToScreen(modal, transitionType: .present)
                                        }
                                    )
                                }
                                
                                /// If we showed the CTA modal then the user doesn't have Session Pro so can't use the
                                /// selected image as their display picture
                                guard !didShowCTAModal else { return }
                                
                                self?.updateProfile(
                                    displayPictureUpdateGenerator: { [weak self] in
                                        guard let self = self else { throw AttachmentError.uploadFailed }
                                        
                                        return try await uploadDisplayPicture(
                                            source: source,
                                            cropRect: style.cropRect
                                        )
                                    },
                                    onComplete: { [weak modal] in modal?.close() }
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
                            self?.updateProfile(
                                displayPictureUpdateGenerator: { .currentUserRemove },
                                onComplete: { [weak modal] in modal?.close() }
                            )
                        }
                    }
                )
            ),
            transitionType: .present
        )
    }
    
    @MainActor private func showPhotoLibraryForAvatar() {
        Permissions.requestLibraryPermissionIfNeeded(isSavingMedia: false, using: dependencies) { [weak self] granted in
            guard granted else { return }
            
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
    
    fileprivate func uploadDisplayPicture(
        source: ImageDataManager.DataSource,
        cropRect: CGRect?
    ) async throws -> DisplayPictureManager.Update {
        let pendingAttachment: PendingAttachment = PendingAttachment(
            source: .media(source),
            using: dependencies
        )
        let preparedAttachment: PreparedAttachment = try await dependencies[singleton: .displayPictureManager].prepareDisplayPicture(
            attachment: pendingAttachment,
            fallbackIfConversionTakesTooLong: true,
            cropRect: cropRect
        )
        let result = try await dependencies[singleton: .displayPictureManager]
            .uploadDisplayPicture(preparedAttachment: preparedAttachment)
        
        return .currentUserUpdateTo(
            url: result.downloadUrl,
            key: result.encryptionKey,
            type: (pendingAttachment.utType.isAnimated ? .animatedImage : .staticImage)
        )
    }
    
    @MainActor fileprivate func updateProfile(
        displayNameUpdate: Profile.TargetUserUpdate<String?> = .none,
        displayPictureUpdateGenerator generator: @escaping () async throws -> DisplayPictureManager.Update = { .none },
        onComplete: @escaping () -> ()
    ) {
        let indicator: ModalActivityIndicatorViewController = ModalActivityIndicatorViewController()
        self.transitionToScreen(indicator, transitionType: .present)
        
        Task.detached(priority: .userInitiated) { [weak self, indicator, dependencies] in
            var displayPictureUpdate: DisplayPictureManager.Update = .none
            
            do {
                displayPictureUpdate = try await generator()
                try await Profile.updateLocal(
                    displayNameUpdate: displayNameUpdate,
                    displayPictureUpdate: displayPictureUpdate,
                    using: dependencies
                )
                
                await indicator.dismiss {
                    onComplete()
                }
            }
            catch {
                let message: String = {
                    switch (displayPictureUpdate, error) {
                        case (.currentUserRemove, _): return "profileDisplayPictureRemoveError".localized()
                        case (_, AttachmentError.fileSizeTooLarge):
                            return "profileDisplayPictureSizeError".localized()
                        
                        default: return "errorConnection".localized()
                    }
                }()
                
                await indicator.dismiss {
                    self?.transitionToScreen(
                        ConfirmationModal(
                            info: ConfirmationModal.Info(
                                title: "profileErrorUpdate".localized(),
                                body: .text(message),
                                cancelTitle: "okay".localized(),
                                cancelStyle: .alert_text,
                                dismissType: .single
                            )
                        ),
                        transitionType: .present
                    )
                }
            }
        }
    }
    
    private func copySessionId(_ sessionId: String, buttonViewModel: SessionButtonViewModel) {
        UIPasteboard.general.string = sessionId
        
        // Ensure we are on the main thread just in case
        DispatchQueue.main.async {
            buttonViewModel.isEnabled = false
            withAnimation { buttonViewModel.title = "copied".localized() }
            
            DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(4)) {
                buttonViewModel.isEnabled = true
                withAnimation { buttonViewModel.title = "copy".localized() }
            }
        }
    }
    
    private func shareSessionId(_ sessionId: String) {
        let shareVC = UIActivityViewController(
            activityItems: [ sessionId ],
            applicationActivities: nil
        )
        
        self.transitionToScreen(shareVC, transitionType: .present)
    }
    
    @MainActor private func openDonationsUrl() {
        guard let modal: ConfirmationModal = dependencies[singleton: .donationsManager].openDonationsUrlModal() else {
            return
        }
        
        self.transitionToScreen(modal, transitionType: .present)
        
        // Mark app review flag that donate button was tapped
        if !dependencies[defaults: .standard, key: .hasPressedDonateButton] {
            dependencies[defaults: .standard, key: .hasPressedDonateButton] = true
        }
    }
    
    private func openTokenUrl() {
        guard let url: URL = URL(string: Constants.urls.token) else { return }
        
        let modal: ConfirmationModal = ConfirmationModal(
            info: ConfirmationModal.Info(
                title: "urlOpen".localized(),
                body: .attributedText(
                    "urlOpenDescription"
                        .put(key: "url", value: url.absoluteString)
                        .localizedFormatted(baseFont: .systemFont(ofSize: Values.smallFontSize))
                ),
                confirmTitle: "open".localized(),
                confirmStyle: .danger,
                cancelTitle: "urlCopy".localized(),
                cancelStyle: .alert_text,
                hasCloseButton: true,
                onConfirm: { modal in
                    UIApplication.shared.open(url, options: [:], completionHandler: nil)
                    modal.dismiss(animated: true)
                },
                onCancel: { modal in
                    UIPasteboard.general.string = url.absoluteString
                    modal.dismiss(animated: true)
                }
            )
        )
        
        self.transitionToScreen(modal, transitionType: .present)
    }
}

