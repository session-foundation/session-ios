// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import DifferenceKit
import SessionUIKit
import SessionMessagingKit
import SessionUtilitiesKit
import SignalUtilitiesKit

class SettingsViewModel: SessionTableViewModel<SettingsViewModel.NavButton, SettingsViewModel.Section, SettingsViewModel.Item> {
    // MARK: - Config
    
    enum NavState {
        case standard
        case editing
    }
    
    enum NavButton: Equatable {
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
                case .sessionId: return "your_session_id".localized()
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
    
    public enum Item: Differentiable {
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
        case clearData
    }
    
    // MARK: - Variables
    
    private let userSessionId: String
    private lazy var imagePickerHandler: ImagePickerHandler = ImagePickerHandler(
        onTransition: { [weak self] in self?.transitionToScreen($0, transitionType: $1) },
        onImagePicked: { [weak self] resultImage in
            guard let oldDisplayName: String = self?.oldDisplayName else { return }
            
            self?.updateProfile(
                name: oldDisplayName,
                avatarUpdate: .uploadImage(resultImage)
            )
        },
        onImageFilePicked: { [weak self] resultImagePath in
            guard let oldDisplayName: String = self?.oldDisplayName else { return }
            
            self?.updateProfile(
                name: oldDisplayName,
                avatarUpdate: .uploadFilePath(resultImagePath)
            )
        }
    )
    fileprivate var oldDisplayName: String
    private var editedDisplayName: String?
    
    // MARK: - Initialization
    
