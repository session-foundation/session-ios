// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUIKit
import SessionMessagingKit
import SessionUtilitiesKit

public enum AppSetup {
    public static func performSetup(
        migrationProgressChanged: ((CGFloat, TimeInterval) -> ())? = nil,
        using dependencies: Dependencies
    ) async {
        var backgroundTask: SessionBackgroundTask? = SessionBackgroundTask(label: #function, using: dependencies)
        
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
        
        try await dependencies[singleton: .storage].perform(
            migrations: SNMessagingKit.migrations,
            onProgressUpdate: { [weak self] progress, minEstimatedTotalTime in
                self?.loadingViewController?.updateProgress(
                    progress: progress,
                    minEstimatedTotalTime: minEstimatedTotalTime
                )
            }
        )
    }
    
    public static func setup(
        backgroundTask: SessionBackgroundTask? = nil,
        migrationProgressChanged: ((CGFloat, TimeInterval) -> ())? = nil,
        using dependencies: Dependencies
    ) async {
        
    }
    
    public static func postMigrationSetup(using dependencies: Dependencies) async throws {
        /// Now that the migrations are complete there are a few more states which need to be setup
        typealias UserInfo = (
            sessionId: SessionId,
            ed25519SecretKey: [UInt8],
            dumpSessionIds: Set<SessionId>,
            unreadCount: Int?
        )
        let userInfo: UserInfo? = try await dependencies[singleton: .storage].readAsync { db -> UserInfo? in
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
            cache.loadState(db)
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
                dependencies[singleton: .extensionHelper].replicateAllConfigDumpsIfNeeded(
                    userSessionId: userInfo.sessionId,
                    allDumpSessionIds: userInfo.dumpSessionIds
                )
            }
        }
        
        /// Ensure any recurring jobs are properly scheduled
        dependencies[singleton: .jobRunner].scheduleRecurringJobsIfNeeded()
    }
}
