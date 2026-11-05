// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import SessionUIKit
import SessionUtilitiesKit

final class MainAppContext: AppContext {
    private let dependencies: Dependencies
    var reportedApplicationState: UIApplication.State
    
    var appLaunchTime: Date = Date()
    let isMainApp: Bool = true
    @MainActor var isMainAppAndForeground: Bool {
        UIApplication.shared.connectedScenes.contains(where: {
            $0.activationState == .foregroundActive ||
            $0.activationState == .foregroundInactive
        })
    }
    @MainActor var frontMostViewController: UIViewController? {
        UIApplication.shared.frontMostViewController(ignoringAlerts: true, using: dependencies)
    }
    
    var mainWindow: UIWindow?
    var wasWokenUpByPushNotification: Bool = false
    private let mainAppLeaseRenewalInterval: TimeInterval
    private var mainAppLeaseTimer: Timer?
    
    @MainActor var statusBarHeight: CGFloat { UIApplication.shared.statusBarFrame.size.height }
    var openSystemSettingsAction: UIAlertAction? {
        let result = UIAlertAction(
            title: "sessionSettings".localized(),
            style: .default
        ) { _ in UIApplication.shared.openSystemSettings() }
        result.accessibilityIdentifier = "\(type(of: self)).system_settings"
        
        return result
    }
    
    static func determineDeviceRTL() -> Bool {
        return (UIApplication.shared.userInterfaceLayoutDirection == .rightToLeft)
    }
    
    // MARK: - Initialization

    /// - Parameter initialApplicationState: The state at launch - a launch straight into the background never posts
    ///   `didEnterBackgroundNotification`, so the observers below can't be relied on to establish it
    init(
        initialApplicationState: UIApplication.State,
        mainAppLeaseRenewalInterval: TimeInterval = MainAppLease.renewalInterval,
        using dependencies: Dependencies
    ) {
        self.dependencies = dependencies
        self.reportedApplicationState = initialApplicationState
        self.mainAppLeaseRenewalInterval = mainAppLeaseRenewalInterval
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationWillEnterForeground(notification:)),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidEnterBackground(notification:)),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationWillResignActive(notification:)),
            name: UIApplication.willResignActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidBecomeActive(notification:)),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationWillTerminate(notification:)),
            name: UIApplication.willTerminateNotification,
            object: nil
        )
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    // MARK: - Notifications
    
    @objc private func applicationWillEnterForeground(notification: NSNotification) {
        Log.assertOnMainThread()

        self.reportedApplicationState = .inactive

        NotificationCenter.default.post(
            name: .sessionWillEnterForeground,
            object: nil
        )
    }

    @objc private func applicationDidEnterBackground(notification: NSNotification) {
        Log.assertOnMainThread()
        
        self.reportedApplicationState = .background
        endMainAppLease(reason: "entered background")

        NotificationCenter.default.post(
            name: .sessionDidEnterBackground,
            object: nil
        )
    }

    /// This fires for any interruption (eg. Control Center, system alerts, permission prompts, CallKit) while the app stays on screen,
    /// so it changes neither `reportedApplicationState` nor the main app lease - ending the lease here would let the notification
    /// extension post notifications for messages the app is already showing
    @objc private func applicationWillResignActive(notification: NSNotification) {
        Log.assertOnMainThread()

        NotificationCenter.default.post(
            name: .sessionWillResignActive,
            object: nil
        )
    }

    @objc private func applicationDidBecomeActive(notification: NSNotification) {
        Log.assertOnMainThread()

        self.reportedApplicationState = .active
        startMainAppLease()

        NotificationCenter.default.post(
            name: .sessionDidBecomeActive,
            object: nil
        )
    }
    
    @objc private func applicationWillTerminate(notification: NSNotification) {
        Log.assertOnMainThread()
        
        endMainAppLease(reason: "terminating")
    }
    
    // MARK: - Main App Lease
    
    private func startMainAppLease() {
        mainAppLeaseTimer?.invalidate()
        
        let until: Date = dependencies.renewMainAppLease()
        Log.info(.appContext, "Main app lease started, \(MainAppLease.state(until: until, now: dependencies.dateNow)).")
        
        /// The timer is deliberately scheduled on the main run loop: if the main thread hangs the app can't respond to anything, so
        /// renewals need to stop and let the lease lapse so the notification extension starts handling pushes again. The `common`
        /// mode keeps it firing while the user is scrolling
        let timer: Timer = Timer(timeInterval: mainAppLeaseRenewalInterval, repeats: true) { [dependencies] _ in
            dependencies.renewMainAppLease()
        }
        timer.tolerance = (mainAppLeaseRenewalInterval / 6)
        RunLoop.main.add(timer, forMode: .common)
        mainAppLeaseTimer = timer
    }
    
    private func endMainAppLease(reason: String) {
        mainAppLeaseTimer?.invalidate()
        mainAppLeaseTimer = nil
        dependencies.endMainAppLease()
        Log.info(.appContext, "Main app lease ended (\(reason)).")
    }
    
    // MARK: - AppContext Functions
    
    @MainActor func setMainWindow(_ mainWindow: UIWindow) {
        self.mainWindow = mainWindow
        
        // Store in SessionUIKit to avoid needing the SessionUtilitiesKit dependency
        SNUIKit.setMainWindow(mainWindow)
    }
    
    func beginBackgroundTask(expirationHandler: @escaping () -> Void) -> UIBackgroundTaskIdentifier {
        return UIApplication.shared.beginBackgroundTask(expirationHandler: expirationHandler)
    }
    
    func endBackgroundTask(_ backgroundTaskIdentifier: UIBackgroundTaskIdentifier) {
        UIApplication.shared.endBackgroundTask(backgroundTaskIdentifier)
    }
    
    // stringlint:ignore_contents
    func ensureSleepBlocking(_ shouldBeBlocking: Bool, blockingObjects: [Any]) {
        guard Thread.isMainThread else {
            return DispatchQueue.main.async { [weak self] in
                self?.ensureSleepBlocking(shouldBeBlocking, blockingObjects: blockingObjects)
            }
        }
        
        if UIApplication.shared.isIdleTimerDisabled != shouldBeBlocking {
            if shouldBeBlocking {
                var logString: String = "Blocking sleep because of: \(String(describing: blockingObjects.first))"
                
                if blockingObjects.count > 1 {
                    logString = "\(logString) (and \(blockingObjects.count - 1) others)"
                }
                Log.info(.appContext, logString)
            }
            else {
                Log.info(.appContext, "Unblocking Sleep.")
            }
        }
        UIApplication.shared.isIdleTimerDisabled = shouldBeBlocking
    }
    
    func openUrl(_ url: URL) {
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
    }
}
