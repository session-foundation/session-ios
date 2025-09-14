// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import AVFoundation
import GRDB
import SessionUIKit
import SessionNetworkingKit
import SessionUtilitiesKit

public enum AppSetup {
    public static func performSetup(using dependencies: Dependencies) async throws {
        /// Order matters here.
        ///
        /// All of these "singletons" should have any dependencies used in their
        /// initializers injected.
        dependencies[singleton: .backgroundTaskManager].startObservingNotifications()
        
        /// Attachments can be stored to NSTemporaryDirectory()
        /// If you receive a media message while the device is locked, the download will fail if
        /// the temporary directory is NSFileProtectionComplete
        try? dependencies[singleton: .fileManager].protectFileOrFolder(
            at: NSTemporaryDirectory(),
            fileProtectionType: .completeUntilFirstUserAuthentication
        )

        SessionEnvironment.shared = SessionEnvironment(
            audioSession: OWSAudioSession(),
            proximityMonitoringManager: OWSProximityMonitoringManagerImpl(using: dependencies),
            windowManager: OWSWindowManager(default: ())
        )
        
        dependencies.warm(cache: .appVersion)
        dependencies.warm(singleton: .network)
        
        /// Configure the different targets
        SNUtilitiesKit.configure(
            networkMaxFileSize: Network.maxFileSize,
            maxValidImageDimention: ImageDataManager.DataSource.maxValidDimension,
            using: dependencies
        )
        SNMessagingKit.configure(using: dependencies)
    }
    
    public static func performDatabaseMigrations(
        using dependencies: Dependencies,
        migrationProgressChanged: ((CGFloat, TimeInterval) -> ())? = nil
    ) async throws {
        /// Run the migrations
        try await dependencies[singleton: .storage].perform(
            migrations: SNMessagingKit.migrations,
            onProgressUpdate: migrationProgressChanged
        )
    }
    
    public static func postMigrationSetup(using dependencies: Dependencies) async throws {
        /// Now that the migrations are complete there are a few more states which need to be setup
        typealias UserInfo = (
            sessionId: SessionId,
            ed25519SecretKey: [UInt8],
            dumpSessionIds: Set<SessionId>,
            unreadCount: Int?
        )
        let userInfo: UserInfo? = try? await dependencies[singleton: .storage].readAsync { db -> UserInfo? in
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
            try? cache.loadState(db, userEd25519SecretKey: ed25519KeyPair.secretKey)
            dependencies.set(cache: .libSession, to: cache)
            
            return (
                userSessionId,
                ed25519KeyPair.secretKey,
                cache.allDumpSessionIds,
                try? Interaction.fetchAppBadgeUnreadCount(db, using: dependencies)
            )
        }
        
        /// Save the `UserMetadata` and replicate `ConfigDump` data if needed
        if let userInfo: UserInfo = userInfo {
            try? dependencies[singleton: .extensionHelper].saveUserMetadata(
                sessionId: userInfo.sessionId,
                ed25519SecretKey: userInfo.ed25519SecretKey,
                unreadCount: userInfo.unreadCount
            )
            
            Task.detached(priority: .medium) {
                await dependencies[singleton: .extensionHelper].replicateAllConfigDumpsIfNeeded(
                    userSessionId: userInfo.sessionId,
                    allDumpSessionIds: userInfo.dumpSessionIds
                )
            }
        }
        
        /// Ensure any recurring jobs are properly scheduled
        dependencies[singleton: .jobRunner].scheduleRecurringJobsIfNeeded()
    }
}
