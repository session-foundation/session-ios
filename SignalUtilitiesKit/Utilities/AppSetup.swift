// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionMessagingKit
import SessionUtilitiesKit
import SessionUIKit
import SessionSnodeKit

public enum AppSetup {
    private static let hasRun: Atomic<Bool> = Atomic(false)
    
    public static func setupEnvironment(
        appSpecificBlock: @escaping () -> (),
        migrationProgressChanged: ((CGFloat, TimeInterval) -> ())? = nil,
        migrationsCompletion: @escaping (Result<Void, Error>, Bool) -> (),
        using dependencies: Dependencies = Dependencies()
    ) {
        guard !AppSetup.hasRun.wrappedValue else { return }
        
        AppSetup.hasRun.mutate { $0 = true }
        
        var backgroundTask: OWSBackgroundTask? = OWSBackgroundTask(labelStr: #function)
        
        DispatchQueue.global(qos: .userInitiated).async {
            // Order matters here.
            //
            // All of these "singletons" should have any dependencies used in their
            // initializers injected.
            OWSBackgroundTaskManager.shared().observeNotifications()
            
            // Attachments can be stored to NSTemporaryDirectory()
            // If you receive a media message while the device is locked, the download will fail if
            // the temporary directory is NSFileProtectionComplete
            let success: Bool = OWSFileSystem.protectFileOrFolder(
                atPath: NSTemporaryDirectory(),
                fileProtectionType: .completeUntilFirstUserAuthentication
            )
            assert(success)

            Environment.shared = Environment(
                reachabilityManager: SSKReachabilityManagerImpl(),
                audioSession: OWSAudioSession(),
                proximityMonitoringManager: OWSProximityMonitoringManagerImpl(),
                windowManager: OWSWindowManager(default: ())
            )
            appSpecificBlock()
            
            /// `performMainSetup` **MUST** run before `perform(migrations:)`
            Configuration.performMainSetup()
            
            runPostSetupMigrations(
                backgroundTask: backgroundTask,
                migrationProgressChanged: migrationProgressChanged,
                migrationsCompletion: migrationsCompletion,
                using: dependencies
            )
            
            // The 'if' is only there to prevent the "variable never read" warning from showing
            if backgroundTask != nil { backgroundTask = nil }
        }
    }
    
    public static func runPostSetupMigrations(
        backgroundTask: OWSBackgroundTask? = nil,
        migrationProgressChanged: ((CGFloat, TimeInterval) -> ())? = nil,
        migrationsCompletion: @escaping (Result<Void, Error>, Bool) -> (),
        using dependencies: Dependencies = Dependencies()
    ) {
        // If the database can't be initialised into a valid state then error
        guard Storage.shared.isValid else {
            DispatchQueue.main.async {
                migrationsCompletion(Result.failure(StorageError.databaseInvalid), false)
            }
            return
        }
        
        var backgroundTask: OWSBackgroundTask? = (backgroundTask ?? OWSBackgroundTask(labelStr: #function))
        
        dependencies.storage.perform(
            migrationTargets: [
                SNUtilitiesKit.self,
                SNSnodeKit.self,
                SNMessagingKit.self,
                SNUIKit.self
            ],
            onProgressUpdate: migrationProgressChanged,
            onMigrationRequirement: { db, requirement in
                switch requirement {
                    case .sessionUtilStateLoaded:
                        guard Identity.userExists(db) else { return }
                        
                        // After the migrations have run but before the migration completion we load the
                        // SessionUtil state
                        SessionUtil.loadState(db, using: dependencies)
                }
            },
            onComplete: { result, needsConfigSync in
                // The 'needsConfigSync' flag should be based on whether either a migration or the
                // configs need to be sync'ed
                migrationsCompletion(result, (needsConfigSync || dependencies.caches[.sessionUtil].needsSync))
                
                // The 'if' is only there to prevent the "variable never read" warning from showing
                if backgroundTask != nil { backgroundTask = nil }
            },
            using: dependencies
        )
    }
}
