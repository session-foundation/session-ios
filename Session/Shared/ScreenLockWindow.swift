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

// MARK: - Window Levels

extension UIWindow.Level {
    /// Behind everything, especially the root window.
    static let background = UIWindow.Level(-1)

    /// In front of the status bar and CallView.
    static var screenBlocking: UIWindow.Level {
        UIWindow.Level(UIWindow.Level.statusBar.rawValue + 2)
    }
}

// MARK: - Notification

extension Notification.Name {
    static let isScreenBlockActiveDidChange = Notification.Name("IsScreenBlockActiveDidChangeNotification")
}

/// Obscures the app screen:
///
/// * In the app switcher.
/// * During 'Screen Lock' unlock process.
public class ScreenLockWindow {
    private let dependencies: Dependencies
    private weak var rootWindow: UIWindow?
    
    /// Indicates whether or not the user is currently locked out of the app.  Should only be set if `db[.isScreenLockEnabled]`.
    ///
    /// * The user is locked out by default on app launch.
    /// * The user is also locked out if the app is sent to the background
    @ThreadSafe private var isScreenLockLocked: Bool = false
    
    /// Set while the Face ID / Touch ID / passcode sheet is presented - keeps the overlay in `.protection` (logo only, no unlock
    /// button) so it doesn't flash behind the system auth sheet
    private var isShowingScreenLockUI: Bool = false
    
    /// Prevents re-locking immediately after a successful unlock on `didBecomeActive`
    private var didUnlockJustSucceed: Bool = false
    
    /// Prevents auto-retrying auth after the user has already failed or cancelled
    private var didLastUnlockAttemptFail: Bool = false
    
    /// Lazily clears `isShowingScreenLockUI` once the app becomes active again (the system auth sheet keeps the app inactive
    /// while it's dismissing)
    private var shouldClearAuthUIWhenActive: Bool = false
    
