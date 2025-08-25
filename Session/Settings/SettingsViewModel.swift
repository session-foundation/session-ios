// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import Lucide
import GRDB
import DifferenceKit
import SessionUIKit
import SessionMessagingKit
import SessionUtilitiesKit
import SignalUtilitiesKit

class SettingsViewModel: SessionTableViewModel, NavigationItemSource, NavigatableStateHolder, ObservableTableSource {
    public let dependencies: Dependencies
    public let navigatableState: NavigatableState = NavigatableState()
    public let state: TableDataState<Section, TableItem> = TableDataState()
    public let observableState: ObservableTableSourceState<Section, TableItem> = ObservableTableSourceState()
    
    private var updatedName: String?
    private var onDisplayPictureSelected: ((ConfirmationModal.ValueUpdate) -> Void)?
    private lazy var imagePickerHandler: ImagePickerHandler = ImagePickerHandler(
        onTransition: { [weak self] in self?.transitionToScreen($0, transitionType: $1) },
        onImageDataPicked: { [weak self] identifier, resultImageData in
            self?.onDisplayPictureSelected?(.image(identifier: identifier, data: resultImageData))
        }
    )
    
    /// This value is the current state of the view
    @MainActor @Published private(set) var internalState: State
    private var observationTask: Task<Void, Never>?
    
    // MARK: - Initialization
    
    @MainActor init(using dependencies: Dependencies) {
        self.dependencies = dependencies
        self.internalState = State.initialState(userSessionId: dependencies[cache: .general].sessionId)
        
        bindState()
    }
    
    // MARK: - Config
    
    enum NavItem: Equatable {
        case close
        case edit
        case qrCode
    }
    
    public enum Section: SessionTableSection {
        case profileInfo
        case sessionId
        
        case sessionProAndCommunity
        case donationAndnetwork
        case settings
        case helpAndData
        
        case footer
        
        var title: String? {
            switch self {
                case .sessionId: return "accountIdYours".localized()
                default: return nil
            }
        }
        
        var style: SessionTableSectionStyle {
            switch self {
                case .sessionId: return .titleSeparator
                case .sessionProAndCommunity, .donationAndnetwork, .settings, .helpAndData: return .padding
                default: return .none
            }
        }
    }
    
    public enum TableItem: Differentiable {
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
    
    public struct State: ObservableKeyProvider {
        let userSessionId: SessionId
        let profile: Profile
        let serviceNetwork: ServiceNetwork
        let forceOffline: Bool
        let developerModeEnabled: Bool
        let hideRecoveryPasswordPermanently: Bool
        
        @MainActor public func sections(viewModel: SettingsViewModel) -> [SectionModel] {
            SettingsViewModel.sections(state: self, viewModel: viewModel)
        }
        
        public var observedKeys: Set<ObservableKey> {
            [
                .profile(userSessionId.hexString),
                .feature(.serviceNetwork),
                .feature(.forceOffline),
                .setting(.developerModeEnabled),
                .setting(.hideRecoveryPasswordPermanently)
            ]
        }
        
        static func initialState(userSessionId: SessionId) -> State {
            return State(
                userSessionId: userSessionId,
                profile: Profile.defaultFor(userSessionId.hexString),
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
                
                // FIXME: To slightly reduce the size of the changes this new observation mechanism is currently wired into the old SessionTableViewController observation mechanism, we should refactor it so everything uses the new mechanism
                self.internalState = updatedState
                self.pendingTableDataSubject.send(updatedState.sections(viewModel: self))
            }
    }
    
