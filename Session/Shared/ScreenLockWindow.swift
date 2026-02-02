// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import LocalAuthentication
import SessionUIKit
import SessionMessagingKit
import SessionUtilitiesKit

// MARK: - Singleton

public extension Singleton {
    static let screenLock: SingletonConfig<ScreenLockWindow> = Dependencies.create(
        identifier: "screenLock",
        createInstance: { dependencies, _ in ScreenLockWindow(using: dependencies) }
    )
}

/// Obscures the app screen:
///
/// * In the app switcher.
/// * During 'Screen Lock' unlock process.
public class ScreenLockWindow {
    private let dependencies: Dependencies
    
    /// Indicates whether or not the user is currently locked out of the app.  Should only be set if `db[.isScreenLockEnabled]`.
    ///
    /// * The user is locked out by default on app launch.
    /// * The user is also locked out if the app is sent to the background
    @ThreadSafe private var isScreenLockLocked: Bool = false
    
    private var isShowingScreenLockUI: Bool = false
    private var didUnlockJustSucceed: Bool = false
    private var didLastUnlockAttemptFail: Bool = false
    
    /// We want to remain in "screen lock" mode while "local auth" UI is dismissing. So we lazily clear isShowingScreenLockUI
    /// using this property.
    private var shouldClearAuthUIWhenActive: Bool = false
    
    // MARK: - UI
    
    @MainActor public lazy var window: UIWindow = {
        let result: UIWindow = UIWindow()
        result.isHidden = false
        result.windowLevel = .background
        result.isOpaque = true
        result.themeBackgroundColorForced = .theme(.classicDark, color: .backgroundPrimary)
        result.rootViewController = self.viewController
        
        return result
    }()
    
    private lazy var viewController: ScreenLockViewController = ScreenLockViewController { [weak self, dependencies] in
        guard dependencies[singleton: .appContext].isAppForegroundAndActive else {
            // This button can be pressed while the app is inactive
            // for a brief window while the iOS auth UI is dismissing.
            return
        }
        
        Log.info(.screenLock, "unlockButtonWasTapped")
        
        self?.didLastUnlockAttemptFail = false
        self?.ensureUI()
    }
    
    // MARK: - Lifecycle
    