    override init() {
        self.userSessionId = getUserHexEncodedPublicKey()
        self.oldDisplayName = Profile.fetchOrCreateCurrentUser().name
        
        super.init()
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

    override var leftNavItems: AnyPublisher<[NavItem]?, Never> {
       navState
           .map { navState -> [NavItem] in
               switch navState {
                   case .standard:
                       return [
                            NavItem(
                                id: .close,
                                image: UIImage(named: "X")?
                                    .withRenderingMode(.alwaysTemplate),
                                style: .plain,
                                accessibilityIdentifier: "Close button"
                            ) { [weak self] in self?.dismissScreen() }
                       ]
                       
                   case .editing:
                       return [
                           NavItem(
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
    }
    
    override var rightNavItems: AnyPublisher<[NavItem]?, Never> {
       navState
           .map { [weak self] navState -> [NavItem] in
               switch navState {
                   case .standard:
                       return [
                            NavItem(
                                id: .qrCode,
                                image: UIImage(named: "QRCode")?
                                    .withRenderingMode(.alwaysTemplate),
                                style: .plain,
                                accessibilityIdentifier: "Show QR code button",
                                action: { [weak self] in
                                    self?.transitionToScreen(QRCodeVC())
                                }
                            )
                       ]
                       
                   case .editing:
                       return [
                            NavItem(
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
                                                title: "vc_settings_display_name_missing_error".localized(),
                                                cancelTitle: "BUTTON_OK".localized(),
                                                cancelStyle: .alert_text
                                            )
                                        ),
                                        transitionType: .present
                                    )
                                    return
                                }
                                guard !ProfileManager.isToLong(profileName: updatedNickname) else {
                                    self?.transitionToScreen(
                                        ConfirmationModal(
                                            info: ConfirmationModal.Info(
                                                title: "vc_settings_display_name_too_long_error".localized(),
                                                cancelTitle: "BUTTON_OK".localized(),
                                                cancelStyle: .alert_text
                                            )
                                        ),
                                        transitionType: .present
                                    )
                                    return
                                }
                                
                                self?.setIsEditing(false)
                                self?.oldDisplayName = updatedNickname
                                self?.updateProfile(
                                    name: updatedNickname,
                                    avatarUpdate: .none
                                )
                            }
                       ]
               }
           }
           .eraseToAnyPublisher()
    }
    
    // MARK: - Content
    
    override var title: String { "vc_settings_title".localized() }
    
    public override var observableTableData: ObservableData { _observableTableData }
    
    /// This is all the data the screen needs to populate itself, please see the following link for tips to help optimise
    /// performance https://github.com/groue/GRDB.swift#valueobservation-performance
    ///
    /// **Note:** This observation will be triggered twice immediately (and be de-duped by the `removeDuplicates`)
    /// this is due to the behaviour of `ValueConcurrentObserver.asyncStartObservation` which triggers it's own
    /// fetch (after the ones in `ValueConcurrentObserver.asyncStart`/`ValueConcurrentObserver.syncStart`)
    /// just in case the database has changed between the two reads - unfortunately it doesn't look like there is a way to prevent this
    private lazy var _observableTableData: ObservableData = ValueObservation
        .trackingConstantRegion { [weak self] db -> [SectionModel] in
            let userPublicKey: String = getUserHexEncodedPublicKey(db)
            let profile: Profile = Profile.fetchOrCreateCurrentUser(db)
            
            return [
                SectionModel(
                    model: .profileInfo,
                    elements: [
                        SessionCell.Info(
                            id: .avatar,
                            accessory: .profile(
                                id: profile.id,
                                size: .extraLarge,
                                profile: profile
                            ),
                            styling: SessionCell.StyleInfo(
                                alignment: .centerHugging,
                                customPadding: SessionCell.Padding(bottom: Values.smallSpacing),
                                backgroundStyle: .noBackground
                            ),
                            onTap: {
                                self?.updateProfilePicture(
                                    hasCustomImage: ProfileManager.hasProfileImageData(
                                        with: profile.profilePictureFileName
                                    )
                                )
                            }
                        ),
                        SessionCell.Info(
                            id: .profileName,
                            title: SessionCell.TextInfo(
                                profile.displayName(),
                                font: .titleLarge,
                                alignment: .center,
                                interaction: .editable
                            ),
                            styling: SessionCell.StyleInfo(
                                alignment: .centerHugging,
                                customPadding: SessionCell.Padding(top: Values.smallSpacing),
                                backgroundStyle: .noBackground
                            ),
                            onTap: { self?.setIsEditing(true) }
                        )
                    ]
                ),
                SectionModel(
                    model: .sessionId,
                    elements: [
                        SessionCell.Info(
                            id: .sessionId,
                            title: SessionCell.TextInfo(
                                profile.id,
                                font: .monoLarge,
                                alignment: .center,
                                interaction: .copy
                            ),
                            styling: SessionCell.StyleInfo(
                                customPadding: SessionCell.Padding(bottom: Values.smallSpacing),
                                backgroundStyle: .noBackground
                            )
                        ),
                        SessionCell.Info(
                            id: .idActions,
                            leftAccessory: .button(
                                style: .bordered,
                                title: "copy".localized(),
                                run: { button in
                                    self?.copySessionId(profile.id, button: button)
                                }
                            ),
                            rightAccessory: .button(
                                style: .bordered,
                                title: "share".localized(),
                                run: { _ in
                                    self?.shareSessionId(profile.id)
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
                ),
                SectionModel(
                    model: .menus,
                    elements: [
                        SessionCell.Info(
                            id: .path,
                            leftAccessory: .customView(hashValue: "PathStatusView") {
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
                            title: "vc_path_title".localized(),
                            onTap: { self?.transitionToScreen(PathVC()) }
                        ),
                        SessionCell.Info(
                            id: .privacy,
                            leftAccessory: .icon(
                                UIImage(named: "icon_privacy")?
                                    .withRenderingMode(.alwaysTemplate)
                            ),
                            title: "vc_settings_privacy_button_title".localized(),
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
                            title: "vc_settings_notifications_button_title".localized(),
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
                            title: "CONVERSATION_SETTINGS_TITLE".localized(),
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
                            title: "MESSAGE_REQUESTS_TITLE".localized(),
                            onTap: {
                                self?.transitionToScreen(MessageRequestsViewController())
                            }
                        ),
                        SessionCell.Info(
                            id: .appearance,
                            leftAccessory: .icon(
                                UIImage(named: "icon_apperance")?
                                    .withRenderingMode(.alwaysTemplate)
                            ),
                            title: "APPEARANCE_TITLE".localized(),
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
                            title: "vc_settings_invite_a_friend_button_title".localized(),
                            onTap: {
                                let invitation: String = "Hey, I've been using Session to chat with complete privacy and security. Come join me! Download it at https://getsession.org/. My Session ID is \(profile.id) !"
                                
                                self?.transitionToScreen(
                                    UIActivityViewController(
                                        activityItems: [ invitation ],
                                        applicationActivities: nil
                                    ),
                                    transitionType: .present
                                )
                            }
                        ),
                        SessionCell.Info(
                            id: .recoveryPhrase,
                            leftAccessory: .icon(
                                UIImage(named: "icon_recovery")?
                                    .withRenderingMode(.alwaysTemplate)
                            ),
                            title: "vc_settings_recovery_phrase_button_title".localized(),
                            onTap: {
                                self?.transitionToScreen(SeedModal(), transitionType: .present)
                            }
                        ),
                        SessionCell.Info(
                            id: .help,
                            leftAccessory: .icon(
                                UIImage(named: "icon_help")?
                                    .withRenderingMode(.alwaysTemplate)
                            ),
                            title: "HELP_TITLE".localized(),
                            onTap: {
                                self?.transitionToScreen(
                                    SessionTableViewController(viewModel: HelpViewModel())
                                )
                            }
                        ),
                        SessionCell.Info(
                            id: .clearData,
                            leftAccessory: .icon(
                                UIImage(named: "icon_bin")?
                                    .withRenderingMode(.alwaysTemplate)
                            ),
                            title: "vc_settings_clear_all_data_button_title".localized(),
                            styling: SessionCell.StyleInfo(tintColor: .danger),
                            onTap: {
                                self?.transitionToScreen(NukeDataModal(), transitionType: .present)
                            }
                        )
                    ]
                )
            ]
        }
        .removeDuplicates()
        .publisher(in: Storage.shared)
        .mapToSessionTableViewData(for: self)
    
    public override var footerView: AnyPublisher<UIView?, Never> {
        Just(VersionFooterView())
            .eraseToAnyPublisher()
    }
    
    // MARK: - Functions
    
    private func updateProfilePicture(hasCustomImage: Bool) {
        let actionSheet: UIAlertController = UIAlertController(
            title: "Update Profile Picture",
            message: nil,
            preferredStyle: .actionSheet
        )
        actionSheet.addAction(UIAlertAction(
            title: "MEDIA_FROM_LIBRARY_BUTTON".localized(),
            style: .default,
            handler: { [weak self] _ in
                self?.showPhotoLibraryForAvatar()
            }
        ))
        
        // Only have the 'remove' button if there is a custom avatar set
        if hasCustomImage {
            actionSheet.addAction(UIAlertAction(
                title: "REMOVE_AVATAR".localized(),
                style: .destructive,
                handler: { [weak self] _ in self?.removeProfileImage() }
            ))
        }
        
        actionSheet.addAction(UIAlertAction(title: "cancel".localized(), style: .cancel, handler: nil))
        
        self.transitionToScreen(actionSheet, transitionType: .present)
    }
    
    private func showPhotoLibraryForAvatar() {
        Permissions.requestLibraryPermissionIfNeeded { [weak self] in
            DispatchQueue.main.async {
                let picker: UIImagePickerController = UIImagePickerController()
                picker.sourceType = .photoLibrary
                picker.mediaTypes = [ "public.image" ]
                picker.delegate = self?.imagePickerHandler
                
                self?.transitionToScreen(picker, transitionType: .present)
            }
        }
    }
    
    private func removeProfileImage() {
        let oldDisplayName: String = self.oldDisplayName
        
        let viewController = ModalActivityIndicatorViewController(canCancel: false) { [weak self] modalActivityIndicator in
            ProfileManager.updateLocal(
                queue: DispatchQueue.global(qos: .default),
                profileName: oldDisplayName,
                avatarUpdate: .remove,
                success: { db in
                    // Wait for the database transaction to complete before updating the UI
                    db.afterNextTransaction { _ in
                        DispatchQueue.main.async {
                            modalActivityIndicator.dismiss(completion: {})
                        }
                    }
                },
                failure: { [weak self] _ in
                    DispatchQueue.main.async {
                        modalActivityIndicator.dismiss {
                            self?.transitionToScreen(
                                ConfirmationModal(
                                    info: ConfirmationModal.Info(
                                        title: "Unable to remove avatar image",
                                        cancelTitle: "BUTTON_OK".localized(),
                                        cancelStyle: .alert_text
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
    
    fileprivate func updateProfile(
        name: String,
        avatarUpdate: ProfileManager.AvatarUpdate
    ) {
        let viewController = ModalActivityIndicatorViewController(canCancel: false) { [weak self] modalActivityIndicator in
            ProfileManager.updateLocal(
                queue: DispatchQueue.global(qos: .default),
                profileName: name,
                avatarUpdate: avatarUpdate,
                success: { db in
                    // Wait for the database transaction to complete before updating the UI
                    db.afterNextTransaction { _ in
                        DispatchQueue.main.async {
                            modalActivityIndicator.dismiss(completion: {})
                        }
                    }
                },
                failure: { [weak self] error in
                    DispatchQueue.main.async {
                        modalActivityIndicator.dismiss {
                            let isMaxFileSizeExceeded: Bool = (error == .avatarUploadMaxFileSizeExceeded)
                            
                            self?.transitionToScreen(
                                ConfirmationModal(
                                    info: ConfirmationModal.Info(
                                        title: (isMaxFileSizeExceeded ?
                                            "Maximum File Size Exceeded" :
                                            "Couldn't Update Profile"
                                        ),
                                        explanation: (isMaxFileSizeExceeded ?
                                            "Please select a smaller photo and try again" :
                                            "Please check your internet connection and try again"
                                        ),
                                        cancelTitle: "BUTTON_OK".localized(),
                                        cancelStyle: .alert_text
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
