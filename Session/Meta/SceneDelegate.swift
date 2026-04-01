// Copyright © 2026 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import SessionUIKit
import SessionMessagingKit
import SessionUtilitiesKit
import SignalUtilitiesKit

// MARK: - Log.Category

private extension Log.Category {
    static let cat: Log.Category = .create("SceneDelegate", defaultLevel: .info)
}

// MARK: - SceneDelegate

class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    /// The AppDelete is initialised by the OS so we should init an instance of `Dependencies` to be used throughout
    var window: UIWindow?
    private var loadMessagesTask: Task<Void, Never>?
    private var jobRunnerShutdownTask: Task<Void, Never>?
    
    private var appDelegate: AppDelegate? {
        UIApplication.shared.delegate as? AppDelegate
    }
    
    // MARK: - Scene Lifecycle

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard
            let windowScene = scene as? UIWindowScene,
            let dependencies: Dependencies = appDelegate?.dependencies,
            let appDelegate
        else { return }

        let mainWindow: UIWindow = TraitObservingWindow(windowScene: windowScene)
        self.window = mainWindow
        appDelegate.dependencies[singleton: .appContext].setMainWindow(mainWindow)
        
        dependencies[singleton: .screenLock].setupWithRootWindow(rootWindow: mainWindow)
        OWSWindowManager.shared().setup(
            withRootWindow: mainWindow,
            screenBlockingWindow: dependencies[singleton: .screenLock].window,
            backgroundWindowLevel: .background
        )
        
        mainWindow.rootViewController = appDelegate.loadingViewController
        mainWindow.makeKeyAndVisible()
        appDelegate.signalWindowReady()
    }
    
    func sceneWillEnterForeground(_ scene: UIScene) {
        Log.appResumedExecution()
        Log.info(.cat, "sceneWillEnterForeground.")
        appDelegate?.dependencies.notifyAsync(key: .sceneLifecycle(.willEnterForeground))
        
        guard let appDelegate else { return }
        
        /// **Note:** We _shouldn't_ need to call this here but for some reason the OS doesn't seems to
        /// be calling the `userNotificationCenter(_:,didReceive:withCompletionHandler:)`
        /// method when the device is locked while the app is in the foreground (or if the user returns to the
        /// springboard without swapping to another app) - adding this here in addition to the one in
        /// `appDidFinishLaunching` seems to fix this odd behaviour (even though it doesn't match
        /// Apple's documentation on the matter)
        appDelegate.dependencies[singleton: .notificationsManager].setDelegate(appDelegate)
        
        Task(priority: .userInitiated) { [dependencies = appDelegate.dependencies] in
            await dependencies[singleton: .storage].resumeDatabaseAccess()
            await dependencies[singleton: .network].resumeNetworkAccess()
        }
    }
    
    func sceneDidEnterBackground(_ scene: UIScene) {
        guard let appDelegate else { return }
        if !appDelegate.hasInitialRootViewController { Log.info(.cat, "Entered background before startup was completed") }
        Log.info(.cat, "sceneDidEnterBackground.")
        Log.flush()
        appDelegate.dependencies.notifyAsync(key: .sceneLifecycle(.didEnterBackground))
        
        // NOTE: Fix an edge case where user taps on the callkit notification
        // but answers the call on another device
        Task(priority: .userInitiated) { [weak appDelegate, dependencies = appDelegate.dependencies] in
            let hasOngoingCall: Bool = (
                dependencies[singleton: .callManager].currentCall != nil &&
                dependencies[singleton: .callManager].currentCall?.hasEnded == false
            )
            
            await appDelegate?.stopPollers(shouldStopUserPoller: !hasOngoingCall)
        }
        
        loadMessagesTask?.cancel()
        loadMessagesTask = nil
        jobRunnerShutdownTask?.cancel()
        jobRunnerShutdownTask = Task(priority: .userInitiated) { [dependencies = appDelegate.dependencies] in
            try? await SessionBackgroundTask.run(label: "Shutdown JobRunner", using: dependencies) { [dependencies] in
                let hasOngoingCall: Bool = (
                    dependencies[singleton: .callManager].currentCall != nil &&
                    dependencies[singleton: .callManager].currentCall?.hasEnded == false
                )
                
                /// Stop all jobs except for message sending and when completed suspend the database
                await dependencies[singleton: .jobRunner].stopAndClearJobs(
                    filters: JobRunner.Filters(
                        exclude: [
                            .variant(.messageSend),
                            .variant(.attachmentUpload),
                            (hasOngoingCall ? .variant(.messageReceive) : nil)
                        ].compactMap { $0 }
                    )
                )
                guard !Task.isCancelled else { return }
                
                await dependencies[singleton: .jobRunner].allQueuesDrained()
                guard !Task.isCancelled else { return }
                
                /// Since we aren't going to stop the remaining jobs if there is an ongoing call then there is no need
                /// to add this log
                let updatedHasOngoingCall: Bool = (
                    dependencies[singleton: .callManager].currentCall != nil &&
                    dependencies[singleton: .callManager].currentCall?.hasEnded == false
                )
                
                if !updatedHasOngoingCall {
                    await dependencies[singleton: .jobRunner].stopAndClearJobs()
                }
                guard !Task.isCancelled else { return }
                
                let finalHasOngoingCall: Bool = (
                    dependencies[singleton: .callManager].currentCall != nil &&
                    dependencies[singleton: .callManager].currentCall?.hasEnded == false
                )
                
                if !finalHasOngoingCall && dependencies[singleton: .appContext].isInBackground {
                    await dependencies[singleton: .network].suspendNetworkAccess()
                    await dependencies[singleton: .storage].suspendDatabaseAccess()
                    Log.info(.appSetup, "Completed network and database shutdowns.")
                    Log.flush()
                }
            }
        }
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        Log.info(.cat, "sceneDidBecomeActive.")
        appDelegate?.dependencies.notifyAsync(key: .sceneLifecycle(.didBecomeActive))
        
        guard
            let dependencies: Dependencies = appDelegate?.dependencies,
            let appDelegate,
            !SNUtilitiesKit.isRunningTests
        else { return }
        
        loadMessagesTask?.cancel()   /// Cancel any stale task from a previous background entry
        loadMessagesTask = nil
        
        Task(priority: .userInitiated) { [weak self, weak appDelegate] in
            self?.scheduleLoadMessages()
            await dependencies[singleton: .jobRunner].appDidBecomeActive()
            appDelegate?.ensureRootViewController(calledFrom: .didBecomeActive)
        }
        
        dependencies[singleton: .appReadiness].runNowOrWhenAppDidBecomeReady { [weak appDelegate] in
            appDelegate?.handleActivation()
            
            /// Clear all notifications whenever we become active once the app is ready
            ///
            /// **Note:** It looks like when opening the app from a notification, `userNotificationCenter(didReceive)` is
            /// no longer always called before `applicationDidBecomeActive` we need to trigger the "clear notifications" logic
            /// within the `runNowOrWhenAppDidBecomeReady` callback and dispatch to the next run loop to ensure it runs after
            /// the notification has actually been handled
            DispatchQueue.main.async {
                appDelegate?.clearAllNotificationsAndRestoreBadgeCount()
            }
        }
        
        /// It's likely that on a fresh launch that the `libSession` cache won't have been initialised by this point, so detatch a task to
        /// wait for it before checking the local network permission
        Task.detached { [dependencies] in
            await dependencies.untilInitialised(cache: .libSession)
            
            if dependencies.mutate(cache: .libSession, { $0.get(.areCallsEnabled) }) && dependencies[defaults: .standard, key: .hasRequestedLocalNetworkPermission] {
                Permissions.checkLocalNetworkPermission(using: dependencies)
            }
            
            /// On every activation, clear old temp directories
            dependencies[singleton: .fileManager].clearOldTemporaryDirectories()
        }
    }

    func sceneWillResignActive(_ scene: UIScene) {
        Log.info(.cat, "sceneWillResignActive.")
        appDelegate?.dependencies.notifyAsync(key: .sceneLifecycle(.willResignActive))
        
        Log.info(.cat, "Setting 'lastSeenHasMicrophonePermission'.")
        appDelegate?.dependencies[defaults: .appGroup, key: .lastSeenHasMicrophonePermission] = (Permissions.microphone == .granted)
        appDelegate?.clearAllNotificationsAndRestoreBadgeCount()

        Log.flush()
    }
    
    public func scheduleLoadMessages() {
        /// Cancel any existing task first (e.g. `AppDelegate` called this on launch, then `sceneDidBecomeActive` fires before
        /// it completes)
        loadMessagesTask?.cancel()
        loadMessagesTask = nil
        
        guard let dependencies = appDelegate?.dependencies else { return }
        
        /// Process any messages the NSE wrote to disk while we the app wasn't in the foreground
        loadMessagesTask = Task(priority: .medium) { [dependencies, weak self] in
            do { try await dependencies[singleton: .extensionHelper].loadMessages() }
            catch { Log.error(.cat, "Failed to load extension messages: \(error)") }
            
            await AppDelegate.updateUnreadBadgeCount(using: dependencies)
            await MainActor.run { [weak self] in self?.loadMessagesTask = nil }
        }
    }
}
