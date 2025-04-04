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
        
        /// Migrate the database file from the `AppGroup` to the documents directory if we haven't already done so
        do { try dependencies[singleton: .extensionHelper].migrateDatabaseToMainAppIfNeeded() }
        catch {
            dependencies.set(
                singleton: .storage,
                to: Storage.createInvalid(with: error, using: dependencies)
            )
        }
        
        /// Perform any database migrations
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
                typealias UserInfo = (sessionId: SessionId, ed25519SecretKey: [UInt8])
                let maybeUserInfo: UserInfo? = dependencies[singleton: .storage].read { db -> UserInfo? in
                    guard
                        Identity.userExists(db, using: dependencies),
                        let userKeyPair: KeyPair = Identity.fetchUserKeyPair(db),
                        let userEdKeyPair: KeyPair = Identity.fetchUserEd25519KeyPair(db)
                    else { return nil }
                    
                    let userSessionId: SessionId = SessionId(.standard, publicKey: userKeyPair.publicKey)
                    
                    /// Cache the users session id so we don't need to fetch it from the database every time
                    dependencies.mutate(cache: .general) {
                        $0.setCachedSessionId(sessionId: userSessionId)
                    }
                    
                    /// Load the `libSession` state into memory
                    let cache: LibSession.Cache = LibSession.Cache(
                        userSessionId: userSessionId,
                        using: dependencies
                    )
                    cache.loadState(db, requestId: requestId)
                    dependencies.set(cache: .libSession, to: cache)
                    
                    return (userSessionId, userEdKeyPair.secretKey)
                }
                
                /// Save the `UserMetadata` and replicate `ConfigDump` data if needed
                if let userInfo: UserInfo = maybeUserInfo {
                    dependencies[singleton: .extensionHelper].saveUserMetadataIfNeeded(
                        sessionId: userInfo.sessionId,
                        ed25519SecretKey: userInfo.ed25519SecretKey
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
