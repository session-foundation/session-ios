// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import DifferenceKit
import SessionUIKit
import SessionMessagingKit
import SessionUtilitiesKit
import SignalUtilitiesKit

class SettingsViewModel: SessionTableViewModel, NavigationItemSource, NavigatableStateHolder, EditableStateHolder, ObservableTableSource {
    public let dependencies: Dependencies
    public let navigatableState: NavigatableState = NavigatableState()
    public let editableState: EditableState<TableItem> = EditableState()
    public let state: TableDataState<Section, TableItem> = TableDataState()
    public let observableState: ObservableTableSourceState<Section, TableItem> = ObservableTableSourceState()
    
    private let userSessionId: String
    private lazy var imagePickerHandler: ImagePickerHandler = ImagePickerHandler(
        onTransition: { [weak self] in self?.transitionToScreen($0, transitionType: $1) },
        onImageDataPicked: { [weak self] resultImageData in
            self?.updatedProfilePictureSelected(
                displayPictureUpdate: .currentUserUploadImageData(resultImageData)
            )
        }
    )
    fileprivate var oldDisplayName: String
    private var editedDisplayName: String?
    private var editProfilePictureModal: ConfirmationModal?
    private var editProfilePictureModalInfo: ConfirmationModal.Info?
    
    // MARK: - Initialization
    
    init(using dependencies: Dependencies = Dependencies()) {
        self.dependencies = dependencies
        self.userSessionId = getUserHexEncodedPublicKey(using: dependencies)
        self.oldDisplayName = Profile.fetchOrCreateCurrentUser(using: dependencies).name
    }
    
    // MARK: - Config
    
    enum NavState {
        case standard
        case editing
    }
    
    enum NavItem: Equatable {
        case close
        case qrCode
        case cancel
        case done
    }
    
