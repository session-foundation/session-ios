// Copyright © 2026 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import SessionUIKit
import SessionMessagingKit
import SessionUtilitiesKit
import SignalUtilitiesKit

extension AppSetup {
    static func setupEnvironment(
        loadingViewController: LoadingViewController?,
        sleepBlockObject: NSObject,
        ensureWindowInitialised: @escaping () async -> Void,
        using dependencies: Dependencies
    ) async throws {
        Log.setup(with: Logger(primaryPrefix: "Session", using: dependencies))
        Log.info(.appSetup, "Setting up environment.")
        LibSession.setupLogger(using: dependencies)
        
        /// If we are running automated tests we should process environment variables before we do anything else
        await DeveloperSettingsViewModel.processUnitTestEnvVariablesIfNeeded(using: dependencies)
        
        /// Setup the VoiP registry
        dependencies[singleton: .pushRegistrationManager].createVoipRegistryIfNecessary()
        
        /// Prevent the device from sleeping during database view async registration (e.g. long database upgrades)
        ///
        /// This block will be cleared in storageIsReady
        dependencies[singleton: .deviceSleepManager].addBlock(blockObject: sleepBlockObject)
        
        /// Initial app setup
        try await AppSetup.performSetup(using: dependencies)
        
        /// Register the push tokens executor
        await dependencies[singleton: .jobRunner].setExecutor(
            SyncPushTokensJob.self,
            for: .syncPushTokens
        )
        
        /// Wait for the window to be setup before continuing
        await ensureWindowInitialised()
        
        try await completeEnvironmentSetup(loadingViewController: loadingViewController, using: dependencies)
    }
    
    /// The part of `setupEnvironment` which needs the database, split out so it can be run again when the background time runs
    /// out while the database is suspended part way through it (the rest of `setupEnvironment` must only run once)
    static func completeEnvironmentSetup(
        loadingViewController: LoadingViewController?,
        using dependencies: Dependencies
    ) async throws {
        var migrationsComplete = false
        while !migrationsComplete {
            do {
                try await AppSetup.performDatabaseMigrations(using: dependencies) { [weak loadingViewController] progress, minEstimatedTotalTime in
                    loadingViewController?.updateProgress(
                        progress: progress,
                        minEstimatedTotalTime: minEstimatedTotalTime
                    )
                }
                migrationsComplete = true
            } catch {
                /// If the failure was due to suspension, wait for the database to resume and retry - the migrator is idempotent
                /// so re-running is always safe. `SceneDelegate.sceneWillEnterForeground` resumes the database, which
                /// moves the state away from `.suspended` and unblocks the `first` call below
                ///
                /// **Note:** If the background time runs out first this task is cancelled, which ends the wait and throws; the
                /// caller is responsible for running this again once the database resumes
                if await dependencies[singleton: .storage].state.first(where: { $0 != .suspended }) == .pendingMigrations {
                    Log.info(.appSetup, "Startup interrupted by suspension, retrying after resume.")
                    continue
                }
                
                throw error
            }
        }
        
        try await AppSetup.postMigrationSetup(using: dependencies)
        
        /// Because the `SessionUIKit` target doesn't depend on the `SessionUtilitiesKit` dependency (it shouldn't
        /// need to since it should just be UI) but since the theme settings are stored in the database we need to pass these through
        /// to `SessionUIKit` and expose a mechanism to save updated settings - this is done here (once the migrations complete)
        await MainActor.run {
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
        dependencies[defaults: .standard, key: .hasRequestedLocalNetworkPermission] = {
            guard dependencies[cache: .general].userExists else { return false }
            
            return dependencies.mutate(cache: .libSession) { cache in
                cache.get(.areCallsEnabled)
            }
        }()
        
        /// Now that the theme settings have been applied we can complete the migrations
        Log.info(.appSetup, "Environment setup complete.")
    }
}
