// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import AVFoundation
import GRDB
import SDWebImageWebPCoder
import SessionUIKit
import SessionNetworkingKit
import SessionUtilitiesKit

// MARK: - Log.Category

public extension Log.Category {
    static let appSetup: Log.Category = .create("AppSetup", defaultLevel: .info)
}

// MARK: - AppSetup

public enum AppSetup {
    public static func performSetup(using dependencies: Dependencies) async throws {
        /// Attachments can be stored to NSTemporaryDirectory()
        /// If you receive a media message while the device is locked, the download will fail if
        /// the temporary directory is NSFileProtectionComplete
        try? dependencies[singleton: .fileManager].protectFileOrFolder(
            at: NSTemporaryDirectory(),
            fileProtectionType: .completeUntilFirstUserAuthentication
        )
        
        /// Need to register the WebP coder for encoding purposes
        SDImageCodersManager.shared.addCoder(SDImageWebPCoder.shared)

        SessionEnvironment.shared = SessionEnvironment(
            proximityMonitoringManager: OWSProximityMonitoringManagerImpl(using: dependencies)
        )
        
        dependencies.warm(cache: .appVersion)
        
        /// Only warm the network if we don't want to defer it's creation to the first request (eg. Notification Service Extension)
        if !dependencies[singleton: .appContext].shouldDeferNetworkInitialisation {
            dependencies.warm(singleton: .network)
        }
        
        dependencies.warm(singleton: .sessionProManager)
        dependencies.warm(singleton: .attachmentManager)
        
        /// Configure the different targets
        SNUtilitiesKit.configure(
            networkMaxFileSize: Network.maxFileSize,
            maxValidImageDimention: ImageDataManager.DataSource.maxValidDimension,
            using: dependencies
        )
        await SNMessagingKit.configureJobRunner(using: dependencies)
    }
    