    init(using dependencies: Dependencies) {
        self.dependencies = dependencies
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    // MARK: - Observations
    
    private func observeNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidBecomeActive),
            name: .sessionDidBecomeActive,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationWillResignActive),
            name: .sessionWillResignActive,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationWillEnterForeground),
            name: .sessionWillEnterForeground,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidEnterBackground),
            name: .sessionDidEnterBackground,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(clockDidChange),
            name: .NSSystemClockDidChange,
            object: nil
        )
    }
    
    @MainActor public func setupWithRootWindow(rootWindow: UIWindow) {
        self.window.frame = rootWindow.bounds
        self.observeNotifications()
        
        /// Hide the screen blocking window until "app is ready" to avoid blocking the loading view
        updateScreenBlockingWindow(state: .none, animated: false)
        
        /// Initialize the screen lock state.
        ///
        /// It's not safe to access `isScreenLockEnabled` in `storage` until the app is ready
        dependencies[singleton: .appReadiness].runNowOrWhenAppWillBecomeReady { [weak self, dependencies] in
            if dependencies[cache: .general].userExists {
                self?.isScreenLockLocked = dependencies.mutate(cache: .libSession, { $0.get(.isScreenLockEnabled) })
            }
            
            switch Thread.isMainThread {
                case true: self?.ensureUI()
                case false: DispatchQueue.main.async { self?.ensureUI() }
            }
        }
    }
    
    /// Checks if app has been unlocked
    public func checkIfScreenIsUnlocked() -> Bool { !isScreenLockLocked }
    
    // MARK: - Functions

    private func determineDesiredUIState() -> ScreenLockViewController.State {
        if isScreenLockLocked {
            if dependencies[singleton: .appContext].isNotInForeground {
                Log.verbose(.screenLock, "App not in foreground, desiredUIState is: protection.")
                return .protection
            }
            
            Log.verbose(.screenLock, "App in foreground and locked, desiredUIState is: \(isShowingScreenLockUI ? "protection" : "lock").")
            return (isShowingScreenLockUI ? .protection : .lock)
        }
        
        if dependencies[singleton: .appContext].isAppForegroundAndActive {
            // App is inactive or background.
            Log.verbose(.screenLock, "App in foreground and not locked, desiredUIState is: none.")
            return .none;
        }
        
        if SessionEnvironment.shared?.isRequestingPermission == true {
            Log.verbose(.screenLock, "App requesting permissions and not locked, desiredUIState is: none.")
            return .none;
        }
        
        Log.verbose(.screenLock, "desiredUIState is: protection.")
        return .protection;
    }
    
    private func tryToActivateScreenLockBasedOnCountdown() {
        guard dependencies[singleton: .appReadiness].isAppReady else {
            /// It's not safe to access `isScreenLockEnabled` in `storage` until the app is ready
            ///
            /// We don't need to try to lock the screen lock;
            /// It will be initialized by `setupWithRootWindow`
            Log.verbose(.screenLock, "tryToActivateScreenLockUponBecomingActive NO 0")
            return
        }
        guard dependencies.mutate(cache: .libSession, { $0.get(.isScreenLockEnabled) }) else {
            /// Screen lock is not enabled.
            Log.verbose(.screenLock, "tryToActivateScreenLockUponBecomingActive NO 1")
            return
        }
        guard !isScreenLockLocked else {
            /// Screen lock is already activated.
            Log.verbose(.screenLock, "tryToActivateScreenLockUponBecomingActive NO 2")
            return
        }
        
        self.isScreenLockLocked = true
    }
    
    /// Ensure that:
    ///
    /// * The blocking window has the correct state.
    /// * That we show the "iOS auth UI to unlock" if necessary.
    private func ensureUI() {
        guard dependencies[singleton: .appReadiness].isAppReady else {
            dependencies[singleton: .appReadiness].runNowOrWhenAppWillBecomeReady { [weak self] in
                self?.ensureUI()
            }
            return
        }
        
        let desiredUIState: ScreenLockViewController.State = determineDesiredUIState()
        Log.verbose(.screenLock, "ensureUI: \(desiredUIState)")
        
        /// Show the "iOS auth UI to unlock" if necessary.
        if desiredUIState == .lock && !didLastUnlockAttemptFail {
            tryToPresentAuthUIToUnlockScreenLock()
        }
        
        /// Note: We want to regenerate the `desiredUIState` as if we are about to show the "unlock screen" UI then we
        /// shouldn't show the "unlock" button
        updateScreenBlockingWindow(state: determineDesiredUIState(), animated: true)
    }

    private func tryToPresentAuthUIToUnlockScreenLock() {
        /// If we're already showing the auth UI; or the app isn't active then don't do anything
        guard
            !isShowingScreenLockUI,
            dependencies[singleton: .appContext].isAppForegroundAndActive
        else { return }
        
        Log.info(.screenLock, "Try to unlock screen lock")
        isShowingScreenLockUI = true
        
        ScreenLock.tryToUnlockScreenLock(
            localizedReason: "authenticateToOpen"
                .put(key: "app_name", value:  Constants.app_name)
                .localized(),
            errorMap: ScreenLockErrors.errorMap,
            defaultErrorDescription: ScreenLockErrors.defaultError,
            success: { [weak self] in
                Log.info(.screenLock, "Unlock screen lock succeeded")
                self?.isShowingScreenLockUI = false
                self?.isScreenLockLocked = false
                self?.didUnlockJustSucceed = true
                self?.ensureUI()
            },
            failure: { [weak self] error in
                Log.info(.screenLock, "Unlock screen lock failed")
                self?.clearAuthUIWhenActive()
                self?.didLastUnlockAttemptFail = true
                self?.showScreenLockFailureAlert(message: "\(error)")
            },
            unexpectedFailure: { [weak self] error in
                Log.warn(.screenLock, "Unlock screen lock unexpectedly failed")

                // Local Authentication isn't working properly.
                // This isn't covered by the docs or the forums but in practice
                // it appears to be effective to retry again after waiting a bit.
                DispatchQueue.main.async {
                    self?.clearAuthUIWhenActive()
                }
            },
            cancel: { [weak self] in
                Log.info(.screenLock, "Unlock screen lock cancelled")

                self?.clearAuthUIWhenActive()
                self?.didLastUnlockAttemptFail = true

                // Re-show the unlock UI
                self?.ensureUI()
            }
        )
        
        self.ensureUI()
    }

    private func showScreenLockFailureAlert(message: String) {
        let modal: ConfirmationModal = ConfirmationModal(
            targetView: viewController.view,
            info: ConfirmationModal.Info(
                title: "authenticateFailed".localized(),
                body: .text(message),
                cancelTitle: "okay".localized(),
                cancelStyle: .alert_text,
                afterClosed: { [weak self] in self?.ensureUI() } // After the alert, update the UI
            )
        )
        viewController.present(modal, animated: true)
    }

    /// The "screen blocking" window has three possible states:
    ///
    /// * "Just a logo".  Used when app is launching and in app switcher.  Must match the "Launch Screen" storyboard pixel-for-pixel.
    /// * "Screen Lock, local auth UI presented". Move the Signal logo so that it is visible.
    /// * "Screen Lock, local auth UI not presented". Move the Signal logo so that it is visible, show "unlock" button.
    private func updateScreenBlockingWindow(state: ScreenLockViewController.State, animated: Bool) {
        let shouldShowBlockWindow: Bool = (state != .none)
        
        OWSWindowManager.shared().isScreenBlockActive = shouldShowBlockWindow
        self.viewController.updateUI(state: state, animated: animated)
    }

    // MARK: - Events
    
    private func clearAuthUIWhenActive() {
        // For continuity, continue to present blocking screen in "screen lock" mode while
        // dismissing the "local auth UI".
        if !dependencies[singleton: .appContext].isAppForegroundAndActive {
            self.shouldClearAuthUIWhenActive = true
        }
        else {
            self.isShowingScreenLockUI = false
            self.ensureUI()
        }
    }

    @objc private func applicationDidBecomeActive() {
        if shouldClearAuthUIWhenActive {
            shouldClearAuthUIWhenActive = false
            isShowingScreenLockUI = false
        }

        if !didUnlockJustSucceed {
            tryToActivateScreenLockBasedOnCountdown()
        }

        didUnlockJustSucceed = false
        ensureUI()
    }

    /// When the OS shows the TouchID/FaceID/Pin UI the application will resign active (and we don't want to re-authenticate if we are
    /// already locked)
    ///
    /// Secondly, we need to show the screen protection _before_ we become inactive in order for it to be reflected in the app switcher
    @objc private func applicationWillResignActive() {
        if !isShowingScreenLockUI {
            didLastUnlockAttemptFail = false
            tryToActivateScreenLockBasedOnCountdown()
        }
        
        didUnlockJustSucceed = false
        ensureUI()
    }

    @objc private func applicationWillEnterForeground() {
        didUnlockJustSucceed = false
        tryToActivateScreenLockBasedOnCountdown()
        ensureUI()
    }

    @objc private func applicationDidEnterBackground() {
        didUnlockJustSucceed = false
        tryToActivateScreenLockBasedOnCountdown()
        ensureUI()
    }

    /// Whenever the device date/time is edited by the user, trigger screen lock immediately if enabled.
    @objc private func clockDidChange() {
        Log.info(.screenLock, "clock did change")

        guard dependencies[singleton: .appReadiness].isAppReady == true else {
            // It's not safe to access OWSScreenLock.isScreenLockEnabled
            // until the app is ready.
            //
            // We don't need to try to lock the screen lock;
            // It will be initialized by `setupWithRootWindow`.
            Log.verbose(.screenLock, "clockDidChange 0")
            return;
        }
        
        DispatchQueue.global(qos: .background).async { [dependencies] in
            self.isScreenLockLocked = dependencies.mutate(cache: .libSession, { $0.get(.playNotificationSoundInForeground) })

            DispatchQueue.main.async {
                // NOTE: this notifications fires _before_ applicationDidBecomeActive,
                // which is desirable.  Don't assume that though; call ensureUI
                // just in case it's necessary.
                self.ensureUI()
            }
        }
    }
}
