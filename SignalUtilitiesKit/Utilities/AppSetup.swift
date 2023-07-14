// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionMessagingKit
import SessionUtilitiesKit
import SessionUIKit

public enum AppSetup {
    private static let hasRun: Atomic<Bool> = Atomic(false)
    
    public static func setupEnvironment(
        appSpecificBlock: @escaping () -> (),
        migrationProgressChanged: ((CGFloat, TimeInterval) -> ())? = nil,
        migrationsCompletion: @escaping (Result<Void, Error>, Bool) -> ()
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
                migrationsCompletion: migrationsCompletion
            )
            
            // The 'if' is only there to prevent the "variable never read" warning from showing
            if backgroundTask != nil { backgroundTask = nil }
        }
    }
    
    public static func runPostSetupMigrations(
        backgroundTask: OWSBackgroundTask? = nil,
        migrationProgressChanged: ((CGFloat, TimeInterval) -> ())? = nil,
        migrationsCompletion: @escaping (Result<Void, Error>, Bool) -> ()
    ) {
        var backgroundTask: OWSBackgroundTask? = (backgroundTask ?? OWSBackgroundTask(labelStr: #function))
        
        Storage.shared.perform(
            migrationTargets: [
                SNUtilitiesKit.self,
                SNSnodeKit.self,
                SNMessagingKit.self,
                SNUIKit.self
            ],
            onProgressUpdate: migrationProgressChanged,
            onComplete: { result, needsConfigSync in
                // After the migrations have run but before the migration completion we load the
                // SessionUtil state and update the 'needsConfigSync' flag based on whether the
                // configs also need to be sync'ed
                if Identity.userExists() {
                    SessionUtil.loadState(
                        userPublicKey: getUserHexEncodedPublicKey(),
                        ed25519SecretKey: Identity.fetchUserEd25519KeyPair()?.secretKey
                    )
                }
                
                // Refresh the migration state for 'SessionUtil' so it's logic can start running
                // correctly when called (doing this here instead of automatically via the
                // `SessionUtil.userConfigsEnabled` property to avoid having to use the correct
                // method when calling within a database read/write closure)
                Storage.shared.read { db in SessionUtil.refreshingUserConfigsEnabled(db) }
                
                migrationsCompletion(result, (needsConfigSync || SessionUtil.needsSync))
                
                // The 'if' is only there to prevent the "variable never read" warning from showing
                if backgroundTask != nil { backgroundTask = nil }
            }
        )
    }
}