    public enum Section: SessionTableSection {
        case profileInfo
        case sessionId
        case menus
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
                case .menus: return .padding
                default: return .none
            }
        }
    }
    
    public enum TableItem: Differentiable {
        case avatar
        case profileName
        
        case sessionId
        case idActions
        
        case path
        case privacy
        case notifications
        case conversations
        case messageRequests
        case appearance
        case inviteAFriend
        case recoveryPhrase
        case help
        case developerSettings
        case clearData
    }
    
    // MARK: - Navigation
    
    lazy var navState: AnyPublisher<NavState, Never> = {
        Publishers
            .CombineLatest(
                isEditing,
                textChanged
                    .handleEvents(
                        receiveOutput: { [weak self] value, _ in
                            self?.editedDisplayName = value
                        }
                    )
                    .filter { _ in false }
                    .prepend((nil, .profileName))
            )
            .map { isEditing, _ -> NavState in (isEditing ? .editing : .standard) }
            .removeDuplicates()
            .prepend(.standard)     // Initial value
            .shareReplay(1)
            .eraseToAnyPublisher()
    }()

    lazy var leftNavItems: AnyPublisher<[SessionNavItem<NavItem>], Never> = navState
        .map { navState -> [SessionNavItem<NavItem>] in
            switch navState {
                case .standard:
                    return [
                        SessionNavItem(
                            id: .close,
                            image: UIImage(named: "X")?
                                .withRenderingMode(.alwaysTemplate),
                            style: .plain,
                            accessibilityIdentifier: "Close button"
                        ) { [weak self] in self?.dismissScreen() }
                    ]
                   
                case .editing:
                    return [
                        SessionNavItem(
                            id: .cancel,
                            systemItem: .cancel,
                            accessibilityIdentifier: "Cancel button"
                        ) { [weak self] in
                            self?.setIsEditing(false)
                            self?.editedDisplayName = self?.oldDisplayName
                        }
                    ]
            }
        }
        .eraseToAnyPublisher()
    
    lazy var rightNavItems: AnyPublisher<[SessionNavItem<NavItem>], Never> = navState
        .map { [weak self, dependencies] navState -> [SessionNavItem<NavItem>] in
            switch navState {
                case .standard:
                    return [
                        SessionNavItem(
                            id: .qrCode,
                            image: UIImage(named: "QRCode")?
                                .withRenderingMode(.alwaysTemplate),
                            style: .plain,
                            accessibilityIdentifier: "View QR code",
                            action: { [weak self] in
                                let viewController: SessionHostingViewController = SessionHostingViewController(
                                    rootView: QRCodeScreen(using: dependencies)
                                )
                                viewController.setNavBarTitle("qrCode".localized())
                                self?.transitionToScreen(viewController)
                            }
                        )
                    ]
                       
                    case .editing:
                        return [
                            SessionNavItem(
                                id: .done,
                                systemItem: .done,
                                accessibilityIdentifier: "Done"
                            ) { [weak self] in
                                let updatedNickname: String = (self?.editedDisplayName ?? "")
                                    .trimmingCharacters(in: .whitespacesAndNewlines)
                                
                                guard !updatedNickname.isEmpty else {
                                    self?.transitionToScreen(
                                        ConfirmationModal(
                                            info: ConfirmationModal.Info(
                                                title: "displayNameErrorDescription".localized(),
                                                cancelTitle: "okay".localized(),
                                                cancelStyle: .alert_text
                                            )
                                        ),
                                        transitionType: .present
                                    )
                                    return
                                }
                                guard !ProfileManager.isTooLong(profileName: updatedNickname) else {
                                    self?.transitionToScreen(
                                        ConfirmationModal(
                                            info: ConfirmationModal.Info(
                                                title: "displayNameErrorDescriptionShorter".localized(),
                                                cancelTitle: "okay".localized(),
                                                cancelStyle: .alert_text
                                            )
                                        ),
                                        transitionType: .present
                                    )
                                    return
                                }
                                
                                self?.setIsEditing(false)
                                self?.oldDisplayName = updatedNickname
                                self?.updateProfile(displayNameUpdate: .currentUserUpdate(updatedNickname))
                            }
                        ]
                }
            }
            .eraseToAnyPublisher()
    
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
        .map { [weak self, dependencies] state -> [SectionModel] in
            let profileInfo: SectionModel = SectionModel(
                model: .profileInfo,
                elements: [
                    SessionCell.Info(
                        id: .avatar,
                        accessory: .profile(
                            id: state.profile.id,
                            size: .hero,
                            profile: state.profile
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
                        onTap: {
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
                        styling: SessionCell.StyleInfo(
                            customPadding: SessionCell.Padding(top: Values.smallSpacing),
                            backgroundStyle: .noBackground
                        ),
                        accessibility: Accessibility(
                            identifier: "Username",
                            label: state.profile.displayName()
                        ),
                        onTap: { self?.setIsEditing(true) }
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
                        leftAccessory: .button(
                            style: .bordered,
                            title: "share".localized(),
                            accessibility: Accessibility(
                                identifier: "Share button",
                                label: "Share button"
                            ),
                            run: { _ in
                                self?.shareSessionId(state.profile.id)
                            }
                        ),
                        rightAccessory: .button(
                            style: .bordered,
                            title: "copy".localized(),
                            accessibility: Accessibility(
                                identifier: "Copy button",
                                label: "Copy button"
                            ),
                            run: { button in
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
            let menus: SectionModel = SectionModel(
                model: .menus,
                elements: [
                    SessionCell.Info(
                        id: .path,
                        leftAccessory: .customView(hashValue: "PathStatusView") {   // stringlint:ignore
                            // Need to ensure this view is the same size as the icons so
                            // wrap it in a larger view
                            let result: UIView = UIView()
                            let pathView: PathStatusView = PathStatusView(size: .large)
                            result.addSubview(pathView)
                            
                            result.set(.width, to: IconSize.medium.size)
                            result.set(.height, to: IconSize.medium.size)
                            pathView.center(in: result)
                            
                            return result
                        },
                        title: "onionRoutingPath".localized(),
                        onTap: { self?.transitionToScreen(PathVC()) }
                    ),
                    SessionCell.Info(
                        id: .privacy,
                        leftAccessory: .icon(
                            UIImage(named: "icon_privacy")?
                                .withRenderingMode(.alwaysTemplate)
                        ),
                        title: "sessionPrivacy".localized(),
                        onTap: {
                            self?.transitionToScreen(
                                SessionTableViewController(viewModel: PrivacySettingsViewModel())
                            )
                        }
                    ),
                    SessionCell.Info(
                        id: .notifications,
                        leftAccessory: .icon(
                            UIImage(named: "icon_speaker")?
                                .withRenderingMode(.alwaysTemplate)
                        ),
                        title: "sessionNotifications".localized(),
                        onTap: {
                            self?.transitionToScreen(
                                SessionTableViewController(viewModel: NotificationSettingsViewModel())
                            )
                        }
                    ),
                    SessionCell.Info(
                        id: .conversations,
                        leftAccessory: .icon(
                            UIImage(named: "icon_msg")?
                                .withRenderingMode(.alwaysTemplate)
                        ),
                        title: "sessionConversations".localized(),
                        onTap: {
                            self?.transitionToScreen(
                                SessionTableViewController(viewModel: ConversationSettingsViewModel())
                            )
                        }
                    ),
                    SessionCell.Info(
                        id: .messageRequests,
                        leftAccessory: .icon(
                            UIImage(named: "icon_msg_req")?
                                .withRenderingMode(.alwaysTemplate)
                        ),
                        title: "sessionMessageRequests".localized(),
                        onTap: {
                            self?.transitionToScreen(
                                SessionTableViewController(viewModel: MessageRequestsViewModel())
                            )
                        }
                    ),
                    SessionCell.Info(
                        id: .appearance,
                        leftAccessory: .icon(
                            UIImage(named: "icon_apperance")?
                                .withRenderingMode(.alwaysTemplate)
                        ),
                        title: "sessionAppearance".localized(),
                        onTap: {
                            self?.transitionToScreen(AppearanceViewController())
                        }
                    ),
                    SessionCell.Info(
                        id: .inviteAFriend,
                        leftAccessory: .icon(
                            UIImage(named: "icon_invite")?
                                .withRenderingMode(.alwaysTemplate)
                        ),
                        title: "sessionInviteAFriend".localized(),
                        onTap: {
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
                    ),
                    (
                        state.hideRecoveryPasswordPermanently ? nil :
                        SessionCell.Info(
                            id: .recoveryPhrase,
                            leftAccessory: .icon(
                                UIImage(named: "SessionShield")?
                                    .withRenderingMode(.alwaysTemplate)
                            ),
                            title: "sessionRecoveryPassword".localized(),
                            accessibility: Accessibility(
                                identifier: "Recovery password menu item",
                                label: "Recovery password menu item"
                            ),
                            onTap: {
                                if let recoveryPasswordView: RecoveryPasswordScreen = try? RecoveryPasswordScreen() {
                                    let viewController: SessionHostingViewController = SessionHostingViewController(rootView: recoveryPasswordView)
                                    viewController.setNavBarTitle("sessionRecoveryPassword".localized())
                                    self?.transitionToScreen(viewController)
                                } else {
                                    let targetViewController: UIViewController = ConfirmationModal(
                                        info: ConfirmationModal.Info(
                                            title: "theError".localized(),
                                            body: .text("recoveryPasswordErrorLoad".localized()),
                                            cancelTitle: "okay".localized(),
                                            cancelStyle: .alert_text
                                        )
                                    )
                                    self?.transitionToScreen(targetViewController, transitionType: .present)
                                }
                            }
                        )
                    ),
                    SessionCell.Info(
                        id: .help,
                        leftAccessory: .icon(
                            UIImage(named: "icon_help")?
                                .withRenderingMode(.alwaysTemplate)
                        ),
                        title: "sessionHelp".localized(),
                        onTap: {
                            self?.transitionToScreen(
                                SessionTableViewController(viewModel: HelpViewModel())
                            )
                        }
                    ),
                    (!state.developerModeEnabled ? nil :
                        SessionCell.Info(
                            id: .developerSettings,
                            leftAccessory: .icon(
                                UIImage(systemName: "wrench.and.screwdriver")?
                                    .withRenderingMode(.alwaysTemplate)
                            ),
                            title: "Developer Settings",    // stringlint:ignore
                            styling: SessionCell.StyleInfo(tintColor: .warning),
                            onTap: {
                                self?.transitionToScreen(
                                    SessionTableViewController(viewModel: DeveloperSettingsViewModel(using: dependencies))
                                )
                            }
                        )
                    ),
                    SessionCell.Info(
                        id: .clearData,
                        leftAccessory: .icon(
                            UIImage(named: "icon_bin")?
                                .withRenderingMode(.alwaysTemplate)
                        ),
                        title: "sessionClearData".localized(),
                        styling: SessionCell.StyleInfo(tintColor: .danger),
                        onTap: {
                            self?.transitionToScreen(NukeDataModal(), transitionType: .present)
                        }
                    )
                ].compactMap { $0 }
            )
            
            return [profileInfo, sessionId, menus]
        }
    
    public lazy var footerView: AnyPublisher<UIView?, Never> = Just(VersionFooterView(numTaps: 9) { [dependencies] in
           /// Do nothing if developer mode is already enabled
            guard !dependencies.storage[.developerModeEnabled] else { return }
           
           dependencies.storage.write { db in
               db[.developerModeEnabled] = true
           }
    }).eraseToAnyPublisher()
    
    // MARK: - Functions
    
    private func updateProfilePicture(currentFileName: String?) {
        let existingImageData: Data? = ProfileManager
            .profileAvatar(id: self.userSessionId)
        let editProfilePictureModalInfo: ConfirmationModal.Info = ConfirmationModal.Info(
            title: "profileDisplayPictureSet".localized(),
            body: .image(
                placeholderData: UIImage(named: "profile_placeholder")?.pngData(),
                valueData: existingImageData,
                icon: .rightPlus,
                style: .circular,
                accessibility: Accessibility(
                    identifier: "Image picker",
                    label: "Image picker"
                ),
                onClick: { [weak self] in self?.showPhotoLibraryForAvatar() }
            ),
            confirmTitle: "save".localized(),
            confirmEnabled: false,
            cancelTitle: "remove".localized(),
            cancelEnabled: (existingImageData != nil),
            hasCloseButton: true,
            dismissOnConfirm: false,
            onConfirm: { modal in modal.close() },
            onCancel: { [weak self] modal in
                self?.updateProfile(
                    displayPictureUpdate: .currentUserRemove,
                    onComplete: { [weak modal] in modal?.close() }
                )
            },
            afterClosed: { [weak self] in
                self?.editProfilePictureModal = nil
                self?.editProfilePictureModalInfo = nil
            }
        )
        let modal: ConfirmationModal = ConfirmationModal(info: editProfilePictureModalInfo)
            
        self.editProfilePictureModalInfo = editProfilePictureModalInfo
        self.editProfilePictureModal = modal
        self.transitionToScreen(modal, transitionType: .present)
    }

    fileprivate func updatedProfilePictureSelected(displayPictureUpdate: ProfileManager.DisplayPictureUpdate) {
        guard let info: ConfirmationModal.Info = self.editProfilePictureModalInfo else { return }
        
        self.editProfilePictureModal?.updateContent(
            with: info.with(
                body: .image(
                    placeholderData: UIImage(named: "profile_placeholder")?.pngData(),
                    valueData: {
                        switch displayPictureUpdate {
                            case .currentUserUploadImageData(let imageData): return imageData
                            default: return nil
                        }
                    }(),
                    icon: .rightPlus,
                    style: .circular,
                    accessibility: Accessibility(
                        identifier: "Image picker",
                        label: "Image picker"
                    ),
                    onClick: { [weak self] in self?.showPhotoLibraryForAvatar() }
                ),
                confirmEnabled: true,
                onConfirm: { [weak self] modal in
                    self?.updateProfile(
                        displayPictureUpdate: displayPictureUpdate,
                        onComplete: { [weak modal] in modal?.close() }
                    )
                }
            )
        )
    }
    
    private func showPhotoLibraryForAvatar() {
        Permissions.requestLibraryPermissionIfNeeded(isSavingMedia: false) { [weak self] in
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
        displayNameUpdate: ProfileManager.DisplayNameUpdate = .none,
        displayPictureUpdate: ProfileManager.DisplayPictureUpdate = .none,
        onComplete: (() -> ())? = nil
    ) {
        let viewController = ModalActivityIndicatorViewController(canCancel: false) { [weak self] modalActivityIndicator in
            ProfileManager.updateLocal(
                queue: .global(qos: .default),
                displayNameUpdate: displayNameUpdate,
                displayPictureUpdate: displayPictureUpdate,
                success: { db in
                    // Wait for the database transaction to complete before updating the UI
                    db.afterNextTransactionNested { _ in
                        DispatchQueue.main.async {
                            modalActivityIndicator.dismiss(completion: {
                                onComplete?()
                            })
                        }
                    }
                },
                failure: { [weak self] error in
                    DispatchQueue.main.async {
                        modalActivityIndicator.dismiss {
                            let message: String = {
                                switch (displayPictureUpdate, error) {
                                    case (.currentUserRemove, _): return "profileDisplayPictureRemoveError".localized()
                                    case (_, .avatarUploadMaxFileSizeExceeded):
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
}
