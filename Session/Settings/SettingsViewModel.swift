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
    
    private let userSessionId: SessionId
    private var updatedName: String?
    private var onDisplayPictureSelected: ((ConfirmationModal.ValueUpdate) -> Void)?
    private lazy var imagePickerHandler: ImagePickerHandler = ImagePickerHandler(
        onTransition: { [weak self] in self?.transitionToScreen($0, transitionType: $1) },
        onImageDataPicked: { [weak self] identifier, resultImageData in
            self?.onDisplayPictureSelected?(.image(identifier: identifier, data: resultImageData))
        }
    )
    
    // MARK: - Initialization
    
    init(using dependencies: Dependencies) {
        self.dependencies = dependencies
        self.userSessionId = dependencies[cache: .general].sessionId
    }
    
    // MARK: - Config
    
    enum NavItem: Equatable {
        case close
        case qrCode
    }
    
    public enum Section: SessionTableSection {
        case profileInfo
        case sessionId
        
        case donationAndCommunity
        case network
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
                case .donationAndCommunity, .network, .settings, .helpAndData: return .padding
                default: return .none
            }
        }
    }
    
    public enum TableItem: Differentiable {
        case avatar
        case profileName
        
        case sessionId
        case idActions
        
        case donate
        case inviteAFriend
        
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
            image: UIImage(named: "QRCode")?
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
        )
    ]
    
    // MARK: - Content
    
    private struct State: Equatable {
        let profile: Profile
        let developerModeEnabled: Bool
        let hideRecoveryPasswordPermanently: Bool
    }
    
    let title: String = "sessionSettings".localized()
    
    lazy var observation: TargetObservation = ObservationBuilder
        .databaseObservation(self) { [weak self, dependencies] db -> State in
            State(
                profile: Profile.fetchOrCreateCurrentUser(db, using: dependencies),
                developerModeEnabled: db[.developerModeEnabled],
                hideRecoveryPasswordPermanently: db[.hideRecoveryPasswordPermanently]
            )
        }
        .compactMap { [weak self] state -> [SectionModel]? in self?.content(state) }
    
    private func content(_ state: State) -> [SectionModel] {
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
                            switch (dependencies[feature: .serviceNetwork], dependencies[feature: .forceOffline]) {
                                case (.testnet, false): return .letter("T", false)     // stringlint:ignore
                                case (.testnet, true): return .letter("T", true)       // stringlint:ignore
                                default: return .none
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
                    onTap: { [weak self] in
                        self?.updateProfilePicture(currentFileName: state.profile.profilePictureFileName)
                    }
                ),
                SessionCell.Info(
                    id: .profileName,
                    title: SessionCell.TextInfo(
                        state.profile.displayName(),
                        font: .titleLarge,
                        alignment: .center,
                        interaction: .editable
                    ),
                    trailingAccessory: .icon(
                        .pencil,
                        size: .mediumAspectFill,
                        customTint: .textSecondary,
                        shouldFill: true
                    ),
                    styling: SessionCell.StyleInfo(
                        alignment: .centerHugging,
                        customPadding: SessionCell.Padding(
                            top: Values.smallSpacing,
                            bottom: Values.mediumSpacing
                        ),
                        backgroundStyle: .noBackground
                    ),
                    accessibility: Accessibility(
                        identifier: "Username",
                        label: state.profile.displayName()
                    ),
                    confirmationInfo: self.updateDisplayName(
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
                        run: { [weak self] _ in
                            self?.shareSessionId(state.profile.id)
                        }
                    ),
                    trailingAccessory: .button(
                        style: .bordered,
                        title: "copy".localized(),
                        accessibility: Accessibility(
                            identifier: "Copy button",
                            label: "Copy button"
                        ),
                        run: { [weak self] button in
                            self?.copySessionId(state.profile.id, button: button)
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
        let donationAndCommunity: SectionModel = SectionModel(
            model: .donationAndCommunity,
            elements: [
                SessionCell.Info(
                    id: .donate,
                    leadingAccessory: .icon(
                        .heart,
                        customTint: .sessionButton_border
                    ),
                    title: "donate".localized(),
                    styling: SessionCell.StyleInfo(
                        tintColor: .sessionButton_border
                    ),
                    onTap: { [weak self] in self?.openDonationsUrl() }
                ),
                SessionCell.Info(
                    id: .inviteAFriend,
                    leadingAccessory: .icon(.userRoundPlus),
                    title: "sessionInviteAFriend".localized(),
                    onTap: { [weak self] in
                        let invitation: String = "accountIdShare"
                            .put(key: "app_name", value: Constants.app_name)
                            .put(key: "account_id", value: state.profile.id)
                            .put(key: "session_download_url", value: Constants.session_download_url)
                            .localized()
                        
                        self?.transitionToScreen(
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
        let network: SectionModel = SectionModel(
            model: .network,
            elements: [
                SessionCell.Info(
                    id: .path,
                    leadingAccessory: .custom(
                        info: PathStatusViewAccessory.Info()
                    ),
                    title: "onionRoutingPath".localized(),
                    onTap: { [weak self, dependencies] in
                        self?.transitionToScreen(PathVC(using: dependencies))
                    }
                ),
                SessionCell.Info(
                    id: .sessionNetwork,
                    leadingAccessory: .icon(
                        UIImage(named: "icon_session_network")?
                            .withRenderingMode(.alwaysTemplate)
                    ),
                    title: Constants.network_name,
                    trailingAccessory: .custom(
                        info: NewTagView.Info()
                    ),
                    onTap: { [weak self, dependencies] in
                        let viewController: SessionHostingViewController = SessionHostingViewController(
                            rootView: SessionNetworkScreen(
                                viewModel: SessionNetworkScreenContent.ViewModel(dependencies: dependencies)
                            )
                        )
                        viewController.setNavBarTitle(Constants.network_name)
                        self?.transitionToScreen(viewController)
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
                    onTap: { [weak self, dependencies] in
                        self?.transitionToScreen(
                            SessionTableViewController(viewModel: PrivacySettingsViewModel(using: dependencies))
                        )
                    }
                ),
                SessionCell.Info(
                    id: .notifications,
                    leadingAccessory: .icon(.volume2),
                    title: "sessionNotifications".localized(),
                    onTap: { [weak self, dependencies] in
                        self?.transitionToScreen(
                            SessionTableViewController(viewModel: NotificationSettingsViewModel(using: dependencies))
                        )
                    }
                ),
                SessionCell.Info(
                    id: .conversations,
                    leadingAccessory: .icon(.usersRound),
                    title: "sessionConversations".localized(),
                    onTap: { [weak self, dependencies] in
                        self?.transitionToScreen(
                            SessionTableViewController(viewModel: ConversationSettingsViewModel(using: dependencies))
                        )
                    }
                ),
                SessionCell.Info(
                    id: .appearance,
                    leadingAccessory: .icon(.paintbrushVertical),
                    title: "sessionAppearance".localized(),
                    onTap: { [weak self, dependencies] in
                        self?.transitionToScreen(
                            SessionTableViewController(viewModel: AppearanceViewModel(using: dependencies))
                        )
                    }
                ),
                SessionCell.Info(
                    id: .messageRequests,
                    leadingAccessory: .icon(.messageSquareWarning),
                    title: "sessionMessageRequests".localized(),
                    onTap: { [weak self, dependencies] in
                        self?.transitionToScreen(
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
                    onTap: { [weak self, dependencies] in
                        guard let recoveryPasswordView: RecoveryPasswordScreen = try? RecoveryPasswordScreen(using: dependencies) else {
                            let targetViewController: UIViewController = ConfirmationModal(
                                info: ConfirmationModal.Info(
                                    title: "theError".localized(),
                                    body: .text("recoveryPasswordErrorLoad".localized()),
                                    cancelTitle: "okay".localized(),
                                    cancelStyle: .alert_text
                                )
                            )
                            self?.transitionToScreen(targetViewController, transitionType: .present)
                            return
                        }
                        
                        let viewController: SessionHostingViewController = SessionHostingViewController(rootView: recoveryPasswordView)
                        viewController.setNavBarTitle("sessionRecoveryPassword".localized())
                        self?.transitionToScreen(viewController)
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
                onTap: { [weak self, dependencies] in
                    self?.transitionToScreen(
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
                    onTap: { [weak self, dependencies] in
                        self?.transitionToScreen(
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
                onTap: { [weak self, dependencies] in
                    self?.transitionToScreen(NukeDataModal(using: dependencies), transitionType: .present)
                }
            )
        )
        let helpAndData: SectionModel = SectionModel(
            model: .helpAndData,
            elements: helpAndDataElements
        )
        
        return [profileInfo, sessionId, donationAndCommunity, network, settings, helpAndData]
    }
    
    public lazy var footerView: AnyPublisher<UIView?, Never> = Just(VersionFooterView(
        numVersionTapsRequired: 9,
        logoTapCallback: { [weak self] in self?.openTokenUrl() },
        versionTapCallback: { [dependencies] in
            /// Do nothing if developer mode is already enabled
            guard !dependencies[singleton: .storage, key: .developerModeEnabled] else { return }
            
            dependencies[singleton: .storage].write { db in
                db[.developerModeEnabled] = true
            }
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
    
    private func updateProfilePicture(currentFileName: String?) {
        let iconName: String = "profile_placeholder" // stringlint:ignore
        var hasSetNewProfilePicture: Bool = false
        let body: ConfirmationModal.Info.Body = .image(
            source: nil,
            placeholder: currentFileName
                .map { try? dependencies[singleton: .displayPictureManager].filepath(for: $0) }
                .map { ImageDataManager.DataSource.url(URL(fileURLWithPath: $0)) }
                .defaulting(to: Lucide.image(icon: .image, size: 40).map { image in
                    ImageDataManager.DataSource.image(
                        iconName,
                        image
                            .withTintColor(#colorLiteral(red: 0.631372549, green: 0.6352941176, blue: 0.631372549, alpha: 1), renderingMode: .alwaysTemplate)
                            .withCircularBackground(backgroundColor: #colorLiteral(red: 0.1764705882, green: 0.1764705882, blue: 0.1764705882, alpha: 1))
                    )
                }),
            icon: (currentFileName != nil ? .pencil : .rightPlus),
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
                    cancelEnabled: (currentFileName != nil) ? .bool(true) : .afterChange { info in
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
                                guard isAnimatedImage && !dependencies[cache: .libSession].isSessionPro else {
                                    self?.updateProfile(
                                        displayPictureUpdate: .currentUserUploadImageData(
                                            data: imageData,
                                            sessionProProof: !isAnimatedImage ? nil :
                                                dependencies.mutate(cache: .libSession, { $0.getProProof() })
                                        ),
                                        onComplete: { [weak modal] in modal?.close() }
                                    )
                                    return
                                }
                            
                                self?.showSessionProCTAIfNeeded()
                            
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
    
    private func showPhotoLibraryForAvatar() {
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
    
    fileprivate func updateProfile(
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
