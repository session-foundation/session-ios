// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import Combine
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
    fileprivate static let maxRootViewControllerInitialQueryDuration: Int = 10
    
    /// The AppDelete is initialised by the OS so we should init an instance of `Dependencies` to be used throughout
    let dependencies: Dependencies = Dependencies.createEmpty()
    var window: UIWindow?
    var backgroundSnapshotBlockerWindow: UIWindow?
    var appStartupWindow: UIWindow?
    var initialLaunchFailed: Bool = false
    @MainActor var hasInitialRootViewController: Bool = false
    private let rootViewControllerCoordinator: RootViewControllerCoordinator = RootViewControllerCoordinator()
    var startTime: CFTimeInterval = 0
    private var loadingViewController: LoadingViewController?
    
    // MARK: - Lifecycle

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        /// If we are running automated tests we should process environment variables before we do anything else
        DeveloperSettingsViewModel.processUnitTestEnvVariablesIfNeeded(using: dependencies)
        
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
        
        Log.info(.cat, "didFinishLaunchingWithOptions called.")
        startTime = CACurrentMediaTime()
        
        // These should be the first things we do (the startup process can fail without them)
        dependencies.set(singleton: .appContext, to: MainAppContext(using: dependencies))
        verifyDBKeysAvailableBeforeBackgroundLaunch()

        dependencies.warm(cache: .appVersion)
        dependencies[singleton: .pushRegistrationManager].createVoipRegistryIfNecessary()

        // Prevent the device from sleeping during database view async registration
        // (e.g. long database upgrades).
        //
        // This block will be cleared in storageIsReady.
        dependencies[singleton: .deviceSleepManager].addBlock(blockObject: self)
        
        let mainWindow: UIWindow = TraitObservingWindow(frame: UIScreen.main.bounds)
        self.loadingViewController = LoadingViewController()
        
        AppSetup.setupEnvironment(
            appSpecificBlock: { [dependencies] in
                Log.setup(with: Logger(primaryPrefix: "Session", using: dependencies))
                Log.info(.cat, "Setting up environment.")
                
                /// Create a proper `SessionCallManager` for the main app (defaults to a no-op version)
                dependencies.set(singleton: .callManager, to: SessionCallManager(using: dependencies))
                
                // Setup LibSession
                LibSession.setupLogger(using: dependencies)
                dependencies.warm(cache: .libSessionNetwork)
                dependencies.warm(singleton: .network)
                dependencies.warm(singleton: .sessionProManager)
                
                // Configure the different targets
                SNUtilitiesKit.configure(
                    networkMaxFileSize: Network.maxFileSize,
                    maxValidImageDimention: ImageDataManager.DataSource.maxValidDimension,
                    using: dependencies
                )
                SNMessagingKit.configure(using: dependencies)
                
                // Update state of current call
                if dependencies[singleton: .callManager].currentCall == nil {
                    dependencies[defaults: .appGroup, key: .isCallOngoing] = false
                    dependencies[defaults: .appGroup, key: .lastCallPreOffer] = nil
                }
                
                // Note: Intentionally dispatching sync as we want to wait for these to complete before
                // continuing
                DispatchQueue.main.sync {
                    dependencies[singleton: .screenLock].setupWithRootWindow(rootWindow: mainWindow)
                    OWSWindowManager.shared().setup(
                        withRootWindow: mainWindow,
                        screenBlockingWindow: dependencies[singleton: .screenLock].window,
                        backgroundWindowLevel: .background
                    )
                }
            },
            migrationProgressChanged: { [weak self] progress, minEstimatedTotalTime in
                self?.loadingViewController?.updateProgress(
                    progress: progress,
                    minEstimatedTotalTime: minEstimatedTotalTime
                )
            },
            migrationsCompletion: { [weak self, dependencies] result in
                if case .failure(let error) = result {
                    DispatchQueue.main.async {
                        self?.initialLaunchFailed = true
                        self?.showFailedStartupAlert(
                            calledFrom: .finishLaunching,
                            error: .databaseError(error)
                        )
                    }
                    return
                }
                
                /// Because the `SessionUIKit` target doesn't depend on the `SessionUtilitiesKit` dependency (it shouldn't
                /// need to since it should just be UI) but since the theme settings are stored in the database we need to pass these through
                /// to `SessionUIKit` and expose a mechanism to save updated settings - this is done here (once the migrations complete)
                Task { @MainActor in
                    SNUIKit.configure(
                        with: SessionSNUIKitConfig(using: dependencies),
                        themeSettings: {
                            /// Only try to extract the theme settings if we actually have an account (if not the `libSession`
                            /// cache won't exist anyway)
                            guard dependencies[cache: .general].userExists else { return nil }
                            
                            return dependencies.mutate(cache: .libSession) { cache -> ThemeSettings in
                                (
                                    cache.get(.theme),
                                    cache.get(.themePrimaryColor),
                                    cache.get(.themeMatchSystemDayNightCycle)
                                )
                            }
                        }()
                    )
                }
                
                /// Adding this to prevent new users being asked for local network permission in the wrong order in the permission chain.
                /// We need to check the local nework permission status every time the app is activated to refresh the UI in Settings screen.
                /// And after granting or denying a system permission request will trigger the local nework permission status check in applicationDidBecomeActive(:)
                /// The only way we can check the status of local network permission will trigger the system prompt to ask for the permission.
                /// So we need this to keep it the correct order of the permission chain.
                /// For users who already enabled the calls permission and made calls, the local network permission should already be asked for.
                /// It won't affect anything.
                if dependencies[cache: .general].userExists {
                    dependencies[defaults: .standard, key: .hasRequestedLocalNetworkPermission] = dependencies.mutate(cache: .libSession) { cache in
                        cache.get(.areCallsEnabled)
                    }
                }
                
                /// Now that the theme settings have been applied we can complete the migrations
                self?.completePostMigrationSetup(calledFrom: .finishLaunching)
            },
            using: dependencies
        )
        
        // No point continuing if we are running tests
        guard !SNUtilitiesKit.isRunningTests else { return true }

        self.window = mainWindow
        dependencies[singleton: .appContext].setMainWindow(mainWindow)
        
        // Show LoadingViewController until the async database view registrations are complete.
        mainWindow.rootViewController = self.loadingViewController
        mainWindow.makeKeyAndVisible()

        /// Create a proper `NotificationPresenter` for the main app (defaults to a no-op version)
        ///
        /// **Note:** This must happen in `appDidFinishLaunching` to ensure we don't miss notifications. Setting the delegate
        /// also seems to prevent us from getting the legacy notification notification callbacks upon launch e.g. `didReceiveLocalNotification`
        dependencies.set(singleton: .notificationsManager, to: NotificationPresenter(using: dependencies))
        dependencies[singleton: .notificationsManager].setDelegate(self)
        
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
    
    func applicationWillEnterForeground(_ application: UIApplication) {
        Log.appResumedExecution()
        Log.info(.cat, "applicationWillEnterForeground.")
        
        /// **Note:** We _shouldn't_ need to call this here but for some reason the OS doesn't seems to
        /// be calling the `userNotificationCenter(_:,didReceive:withCompletionHandler:)`
        /// method when the device is locked while the app is in the foreground (or if the user returns to the
        /// springboard without swapping to another app) - adding this here in addition to the one in
        /// `appDidFinishLaunching` seems to fix this odd behaviour (even though it doesn't match
        /// Apple's documentation on the matter)
        dependencies[singleton: .notificationsManager].setDelegate(self)
        
        dependencies[singleton: .storage].resumeDatabaseAccess()
        dependencies.mutate(cache: .libSessionNetwork) { $0.resumeNetworkAccess() }
        
        // Reset the 'startTime' (since it would be invalid from the last launch)
        startTime = CACurrentMediaTime()
        
        // If we've already completed migrations at least once this launch then check
        // to see if any "delayed" migrations now need to run
        if dependencies[singleton: .storage].hasCompletedMigrations {
            Log.info(.cat, "Checking for pending migrations")
            let initialLaunchFailed: Bool = self.initialLaunchFailed
            
            dependencies[singleton: .appReadiness].invalidate()
            
            // If the user went to the background too quickly then the database can be suspended before
            // properly starting up, in this case an alert will be shown but we can recover from it so
            // dismiss any alerts that were shown
            if initialLaunchFailed {
                self.window?.rootViewController?.dismiss(animated: false)
            }
            
            // Dispatch async so things can continue to be progressed if a migration does need to run
            DispatchQueue.global(qos: .userInitiated).async { [weak self, dependencies] in
                AppSetup.runPostSetupMigrations(
                    migrationProgressChanged: { progress, minEstimatedTotalTime in
                        self?.loadingViewController?.updateProgress(
                            progress: progress,
                            minEstimatedTotalTime: minEstimatedTotalTime
                        )
                    },
                    migrationsCompletion: { result in
                        if case .failure(let error) = result {
                            DispatchQueue.main.async {
                                self?.showFailedStartupAlert(
                                    calledFrom: .enterForeground(initialLaunchFailed: initialLaunchFailed),
                                    error: .databaseError(error)
                                )
                            }
                            return
                        }
                        
                        self?.completePostMigrationSetup(
                            calledFrom: .enterForeground(initialLaunchFailed: initialLaunchFailed)
                        )
                    },
                    using: dependencies
                )
            }
        }
    }
    
    func applicationDidEnterBackground(_ application: UIApplication) {
        if !hasInitialRootViewController { Log.info(.cat, "Entered background before startup was completed") }
        Log.info(.cat, "applicationDidEnterBackground.")
        Log.flush()
        
        // NOTE: Fix an edge case where user taps on the callkit notification
        // but answers the call on another device
        stopPollers(shouldStopUserPoller: !self.hasCallOngoing())
        
        // Stop all jobs except for message sending and when completed suspend the database
        dependencies[singleton: .jobRunner].stopAndClearPendingJobs(exceptForVariant: .messageSend) { [dependencies] neededBackgroundProcessing in
            if !self.hasCallOngoing() && (!neededBackgroundProcessing || dependencies[singleton: .appContext].isInBackground) {
                dependencies.mutate(cache: .libSessionNetwork) { $0.suspendNetworkAccess() }
                dependencies[singleton: .storage].suspendDatabaseAccess()
                Log.info(.cat, "completed network and database shutdowns.")
                Log.flush()
            }
        }
    }
    
    func applicationDidReceiveMemoryWarning(_ application: UIApplication) {
        Log.warn(.cat, "applicationDidReceiveMemoryWarning")
    }

    func applicationWillTerminate(_ application: UIApplication) {
        Log.info(.cat, "applicationWillTerminate.")
        Log.flush()

        stopPollers()
    }
    
    func applicationDidBecomeActive(_ application: UIApplication) {
        Log.info(.cat, "applicationDidBecomeActive.")
        guard !SNUtilitiesKit.isRunningTests else { return }
        
        Log.info(.cat, "Setting 'isMainAppActive' to true.")
        dependencies[defaults: .appGroup, key: .isMainAppActive] = true
        
        // FIXME: Seems like there are some discrepancies between the expectations of how the iOS lifecycle methods work, we should look into them and ensure the code behaves as expected (in this case there were situations where these two wouldn't get called when returning from the background)
        dependencies[singleton: .storage].resumeDatabaseAccess()
        dependencies.mutate(cache: .libSessionNetwork) { $0.resumeNetworkAccess() }
        
        ensureRootViewController(calledFrom: .didBecomeActive)

        dependencies[singleton: .appReadiness].runNowOrWhenAppDidBecomeReady { [weak self] in
            self?.handleActivation()
            
            /// Clear all notifications whenever we become active once the app is ready
            ///
            /// **Note:** It looks like when opening the app from a notification, `userNotificationCenter(didReceive)` is
            /// no longer always called before `applicationDidBecomeActive` we need to trigger the "clear notifications" logic
            /// within the `runNowOrWhenAppDidBecomeReady` callback and dispatch to the next run loop to ensure it runs after
            /// the notification has actually been handled
            DispatchQueue.main.async {
                self?.clearAllNotificationsAndRestoreBadgeCount()
            }
        }

        /// On every activation, clear old temp directories.
        dependencies[singleton: .fileManager].clearOldTemporaryDirectories()
        
        /// It's likely that on a fresh launch that the `libSession` cache won't have been initialised by this point, so detatch a task to
        /// wait for it before checking the local network permission
        Task.detached { [dependencies] in
            try? await dependencies.waitUntilInitialised(cache: .libSession)
            
            if dependencies.mutate(cache: .libSession, { $0.get(.areCallsEnabled) }) && dependencies[defaults: .standard, key: .hasRequestedLocalNetworkPermission] {
                Permissions.checkLocalNetworkPermission(using: dependencies)
            }
        }
    }
    
    func applicationWillResignActive(_ application: UIApplication) {
        Log.info(.cat, "applicationWillResignActive.")
        clearAllNotificationsAndRestoreBadgeCount()
        
        Log.info(.cat, "Setting 'isMainAppActive' to false.")
        dependencies[defaults: .appGroup, key: .isMainAppActive] = false
        Log.info(.cat, "Setting 'lastSeenHasMicrophonePermission'.")
        dependencies[defaults: .appGroup, key: .lastSeenHasMicrophonePermission] = (Permissions.microphone == .granted)

        Log.flush()
    }
    
    // MARK: - Orientation

    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        if UIDevice.current.isIPad {
            return .all
        }
        
        return .portrait
    }
    
    // MARK: - Background Fetching
    
    func application(_ application: UIApplication, performFetchWithCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        /// It seems like it's possible for this function to be called with an invalid `backgroundTimeRemaining` value
        /// (`TimeInterval.greatestFiniteMagnitude`) in which case we just want to mark it as a failure
        ///
        /// Additionally we want to ensure that our timeout timer has enough time to run so make sure we have at least `5 seconds`
        /// of background execution (if we don't then the process could incorrectly run longer than it should)
        let remainingTime: TimeInterval = application.backgroundTimeRemaining
        
        guard
            remainingTime != TimeInterval.nan &&
            remainingTime < TimeInterval.greatestFiniteMagnitude &&
            remainingTime > 5
        else { return completionHandler(.failed) }
        
        Log.appResumedExecution()
        Log.info(.backgroundPoller, "Starting background fetch.")
        dependencies[singleton: .storage].resumeDatabaseAccess()
        dependencies.mutate(cache: .libSessionNetwork) { $0.resumeNetworkAccess() }
        
        let queue: DispatchQueue = DispatchQueue(label: "com.session.backgroundPoll")
        let poller: BackgroundPoller = BackgroundPoller()
        var cancellable: AnyCancellable?
        
        /// Background tasks only last for a certain amount of time (which can result in a crash and a prompt appearing for the user),
        /// we want to avoid this and need to make sure to suspend the database again before the background task ends so we start
        /// a timer that expires before the background task is due to expire in order to do so
        ///
        /// **Note:** We **MUST** capture both `poller` and `cancellable` strongly in the event handler to ensure neither
        /// go out of scope until we want them to (we essentually want a retain cycle in this case)
        let durationRemainingMs: Int = max(1, Int((remainingTime - 5) * 1000))
        let timer: DispatchSourceTimer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(durationRemainingMs))
        timer.setEventHandler { [poller, dependencies] in
            guard cancellable != nil else { return }
            
            Log.info(.backgroundPoller, "Background poll failed due to manual timeout.")
            cancellable?.cancel()
            
            if dependencies[singleton: .appContext].isInBackground && !self.hasCallOngoing() {
                dependencies.mutate(cache: .libSessionNetwork) { $0.suspendNetworkAccess() }
                dependencies[singleton: .storage].suspendDatabaseAccess()
                Log.flush()
            }
            
            _ = poller // Capture poller to ensure it doesn't go out of scope
            completionHandler(.failed)
        }
        timer.resume()
        
        dependencies[singleton: .appReadiness].runNowOrWhenAppDidBecomeReady { [dependencies, poller] in
            /// If the 'AppReadiness' process takes too long then it's possible for the user to open the app after this closure is registered
            /// but before it's actually triggered - this can result in the `BackgroundPoller` incorrectly getting called in the foreground,
            /// this check is here to prevent that
            guard dependencies[singleton: .appContext].isInBackground else { return }
            
            /// Kick off the `BackgroundPoller`
            ///
            /// **Note:** We **MUST** capture both `poller` and `timer` strongly in the completion handler to ensure neither
            /// go out of scope until we want them to (we essentually want a retain cycle in this case)
            cancellable = poller
                .poll(using: dependencies)
                .subscribe(on: queue, using: dependencies)
                .receive(on: queue, using: dependencies)
                .sink(
                    receiveCompletion: { [timer, poller] result in
                        // Ensure we haven't timed out yet
                        guard timer.isCancelled == false else { return }
                        
                        // Immediately cancel the timer to prevent the timeout being triggered
                        timer.cancel()
                        
                        // Update the app badge in case the unread count changed
                        if
                            let unreadCount: Int = dependencies[singleton: .storage].read({ db in
                                try Interaction.fetchAppBadgeUnreadCount(db, using: dependencies)
                            })
                        {
                            try? dependencies[singleton: .extensionHelper].saveUserMetadata(
                                sessionId: dependencies[cache: .general].sessionId,
                                ed25519SecretKey: dependencies[cache: .general].ed25519SecretKey,
                                unreadCount: unreadCount
                            )
                            
                            DispatchQueue.main.async(using: dependencies) {
                                UIApplication.shared.applicationIconBadgeNumber = unreadCount
                            }
                        }
                        
                        // If we are still running in the background then suspend the network & database
                        if dependencies[singleton: .appContext].isInBackground && !self.hasCallOngoing() {
                            dependencies.mutate(cache: .libSessionNetwork) { $0.suspendNetworkAccess() }
                            dependencies[singleton: .storage].suspendDatabaseAccess()
                            Log.flush()
                        }
                        
                        _ = poller // Capture poller to ensure it doesn't go out of scope
                        
                        // Complete the background task
                        switch result {
                            case .failure: completionHandler(.failed)
                            case .finished: completionHandler(.newData)
                        }
                    },
                    receiveValue: { _ in }
                )
        }
    }
    
    // MARK: - App Readiness
    
    private func completePostMigrationSetup(calledFrom lifecycleMethod: LifecycleMethod) {
        Log.info(.cat, "Migrations completed, performing setup and ensuring rootViewController")
        dependencies[singleton: .jobRunner].setExecutor(SyncPushTokensJob.self, for: .syncPushTokens)
        
        /// We need to do a clean up for disappear after send messages that are received by push notifications before the app sets up
        /// the main screen and loads initial data to prevent a case where the the conversation screen can show stale (ie. deleted)
        /// interactions incorrectly
        DisappearingMessagesJob.cleanExpiredMessagesOnResume(using: dependencies)
        
        /// Now that the database is setup we can load in any messages which were processed by the extensions (flag that we will load
        /// them in this thread and create a task to _actually_ load them asynchronously
        ///
        /// **Note:** This **MUST** be called before `dependencies[singleton: .appReadiness].setAppReady()` is
        /// called otherwise a user tapping on a notification may not open the conversation showing the message
        dependencies[singleton: .extensionHelper].willLoadMessages()
        
        Task(priority: .medium) { [dependencies] in
            do { try await dependencies[singleton: .extensionHelper].loadMessages() }
            catch { Log.error(.cat, "Failed to load messages from extensions: \(error)") }
        }
        
        // Setup the UI if needed, then trigger any post-UI setup actions
        self.ensureRootViewController(calledFrom: lifecycleMethod) { [weak self, dependencies] success in
            // If we didn't successfully ensure the rootViewController then don't continue as
            // the user is in an invalid state (and should have already been shown a modal)
            guard success else { return }
            
            Log.info(.cat, "RootViewController ready for state: \(dependencies[cache: .onboarding].state), readying remaining processes")
            self?.initialLaunchFailed = false
            
            /// Trigger any launch-specific jobs and start the JobRunner with `jobRunner.appDidFinishLaunching(using:)` some
            /// of these jobs (eg. DisappearingMessages job) can impact the interactions which get fetched to display on the home
            /// screen, if the PagedDatabaseObserver hasn't been setup yet then the home screen can show stale (ie. deleted)
            /// interactions incorrectly
            if lifecycleMethod == .finishLaunching {
                dependencies[singleton: .jobRunner].appDidFinishLaunching()
            }
            
            /// Flag that the app is ready via `AppReadiness.setAppIsReady()`
            ///
            /// If we are launching the app from a push notification we need to ensure we wait until after the `HomeVC` is setup
            /// otherwise it won't open the related thread
            ///
            /// **Note:** This this does much more than set a flag - it will also run all deferred blocks (including the JobRunner
            /// `appDidBecomeActive` method hence why it **must** also come after calling
            /// `jobRunner.appDidFinishLaunching(using:)`)
            dependencies[singleton: .appReadiness].setAppReady()
            
            /// Remove the sleep blocking once the startup is done (needs to run on the main thread and sleeping while
            /// doing the startup could suspend the database causing errors/crashes
            dependencies[singleton: .deviceSleepManager].removeBlock(blockObject: self)
            
            /// App launch hasn't really completed until the main screen is loaded so wait until then to register it
            dependencies.mutate(cache: .appVersion) { $0.mainAppLaunchDidComplete() }
            
            /// App won't be ready for extensions and no need to enqueue a config sync unless we successfully completed startup
            dependencies[singleton: .storage].writeAsync { db in
                /// Increment the launch count (guaranteed to change which results in the write actually doing something and
                /// outputting and error if the DB is suspended)
                db[.activeCounter] = ((db[.activeCounter] ?? 0) + 1)
            }
            
            /// Now that the migrations are completed schedule config syncs for **all** configs that have pending changes to
            /// ensure that any pending local state gets pushed and any jobs waiting for a successful config sync are run
            ///
            /// **Note:** We only want to do this if the app is active, and the user has completed the Onboarding process
            if dependencies[singleton: .appContext].isAppForegroundAndActive && dependencies[cache: .onboarding].state == .completed {
                dependencies.mutate(cache: .libSession) { $0.syncAllPendingPushesAsync() }
            }
            
            // Add a log to track the proper startup time of the app so we know whether we need to
            // improve it in the future from user logs
            let startupDuration: CFTimeInterval = ((self?.startTime).map { CACurrentMediaTime() - $0 } ?? -1)
            Log.info(.cat, "\(lifecycleMethod.timingName) completed in \(.seconds(startupDuration), unit: .ms).")
        }
        
        // May as well run these on the background thread
        dependencies[singleton: .audioSession].setup()
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
            self?.window?.rootViewController?.present(alert, animated: animated, completion: nil)
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
                    alert.addAction(UIAlertAction(title: "clear".localized(), style: .destructive) { _ in
                        // Reset the current database for a clean migration
                        dependencies[singleton: .storage].resetForCleanMigration()
                        
                        // Hide the top banner if there was one
                        TopBannerController.hide()
                        
                        // The re-run the migration (should succeed since there is no data)
                        AppSetup.runPostSetupMigrations(
                            migrationProgressChanged: { [weak self] progress, minEstimatedTotalTime in
                                self?.loadingViewController?.updateProgress(
                                    progress: progress,
                                    minEstimatedTotalTime: minEstimatedTotalTime
                                )
                            },
                            migrationsCompletion: { [weak self] result in
                                switch result {
                                    case .failure:
                                        DispatchQueue.main.async {
                                            self?.showFailedStartupAlert(
                                                calledFrom: lifecycleMethod,
                                                error: .failedToRestore
                                            )
                                        }
                                        
                                    case .success:
                                        self?.completePostMigrationSetup(calledFrom: lifecycleMethod)
                                }
                            },
                            using: dependencies
                        )
                    })
                    
                    alert.addAction(UIAlertAction(title: "cancel".localized(), style: .default) { _ in
                        DispatchQueue.main.async {
                            self?.showFailedStartupAlert(
                                calledFrom: lifecycleMethod,
                                error: error
                            )
                        }
                    })
                    self?.window?.rootViewController?.present(alert, animated: animated, completion: nil)
                })
                
            default: break
        }
        
        alert.addAction(UIAlertAction(title: "quit".put(key: "app_name", value: Constants.app_name).localized(), style: .default) { _ in
            Log.flush()
            exit(0)
        })
        
        Log.info(.cat, "Showing startup alert due to error: \(error.description)")
        self.window?.rootViewController?.present(alert, animated: animated, completion: presentationCompletion)
    }
    
    /// The user must unlock the device once after reboot before the database encryption key can be accessed.
    private func verifyDBKeysAvailableBeforeBackgroundLaunch() {
        guard UIApplication.shared.applicationState == .background else { return }
        
        guard !dependencies[singleton: .storage].isDatabasePasswordAccessible else { return }    // All good
        
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
    
    private func enableBackgroundRefreshIfNecessary() {
        dependencies[singleton: .appReadiness].runNowOrWhenAppDidBecomeReady {
            UIApplication.shared.setMinimumBackgroundFetchInterval(UIApplication.backgroundFetchIntervalMinimum)
        }
    }

    fileprivate func handleActivation() {
        /// There is a _fun_ behaviour here where if the user launches the app, sends it to the background at the right time and then
        /// opens it again the `AppReadiness` closures can be triggered before `applicationDidBecomeActive` has been
        /// called again - this can result in odd behaviours so hold off on running this logic until it's properly called again
        guard dependencies[defaults: .appGroup, key: .isMainAppActive] == true else { return }
        
        /// There is a warning which can happen on launch because the Database read can be blocked by another database operation
        /// which could result in this blocking the main thread, as a result we want to check the identity exists on a background thread
        /// and then return to the main thread only when required
        DispatchQueue.global(qos: .default).async { [weak self, dependencies] in
            guard dependencies[cache: .onboarding].state == .completed else { return }
            
            self?.enableBackgroundRefreshIfNecessary()
            dependencies[singleton: .jobRunner].appDidBecomeActive()
            
            self?.startPollersIfNeeded()
            
            Network.SessionNetwork.client.initialize(using: dependencies)

            if dependencies[singleton: .appContext].isMainApp {
                DispatchQueue.main.async {
                    self?.handleAppActivatedWithOngoingCallIfNeeded()
                }
            }
        }
    }
    
    private func ensureRootViewController(
        calledFrom lifecycleMethod: LifecycleMethod,
        onComplete: @escaping ((Bool) -> Void) = { _ in }
    ) {
        Task {
            await rootViewControllerCoordinator.ensureSetup(
                calledFrom: lifecycleMethod,
                appDelegate: self,
                using: dependencies,
                onComplete: onComplete
            )
        }
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
    
    private func clearAllNotificationsAndRestoreBadgeCount() {
        dependencies[singleton: .appReadiness].runNowOrWhenAppDidBecomeReady { [dependencies] in
            dependencies[singleton: .notificationsManager].clearAllNotifications()
            
            guard dependencies[singleton: .appContext].isMainApp else { return }
            
            /// On application startup the `Storage.read` can be slightly slow while GRDB spins up it's database
            /// read pools (up to a few seconds), since this read is blocking we want to dispatch it to run async to ensure
            /// we don't block user interaction while it's running
            DispatchQueue.global(qos: .default).async {
                if
                    let unreadCount: Int = dependencies[singleton: .storage].read({ db in
                        try Interaction.fetchAppBadgeUnreadCount(db, using: dependencies)
                    })
                {
                    try? dependencies[singleton: .extensionHelper].saveUserMetadata(
                        sessionId: dependencies[cache: .general].sessionId,
                        ed25519SecretKey: dependencies[cache: .general].ed25519SecretKey,
                        unreadCount: unreadCount
                    )
                    
                    DispatchQueue.main.async(using: dependencies) {
                        UIApplication.shared.applicationIconBadgeNumber = unreadCount
                    }
                }
            }
        }
    }
    
    func application(_ application: UIApplication, performActionFor shortcutItem: UIApplicationShortcutItem, completionHandler: @escaping (Bool) -> Void) {
        dependencies[singleton: .appReadiness].runNowOrWhenAppDidBecomeReady { [dependencies] in
            guard dependencies[cache: .onboarding].state == .completed else { return }
            
            dependencies[singleton: .app].createNewConversation()
            completionHandler(true)
        }
    }

    /// The method will be called on the delegate only if the application is in the foreground. If the method is not implemented or the
    /// handler is not called in a timely manner then the notification will not be presented. The application can choose to have the
    /// notification presented as a sound, badge, alert and/or in the notification list.
    ///
    /// This decision should be based on whether the information in the notification is otherwise visible to the user.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        if notification.request.content.userInfo["remote"] != nil {
            Log.info(.cat, "Ignoring remote notifications while the app is in the foreground.")
            return
        }
        
        dependencies[singleton: .appReadiness].runNowOrWhenAppDidBecomeReady {
            // We need to respect the in-app notification sound preference. This method, which is called
            // for modern UNUserNotification users, could be a place to do that, but since we'd still
            // need to handle this behavior for legacy UINotification users anyway, we "allow" all
            // notification options here, and rely on the shared logic in NotificationPresenter to
            // honor notification sound preferences for both modern and legacy users.
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
                await MainActor.run {
                    dependencies[singleton: .notificationActionHandler].handleNotificationResponse(
                        response,
                        completionHandler: completionHandler
                    )
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
                .readAsync { db in Profile.displayName(db, id: callerId) }) ?? callerId.truncated())
            
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
    
    // MARK: - Polling
    
    public func startPollersIfNeeded() {
        guard dependencies[cache: .onboarding].state == .completed else { return }
        
        /// Start the pollers on a background thread so that any database queries they need to run don't
        /// block the main thread
        DispatchQueue.global(qos: .background).async { [dependencies] in
            dependencies[singleton: .currentUserPoller].startIfNeeded()
            dependencies.mutate(cache: .groupPollers) { $0.startAllPollers() }
            dependencies.mutate(cache: .communityPollers) { $0.startAllPollers() }
        }
    }
    
    public func stopPollers(shouldStopUserPoller: Bool = true) {
        guard dependencies[cache: .onboarding].state == .completed else { return }
        
        if shouldStopUserPoller {
            dependencies[singleton: .currentUserPoller].stop()
        }
    
        dependencies.mutate(cache: .groupPollers) { $0.stopAndRemoveAllPollers() }
        dependencies.mutate(cache: .communityPollers) { $0.stopAndRemoveAllPollers() }
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
        guard let homeViewController: HomeVC = (window?.rootViewController as? UINavigationController)?.visibleViewController as? HomeVC else {
            return
        }
        
        homeViewController.createNewDMFromDeepLink(sessionId: sessionId)
    }
        
    // MARK: - Call handling
        
    func hasIncomingCallWaiting() -> Bool {
        return (dependencies[singleton: .callManager].currentCall?.hasStartedConnecting == false)
    }
    
    func hasCallOngoing() -> Bool {
        return (dependencies[singleton: .callManager].currentCall?.hasEnded == false)
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
    private var pendingCompletions: [(Bool) -> Void] = []
    
    func ensureSetup(
        calledFrom lifecycleMethod: LifecycleMethod,
        appDelegate: AppDelegate,
        using dependencies: Dependencies,
        onComplete: @escaping (Bool) -> Void
    ) async {
        guard !isComplete else {
            return await MainActor.run {
                onComplete(true)
            }
        }
        
        pendingCompletions.append(onComplete)
        
        guard !isRunning else { return }
        
        isRunning = true
        await performSetup(
            calledFrom: lifecycleMethod,
            appDelegate: appDelegate,
            using: dependencies
        )
    }
    
    private func performSetup(
        calledFrom lifecycleMethod: LifecycleMethod,
        appDelegate: AppDelegate,
        using dependencies: Dependencies
    ) async {
        let hasInitialRootViewController = await MainActor.run { appDelegate.hasInitialRootViewController }
        
        guard
            dependencies[singleton: .storage].isValid &&
            (
                dependencies[singleton: .appReadiness].isAppReady ||
                lifecycleMethod == .finishLaunching ||
                lifecycleMethod == .enterForeground(initialLaunchFailed: true)
            ) &&
            !hasInitialRootViewController
        else {
            markFailed()
            return
        }

        /// Start a timeout for the creation of the rootViewController setup process (if it takes too long then we want to give the user
        /// the option to export their logs)
        let timeoutTask: Task<Void, Error> = Task { @MainActor in
            try await Task.sleep(for: .seconds(AppDelegate.maxRootViewControllerInitialQueryDuration))
            appDelegate.showFailedStartupAlert(calledFrom: lifecycleMethod, error: .startupTimeout)
            await self.markFailed()
        }
        
        // All logic which needs to run after the 'rootViewController' is created
        let setupComplete: @MainActor (UIViewController) -> Void = { @MainActor [weak appDelegate] rootViewController in
            guard let appDelegate else { return }
            
            /// `MainAppContext.determineDeviceRTL` uses UIKit to retrime `isRTL` so must be run on the main thread to prevent
            /// lag/crashes on background threads
            Dependencies.setIsRTLRetriever(requiresMainThread: true) { MainAppContext.determineDeviceRTL() }
            
            /// Setup the `TopBannerController`
            let presentedViewController: UIViewController? = appDelegate.window?.rootViewController?.presentedViewController
            let targetRootViewController: UIViewController = TopBannerController(
                child: StyledNavigationController(rootViewController: rootViewController),
                cachedWarning: dependencies[defaults: .appGroup, key: .topBannerWarningToShow]
                    .map { rawValue in TopBannerController.Warning(rawValue: rawValue) }
            )
            
            /// Insert the `targetRootViewController` below the current view and trigger a layout without animation before properly
            /// swapping the `rootViewController` over so we can avoid any weird initial layout behaviours
            UIView.performWithoutAnimation {
                appDelegate.window?.rootViewController = targetRootViewController
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
                        appDelegate.window?.rootViewController?.dismiss(animated: true)
                    }
                
                case is UIActivityViewController: HelpViewModel.shareLogs(animated: false, using: dependencies)
                default: break
            }
            
            timeoutTask.cancel()
            Task {
                await self.markComplete()
            }
        }
        
        // Navigate to the approriate screen depending on the onboarding state
        dependencies.warm(cache: .onboarding)
        
        switch dependencies[cache: .onboarding].state {
            case .noUser, .noUserInvalidKeyPair, .noUserInvalidSeedGeneration:
                if dependencies[cache: .onboarding].state == .noUserInvalidKeyPair {
                    Log.critical(.cat, "Failed to load credentials for existing user, generated a new identity.")
                }
                else if dependencies[cache: .onboarding].state == .noUserInvalidSeedGeneration {
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
                await MainActor.run {
                    let viewController = SessionHostingViewController(rootView: DisplayNameScreen(using: dependencies))
                    viewController.setUpNavBarSessionIcon()
                    setupComplete(viewController)
                    
                    /// Once the onboarding process is complete we need to call `handleActivation`
                    dependencies[cache: .onboarding].onboardingCompletePublisher
                        .subscribe(on: DispatchQueue.main, using: dependencies)
                        .receive(on: DispatchQueue.main, using: dependencies)
                        .sinkUntilComplete(receiveCompletion: { [weak appDelegate] _ in
                            appDelegate?.handleActivation()
                        })
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
    
    private func markComplete() {
        isComplete = true
        isRunning = false
        
        let completions: [(Bool) -> Void] = pendingCompletions
        pendingCompletions = []
        
        Task { @MainActor in
            completions.forEach { $0(true) }
        }
    }
    
    private func markFailed() {
        isRunning = false
        
        let completions: [(Bool) -> Void] = pendingCompletions
        pendingCompletions = []
        
        Task { @MainActor in
            completions.forEach { $0(false) }
        }
    }
}

// MARK: - LifecycleMethod

private enum LifecycleMethod: Equatable {
    case finishLaunching
    case enterForeground(initialLaunchFailed: Bool)
    case didBecomeActive
    
    // stringlint:ignore_contents
    var timingName: String {
        switch self {
            case .finishLaunching: return "Launch"
            case .enterForeground: return "EnterForeground"
            case .didBecomeActive: return "BecomeActive"
        }
    }
    
    static func == (lhs: LifecycleMethod, rhs: LifecycleMethod) -> Bool {
        switch (lhs, rhs) {
            case (.finishLaunching, .finishLaunching): return true
            case (.enterForeground(let lhsFailed), .enterForeground(let rhsFailed)): return (lhsFailed == rhsFailed)
            case (.didBecomeActive, .didBecomeActive): return true
            default: return false
        }
    }
}