    /// Whether the screen block is currently active - manipulates window levels rather than hiding/showing to avoid bad frames
    @MainActor private var isScreenBlockActive: Bool = false {
        didSet {
            guard oldValue != isScreenBlockActive else { return }
            
            if isScreenBlockActive {
                rootWindow?.isHidden = true
                window.windowLevel = .screenBlocking
                window.makeKeyAndVisible()
            }
            else {
                rootWindow?.makeKeyAndVisible()
                
                /// Defer lowering the block window by one run loop so the root window has time to render its content before it's
                /// uncovered. Without this, both changes land in the same CA transaction and the block window moves behind
                /// before the root window has committed its first frame, producing a black screen.
                DispatchQueue.main.async { [weak self] in
                    self?.window.windowLevel = .background
                }
            }
            
            NotificationCenter.default.post(name: .isScreenBlockActiveDidChange, object: nil)
        }
    }
    
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
        self?.updateUI()
    }
    
    // MARK: - Lifecycle
    
    init(using dependencies: Dependencies) {
        self.dependencies = dependencies
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    // MARK: - Observations
    
    @MainActor public func setupWithRootWindow(rootWindow: UIWindow) {
        self.rootWindow = rootWindow
        self.window.windowScene = rootWindow.windowScene
        self.window.frame = rootWindow.bounds
        
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
        
        /// Hide the screen blocking window until "app is ready" to avoid blocking the loading view
        updateScreenBlockingWindow(state: .none, animated: false)
        
        /// Initialize the screen lock state.
        ///
        /// It's not safe to access `isScreenLockEnabled` in `storage` until the app is ready
        dependencies[singleton: .appReadiness].runNowOrWhenAppWillBecomeReady { [weak self, dependencies] in
            if dependencies[cache: .general].userExists {
                self?.isScreenLockLocked = dependencies.mutate(cache: .libSession, { $0.get(.isScreenLockEnabled) })
            }
            
            DispatchQueue.main.async { self?.updateUI() }
        }
    }
    
    /// Checks if app has been unlocked
    public func checkIfScreenIsUnlocked() -> Bool { !isScreenLockLocked }
    
    // MARK: - Functions

    private func desiredState() -> ScreenLockViewController.State {
        guard dependencies[singleton: .appContext].isAppForegroundAndActive else {
            Log.verbose(.screenLock, "App not in foreground, desiredUIState is: protection.")
            return .protection
        }
        guard isScreenLockLocked else {
            Log.verbose(.screenLock, "App in foreground and not locked, desiredUIState is: none.")
            return .none
        }
        
        /// Keep protection (no unlock button) while the system auth sheet is visible, since that sheet makes the app .inactive and we
        /// don't want the button to flash
        Log.verbose(.screenLock, "App in foreground and locked, desiredUIState is: \(isShowingScreenLockUI ? "protection" : "lock").")
        return (isShowingScreenLockUI ? .protection : .lock)
    }
    
    @MainActor public func updateUI() {
        guard dependencies[singleton: .appReadiness].syncState.isReady else {
            dependencies[singleton: .appReadiness].runNowOrWhenAppWillBecomeReady { [weak self] in
                DispatchQueue.main.async { self?.updateUI() }
            }
            return
        }
        
        _updateUI(animated: true)
    }
    
    /// Ensure that:
    ///
    /// * The blocking window has the correct state.
    /// * That we show the "iOS auth UI to unlock" if necessary.
    @MainActor public func forceEnsureUI(
        resetLockedState: Bool = false,
        animated: Bool
    ) {
        if resetLockedState && dependencies[cache: .general].userExists {
            isScreenLockLocked = dependencies.mutate(cache: .libSession, { $0.get(.isScreenLockEnabled) })
        }
        _updateUI(animated: animated)
    }
    
    @MainActor private func _updateUI(animated: Bool) {
        let state: ScreenLockViewController.State = desiredState()
        Log.verbose(.screenLock, "_updateUI: \(state)")
        
        /// Show the "iOS auth UI to unlock" if necessary.
        if state == .lock && !didLastUnlockAttemptFail {
            tryToPresentAuthUI()
        }
        
        /// Note: We want to regenerate the `state` as if we are about to show the "unlock screen" UI then we shouldn't show the "unlock" button
        updateScreenBlockingWindow(state: desiredState(), animated: animated)
    }
    
    /// The "screen blocking" window has three possible states:
    ///
    /// * "Just a logo".  Used when app is launching and in app switcher.  Must match the "Launch Screen" storyboard pixel-for-pixel.
    /// * "Screen Lock, local auth UI presented". Move the Signal logo so that it is visible.
    /// * "Screen Lock, local auth UI not presented". Move the Signal logo so that it is visible, show "unlock" button.
    @MainActor private func updateScreenBlockingWindow(state: ScreenLockViewController.State, animated: Bool) {
        isScreenBlockActive = (state != .none)
        self.viewController.updateUI(state: state, animated: animated)
    }
    
    // MARK: - Authentication
    
    @MainActor private func tryToPresentAuthUI() {
        /// If we're already showing the auth UI; or the app isn't active then don't do anything
        guard
            !isShowingScreenLockUI,
            dependencies[singleton: .appContext].isAppForegroundAndActive
        else { return }
        
        Log.info(.screenLock, "Presenting auth UI")
        isShowingScreenLockUI = true
        
        ScreenLock.tryToUnlockScreenLock(
            localizedReason: "authenticateToOpen"
                .put(key: "app_name", value:  Constants.app_name)
                .localized(),
            errorMap: ScreenLockErrors.errorMap,
            defaultErrorDescription: ScreenLockErrors.defaultError,
            success: { [weak self] in
                Log.info(.screenLock, "Auth succeeded")
                self?.isShowingScreenLockUI = false
                self?.isScreenLockLocked = false
                self?.didUnlockJustSucceed = true
                self?.updateUI()
            },
            failure: { [weak self] error in
                Log.info(.screenLock, "Auth failed")
                self?.clearAuthUIWhenActive()
                self?.didLastUnlockAttemptFail = true
                self?.showAuthFailureAlert(message: "\(error)")
            },
            unexpectedFailure: { [weak self] error in
                Log.warn(.screenLock, "Auth unexpectedly failed")

                // Local Authentication isn't working properly.
                // This isn't covered by the docs or the forums but in practice
                // it appears to be effective to retry again after waiting a bit.
                DispatchQueue.main.async {
                    self?.clearAuthUIWhenActive()
                }
            },
            cancel: { [weak self] in
                Log.info(.screenLock, "Auth cancelled")

                self?.clearAuthUIWhenActive()
                self?.didLastUnlockAttemptFail = true

                // Re-show the unlock UI
                self?.updateUI()
            }
        )
        
        /// Show protection immediately so the button disappears while the sheet is up
        updateScreenBlockingWindow(state: .protection, animated: true)
    }

    @MainActor private func showAuthFailureAlert(message: String) {
        let modal: ConfirmationModal = ConfirmationModal(
            targetView: viewController.view,
            info: ConfirmationModal.Info(
                title: "authenticateFailed".localized(),
                body: .text(message),
                cancelTitle: "okay".localized(),
                cancelStyle: .alert_text,
                afterClosed: { [weak self] in
                    /// After the alert, update the UI
                    DispatchQueue.main.async {
                        self?.updateUI()
                    }
                }
            )
        )
        viewController.present(modal, animated: true)
    }

    @MainActor private func clearAuthUIWhenActive() {
        // For continuity, continue to present blocking screen in "screen lock" mode while
        // dismissing the "local auth UI".
        if dependencies[singleton: .appContext].isAppForegroundAndActive {
            self.isShowingScreenLockUI = false
            self.updateUI()
        }
        else {
            self.shouldClearAuthUIWhenActive = true
        }
    }
    
    // MARK: - Screen Lock Activation
    
    private func tryToActivateScreenLock() {
        guard dependencies[singleton: .appReadiness].syncState.isReady else {
            /// It's not safe to access `isScreenLockEnabled` in `storage` until the app is ready
            ///
            /// We don't need to try to lock the screen lock;
            /// It will be initialized by `setupWithRootWindow`
            Log.verbose(.screenLock, "tryToActivateScreenLock: app not ready, skipping")
            return
        }
        guard dependencies.mutate(cache: .libSession, { $0.get(.isScreenLockEnabled) }) else {
            /// Screen lock is not enabled.
            Log.verbose(.screenLock, "tryToActivateScreenLock: screen lock disabled, skipping")
            return
        }
        guard !isScreenLockLocked else {
            /// Screen lock is already activated.
            Log.verbose(.screenLock, "tryToActivateScreenLock: already locked, skipping")
            return
        }
        
        Log.verbose(.screenLock, "tryToActivateScreenLock: locking")
        self.isScreenLockLocked = true
    }
    
    // MARK: - App Lifecycle

    /// When the OS shows the TouchID/FaceID/Pin UI the application will resign active (and we don't want to re-authenticate if we are
    /// already locked)
    ///
    /// Secondly, we need to show the screen protection _before_ we become inactive in order for it to be reflected in the app switcher
    @MainActor @objc private func applicationWillResignActive() {
        if !isShowingScreenLockUI {
            didLastUnlockAttemptFail = false
            tryToActivateScreenLock()
        }
        
        didUnlockJustSucceed = false
        updateScreenBlockingWindow(state: .protection, animated: false)
        
        /// Force CA to commit the window changes to the render server immediately, before the app switcher takes its snapshot
        CATransaction.flush()
    }
    
    @MainActor @objc private func applicationDidEnterBackground() {
        updateScreenBlockingWindow(state: .protection, animated: false)
        
        /// Force CA to commit the window changes to the render server immediately, before the app switcher takes its snapshot
        CATransaction.flush()
    }
    
    @MainActor @objc private func applicationDidBecomeActive() {
        if shouldClearAuthUIWhenActive {
            shouldClearAuthUIWhenActive = false
            isShowingScreenLockUI = false
        }

        if !didUnlockJustSucceed {
            tryToActivateScreenLock()
        }

        didUnlockJustSucceed = false
        updateUI()
    }

    /// Whenever the device date/time is edited by the user, trigger screen lock immediately if enabled.
    @objc private func clockDidChange() {
        Log.info(.screenLock, "clock did change")

        guard dependencies[singleton: .appReadiness].syncState.isReady else {
            // It's not safe to access OWSScreenLock.isScreenLockEnabled
            // until the app is ready.
            //
            // We don't need to try to lock the screen lock;
            // It will be initialized by `setupWithRootWindow`.
            Log.verbose(.screenLock, "clockDidChange 0")
            return;
        }
        
        DispatchQueue.global(qos: .background).async { [weak self, dependencies] in
            self?.isScreenLockLocked = dependencies.mutate(cache: .libSession, {
                $0.get(.isScreenLockEnabled)
            })

            DispatchQueue.main.async {
                // NOTE: this notifications fires _before_ applicationDidBecomeActive,
                // which is desirable.  Don't assume that though; call ensureUI
                // just in case it's necessary.
                self?.updateUI()
            }
        }
    }
}
