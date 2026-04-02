// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import Combine
import BackgroundTasks
import UserNotifications
import GRDB
import SessionUIKit
import SessionMessagingKit
import SessionUtilitiesKit
import SignalUtilitiesKit
import SessionNetworkingKit

// MARK: - Log.Category

private extension Log.Category {
    static let cat: Log.Category = .create("AppDelegate", defaultLevel: .info)
}

// MARK: - AppDelegate

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    private static let backgroundFetchId: String = "com.loki-project.loki-messenger.background-fetch" // stringlint:ignore
    fileprivate static let maxRootViewControllerInitialQueryDuration: Int = 10
    
    /// The AppDelete is initialised by the OS so we should init an instance of `Dependencies` to be used throughout
    let dependencies: Dependencies = Dependencies.createEmpty()
    @MainActor var hasInitialRootViewController: Bool = false
    private var rootViewControllerCoordinator: RootViewControllerCoordinator = RootViewControllerCoordinator()
    var startTime: CFTimeInterval = 0
    var loadingViewController: LoadingViewController? = LoadingViewController()
    private var hasNotifiedWindowReady: Bool = false
    private var windowReadyContinuation: CheckedContinuation<Void, Never>?
    
    // MARK: - Lifecycle

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        Log.info(.cat, "didFinishLaunchingWithOptions called.")
        startTime = CACurrentMediaTime()
        
#if DEBUG
        /// If we are running unit tests then we don't want to run the usual application startup process (as it could slow down and/or
        /// interfere with the unit tests)
        guard !SNUtilitiesKit.isRunningTests else { return true }
        
        /// If we are running a Preview then we don't want to setup the application (previews are generally self contained individual views so
        /// doing all this application setup is a waste or work, and could even cause crashes for the preview)
        if ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1" {   // stringlint:ignore
            return true
        }
