// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import Photos
import PhotosUI
import AVFAudio
import SessionUIKit
import SessionUtilitiesKit
import SessionMessagingKit
import Network

extension Permissions {
    @discardableResult public static func requestCameraPermissionIfNeeded(
        presentingViewController: UIViewController? = nil,
        onAuthorized: (() -> Void)? = nil
    ) -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized:
                onAuthorized?()
                return true
            
            case .denied, .restricted:
                guard
                    Singleton.hasAppContext,
                    let presentingViewController: UIViewController = (presentingViewController ?? Singleton.appContext.frontmostViewController)
                else { return false }
                
                let confirmationModal: ConfirmationModal = ConfirmationModal(
                    info: ConfirmationModal.Info(
                        title: "permissionsRequired".localized(),
                        body: .text(
                            "cameraGrantAccessDenied"
                                .put(key: "app_name", value: Constants.app_name)
                                .localized()
                        ),
                        confirmTitle: "sessionSettings".localized(),
                        dismissOnConfirm: false
                    ) { [weak presentingViewController] _ in
                        presentingViewController?.dismiss(animated: true, completion: {
                            UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!)
                        })
                    }
                )
                presentingViewController.present(confirmationModal, animated: true, completion: nil)
                return false
                
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .video, completionHandler: { _ in
                    onAuthorized?()
                })
                return false
                
            default: return false
        }
    }

    public static func requestMicrophonePermissionIfNeeded(
        presentingViewController: UIViewController? = nil,
        onNotGranted: (() -> Void)? = nil
    ) {
        let handlePermissionDenied: () -> Void = {
            guard
                Singleton.hasAppContext,
                let presentingViewController: UIViewController = (presentingViewController ?? Singleton.appContext.frontmostViewController)
            else { return }
            onNotGranted?()
            
            let confirmationModal: ConfirmationModal = ConfirmationModal(
                info: ConfirmationModal.Info(
                    title: "permissionsRequired".localized(),
                    body: .text(
                        "permissionsMicrophoneAccessRequiredIos"
                            .put(key: "app_name", value: Constants.app_name)
                            .localized()
                    ),
                    confirmTitle: "sessionSettings".localized(),
                    dismissOnConfirm: false,
                    onConfirm: { [weak presentingViewController] _ in
                        presentingViewController?.dismiss(animated: true, completion: {
                            UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!)
                        })
                    },
                    afterClosed: { onNotGranted?() }
                )
            )
            presentingViewController.present(confirmationModal, animated: true, completion: nil)
        }
        
        if #available(iOS 17.0, *) {
            switch AVAudioApplication.shared.recordPermission {
                case .granted: break
                case .denied: handlePermissionDenied()
                case .undetermined:
                    onNotGranted?()
                    AVAudioApplication.requestRecordPermission { granted in
                        UserDefaults.sharedLokiProject?[.lastSeenHasMicrophonePermission] = granted
                    }
                default: break
            }
        } else {
            switch AVAudioSession.sharedInstance().recordPermission {
                case .granted: break
                case .denied: handlePermissionDenied()
                case .undetermined:
                    onNotGranted?()
                    AVAudioSession.sharedInstance().requestRecordPermission { granted in
                        UserDefaults.sharedLokiProject?[.lastSeenHasMicrophonePermission] = granted
                    }
                default: break
            }
        }
    }

    public static func requestLibraryPermissionIfNeeded(
        isSavingMedia: Bool,
        presentingViewController: UIViewController? = nil,
        onAuthorized: @escaping () -> Void
    ) {
        let targetPermission: PHAccessLevel = (isSavingMedia ? .addOnly : .readWrite)
        let authorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if authorizationStatus == .notDetermined {
            // When the user chooses to select photos (which is the .limit status),
            // the PHPhotoUI will present the picker view on the top of the front view.
            // Since we have the ScreenLockUI showing when we request premissions,
            // the picker view will be presented on the top of the ScreenLockUI.
            // However, the ScreenLockUI will dismiss with the permission request alert view, so
            // the picker view then will dismiss, too. The selection process cannot be finished
            // this way. So we add a flag (isRequestingPermission) to prevent the ScreenLockUI
            // from showing when we request the photo library permission.
            SessionEnvironment.shared?.isRequestingPermission = true
            
            PHPhotoLibrary.requestAuthorization(for: targetPermission) { status in
                SessionEnvironment.shared?.isRequestingPermission = false
                if [ PHAuthorizationStatus.authorized, PHAuthorizationStatus.limited ].contains(status) {
                    onAuthorized()
                }
            }
        }
        
        switch authorizationStatus {
            case .authorized, .limited: onAuthorized()
            case .denied, .restricted:
                guard
                    Singleton.hasAppContext,
                    let presentingViewController: UIViewController = (presentingViewController ?? Singleton.appContext.frontmostViewController)
                else { return }
                
                let confirmationModal: ConfirmationModal = ConfirmationModal(
                    info: ConfirmationModal.Info(
                        title: "permissionsRequired".localized(),
                        body: .text(
                            "permissionsLibrary"
                                .put(key: "app_name", value: Constants.app_name)
                                .localized()
                        ),
                        confirmTitle: "sessionSettings".localized(),
                        dismissOnConfirm: false
                    ) { [weak presentingViewController] _ in
                        presentingViewController?.dismiss(animated: true, completion: {
                            UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!)
                        })
                    }
                )
                presentingViewController.present(confirmationModal, animated: true, completion: nil)
                
            default: return
        }
    }
    
    public static func requestLocalNetworkPermissionIfNeeded() {
        checkLocalNetworkPermission()
    }
    
    public static func checkLocalNetworkPermission() {
        let connection = NWConnection(host: "192.168.1.1", port: 80, using: .tcp)
        connection.stateUpdateHandler = { newState in
            switch newState {
                case .ready:
                    UserDefaults.sharedLokiProject?[.lastSeenHasLocalNetworkPermission] = true
                    connection.cancel() // Stop connection since we only need permission status
                case .failed(let error):
                    switch error {
                        case .posix(let code):
                            if code.rawValue == 13 {
                                UserDefaults.sharedLokiProject?[.lastSeenHasLocalNetworkPermission] = false
                            }
                        default:
                            break
                    }
                default:
                    break
            }
        }
        connection.start(queue: .main)
    }
}
