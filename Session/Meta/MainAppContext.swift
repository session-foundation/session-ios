// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import SignalCoreKit
import SessionUtilitiesKit

final class MainAppContext: NSObject, AppContext {
    var reportedApplicationState: UIApplication.State
    
    let appLaunchTime = Date()
    let isMainApp: Bool = true
    var isMainAppAndActive: Bool { UIApplication.shared.applicationState == .active }
    var isShareExtension: Bool = false
    var appActiveBlocks: [AppActiveBlock] = []
    
    var mainWindow: UIWindow?
    var wasWokenUpByPushNotification: Bool = false
    
    private static var _isRTL: Bool = {
        return (UIApplication.shared.userInterfaceLayoutDirection == .rightToLeft)
    }()
    
    var isRTL: Bool { return MainAppContext._isRTL }
    
    var statusBarHeight: CGFloat { UIApplication.shared.statusBarFrame.size.height }
    var openSystemSettingsAction: UIAlertAction? {
        let result = UIAlertAction(
            title: "OPEN_SETTINGS_BUTTON".localized(),
            style: .default
        ) { _ in UIApplication.shared.openSystemSettings() }
        result.accessibilityIdentifier = "\(type(of: self)).system_settings"
        
        return result
    }
    
    // MARK: - Initialization

    override init() {
        self.reportedApplicationState = .inactive
        
        super.init()
        
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
        AssertIsOnMainThread()

        self.reportedApplicationState = .inactive
        OWSLogger.info("")

        NotificationCenter.default.post(
            name: .OWSApplicationWillEnterForeground,
            object: nil
        )
    }

    @objc private func applicationDidEnterBackground(notification: NSNotification) {
        AssertIsOnMainThread()
        
        self.reportedApplicationState = .background

        OWSLogger.info("")
        DDLog.flushLog()
        
        NotificationCenter.default.post(
            name: .OWSApplicationDidEnterBackground,
            object: nil
        )
    }

    @objc private func applicationWillResignActive(notification: NSNotification) {
        AssertIsOnMainThread()

        self.reportedApplicationState = .inactive

        OWSLogger.info("")
        DDLog.flushLog()

        NotificationCenter.default.post(
            name: .OWSApplicationWillResignActive,
            object: nil
        )
    }

    @objc private func applicationDidBecomeActive(notification: NSNotification) {
        AssertIsOnMainThread()

        self.reportedApplicationState = .active

        OWSLogger.info("")

        NotificationCenter.default.post(
            name: .OWSApplicationDidBecomeActive,
            object: nil
        )

        self.runAppActiveBlocks()
    }

    @objc private func applicationWillTerminate(notification: NSNotification) {
        AssertIsOnMainThread()

        OWSLogger.info("")
        DDLog.flushLog()
    }
    
    // MARK: - AppContext Functions
    
    func setStatusBarHidden(_ isHidden: Bool, animated isAnimated: Bool) {
        UIApplication.shared.setStatusBarHidden(isHidden, with: (isAnimated ? .slide : .none))
    }
    
    func isAppForegroundAndActive() -> Bool {
        return (reportedApplicationState == .active)
    }
    
    func isInBackground() -> Bool {
        return (reportedApplicationState == .background)
    }
    
    func beginBackgroundTask(expirationHandler: @escaping BackgroundTaskExpirationHandler) -> UIBackgroundTaskIdentifier {
        return UIApplication.shared.beginBackgroundTask(expirationHandler: expirationHandler)
    }
    
    func endBackgroundTask(_ backgroundTaskIdentifier: UIBackgroundTaskIdentifier) {
        UIApplication.shared.endBackgroundTask(backgroundTaskIdentifier)
    }
        
    func ensureSleepBlocking(_ shouldBeBlocking: Bool, blockingObjects: [Any]) {
        if UIApplication.shared.isIdleTimerDisabled != shouldBeBlocking {
            if shouldBeBlocking {
                var logString: String = "Blocking sleep because of: \(String(describing: blockingObjects.first))"
                
                if blockingObjects.count > 1 {
                    logString = "\(logString) (and \(blockingObjects.count - 1) others)"
                }
                OWSLogger.info(logString)
            }
            else {
                OWSLogger.info("Unblocking Sleep.")
            }
        }
        UIApplication.shared.isIdleTimerDisabled = shouldBeBlocking
    }
    
    func frontmostViewController() -> UIViewController? {
        UIApplication.shared.frontmostViewControllerIgnoringAlerts
    }
    
    func setNetworkActivityIndicatorVisible(_ value: Bool) {
        UIApplication.shared.isNetworkActivityIndicatorVisible = value
    }
    
    // MARK: -
    
    func runNowOr(whenMainAppIsActive block: @escaping AppActiveBlock) {
        Threading.dispatchMainThreadSafe { [weak self] in
            if self?.isMainAppAndActive == true {
                // App active blocks typically will be used to safely access the
                // shared data container, so use a background task to protect this
                // work.
                var backgroundTask: OWSBackgroundTask? = OWSBackgroundTask(label: #function)
                block()
                if backgroundTask != nil { backgroundTask = nil }
                return
            }
            
            self?.appActiveBlocks.append(block)
        }
    }
    
    func runAppActiveBlocks() {
        // App active blocks typically will be used to safely access the
        // shared data container, so use a background task to protect this
        // work.
        var backgroundTask: OWSBackgroundTask? = OWSBackgroundTask(label: #function)

        let appActiveBlocks: [AppActiveBlock] = self.appActiveBlocks
        self.appActiveBlocks.removeAll()
        
        appActiveBlocks.forEach { $0() }
        if backgroundTask != nil { backgroundTask = nil }
    }
    
    func appDocumentDirectoryPath() -> String {
        let targetPath: String? = FileManager.default
            .urls(
                for: .documentDirectory,
                in: .userDomainMask
            )
            .last?
            .path
        owsAssertDebug(targetPath != nil)
        
        return (targetPath ?? "")
    }
    
    func appSharedDataDirectoryPath() -> String {
        let targetPath: String? = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: UserDefaults.applicationGroup)?
            .path
        owsAssertDebug(targetPath != nil)
        
        return (targetPath ?? "")
    }
    
    func appUserDefaults() -> UserDefaults {
        owsAssertDebug(UserDefaults.sharedLokiProject != nil)
        
        return (UserDefaults.sharedLokiProject ?? UserDefaults.standard)
    }
}