#endif
        
        /// These should be the first things we do (the startup process can fail without them)
        dependencies.set(singleton: .appContext, to: MainAppContext(using: dependencies))
        verifyDBKeysAvailableBeforeBackgroundLaunch()
        
        /// Kick of a task to perform the app setup
        Task(priority: .userInitiated) { [weak self, dependencies] in
            try? await SessionBackgroundTask.run(
                label: "Setup Environment", // stringlint:ignore
                using: dependencies
            ) { [weak self, dependencies] in
                guard let self else { return }
                
                do {
                    try await AppSetup.setupEnvironment(
                        loadingViewController: self.loadingViewController,
                        sleepBlockObject: self,
                        ensureWindowInitialised: self.ensureWindowInitialised,
                        using: dependencies
                    )
                    await self.completePostMigrationSetup(calledFrom: .finishLaunching)
                }
                catch {
                    await MainActor.run { [weak self] in
                        self?.showFailedStartupAlert(
                            calledFrom: .finishLaunching,
                            error: .databaseError(error)
                        )
                    }
                }
            }
        }
        
        /// Register the background refresh task handler - must happen before the app finishes launching
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: AppDelegate.backgroundFetchId,
            using: nil
        ) { [weak self] task in
            guard let task = task as? BGAppRefreshTask else { return }
            self?.handleBackgroundRefresh(task: task)
        }
        
        /// Create a proper `NotificationPresenter` for the main app (defaults to a no-op version)
        ///
        /// **Note:** This must happen in `appDidFinishLaunching` to ensure we don't miss notifications. Setting the delegate
        /// also seems to prevent us from getting the legacy notification notification callbacks upon launch e.g. `didReceiveLocalNotification`
        dependencies.set(singleton: .notificationsManager, to: NotificationPresenter(using: dependencies))
        dependencies[singleton: .notificationsManager].setDelegate(self)
        
        /// Create a proper `SessionCallManager` for the main app (defaults to a no-op version) - need to do this synchronously
        /// before returning, otherwise a VoIP push delivered immediately after launch could interact with the no-op version
        dependencies.set(singleton: .callManager, to: SessionCallManager(using: dependencies))
        dependencies.warm(singleton: .pushRegistrationManager)
        
        /// Update state of current call
        if dependencies[singleton: .callManager].currentCall == nil {
            dependencies[defaults: .appGroup, key: .isCallOngoing] = false
            dependencies[defaults: .appGroup, key: .lastCallPreOffer] = nil
        }
        
        NotificationCenter.default.addObserver(
            forName: .missedCall,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            DispatchQueue.main.async { [weak self] in
                self?.showMissedCallTipsIfNeeded(notification)
            }
        }
        
        Log.info(.cat, "didFinishLaunchingWithOptions completed.")
        return true
    }
    
    func applicationDidReceiveMemoryWarning(_ application: UIApplication) {
        Log.warn(.cat, "applicationDidReceiveMemoryWarning")
    }

    func applicationWillTerminate(_ application: UIApplication) {
        Log.info(.cat, "applicationWillTerminate.")
        Log.flush()

        Task(priority: .userInitiated) { [weak self] in
            await self?.stopPollers()
        }
    }
    
    // MARK: - Scene Configuration
    
    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        return UISceneConfiguration(
            name: "Default Configuration",  // stringlint:ignore
            sessionRole: connectingSceneSession.role
        )
    }
    
    func application(
        _ application: UIApplication,
        didDiscardSceneSessions sceneSessions: Set<UISceneSession>
    ) {}
    
    // MARK: - Orientation

    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        if UIDevice.current.isIPad {
            return .all
        }
        
        return .portrait
    }
    
    // MARK: - Background Fetching
    
    /// To simulate a background refresh during development, pause the app in the debugger and run:
    /// `e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateLaunchForTaskWithIdentifier:@"com.loki-project.loki-messenger.background-fetch"]`
    ///
    /// **Note:** The new `BGAppRefreshTask` API doesn't work on the simulator so can only be tested on a real device
    private func scheduleBackgroundRefresh() {
        let request: BGAppRefreshTaskRequest = BGAppRefreshTaskRequest(
            identifier: AppDelegate.backgroundFetchId
        )
        /// `earliestBeginDate` of nil lets the system decide the optimal time
        request.earliestBeginDate = nil
        
        do {
            try BGTaskScheduler.shared.submit(request)
            Log.info(.cat, "Background refresh task scheduled successfully.")
        }
        catch let error as BGTaskScheduler.Error where error.code == .unavailable {
            /// BGTaskScheduler is unavailable in the simulator
        }
        catch let error as BGTaskScheduler.Error where error.code == .tooManyPendingTaskRequests {
            /// Already scheduled, no need to log
        }
        catch {
            Log.warn(.cat, "Failed to schedule background refresh: \(error)")
        }
    }
    
    private func handleBackgroundRefresh(task: BGAppRefreshTask) {
        /// Immediately reschedule the next refresh so we don't miss future opportunities even if this one gets cancelled or fails
        scheduleBackgroundRefresh()
        
        let fetchTask: Task<Void, Never> = Task(priority: .userInitiated) { [dependencies] in
            Log.appResumedExecution()
            Log.info(.backgroundPoller, "Starting background fetch.")
            await dependencies[singleton: .appReadiness].isReady()
            
            guard
                !Task.isCancelled,
                dependencies[singleton: .appContext].isInBackground
            else {
                task.setTaskCompleted(success: false)
                return
            }
            
            /// Resume database and network access
            await dependencies[singleton: .storage].resumeDatabaseAccess()
            await dependencies[singleton: .network].resumeNetworkAccess(autoReconnect: false)
            
            /// Perform the polling
            let poller: BackgroundPoller = BackgroundPoller()
            let hadValidMessages: Bool = await poller.poll(using: dependencies)
            
            /// Update the app badge in case the unread count changed
            await AppDelegate.updateUnreadBadgeCount(using: dependencies)
            
            /// If we are still running in the background then suspend the network & database
            let hasOngoingCall: Bool = (
                dependencies[singleton: .callManager].currentCall != nil &&
                dependencies[singleton: .callManager].currentCall?.hasEnded == false
            )
            
            if dependencies[singleton: .appContext].isInBackground && !hasOngoingCall {
                await dependencies[singleton: .network].suspendNetworkAccess()
                await dependencies[singleton: .storage].suspendDatabaseAccess()
                Log.flush()
            }
            
            task.setTaskCompleted(success: hadValidMessages)
        }
        
        task.expirationHandler = {
            fetchTask.cancel()
        }
    }
    
    // MARK: - App Readiness
    
    private func ensureWindowInitialised() async {
        if hasNotifiedWindowReady { return }
        
        return await withCheckedContinuation { continuation in
            windowReadyContinuation = continuation
        }
    }
    
    func signalWindowReady() {
        hasNotifiedWindowReady = true
        windowReadyContinuation?.resume()
        windowReadyContinuation = nil
    }
    
    private func completePostMigrationSetup(calledFrom lifecycleMethod: LifecycleMethod) async {
        Log.info(.cat, "Migrations completed, performing setup and ensuring rootViewController")
        
        /// We need to do a clean up for disappear after send messages that are received by push notifications before the app sets up
        /// the main screen and loads initial data to prevent a case where the the conversation screen can show stale (ie. deleted)
        /// interactions incorrectly
        await DisappearingMessagesJob.cleanExpiredMessagesOnResume(using: dependencies)
        
        /// Now that the database is setup we can load in any messages which were processed by the extensions
        ///
        /// **Note:** This should be called on launch before `dependencies[singleton: .appReadiness].setAppReady()`
        /// is called to add a safety margin to help prevent an issue where a user tapping on a notification may not open the conversation
        /// showing the message
        await MainActor.run {
            (UIApplication.shared.connectedScenes.first?.delegate as? SceneDelegate)?.scheduleLoadMessages()
        }
        
        /// May as well run this on the background thread
        dependencies[singleton: .audioSession].setup()
        
        /// Setup the UI if needed, then trigger any post-UI setup actions
        ///
        /// **Note:** If we didn't successfully ensure the `rootViewController` then don't continue as the user is in an invalid
        /// state (and should have already been shown a modal)
        guard await self.ensureRootViewController(calledFrom: lifecycleMethod) else { return }
        
        let onboardingState: Onboarding.State = await dependencies[singleton: .onboarding].state
            .first(defaultValue: .unknown)
        Log.info(.cat, "RootViewController ready for state: \(onboardingState), readying remaining processes")
        
        /// Flag that the app is ready via `AppReadiness.setAppIsReady()`
        ///
        /// If we are launching the app from a push notification we need to ensure we wait until after the `HomeVC` is setup
        /// otherwise it won't open the related thread
        ///
        /// **Note:** This this does much more than set a flag - it will also run all deferred blocks
        await dependencies[singleton: .appReadiness].setAppReady()
        
        /// Remove the sleep blocking once the startup is done (needs to run on the main thread and sleeping while
        /// doing the startup could suspend the database causing errors/crashes
        dependencies[singleton: .deviceSleepManager].removeBlock(blockObject: self)
        
        /// App launch hasn't really completed until the main screen is loaded so wait until then to register it
        dependencies.mutate(cache: .appVersion) { $0.mainAppLaunchDidComplete() }
        
        /// App won't be ready for extensions and no need to enqueue a config sync unless we successfully completed startup
        try? await dependencies[singleton: .storage].write { db in
            /// Increment the launch count (guaranteed to change which results in the write actually doing something and
            /// outputting and error if the DB is suspended)
            db[.activeCounter] = ((db[.activeCounter] ?? 0) + 1)
        }
        
        /// Now that the migrations are completed schedule config syncs for **all** configs that have pending changes to
        /// ensure that any pending local state gets pushed and any jobs waiting for a successful config sync are run
        ///
        /// **Note:** We only want to do this if the app is active, and the user has completed the Onboarding process
        if dependencies[singleton: .appContext].isAppForegroundAndActive && onboardingState == .completed {
            dependencies.mutate(cache: .libSession) { $0.syncAllPendingPushesAsync() }
        }
            
        /// No need for the `loadingViewController` anymore since we have the proper UI now
        self.loadingViewController = nil
        
        /// Add a log to track the proper startup time of the app so we know whether we need to improve it in the future from user logs
        let startupDuration: CFTimeInterval = (CACurrentMediaTime() - startTime)
        Log.info(.cat, "\(lifecycleMethod.timingName) completed in \(.seconds(startupDuration), unit: .ms).")
    }
    
    fileprivate func showFailedStartupAlert(
        calledFrom lifecycleMethod: LifecycleMethod,
        error: StartupError,
        animated: Bool = true,
        presentationCompletion: (() -> Void)? = nil
    ) {
        /// This **must** be a standard `UIAlertController` instead of a `ConfirmationModal` because we may not
        /// have access to the database when displaying this so can't extract theme information for styling purposes
        let alert: UIAlertController = UIAlertController(
            title: Constants.app_name,
            message: error.message,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "helpReportABugExportLogs".localized(), style: .default) { [dependencies] _ in
            HelpViewModel.shareLogs(viewControllerToDismiss: alert, using: dependencies) { [weak self] in
                // Don't bother showing the "Failed Startup" modal again if we happen to now
                // have an initial view controller (this most likely means that the startup
                // completed while the user was sharing logs so we can just let the user use
                // the app)
                guard self?.hasInitialRootViewController == false else { return }
                
                self?.showFailedStartupAlert(calledFrom: lifecycleMethod, error: error)
            }
        })
        
        // Always offer the 'Clear Data' option
        alert.addAction(UIAlertAction(title: "clearDevice".localized(), style: .destructive) { [weak self, dependencies] _ in
            let alert: UIAlertController = UIAlertController(
                title: "clearDevice".localized(),
                message: "clearDeviceDescription".localized(),
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "clear".localized(), style: .destructive) { _ in
                NukeDataModal.deleteAllLocalData(using: dependencies)
            })
            
            alert.addAction(UIAlertAction(title: "cancel".localized(), style: .default) { _ in
                DispatchQueue.main.async {
                    self?.showFailedStartupAlert(
                        calledFrom: lifecycleMethod,
                        error: error
                    )
                }
            })
            dependencies[singleton: .appContext].mainWindow?.rootViewController?.present(alert, animated: animated, completion: nil)
        })
        
        switch error {
            // Don't offer the 'Restore' option if it was a 'startupFailed' error as a restore is unlikely to
            // resolve it (most likely the database is locked or the key was somehow lost - safer to get them
            // to restart and manually reinstall/restore)
            case .databaseError(StorageError.startupFailed), .databaseError(DatabaseError.SQLITE_LOCKED): break
                
            // Offer the 'Restore' option if it was a migration error
            case .databaseError:
                alert.addAction(UIAlertAction(title: "clearDeviceRestore".localized(), style: .destructive) { [weak self, dependencies] _ in
                    let alert: UIAlertController = UIAlertController(
                        title: "clearDeviceRestore".localized(),
                        message: "databaseErrorRestoreDataWarning".localized(),
                        preferredStyle: .alert
                    )
                    alert.addAction(UIAlertAction(title: "clear".localized(), style: .destructive) { [weak self, dependencies] _ in
                        // Hide the top banner if there was one
                        TopBannerController.hide()
                        
                        Task(priority: .userInitiated) { [weak self, dependencies] in
                            await self?.stopPollers()
                            self?.hasInitialRootViewController = false
                            
                            let loadingViewController: LoadingViewController = LoadingViewController()
                            self?.loadingViewController = loadingViewController
                            dependencies[singleton: .appContext].mainWindow?.rootViewController = loadingViewController
                            dependencies[singleton: .appContext].mainWindow?.makeKeyAndVisible()
                            self?.rootViewControllerCoordinator = RootViewControllerCoordinator()
                            
                            // Reset the current database for a clean migration
                            await dependencies[singleton: .storage].resetForCleanMigration()
                            
                            // The re-run the migration (should succeed since there is no data)
                            do {
                                try await AppSetup.performDatabaseMigrations(using: dependencies) { [weak self] progress, minEstimatedTotalTime in
                                    self?.loadingViewController?.updateProgress(
                                        progress: progress,
                                        minEstimatedTotalTime: minEstimatedTotalTime
                                    )
                                }
                                try await AppSetup.postMigrationSetup(using: dependencies)
                                
                                await self?.completePostMigrationSetup(calledFrom: lifecycleMethod)
                            }
                            catch {
                                await MainActor.run {
                                    self?.showFailedStartupAlert(
                                        calledFrom: lifecycleMethod,
                                        error: .failedToRestore
                                    )
                                }
                            }
                        }
                    })
                    
                    alert.addAction(UIAlertAction(title: "cancel".localized(), style: .default) { _ in
                        DispatchQueue.main.async {
                            self?.showFailedStartupAlert(
                                calledFrom: lifecycleMethod,
                                error: error
                            )
                        }
                    })
                    dependencies[singleton: .appContext].mainWindow?.rootViewController?.present(alert, animated: animated, completion: nil)
                })
                
            default: break
        }
        
        alert.addAction(UIAlertAction(title: "quit".put(key: "app_name", value: Constants.app_name).localized(), style: .default) { _ in
            Log.flush()
            exit(0)
        })
        
        Log.info(.cat, "Showing startup alert due to error: \(error.description)")
        dependencies[singleton: .appContext].mainWindow?.rootViewController?.present(alert, animated: animated, completion: presentationCompletion)
    }
    
    /// The user must unlock the device once after reboot before the database encryption key can be accessed.
    private func verifyDBKeysAvailableBeforeBackgroundLaunch() {
        guard UIApplication.shared.applicationState == .background else { return }
        
        do {
            try dependencies[singleton: .storage].ensureDatabasePasswordAccess()
            return /// Password is accessible
        }
        catch KeychainStorageError.failure(let code, _, _) where code == errSecItemNotFound {
            return /// No account yet
        }
        catch {
            /// Key exists but is inaccessible — device locked since reboot
        }
        
        Log.warn(.cat, "Exiting because we are in the background and the database password is not accessible.")
        
        let notificationContent: UNMutableNotificationContent = UNMutableNotificationContent()
        notificationContent.body = "notificationsIosRestart"
            .put(key: "device", value: UIDevice.current.localizedModel)
            .localized()
        let notificationRequest: UNNotificationRequest = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: notificationContent,
            trigger: nil
        )
        
        // Make sure we clear any existing notifications so that they don't start stacking up
        // if the user receives multiple pushes.
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
        UIApplication.shared.applicationIconBadgeNumber = 0
        
        UNUserNotificationCenter.current().add(notificationRequest, withCompletionHandler: nil)
        UIApplication.shared.applicationIconBadgeNumber = 1
        
        Log.flush()
        exit(0)
    }

    public func handleActivation() {
        /// There is a _fun_ behaviour here where if the user launches the app, sends it to the background at the right time and then
        /// opens it again the `AppReadiness` closures can be triggered before `applicationDidBecomeActive` has been
        /// called again - this can result in odd behaviours so hold off on running this logic until it's properly called again
        guard dependencies[defaults: .appGroup, key: .isMainAppActive] == true else { return }
        
        /// There is a warning which can happen on launch because the Database read can be blocked by another database operation
        /// which could result in this blocking the main thread, as a result we want to check the identity exists on a background thread
        /// and then return to the main thread only when required
        Task(priority: .medium) { [weak self, dependencies] in
            guard await dependencies[singleton: .onboarding].state.first() == .completed else { return }
            
            self?.scheduleBackgroundRefresh()
            
            /// Kick off polling and fetch the Session Network info in the background
            Task.detached { await self?.startPollersIfNeeded() }
            Task.detached {
                dependencies[singleton: .sessionNetworkPageManager].fetchInfoInBackground()
            }

            if dependencies[singleton: .appContext].isMainApp {
                await MainActor.run {
                    self?.handleAppActivatedWithOngoingCallIfNeeded()
                }
            }
        }
    }
    
    @discardableResult public func ensureRootViewController(
        calledFrom lifecycleMethod: LifecycleMethod
    ) async -> Bool {
        return await rootViewControllerCoordinator.ensureSetup(
            calledFrom: lifecycleMethod,
            appDelegate: self,
            using: dependencies
        )
    }
    
    // MARK: - Notifications
    
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Log.info(.syncPushTokensJob, "Received push token.")
        dependencies[singleton: .pushRegistrationManager].didReceiveVanillaPushToken(deviceToken)
    }
    
    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Log.error(.syncPushTokensJob, "Failed to register push token with error: \(error).")
        
        #if DEBUG
        Log.warn(.syncPushTokensJob, "We're in debug mode. Faking success for remote registration with a fake push identifier.")
        dependencies[singleton: .pushRegistrationManager].didReceiveVanillaPushToken(Data(count: 32))
        #else
        dependencies[singleton: .pushRegistrationManager].didFailToReceiveVanillaPushToken(error: error)
        #endif
    }
    
    public func clearAllNotificationsAndRestoreBadgeCount() {
        dependencies[singleton: .appReadiness].runNowOrWhenAppDidBecomeReady { [dependencies] in
            dependencies[singleton: .notificationsManager].clearAllNotifications()
            
            guard dependencies[singleton: .appContext].isMainApp else { return }
            
            /// On application startup the `Storage.read` can be slightly slow while GRDB spins up it's database
            /// read pools (up to a few seconds), since this read is blocking we want to dispatch it to run async to ensure
            /// we don't block user interaction while it's running
            Task(priority: .userInitiated) { [dependencies] in
                await AppDelegate.updateUnreadBadgeCount(using: dependencies)
            }
        }
    }
    
    func application(_ application: UIApplication, performActionFor shortcutItem: UIApplicationShortcutItem, completionHandler: @escaping (Bool) -> Void) {
        dependencies[singleton: .appReadiness].runNowOrWhenAppDidBecomeReady { [dependencies] in
            Task(priority: .userInitiated) {
                guard await dependencies[singleton: .onboarding].state.first() == .completed else { return }
                
                await MainActor.run { [dependencies] in
                    dependencies[singleton: .app].createNewConversation()
                }
                completionHandler(true)
            }
        }
    }

    /// The method will be called on the delegate only if the application is in the foreground. If the method is not implemented or the
    /// handler is not called in a timely manner then the notification will not be presented. The application can choose to have the
    /// notification presented as a sound, badge, alert and/or in the notification list.
    ///
    /// This decision should be based on whether the information in the notification is otherwise visible to the user.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        if notification.request.content.userInfo["remote"] != nil {
            /// Only suppress if we're genuinely active, not mid-transition
            guard dependencies[defaults: .appGroup, key: .isMainAppActive] else {
                dependencies[singleton: .appReadiness].runNowOrWhenAppDidBecomeReady {
                    completionHandler([.badge, .banner, .sound, .list])
                }
                return
            }
            
            Log.info(.cat, "Ignoring remote notifications while the app is in the foreground.")
            return
        }
        
        dependencies[singleton: .appReadiness].runNowOrWhenAppDidBecomeReady {
            /// We need to respect the in-app notification sound preference. This method, which is called for modern
            /// `UNUserNotification` users, could be a place to do that, but since we'd still need to handle this behavior for
            /// legacy `UINotification` users anyway, we "allow" all notification options here, and rely on the shared logic in
            /// `NotificationPresenter` to honor notification sound preferences for both modern and legacy users.
            completionHandler([.badge, .banner, .sound, .list])
        }
    }

    /// The method will be called on the delegate when the user responded to the notification by opening the application, dismissing
    /// the notification or choosing a UNNotificationAction. The delegate must be set before the application returns from
    /// application:didFinishLaunchingWithOptions:.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        dependencies[singleton: .appReadiness].runNowOrWhenAppDidBecomeReady { [dependencies] in
            /// Give the app 3 seconds to load notification messages into the database before trying to handle the notification response
            Task(priority: .userInitiated) {
                await dependencies[singleton: .extensionHelper].waitUntilMessagesAreLoaded(timeout: .seconds(3))
                await dependencies[singleton: .notificationActionHandler].handleNotificationResponse(
                    response
                )
                
                await MainActor.run {
                    completionHandler()
                }
            }
        }
    }

    /// The method will be called on the delegate when the application is launched in response to the user's request to view in-app
    /// notification settings. Add UNAuthorizationOptionProvidesAppNotificationSettings as an option in
    /// requestAuthorizationWithOptions:completionHandler: to add a button to inline notification settings view and the notification
    /// settings view in Settings. The notification will be nil when opened from Settings.
    func userNotificationCenter(_ center: UNUserNotificationCenter, openSettingsFor notification: UNNotification?) {
    }
    
    // MARK: - Notification Handling
    
    @MainActor private func showMissedCallTipsIfNeeded(_ notification: Notification) {
        guard
            dependencies[singleton: .appContext].isValid,
            !dependencies[defaults: .standard, key: .hasSeenCallMissedTips],
            let callerId: String = notification.userInfo?[Notification.Key.senderId.rawValue] as? String
        else { return }
        
        Task.detached(priority: .userInitiated) { [dependencies] in
            let callerDisplayName: String = ((try? await dependencies[singleton: .storage]
                .read { db in Profile.displayName(db, id: callerId) }) ?? callerId.truncated())
            
            await MainActor.run { [dependencies] in
                guard let presentingVC = dependencies[singleton: .appContext].frontMostViewController else {
                    return
                }
                
                let callMissedTipsModal: CallMissedTipsModal = CallMissedTipsModal(
                    caller: callerDisplayName,
                    presentingViewController: presentingVC,
                    using: dependencies
                )
                presentingVC.present(callMissedTipsModal, animated: true, completion: nil)
                
                dependencies[defaults: .standard, key: .hasSeenCallMissedTips] = true
            }
        }
    }
    
    public static func updateUnreadBadgeCount(using dependencies: Dependencies) async {
        let unreadCount: Int
        
        do {
            unreadCount = try await dependencies[singleton: .storage].read { db in
                try Interaction.fetchAppBadgeUnreadCount(db, using: dependencies)
            }
        }
        catch {
            Log.error("Failed to update app badge count: \(error)")
            return
        }
        
        try? dependencies[singleton: .extensionHelper].saveUserMetadata(
            sessionId: dependencies[cache: .general].sessionId,
            ed25519SecretKey: dependencies[cache: .general].ed25519SecretKey,
            unreadCount: unreadCount
        )
        
        await MainActor.run {
            UIApplication.shared.applicationIconBadgeNumber = unreadCount
        }
    }
    
    // MARK: - Polling
    
    public func startPollersIfNeeded() async {
        guard await dependencies[singleton: .onboarding].state.first() == .completed else { return }
        
        await dependencies[singleton: .currentUserPoller].startIfNeeded()
        await dependencies[singleton: .groupPollerManager].startAllPollers()
        await dependencies[singleton: .communityPollerManager].startAllPollers()
    }
    
    public func stopPollers(shouldStopUserPoller: Bool = true) async {
        guard await dependencies[singleton: .onboarding].state.first() == .completed else { return }
        
        if shouldStopUserPoller {
            await dependencies[singleton: .currentUserPoller].stop()
        }
        
        await dependencies[singleton: .groupPollerManager].stopAndRemoveAllPollers()
        await dependencies[singleton: .communityPollerManager].stopAndRemoveAllPollers()
    }
    
    // MARK: - App Link

    func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
        guard let components: URLComponents = URLComponents(url: url, resolvingAgainstBaseURL: true) else {
            return false
        }
        
        // URL Scheme is sessionmessenger://DM?sessionID=1234
        // We can later add more parameters like message etc.
        // stringlint:ignore_contents
        if components.host == "DM" {
            let matches: [URLQueryItem] = (components.queryItems ?? [])
                .filter { item in item.name == "sessionID" }
            
            if let sessionId: String = matches.first?.value {
                createNewDMFromDeepLink(sessionId: sessionId)
                return true
            }
        }
        
        return false
    }

    private func createNewDMFromDeepLink(sessionId: String) {
        guard let homeViewController: HomeVC = dependencies[singleton: .app].homeViewController else {
            return
        }
        
        homeViewController.createNewDMFromDeepLink(sessionId: sessionId)
    }
        
    // MARK: - Call handling
        
    func hasIncomingCallWaiting() -> Bool {
        return (dependencies[singleton: .callManager].currentCall?.hasStartedConnecting == false)
    }
    
    func handleAppActivatedWithOngoingCallIfNeeded() {
        guard
            let call: SessionCall = (dependencies[singleton: .callManager].currentCall as? SessionCall),
            MiniCallView.current == nil
        else { return }
        
        if let callVC = dependencies[singleton: .appContext].frontMostViewController as? CallVC, callVC.call.uuid == call.uuid {
            return
        }
        
        // FIXME: Handle more gracefully
        guard let presentingVC = dependencies[singleton: .appContext].frontMostViewController else { preconditionFailure() }
        
        let callVC: CallVC = CallVC(for: call, using: dependencies)
        presentingVC.present(callVC, animated: true, completion: nil)
    }
}

