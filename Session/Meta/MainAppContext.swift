// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import SessionUIKit
import SessionUtilitiesKit

final class MainAppContext: AppContext {
    private let dependencies: Dependencies
    var reportedApplicationState: UIApplication.State
    
    var appLaunchTime: Date = Date()
    let isMainApp: Bool = true
    @MainActor var isMainAppAndActive: Bool { UIApplication.shared.applicationState == .active }
    @MainActor var frontMostViewController: UIViewController? {
        UIApplication.shared.frontMostViewController(ignoringAlerts: true, using: dependencies)
    }
    @MainActor var backgroundTimeRemaining: TimeInterval { UIApplication.shared.backgroundTimeRemaining }
    
    var mainWindow: UIWindow?
    var wasWokenUpByPushNotification: Bool = false
    
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

    init(using dependencies: Dependencies) {
        self.dependencies = dependencies
        self.reportedApplicationState = .inactive
        
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

        NotificationCenter.default.post(
            name: .sessionDidEnterBackground,
            object: nil
        )
    }

    @objc private func applicationWillResignActive(notification: NSNotification) {
        Log.assertOnMainThread()

        self.reportedApplicationState = .inactive

        NotificationCenter.default.post(
            name: .sessionWillResignActive,
            object: nil
        )
    }

    @objc private func applicationDidBecomeActive(notification: NSNotification) {
        Log.assertOnMainThread()

        self.reportedApplicationState = .active

        NotificationCenter.default.post(
            name: .sessionDidBecomeActive,
            object: nil
        )
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
                Log.info(logString)
            }
            else {
                Log.info("Unblocking Sleep.")
            }
        }
        UIApplication.shared.isIdleTimerDisabled = shouldBeBlocking
    }
    
    func openUrl(_ url: URL) {
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
    }
}
