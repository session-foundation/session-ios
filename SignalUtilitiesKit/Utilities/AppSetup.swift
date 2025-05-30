// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUIKit
import SessionSnodeKit
import SessionMessagingKit
import SessionUtilitiesKit

public enum AppSetup {
    public static func setupEnvironment(
        requestId: String? = nil,
        additionalMigrationTargets: [MigratableTarget.Type] = [],
        appSpecificBlock: (() -> ())? = nil,
        migrationProgressChanged: ((CGFloat, TimeInterval) -> ())? = nil,
        migrationsCompletion: @escaping (Result<Void, Error>) -> (),
        using dependencies: Dependencies
    ) {
        var backgroundTask: SessionBackgroundTask? = SessionBackgroundTask(label: #function, using: dependencies)
        
        DispatchQueue.global(qos: .userInitiated).async {
            // Order matters here.
            //
            // All of these "singletons" should have any dependencies used in their
            // initializers injected.
            dependencies[singleton: .backgroundTaskManager].startObservingNotifications()
            
            // Attachments can be stored to NSTemporaryDirectory()
            // If you receive a media message while the device is locked, the download will fail if
            // the temporary directory is NSFileProtectionComplete
            try? dependencies[singleton: .fileManager].protectFileOrFolder(
                at: NSTemporaryDirectory(),
                fileProtectionType: .completeUntilFirstUserAuthentication
            )

            SessionEnvironment.shared = SessionEnvironment(
                audioSession: OWSAudioSession(),
                proximityMonitoringManager: OWSProximityMonitoringManagerImpl(using: dependencies),
                windowManager: OWSWindowManager(default: ())
            )
            appSpecificBlock?()
            
            runPostSetupMigrations(
                requestId: requestId,
                backgroundTask: backgroundTask,
                additionalMigrationTargets: additionalMigrationTargets,
                migrationProgressChanged: migrationProgressChanged,
                migrationsCompletion: migrationsCompletion,
                using: dependencies
            )
            
            // The 'if' is only there to prevent the "variable never read" warning from showing
            if backgroundTask != nil { backgroundTask = nil }
        }
    }
    
    public static func runPostSetupMigrations(
        requestId: String? = nil,
        backgroundTask: SessionBackgroundTask? = nil,
        additionalMigrationTargets: [MigratableTarget.Type] = [],
        migrationProgressChanged: ((CGFloat, TimeInterval) -> ())? = nil,
        migrationsCompletion: @escaping (Result<Void, Error>) -> (),
        using dependencies: Dependencies
    ) {
        var backgroundTask: SessionBackgroundTask? = (backgroundTask ?? SessionBackgroundTask(label: #function, using: dependencies))
        
        dependencies[singleton: .storage].perform(
            migrationTargets: additionalMigrationTargets
                .appending(contentsOf: [
                    SNUtilitiesKit.self,
                    SNSnodeKit.self,
                    SNMessagingKit.self
                ]),
            onProgressUpdate: migrationProgressChanged,
            onComplete: { result in
                // Now that the migrations are complete there are a few more states which need
                // to be setup
                typealias UserInfo = (sessionId: SessionId, ed25519SecretKey: [UInt8], unreadCount: Int?)
                let maybeUserInfo: UserInfo? = dependencies[singleton: .storage].read { db in
                    guard let ed25519KeyPair: KeyPair = Identity.fetchUserEd25519KeyPair(db) else {
                        return nil
                    }
                    
                    /// Cache the users session id so we don't need to fetch it from the database every time
                    dependencies.mutate(cache: .general) {
                        $0.setSecretKey(ed25519SecretKey: ed25519KeyPair.secretKey)
                    }
                    
                    /// Load the `libSession` state into memory
                    let userSessionId: SessionId = dependencies[cache: .general].sessionId
                    let cache: LibSession.Cache = LibSession.Cache(
                        userSessionId: userSessionId,
                        using: dependencies
                    )
                    cache.loadState(db, requestId: requestId)
                    dependencies.set(cache: .libSession, to: cache)
                    
                    return (
                        userSessionId,
                        ed25519KeyPair.secretKey,
                        try? Interaction.fetchAppBadgeUnreadCount(db, using: dependencies)
                    )
                }
                
                /// Save the `UserMetadata` and replicate `ConfigDump` data if needed
                if let userInfo: UserInfo = maybeUserInfo {
                    try? dependencies[singleton: .extensionHelper].saveUserMetadata(
                        sessionId: userInfo.sessionId,
                        ed25519SecretKey: userInfo.ed25519SecretKey,
                        unreadCount: userInfo.unreadCount
                    )
                    
                    Task {
                        dependencies[singleton: .extensionHelper].replicateAllConfigDumpsIfNeeded(
                            userSessionId: userInfo.sessionId
                        )
                    }
                }
                
                /// Ensure any recurring jobs are properly scheduled
                dependencies[singleton: .jobRunner].scheduleRecurringJobsIfNeeded()
                
                /// Callback that the migrations have completed
                migrationsCompletion(result)
                
                /// The 'if' is only there to prevent the "variable never read" warning from showing
                if backgroundTask != nil { backgroundTask = nil }
            }
        )
    }
}
