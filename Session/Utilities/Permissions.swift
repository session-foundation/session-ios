// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import Photos
import PhotosUI
import AVFAudio
import SessionUIKit
import SessionUtilitiesKit
import SessionMessagingKit
import Network

// MARK: - Log.Category

private extension Log.Category {
    static let cat: Log.Category = .create("Permissions", defaultLevel: .off)
}

// MARK: - Permissions

extension Permissions {
    @MainActor @discardableResult public static func requestCameraPermissionIfNeeded(
        presentingViewController: UIViewController? = nil,
        useCustomDeniedAlert: Bool = false,
        using dependencies: Dependencies,
        onAuthorized: ((Bool) -> Void)? = nil
    ) -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized:
                onAuthorized?(true)
                return true
            
            case .denied, .restricted:
                guard
                    let presentingViewController: UIViewController = (presentingViewController ?? dependencies[singleton: .appContext].frontMostViewController),
                    !useCustomDeniedAlert
                else {
                    onAuthorized?(false)
                    return false
                }
                
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
                AVCaptureDevice.requestAccess(for: .video, completionHandler: { granted in
                    onAuthorized?(granted)
                })
                return false
                
            default: return false
        }
    }

    @MainActor public static func requestMicrophonePermissionIfNeeded(
        presentingViewController: UIViewController? = nil,
        using dependencies: Dependencies,
        onAuthorized: ((Bool) -> Void)? = nil,
        onNotGranted: (() -> Void)? = nil
    ) {
        let handlePermissionDenied: () -> Void = {
            guard
                let presentingViewController: UIViewController = (presentingViewController ?? dependencies[singleton: .appContext].frontMostViewController)
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
                        dependencies[defaults: .appGroup, key: .lastSeenHasMicrophonePermission] = granted
                        onAuthorized?(granted)
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
                        dependencies[defaults: .appGroup, key: .lastSeenHasMicrophonePermission] = granted
                        onAuthorized?(granted)
                    }
                default: break
            }
        }
    }

    @MainActor public static func requestLibraryPermissionIfNeeded(
        isSavingMedia: Bool,
        presentingViewController: UIViewController? = nil,
        using dependencies: Dependencies,
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
                    let presentingViewController: UIViewController = (presentingViewController ?? dependencies[singleton: .appContext].frontMostViewController)
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
    
    // MARK: - Local Network Premission
    
    public static func localNetwork(using dependencies: Dependencies) -> Status {
        let status: Bool = dependencies.mutate(cache: .libSession, { $0.get(.lastSeenHasLocalNetworkPermission) })
        return status ? .granted : .denied
    }
    
    public static func requestLocalNetworkPermissionIfNeeded(using dependencies: Dependencies) {
        dependencies[defaults: .standard, key: .hasRequestedLocalNetworkPermission] = true
        checkLocalNetworkPermission(using: dependencies)
    }
    
    public static func checkLocalNetworkPermission(using dependencies: Dependencies) {
        Task {
            do {
                if try await checkLocalNetworkPermissionWithBonjour() {
                    // Permission is granted, continue to next onboarding step
                    dependencies.setAsync(.lastSeenHasLocalNetworkPermission, true)
                } else {
                    // Permission denied, explain why we need it and show button to open Settings
                    dependencies.setAsync(.lastSeenHasLocalNetworkPermission, false)
                }
            } catch {
                // Networking failure, handle error
            }
        }
    }
    
    public static func checkLocalNetworkPermissionWithBonjour() async throws -> Bool {
        let type = "_session_local_network_access_check._tcp" // stringlint:ignore
        let queue = DispatchQueue(label: "localNetworkAuthCheck")

        let listener = try NWListener(using: NWParameters(tls: .none, tcp: NWProtocolTCP.Options()))
        listener.service = NWListener.Service(name: UUID().uuidString, type: type)
        listener.newConnectionHandler = { _ in } // Must be set or else the listener will error with POSIX error 22

        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: type, domain: nil), using: parameters)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
                class LocalState {
                    var didResume = false
                }
                let local = LocalState()
                @Sendable func resume(with result: Result<Bool, Error>) {
                    if local.didResume {
                        Log.debug(.cat, "Already resumed, ignoring subsequent result.")
                        return
                    }
                    local.didResume = true

                    // Teardown listener and browser
                    listener.stateUpdateHandler = { _ in }
                    browser.stateUpdateHandler = { _ in }
                    browser.browseResultsChangedHandler = { _, _ in }
                    listener.cancel()
                    browser.cancel()

                    continuation.resume(with: result)
                }

                // Do not setup listener/browser is we're already cancelled, it does work but logs a lot of very ugly errors
                if Task.isCancelled {
                    resume(with: .failure(CancellationError()))
                    return
                }

                listener.stateUpdateHandler = { newState in
                    switch newState {
                        case .setup:
                            Log.debug(.cat, "Listener performing setup.")
                        case .ready:
                            Log.debug(.cat, "Listener ready to be discovered.")
                        case .cancelled:
                            Log.debug(.cat, "Listener cancelled.")
                            resume(with: .failure(CancellationError()))
                        case .failed(let error):
                            Log.debug(.cat, "Listener failed, stopping. \(error)")
                            resume(with: .failure(error))
                        case .waiting(let error):
                            Log.debug(.cat, "Listener waiting, stopping. \(error)")
                            resume(with: .failure(error))
                        @unknown default:
                            Log.debug(.cat, "Ignoring unknown listener state: \(String(describing: newState))")
                    }
                }
                listener.start(queue: queue)

                browser.stateUpdateHandler = { newState in
                    switch newState {
                        case .setup:
                            Log.debug(.cat, "Browser performing setup.")
                            return
                        case .ready:
                            Log.debug(.cat, "Browser ready to discover listeners.")
                            return
                        case .cancelled:
                            Log.debug(.cat, "Browser cancelled.")
                            resume(with: .failure(CancellationError()))
                        case .failed(let error):
                            Log.debug(.cat, "Browser failed, stopping. \(error)")
                            resume(with: .failure(error))
                        case let .waiting(error):
                            switch error {
                                case .dns(DNSServiceErrorType(kDNSServiceErr_PolicyDenied)):
                                    Log.debug(.cat, "Browser permission denied, reporting failure.")
                                    resume(with: .success(false))
                                default:
                                    Log.debug(.cat, "Browser waiting, stopping. \(error)")
                                    resume(with: .failure(error))
                                }
                        @unknown default:
                            Log.debug(.cat, "Ignoring unknown browser state: \(String(describing: newState))")
                            return
                    }
                }

                browser.browseResultsChangedHandler = { results, changes in
                    if results.isEmpty {
                        Log.debug(.cat, "Got empty result set from browser, ignoring.")
                        return
                    }

                    Log.debug(.cat, "Discovered \(results.count) listeners, reporting success.")
                    resume(with: .success(true))
                }
                browser.start(queue: queue)

                // Task cancelled while setting up listener & browser, tear down immediatly
                if Task.isCancelled {
                    Log.debug(.cat, "Task cancelled during listener & browser start. (Some warnings might be logged by the listener or browser.)")
                    resume(with: .failure(CancellationError()))
                    return
                }
            }
        } onCancel: {
            listener.cancel()
            browser.cancel()
        }
    }
    
    public static func requestPermissionsForCalls(
        presentingViewController: UIViewController? = nil,
        using dependencies: Dependencies
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            requestMicrophonePermissionIfNeeded(
                presentingViewController: presentingViewController,
                using: dependencies,
                onAuthorized: { _ in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                        requestCameraPermissionIfNeeded(
                            presentingViewController: presentingViewController,
                            using: dependencies,
                            onAuthorized: { _ in
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                                    requestLocalNetworkPermissionIfNeeded(using: dependencies)
                                }
                            }
                        )
                    }
                }
            )
        }
    }
    
    // MARK: - Custom camera permission request dialog
    public static func remindCameraAccessRequirement(using dependencies: Dependencies) {
        /*
         Only show when the folliwing conditions are true
         - Remind me later is tapped when trying to enable camera on calls
         - Not in background state
         - Camera permission is not yet allowed
         */
        guard
            dependencies[defaults: .standard, key: .shouldRemindGrantingCameraPermissionForCalls],
            !dependencies[singleton: .appContext].isInBackground,
            Permissions.camera == .denied
        else {
            return
        }
        
        DispatchQueue.main.async { [dependencies] in
            guard let controller = dependencies[singleton: .appContext].frontMostViewController else {
                return
            }
            
            dependencies[defaults: .standard, key: .shouldRemindGrantingCameraPermissionForCalls] = false
            
            let confirmationModal: ConfirmationModal = ConfirmationModal(
                info: ConfirmationModal.Info(
                    title: "enableCameraAccess".localized(),
                    body: .text(
                        "cameraAccessReminderMessage".localized(),
                        scrollMode: .never
                    ),
                    confirmTitle: "openSettings".localized(),
                    onConfirm: { _ in UIApplication.shared.openSystemSettings() }
                )
            )
            controller.present(confirmationModal, animated: true, completion: nil)
        }
    }
    
    public static func showEnableCameraAccessInstructions(using dependencies: Dependencies) {
        DispatchQueue.main.async {
            guard let controller = dependencies[singleton: .appContext].frontMostViewController
            else { return }
            
            let confirmationModal: ConfirmationModal = ConfirmationModal(
                info: ConfirmationModal.Info(
                    title: "enableCameraAccess".localized(),
                    body: .text("cameraAccessInstructions"
                            .localized()),
                    confirmTitle: "openSettings".localized(),
                    onConfirm: { _ in UIApplication.shared.openSystemSettings() }
                )
            )
            controller.present(confirmationModal, animated: true, completion: nil)
        }
    }
}