// MARK: - RootViewControllerCoordinator

private actor RootViewControllerCoordinator {
    private var isRunning: Bool = false
    private var isComplete: Bool = false
    private var pendingContinuations: [CheckedContinuation<Bool, Never>] = []
    
    func ensureSetup(
        calledFrom lifecycleMethod: LifecycleMethod,
        appDelegate: AppDelegate,
        using dependencies: Dependencies
    ) async -> Bool {
        guard !isComplete else { return true }
        
        return await withCheckedContinuation { continuation in
            pendingContinuations.append(continuation)

            guard !isRunning else { return }
            isRunning = true

            Task {
                await performSetup(calledFrom: lifecycleMethod, appDelegate: appDelegate, using: dependencies)
            }
        }
    }
    
    private func performSetup(
        calledFrom lifecycleMethod: LifecycleMethod,
        appDelegate: AppDelegate,
        using dependencies: Dependencies
    ) async {
        let hasInitialRootViewController = await MainActor.run { appDelegate.hasInitialRootViewController }
        let storageState: Storage.State? = await dependencies[singleton: .storage].state.first()
        
        guard
            storageState != .notSetup &&
            storageState != .noDatabaseConnection &&
            storageState != .migrationsFailed &&
            (
                dependencies[singleton: .appReadiness].syncState.isReady ||
                lifecycleMethod == .finishLaunching ||
                lifecycleMethod == .enterForeground
            ) &&
            !hasInitialRootViewController
        else {
            await markFailed()
            return
        }

        /// Start a timeout for the creation of the rootViewController setup process (if it takes too long then we want to give the user
        /// the option to export their logs)
        let timeoutTask: Task<Void, Error> = Task { @MainActor in
            try await Task.sleep(for: .seconds(AppDelegate.maxRootViewControllerInitialQueryDuration))
            
            /// It's possible for this timeout to complete after the home screen has been shown but before the task is cancelled so
            /// we need to protect against that case because the user can't dismiss the modal that appears)
            guard !appDelegate.hasInitialRootViewController else { return }
            
            appDelegate.showFailedStartupAlert(calledFrom: lifecycleMethod, error: .startupTimeout)
            await self.markFailed()
        }
        
        // All logic which needs to run after the 'rootViewController' is created
        let setupComplete: @MainActor (UIViewController) -> Void = { @MainActor [weak appDelegate] rootViewController in
            guard let appDelegate else { return }
            
            /// `MainAppContext.determineDeviceRTL` uses UIKit to retrime `isRTL` so must be run on the main thread
            /// to prevent lag/crashes on background threads
            Dependencies.setIsRTLRetriever(requiresMainThread: true) {
                MainAppContext.determineDeviceRTL()
            }
            
            /// Setup the `TopBannerController`
            let presentedViewController: UIViewController? = dependencies[singleton: .appContext].mainWindow?.rootViewController?.presentedViewController
            let targetRootViewController: UIViewController = TopBannerController(
                child: StyledNavigationController(rootViewController: rootViewController),
                cachedWarning: dependencies[defaults: .appGroup, key: .topBannerWarningToShow]
                    .map { rawValue in TopBannerController.Warning(rawValue: rawValue) }
            )
            
            /// Ensure the `ScreenLock` UI before swapping over the `rootViewController` to prevent rendering anything
            /// before it is updated
            ///
            /// **Note:** intentionally calling `forceEnsureUI` with `resetLockedState` set to `true` rather than
            /// `ensureUI` because the app technically isn't "ready" just yet but we want to do it anyway (any want to have the
            /// locked state based on the users setting)
            UIView.performWithoutAnimation {
                dependencies[singleton: .screenLock].forceEnsureUI(
                    resetLockedState: true,
                    animated: false
                )
                dependencies[singleton: .appContext].mainWindow?.rootViewController = targetRootViewController
            }
            
            appDelegate.hasInitialRootViewController = true
            UIViewController.attemptRotationToDeviceOrientation()
            
            /// **Note:** There is an annoying case when starting the app by interacting with a push notification where
            /// the `HomeVC` won't have completed loading it's view which means the `SessionApp.homeViewController`
            /// won't have been set - we set the value directly here to resolve this edge case
            if let homeViewController: HomeVC = rootViewController as? HomeVC {
                dependencies[singleton: .app].setHomeViewController(homeViewController)
            }
            
            /// If we were previously presenting a viewController but are no longer preseting it then present it again
            ///
            /// **Note:** Looks like the OS will throw an exception if we try to present a screen which is already (or
            /// was previously?) presented, even if it's not attached to the screen it seems...
            switch presentedViewController {
                case is UIAlertController, is ConfirmationModal:
                    /// If the viewController we were presenting happened to be the "failed startup" modal then we can dismiss it
                    /// automatically (while this seems redundant it's less jarring for the user than just instantly having it disappear)
                    appDelegate.showFailedStartupAlert(
                        calledFrom: lifecycleMethod,
                        error: .startupTimeout,
                        animated: false
                    ) {
                        dependencies[singleton: .appContext].mainWindow?.rootViewController?.dismiss(animated: true)
                    }
                
                case is UIActivityViewController: HelpViewModel.shareLogs(animated: false, using: dependencies)
                default: break
            }
            
            timeoutTask.cancel()
            Task(priority: .high) {
                await self.markComplete()
            }
        }
        
        // Navigate to the approriate screen depending on the onboarding state
        try? await dependencies[singleton: .onboarding].loadInitialState()
        let state: Onboarding.State? = await dependencies[singleton: .onboarding].state.first()
        
        switch state {
            case .none, .unknown, .noUser, .noUserInvalidKeyPair, .noUserInvalidSeedGeneration:
                if state == .noUserInvalidKeyPair {
                    Log.critical(.cat, "Failed to load credentials for existing user, generated a new identity.")
                }
                else if state == .noUserInvalidSeedGeneration {
                    Log.critical(.cat, "Failed to create an initial identity for a potentially new user.")
                }
                
                await MainActor.run {
                    /// Once the onboarding process is complete we need to call `handleActivation`
                    let viewController = SessionHostingViewController(rootView: LandingScreen(using: dependencies) { [weak appDelegate] in
                        appDelegate?.handleActivation()
                    })
                    viewController.setUpNavBarSessionIcon()
                    setupComplete(viewController)
                }
                
            case .missingName:
                let initialFlow: Onboarding.Flow = await dependencies[singleton: .onboarding].initialFlow
                
                await MainActor.run {
                    let viewController = SessionHostingViewController(
                        rootView: DisplayNameScreen(flow: initialFlow, using: dependencies)
                    )
                    viewController.setUpNavBarSessionIcon()
                    setupComplete(viewController)
                    
                    /// Once the onboarding process is complete we need to call `handleActivation`
                    Task(priority: .userInitiated) { [weak appDelegate] in
                        _ = await dependencies[singleton: .onboarding].state.first(where: { $0 == .completed })
                        
                        appDelegate?.handleActivation()
                    }
                }
                
            case .completed:
                await MainActor.run {
                    /// We want to start observing the changes for the 'HomeVC' and want to wait until we actually get data back before we
                    /// continue as we don't want to show a blank home screen
                    let viewController: HomeVC = HomeVC(using: dependencies)
                    viewController.afterInitialConversationsLoaded {
                        setupComplete(viewController)
                    }
                }
        }
    }
    
    private func markComplete() async {
        isComplete = true
        isRunning = false
        pendingContinuations.forEach { $0.resume(returning: true) }
        pendingContinuations = []
    }
    
    private func markFailed() async {
        isRunning = false
        pendingContinuations.forEach { $0.resume(returning: false) }
        pendingContinuations = []
    }
}

// MARK: - LifecycleMethod

public enum LifecycleMethod: Equatable {
    case finishLaunching
    case enterForeground
    case didBecomeActive
    
    // stringlint:ignore_contents
    var timingName: String {
        switch self {
            case .finishLaunching: return "Launch"
            case .enterForeground: return "EnterForeground"
            case .didBecomeActive: return "BecomeActive"
        }
    }
    
    public static func == (lhs: LifecycleMethod, rhs: LifecycleMethod) -> Bool {
        switch (lhs, rhs) {
            case (.finishLaunching, .finishLaunching): return true
            case (.enterForeground, .enterForeground): return true
            case (.didBecomeActive, .didBecomeActive): return true
            default: return false
        }
    }
}