    public static func performDatabaseMigrations(
        using dependencies: Dependencies,
        migrationProgressChanged: (@MainActor (CGFloat, TimeInterval) -> ())? = nil
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
        /// This read is what decides whether the user has an account: an empty result sends the caller to the onboarding
        /// flow. A failure to read must therefore surface as a failure rather than as an empty result, because a
        /// registration started from a misread database overwrites the identity it failed to see, keeping no copy
        func readUserInfo() async throws -> UserInfo? {
            return try await dependencies[singleton: .storage].read { db -> UserInfo? in
                guard let ed25519KeyPair: KeyPair = try Identity.fetchUserEd25519KeyPair(db) else {
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
        }
        
        var userInfo: UserInfo? = try await readUserInfo()
        
        /// A database whose identity is missing while its other data survives is never a new user (see
        /// `recoverIdentityIfPossible`), so try to put the identity back before anything treats the device as having no account
        if userInfo == nil, await AppSetup.recoverIdentityIfPossible(using: dependencies) {
            userInfo = try await readUserInfo()
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
        
        /// Load community data into memory
        await dependencies[singleton: .communityManager].loadCacheIfNeeded()

        /// Copy keychain items into the app group's access group so they survive a change of team ID
        ///
        /// This runs on every launch rather than once, because the keys are created lazily at different times -
        /// `dbCipherKeySpec` when the database is first opened, the others on first use - so a single run would
        /// permanently miss whichever keys did not exist yet. The migration is idempotent, so repeating it is
        /// only the cost of a few keychain operations
        ///
        /// It has to run **after** the database is set up: on a fresh install `dbCipherKeySpec` does not exist
        /// until then, and a migration that ran earlier would find nothing to copy
        KeychainAccessGroupMigration.run(
            keys: [
                .dbCipherKeySpec,
                .extensionEncryptionKey,
                .pushNotificationEncryptionKey
            ],
            using: dependencies
        )
    }
}

// MARK: - Identity Recovery

public extension AppSetup {
    /// Derives both key pairs from an ed25519 secret key the way registration derives them from the seed, and only when the secret
    /// key is the one its own seed produces - so a malformed or truncated key yields nothing rather than a different identity
    static func identityKeyPairs(
        ed25519SecretKey: [UInt8],
        using dependencies: Dependencies
    ) -> (ed25519KeyPair: KeyPair, x25519KeyPair: KeyPair)? {
        guard
            ed25519SecretKey.count >= 32,
            let ed25519KeyPair: KeyPair = dependencies[singleton: .crypto].generate(
                .ed25519KeyPair(seed: Array(ed25519SecretKey.prefix(upTo: 32)))
            ),
            ed25519KeyPair.secretKey == ed25519SecretKey,
            let x25519PublicKey: [UInt8] = dependencies[singleton: .crypto].generate(
                .x25519(ed25519Pubkey: ed25519KeyPair.publicKey)
            ),
            let x25519SecretKey: [UInt8] = dependencies[singleton: .crypto].generate(
                .x25519(ed25519Seckey: ed25519KeyPair.secretKey)
            )
        else { return nil }
        
        return (ed25519KeyPair, KeyPair(publicKey: x25519PublicKey, secretKey: x25519SecretKey))
    }
    
    /// The Session IDs the user config dumps were written for - only ever the account's own, so it identifies whose data this is
    /// even when the identity rows are gone
    static func userConfigSessionIds(_ db: ObservingDatabase) throws -> Set<String> {
        return Set(try ConfigDump
            .select(.publicKey)
            .filter(ConfigDump.Variant.userVariants.contains(ConfigDump.Columns.variant))
            .asRequest(of: String.self)
            .fetchAll(db))
    }
    
    /// Whether a key held for the extensions may be stored as the identity of a database which has none
    ///
    /// No user action leaves a database with its data but without its identity: clearing the device removes the extension cache,
    /// and "Clear Device and Restore" removes it along with the whole database. So the state only arises by accident, and the key
    /// is only accepted when it provably belongs to the data - the Session ID it derives must be the one every user config dump
    /// was written for, which a key from any other account cannot produce
    static func canRecoverIdentity(
        identityRowCount: Int,
        metadataSessionId: SessionId,
        keySessionId: SessionId,
        userConfigSessionIds: Set<String>
    ) -> Bool {
        /// Any row at all means an identity exists, even a partial one, and that must never be overwritten
        guard identityRowCount == 0 else { return false }
        guard metadataSessionId == keySessionId else { return false }
        
        return (userConfigSessionIds == [keySessionId.hexString])
    }
    
    /// Stores the identity from the extension metadata when the database has lost its own, so startup can continue into the
    /// account instead of onboarding
    ///
    /// **Never throws, and does nothing unless every check passes.** This runs in the startup path, so any failure has to leave
    /// startup exactly where it was - with no user, heading to onboarding
    ///
    /// - Returns: whether an identity was stored
    static func recoverIdentityIfPossible(using dependencies: Dependencies) async -> Bool {
        /// The extensions only read the metadata, and must not decide on their own that the app's account should come back
        guard dependencies[singleton: .appContext].isMainApp else { return false }
        
        /// Checking the file first avoids generating the metadata's encryption key on a fresh install
        guard
            dependencies[singleton: .extensionHelper].userMetadataExists(),
            let metadata: ExtensionHelper.UserMetadata = dependencies[singleton: .extensionHelper].loadUserMetadata(),
            let keyPairs: (ed25519KeyPair: KeyPair, x25519KeyPair: KeyPair) = AppSetup.identityKeyPairs(
                ed25519SecretKey: metadata.ed25519SecretKey,
                using: dependencies
            )
        else { return false }
        
        let keySessionId: SessionId = SessionId(.standard, publicKey: keyPairs.x25519KeyPair.publicKey)
        
        do {
            /// The checks run inside the write so that an identity stored between checking and writing is never overwritten
            let restoredDataCounts: (threads: Int, interactions: Int)? = try await dependencies[singleton: .storage].write { db in
                let canRecover: Bool = AppSetup.canRecoverIdentity(
                    identityRowCount: try Identity.fetchCount(db),
                    metadataSessionId: metadata.sessionId,
                    keySessionId: keySessionId,
                    userConfigSessionIds: try AppSetup.userConfigSessionIds(db)
                )
                
                guard canRecover else { return nil }
                
                try Identity.store(
                    db,
                    ed25519KeyPair: keyPairs.ed25519KeyPair,
                    x25519KeyPair: keyPairs.x25519KeyPair
                )
                
                return (try SessionThread.fetchCount(db), try Interaction.fetchCount(db))
            }
            
            guard let restoredDataCounts else { return false }
            
            Log.critical(.appSetup, "Restored the missing identity from the extension metadata (threads: \(restoredDataCounts.threads), interactions: \(restoredDataCounts.interactions)).")
            return true
        }
        catch {
            Log.critical(.appSetup, "Failed to restore the missing identity: \(error)")
            return false
        }
    }
}