    @Sendable private static func queryState(
        previousState: State,
        events: [ObservedEvent],
        isInitialFetch: Bool,
        using dependencies: Dependencies
    ) async -> State {
        /// Store mutable copies of the data to update
        var profile: Profile = previousState.profile
        var serviceNetwork: ServiceNetwork = previousState.serviceNetwork
        var forceOffline: Bool = previousState.forceOffline
        var developerModeEnabled: Bool = previousState.developerModeEnabled
        var hideRecoveryPasswordPermanently: Bool = previousState.hideRecoveryPasswordPermanently
        
        if isInitialFetch {
            serviceNetwork = dependencies[feature: .serviceNetwork]
            forceOffline = dependencies[feature: .forceOffline]
            
            dependencies.mutate(cache: .libSession) { libSession in
                profile = libSession.profile
                developerModeEnabled = libSession.get(.developerModeEnabled)
                hideRecoveryPasswordPermanently = libSession.get(.hideRecoveryPasswordPermanently)
            }
        }
        
        /// Process any event changes
        let groupedEvents: [GenericObservableKey: Set<ObservedEvent>]? = events
            .reduce(into: [:]) { result, event in
                result[event.key.generic, default: []].insert(event)
            }
        groupedEvents?[.profile]?.forEach { event in
            switch (event.value as? ProfileEvent)?.change {
                case .name(let name): profile = profile.with(name: name)
                case .nickname(let nickname): profile = profile.with(nickname: nickname)
                case .displayPictureUrl(let url): profile = profile.with(displayPictureUrl: url)
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
        
        /// Generate the new state
        return State(
            userSessionId: previousState.userSessionId,
            profile: profile,
            serviceNetwork: serviceNetwork,
            forceOffline: forceOffline,
            developerModeEnabled: developerModeEnabled,
            hideRecoveryPasswordPermanently: hideRecoveryPasswordPermanently
        )
    }
    
    private static func sections(state: State, viewModel: SettingsViewModel) -> [SectionModel] {
        let profileInfo: SectionModel = SectionModel(
            model: .profileInfo,
            elements: [
                SessionCell.Info(
                    id: .avatar,
                    accessory: .profile(
                        id: state.profile.id,
                        size: .hero,
                        profile: state.profile,
                        profileIcon: {
                            switch (state.serviceNetwork, state.forceOffline) {
                                case (.testnet, false): return .letter("T", false)     // stringlint:ignore
                                case (.testnet, true): return .letter("T", true)       // stringlint:ignore
                                default: return .pencil
                            }
                        }()
                    ),
                    styling: SessionCell.StyleInfo(
                        alignment: .centerHugging,
                        customPadding: SessionCell.Padding(bottom: Values.smallSpacing),
                        backgroundStyle: .noBackground
                    ),
                    accessibility: Accessibility(
                        identifier: "User settings",
                        label: "Profile picture"
                    ),
                    onTap: { [weak viewModel] in
                        viewModel?.updateProfilePicture(currentUrl: state.profile.displayPictureUrl)
                    }
                ),
                SessionCell.Info(
                    id: .profileName,
                    title: SessionCell.TextInfo(
                        state.profile.displayName(),
                        font: .titleLarge,
                        alignment: .center,
                        interaction: .editable,
                        textTailing: (
                            viewModel.dependencies[cache: .libSession].isSessionPro ?
                            SessionProBadge(size: .medium).toImage() :
                                nil
                        )
                    ),
                    styling: SessionCell.StyleInfo(
                        alignment: .centerHugging,
                        customPadding: SessionCell.Padding(
                            top: Values.smallSpacing,
                            bottom: Values.mediumSpacing,
                            interItem: 0
                        ),
                        backgroundStyle: .noBackground
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
                SessionCell.Info(
                    id: .sessionId,
                    title: SessionCell.TextInfo(
                        state.profile.id,
                        font: .monoLarge,
                        alignment: .center,
                        interaction: .copy
                    ),
                    styling: SessionCell.StyleInfo(
                        customPadding: SessionCell.Padding(bottom: Values.smallSpacing),
                        backgroundStyle: .noBackground
                    ),
                    accessibility: Accessibility(
                        identifier: "Account ID",
                        label: state.profile.id
                    )
                ),
                SessionCell.Info(
                    id: .idActions,
                    leadingAccessory: .button(
                        style: .bordered,
                        title: "share".localized(),
                        accessibility: Accessibility(
                            identifier: "Share button",
                            label: "Share button"
                        ),
                        run: { [weak viewModel] _ in
                            viewModel?.shareSessionId(state.profile.id)
                        }
                    ),
                    trailingAccessory: .button(
                        style: .bordered,
                        title: "copy".localized(),
                        accessibility: Accessibility(
                            identifier: "Copy button",
                            label: "Copy button"
                        ),
                        run: { [weak viewModel] button in
                            viewModel?.copySessionId(state.profile.id, button: button)
                        }
                    ),
                    styling: SessionCell.StyleInfo(
                        customPadding: SessionCell.Padding(
                            top: Values.smallSpacing,
                            leading: 0,
                            trailing: 0
                        ),
                        backgroundStyle: .noBackground
                    )
                )
            ]
        )
        let sessionProAndCommunity: SectionModel = SectionModel(
            model: .sessionProAndCommunity,
            elements: [
                SessionCell.Info(
                    id: .sessionPro,
                    leadingAccessory: .proBadge(size: .small),
                    title: Constants.app_pro,
                    styling: SessionCell.StyleInfo(
                        tintColor: .sessionButton_border
                    ),
                    onTap: { [weak viewModel] in
                        // TODO: Implement
                    }
                ),
                SessionCell.Info(
                    id: .inviteAFriend,
                    leadingAccessory: .icon(.userRoundPlus),
                    title: "sessionInviteAFriend".localized(),
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
        let donationAndNetwork: SectionModel = SectionModel(
            model: .donationAndnetwork,
            elements: [
                SessionCell.Info(
                    id: .donate,
                    leadingAccessory: .icon(
                        .heart,
                        customTint: .sessionButton_border
                    ),
                    title: "donate".localized(),
                    onTap: { [weak viewModel] in viewModel?.openDonationsUrl() }
                ),
                SessionCell.Info(
                    id: .path,
                    leadingAccessory: .custom(
                        info: PathStatusViewAccessory.Info()
                    ),
                    title: "onionRoutingPath".localized(),
                    onTap: { [weak viewModel, dependencies = viewModel.dependencies] in
                        viewModel?.transitionToScreen(PathVC(using: dependencies))
                    }
                ),
                SessionCell.Info(
                    id: .sessionNetwork,
                    leadingAccessory: .icon(
                        UIImage(named: "icon_session_network")?
                            .withRenderingMode(.alwaysTemplate)
                    ),
                    title: Constants.network_name,
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
        let settings: SectionModel = SectionModel(
            model: .settings,
            elements: [
                SessionCell.Info(
                    id: .privacy,
                    leadingAccessory: .icon(.lockKeyhole),
                    title: "sessionPrivacy".localized(),
                    onTap: { [weak viewModel, dependencies = viewModel.dependencies] in
                        viewModel?.transitionToScreen(
                            SessionTableViewController(viewModel: PrivacySettingsViewModel(using: dependencies))
                        )
                    }
                ),
                SessionCell.Info(
                    id: .notifications,
                    leadingAccessory: .icon(.volume2),
                    title: "sessionNotifications".localized(),
                    onTap: { [weak viewModel, dependencies = viewModel.dependencies] in
                        viewModel?.transitionToScreen(
                            SessionTableViewController(viewModel: NotificationSettingsViewModel(using: dependencies))
                        )
                    }
                ),
                SessionCell.Info(
                    id: .conversations,
                    leadingAccessory: .icon(.usersRound),
                    title: "sessionConversations".localized(),
                    onTap: { [weak viewModel, dependencies = viewModel.dependencies] in
                        viewModel?.transitionToScreen(
                            SessionTableViewController(viewModel: ConversationSettingsViewModel(using: dependencies))
                        )
                    }
                ),
                SessionCell.Info(
                    id: .appearance,
                    leadingAccessory: .icon(.paintbrushVertical),
                    title: "sessionAppearance".localized(),
                    onTap: { [weak viewModel, dependencies = viewModel.dependencies] in
                        viewModel?.transitionToScreen(
                            SessionTableViewController(viewModel: AppearanceViewModel(using: dependencies))
                        )
                    }
                ),
                SessionCell.Info(
                    id: .messageRequests,
                    leadingAccessory: .icon(.messageSquareWarning),
                    title: "sessionMessageRequests".localized(),
                    onTap: { [weak viewModel, dependencies = viewModel.dependencies] in
                        viewModel?.transitionToScreen(
                            SessionTableViewController(viewModel: MessageRequestsViewModel(using: dependencies))
                        )
                    }
                )
            ]
        )
        
        var helpAndDataElements: [SessionCell.Info<TableItem>] = []
        if !state.hideRecoveryPasswordPermanently {
            helpAndDataElements.append(
                SessionCell.Info(
                    id: .recoveryPhrase,
                    leadingAccessory: .icon(
                        UIImage(named: "SessionShield")?
                            .withRenderingMode(.alwaysTemplate)
                    ),
                    title: "sessionRecoveryPassword".localized(),
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
            SessionCell.Info(
                id: .help,
                leadingAccessory: .icon(
                    UIImage(named: "icon_help")?
                        .withRenderingMode(.alwaysTemplate)
                ),
                title: "sessionHelp".localized(),
                onTap: { [weak viewModel, dependencies = viewModel.dependencies] in
                    viewModel?.transitionToScreen(
                        SessionTableViewController(viewModel: HelpViewModel(using: dependencies))
                    )
                }
            )
        )
        
        if state.developerModeEnabled {
            helpAndDataElements.append(
                SessionCell.Info(
                    id: .developerSettings,
                    leadingAccessory: .icon(.squareCode),
                    title: "Developer Settings",    // stringlint:ignore
                    styling: SessionCell.StyleInfo(tintColor: .warning),
                    onTap: { [weak viewModel, dependencies = viewModel.dependencies] in
                        viewModel?.transitionToScreen(
                            SessionTableViewController(viewModel: DeveloperSettingsViewModel(using: dependencies))
                        )
                    }
                )
            )
        }
        
        helpAndDataElements.append(
            SessionCell.Info(
                id: .clearData,
                leadingAccessory: .icon(.trash2),
                title: "sessionClearData".localized(),
                styling: SessionCell.StyleInfo(tintColor: .danger),
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
    
    public lazy var footerView: AnyPublisher<UIView?, Never> = Just(VersionFooterView(
        numVersionTapsRequired: 9,
        logoTapCallback: { [weak self] in self?.openTokenUrl() },
        versionTapCallback: { [dependencies] in
            /// Do nothing if developer mode is already enabled
            guard !dependencies.mutate(cache: .libSession, { $0.get(.developerModeEnabled) }) else { return }
            
            dependencies.setAsync(.developerModeEnabled, true)
        }
    )).eraseToAnyPublisher()
    
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
    
    private func updateProfilePicture(currentUrl: String?) {
        let iconName: String = "profile_placeholder" // stringlint:ignore
        var hasSetNewProfilePicture: Bool = false
        let body: ConfirmationModal.Info.Body = .image(
            source: nil,
            placeholder: currentUrl
                .map { try? dependencies[singleton: .displayPictureManager].path(for: $0) }
                .map { ImageDataManager.DataSource.url(URL(fileURLWithPath: $0)) }
                .defaulting(to: Lucide.image(icon: .image, size: 40).map { image in
                    ImageDataManager.DataSource.image(
                        iconName,
                        image
                            .withTintColor(#colorLiteral(red: 0.631372549, green: 0.6352941176, blue: 0.631372549, alpha: 1), renderingMode: .alwaysTemplate)
                            .withCircularBackground(backgroundColor: #colorLiteral(red: 0.1764705882, green: 0.1764705882, blue: 0.1764705882, alpha: 1))
                    )
                }),
            icon: (currentUrl != nil ? .pencil : .rightPlus),
            style: .circular,
            showPro: dependencies[feature: .sessionProEnabled],
            accessibility: Accessibility(
                identifier: "Upload",
                label: "Upload"
            ),
            dataManager: dependencies[singleton: .imageDataManager],
            onProBageTapped: { [weak self] in
                self?.showSessionProCTAIfNeeded()
            },
            onClick: { [weak self] onDisplayPictureSelected in
                self?.onDisplayPictureSelected = { valueUpdate in
                    onDisplayPictureSelected(valueUpdate)
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
                            case .image(let source, _, _, _, _, _, _, _, _): return (source?.imageData != nil)
                            default: return false
                        }
                    },
                    cancelTitle: "remove".localized(),
                    cancelEnabled: (currentUrl != nil) ? .bool(true) : .afterChange { info in
                        switch info.body {
                            case .image(let source, _, _, _, _, _, _, _, _): return (source?.imageData != nil)
                            default: return false
                        }
                    },
                    hasCloseButton: true,
                    dismissOnConfirm: false,
                    onConfirm: { [weak self, dependencies] modal in
                        switch modal.info.body {
                            case .image(.some(let source), _, _, _, _, _, _, _, _):
                                guard let imageData: Data = source.imageData else { return }
                            
                                let isAnimatedImage: Bool = ImageDataManager.isAnimatedImage(imageData)
                                guard (
                                    !isAnimatedImage ||
                                    dependencies[cache: .libSession].isSessionPro ||
                                    !dependencies[feature: .sessionProEnabled]
                                ) else {
                                    self?.showSessionProCTAIfNeeded()
                                    return
                                }
                            
                                self?.updateProfile(
                                    displayPictureUpdate: .currentUserUploadImageData(data: imageData),
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
                                displayPictureUpdate: .currentUserRemove,
                                onComplete: { [weak modal] in modal?.close() }
                            )
                        }
                    }
                )
            ),
            transitionType: .present
        )
    }
    
    @discardableResult func showSessionProCTAIfNeeded() -> Bool {
        guard dependencies[feature: .sessionProEnabled] else { return false }
        let sessionProModal: ModalHostingViewController = ModalHostingViewController(
            modal: ProCTAModal(
                delegate: dependencies[singleton: .sessionProState],
                variant: .animatedProfileImage(
                    isSessionProActivated: dependencies[cache: .libSession].isSessionPro
                ),
                dataManager: dependencies[singleton: .imageDataManager]
            )
        )
        self.transitionToScreen(sessionProModal, transitionType: .present)
        return true
    }
    
    @MainActor private func showPhotoLibraryForAvatar() {
        Permissions.requestLibraryPermissionIfNeeded(isSavingMedia: false, using: dependencies) { [weak self] in
            DispatchQueue.main.async {
                let picker: UIImagePickerController = UIImagePickerController()
                picker.sourceType = .photoLibrary
                picker.mediaTypes = [ "public.image" ]  // stringlint:ignore
                picker.delegate = self?.imagePickerHandler
                
                self?.transitionToScreen(picker, transitionType: .present)
            }
        }
    }
    
    @MainActor fileprivate func updateProfile(
        displayNameUpdate: Profile.DisplayNameUpdate = .none,
        displayPictureUpdate: DisplayPictureManager.Update = .none,
        onComplete: @escaping () -> ()
    ) {
        let viewController = ModalActivityIndicatorViewController(canCancel: false) { [weak self, dependencies] modalActivityIndicator in
            Profile
                .updateLocal(
                    displayNameUpdate: displayNameUpdate,
                    displayPictureUpdate: displayPictureUpdate,
                    using: dependencies
                )
                .subscribe(on: DispatchQueue.global(qos: .default), using: dependencies)
                .receive(on: DispatchQueue.main, using: dependencies)
                .sinkUntilComplete(
                    receiveCompletion: { result in
                        modalActivityIndicator.dismiss {
                            switch result {
                                case .finished: onComplete()
                                case .failure(let error):
                                    let message: String = {
                                        switch (displayPictureUpdate, error) {
                                            case (.currentUserRemove, _): return "profileDisplayPictureRemoveError".localized()
                                            case (_, .uploadMaxFileSizeExceeded):
                                                return "profileDisplayPictureSizeError".localized()
                                            
                                            default: return "errorConnection".localized()
                                        }
                                    }()
                                    
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
                )
        }
        
        self.transitionToScreen(viewController, transitionType: .present)
    }
    
    private func copySessionId(_ sessionId: String, button: SessionButton?) {
        UIPasteboard.general.string = sessionId
        
        guard let button: SessionButton = button else { return }
        
        // Ensure we are on the main thread just in case
        DispatchQueue.main.async {
            button.isUserInteractionEnabled = false
            
            UIView.transition(
                with: button,
                duration: 0.25,
                options: .transitionCrossDissolve,
                animations: {
                    button.setTitle("copied".localized(), for: .normal)
                },
                completion: { _ in
                    DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(4)) {
                        button.isUserInteractionEnabled = true
                    
                        UIView.transition(
                            with: button,
                            duration: 0.25,
                            options: .transitionCrossDissolve,
                            animations: {
                                button.setTitle("copy".localized(), for: .normal)
                            },
                            completion: nil
                        )
                    }
                }
            )
        }
    }
    
    private func shareSessionId(_ sessionId: String) {
        let shareVC = UIActivityViewController(
            activityItems: [ sessionId ],
            applicationActivities: nil
        )
        
        self.transitionToScreen(shareVC, transitionType: .present)
    }
    
    private func openDonationsUrl() {
        guard let url: URL = URL(string: Constants.session_donations_url) else { return }
        
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
    
    private func openTokenUrl() {
        guard let url: URL = URL(string: Constants.session_token_url) else { return }
        
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
