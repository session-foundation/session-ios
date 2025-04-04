// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit

// MARK: - Singleton

public extension Singleton {
    static let extensionHelper: SingletonConfig<ExtensionHelper> = Dependencies.create(
        identifier: "extensionHelper",
        createInstance: { dependencies in ExtensionHelper(using: dependencies) }
    )
}

// MARK: - KeychainStorage

// stringlint:ignore_contents
public extension KeychainStorage.DataKey {
    static let extensionEncryptionKey: Self = "ExtensionEncryptionKeyKey"
}

// MARK: - Log.Category

private extension Log.Category {
    static let cat: Log.Category = .create("ExtensionHelper", defaultLevel: .info)
}

// MARK: - ExtensionHelper

public class ExtensionHelper {
    public static var sharedExtensionCacheDirectoryPath: String { "\(SessionFileManager.nonInjectedAppSharedDataDirectoryPath)/extensionCache" }
    private static var metadataPath: String { "\(ExtensionHelper.sharedExtensionCacheDirectoryPath)/metadata" }
    private static func dumpFilePath(_ hash: [UInt8]) -> String {
        return "\(ExtensionHelper.sharedExtensionCacheDirectoryPath)/\(hash.toHexString())"
    }
    private let encryptionKeyLength: Int = 32
    
    private let dependencies: Dependencies
    
    // MARK: - Initialization
    
    init(using dependencies: Dependencies) {
        self.dependencies = dependencies
    }
    
    // MARK: - User Metadata
    
    public func saveUserMetadataIfNeeded(sessionId: SessionId, ed25519SecretKey: [UInt8]) {
        /// Create the `UserMetadata` if needed
        guard !dependencies[singleton: .fileManager].fileExists(atPath: ExtensionHelper.metadataPath) else {
            return
        }
        
        saveUserMetadata(
            sessionId: sessionId,
            ed25519SecretKey: ed25519SecretKey
        )
    }
    
    public func saveUserMetadata(sessionId: SessionId, ed25519SecretKey: [UInt8]) {
        let metadata: UserMetadata = UserMetadata(
            sessionId: sessionId,
            ed25519SecretKey: ed25519SecretKey
        )
        
        /// Load in the data and `encKey` and reset the `encKey` as soon as the function ends
        guard
            let metadataAsData: Data = try? JSONEncoder(using: dependencies).encode(metadata),
            var encKey: [UInt8] = (try? dependencies[singleton: .keychain]
                .getOrGenerateEncryptionKey(
                    forKey: .extensionEncryptionKey,
                    length: encryptionKeyLength,
                    cat: .cat
                )).map({ Array($0) })
        else { return }
        defer { encKey.resetBytes(in: 0..<encKey.count) }
        
        guard
            let ciphertext: Data = dependencies[singleton: .crypto].generate(
                .ciphertextWithXChaCha20(
                    plaintext: metadataAsData,
                    encKey: encKey
                )
            )
        else { return }
        
        let plain: Data? = dependencies[singleton: .crypto].generate(
            .plaintextWithXChaCha20(
                ciphertext: ciphertext,
                encKey: encKey
            )
        )
        
        /// Ensure the directory exists
        try? dependencies[singleton: .fileManager]
            .ensureDirectoryExists(at: ExtensionHelper.sharedExtensionCacheDirectoryPath)
        try? dependencies[singleton: .fileManager]
            .protectFileOrFolder(at: ExtensionHelper.sharedExtensionCacheDirectoryPath)
        
        /// Write the encrypted data to a temporary file, remove the old one and move it from the temp file to the final location
        try? dependencies[singleton: .fileManager].removeItem(atPath: "\(ExtensionHelper.metadataPath)-new")
        try? ciphertext.write(to: URL(fileURLWithPath: "\(ExtensionHelper.metadataPath)-new"))
        try? dependencies[singleton: .fileManager].removeItem(atPath: ExtensionHelper.metadataPath)
        try? dependencies[singleton: .fileManager].moveItem(
            atPath: "\(ExtensionHelper.metadataPath)-new",
            toPath: ExtensionHelper.metadataPath
        )
    }
    
    public func loadUserMetadata() -> UserMetadata? {
        /// Load in the data and `encKey` and reset the `encKey` as soon as the function ends
        guard
            let ciphertext: Data = dependencies[singleton: .fileManager]
                .contents(atPath: ExtensionHelper.metadataPath),
            var encKey: [UInt8] = (try? dependencies[singleton: .keychain]
                .getOrGenerateEncryptionKey(
                    forKey: .extensionEncryptionKey,
                    length: encryptionKeyLength,
                    cat: .cat
                )).map({ Array($0) })
        else { return nil }
        defer { encKey.resetBytes(in: 0..<encKey.count) }

        guard
            let plaintext: Data = dependencies[singleton: .crypto].generate(
                .plaintextWithXChaCha20(
                    ciphertext: ciphertext,
                    encKey: encKey
                )
            )
        else { return nil }
        
        return try? JSONDecoder(using: dependencies)
            .decode(UserMetadata.self, from: plaintext)
    }
    
    
    // TODO: [DATABASE REFACTOR] Encrypt/Decrypt functions for files
    
    // TODO: [DATABASE REFACTOR] Write metadata to file in AppGroup
    // TODO: [DATABASE REFACTOR] Load in metadata from file in AppGroup
    // TODO: [DATABASE REFACTOR] Update config dumps in PN Extension (in case app doesn't get opened for a while)
    // TODO: [DATABASE REFACTOR] Write message data to files in AppGroup
    // TODO: [DATABASE REFACTOR] Read message data from files in AppGroup
    // TODO: [DATABASE REFACTOR] Update share extension to send messages but not save to the database
    // TODO: [DATABASE REFACTOR] Process message solely for notification purposes
    
    
    // TODO: [DATABASE REFACTOR] LibSession Changes
        // TODO: Add local_path to "profile_pic" and store locally in userProfile, contacts, userGroups, groupInfo, groupMembers.member config dumps
        // TODO: Add community.name in local userGroup config dump
        // TODO: Add community.permissions in local userGroup config dump
        // TODO: Need to make sure we are syncing the 'joinedAt' for communities
        // TODO: Need to start syncing the notification settings
        // TODO: Need to add a new synced 'active_at' timestamp to the ConvoInfoVolatile config
            // TODO: Update on:
                // TODO: Create (or join) a conversation
                // TODO: Receive a message (regardless of reading/deleting/disappearing)
                // TODO: Sending a message or control message (but not a reaction)
                // TODO: Unblock a contact
                // TODO: Accepting a message request
                // TODO: When unblinding a conversation (max value)
    
    // TODO: [DATABASE REFACTOR] Add support for blinded outgoing conversations? (in userGroups? contacts?)
    
    // MARK: - Config Dumps
    
    private func hash(for sessionId: SessionId, variant: ConfigDump.Variant) -> [UInt8]? {
        return "\(sessionId.hexString)-\(variant)".data(using: .utf8).map { dataToHash in
            dependencies[singleton: .crypto].generate(
                .hash(message: Array(dataToHash))
            )
        }
    }
    
    public func loadConfigState(
        into cache: LibSession.Cache,
        for sessionId: SessionId,
        userSessionId: SessionId,
        userEd25519SecretKey: [UInt8]
    ) {
        /// Load in the data and `encKey` and reset the `encKey` as soon as the function ends
        guard
            var encKey: [UInt8] = (try? dependencies[singleton: .keychain]
                .getOrGenerateEncryptionKey(
                    forKey: .extensionEncryptionKey,
                    length: encryptionKeyLength,
                    cat: .cat
                )).map({ Array($0) })
        else { return }
        defer { encKey.resetBytes(in: 0..<encKey.count) }
        
        /// We always need to load the User Config states even if we want to load the config for a group (because they store the group
        /// secret key if the user is an admin)
        ConfigDump.Variant.userVariants
            .sorted { $0.loadOrder < $1.loadOrder }
            .forEach { variant in
                guard
                    let hash: [UInt8] = hash(for: userSessionId, variant: variant),
                    let ciphertext: Data = dependencies[singleton: .fileManager].contents(
                        atPath: "\(ExtensionHelper.dumpFilePath(hash))"
                    ),
                    let plaintext: Data = dependencies[singleton: .crypto].generate(
                        .plaintextWithXChaCha20(
                            ciphertext: ciphertext,
                            encKey: encKey
                        )
                    ),
                    let config: LibSession.Config = try? cache.loadState(
                        for: variant,
                        sessionId: userSessionId,
                        userEd25519SecretKey: userEd25519SecretKey,
                        groupEd25519SecretKey: nil,
                        cachedData: plaintext
                    )
                else {
                    /// If a file doesn't exist at the path then assume we don't have a config dump and just load in a default one
                    return cache.loadDefaultStateFor(
                        variant: variant,
                        sessionId: userSessionId,
                        userEd25519SecretKey: userEd25519SecretKey,
                        groupEd25519SecretKey: nil
                    )
                }
                
                cache.setConfig(for: variant, sessionId: userSessionId, to: config)
            }
        
        /// If we only care about the user configs then we can stop here
        guard sessionId != userSessionId else { return }
        
        // TODO: [DATABASE REFACTOR] Load the config state for the desired group
    }
    
    public func replicate(dump: ConfigDump?, replaceExisting: Bool = true) {
        /// Load in the data and `encKey` and reset the `encKey` as soon as the function ends
        guard
            let dump: ConfigDump = dump,
            let hash: [UInt8] = hash(for: dump.sessionId, variant: dump.variant),
            var encKey: [UInt8] = (try? dependencies[singleton: .keychain]
                .getOrGenerateEncryptionKey(
                    forKey: .extensionEncryptionKey,
                    length: encryptionKeyLength,
                    cat: .cat
                )).map({ Array($0) })
        else { return }
        defer { encKey.resetBytes(in: 0..<encKey.count) }
        
        /// Only continue if we want to replace an existing dump, or one doesn't exist
        guard
            replaceExisting ||
            !dependencies[singleton: .fileManager].fileExists(
                atPath: "\(ExtensionHelper.dumpFilePath(hash))"
            )
        else { return }
        
        /// Ensure the directory exists
        try? dependencies[singleton: .fileManager]
            .ensureDirectoryExists(at: ExtensionHelper.sharedExtensionCacheDirectoryPath)
        try? dependencies[singleton: .fileManager]
            .protectFileOrFolder(at: ExtensionHelper.sharedExtensionCacheDirectoryPath)
        
        /// Generate the `ciphertext` and save it to the `AppGroup`
        do {
            let ciphertext: Data = try dependencies[singleton: .crypto].tryGenerate(
                .ciphertextWithXChaCha20(
                    plaintext: dump.data,
                    encKey: encKey
                )
            )
            
            try? dependencies[singleton: .fileManager].removeItem(
                atPath: "\(ExtensionHelper.dumpFilePath(hash))-new"
            )
            try ciphertext.write(to: URL(fileURLWithPath: "\(ExtensionHelper.dumpFilePath(hash))-new"))
            try? dependencies[singleton: .fileManager].removeItem(
                atPath: "\(ExtensionHelper.dumpFilePath(hash))"
            )
            try dependencies[singleton: .fileManager].moveItem(
                atPath: "\(ExtensionHelper.dumpFilePath(hash))-new",
                toPath: "\(ExtensionHelper.dumpFilePath(hash))"
            )
        }
        catch { Log.error(.cat, "Failed to replicate \(dump.variant) dump for \(dump.sessionId.hexString).") }
    }
    
    // MARK: - Initial Database Location Migration

    public func migrateDatabaseToMainAppIfNeeded() throws {
        let sharedDatabaseDirectoryPath: String = "\(SessionFileManager.nonInjectedAppSharedDataDirectoryPath)/database"
        
        /// No need to move the database if it's already been moved
        guard dependencies[singleton: .fileManager].fileExists(atPath: sharedDatabaseDirectoryPath) else {
            return
        }
        
        /// Move the database directory from the `AppGroup` to the local documents directory
        do {
            try dependencies[singleton: .fileManager]
                .moveItem(atPath: sharedDatabaseDirectoryPath, toPath: Storage.databaseDirectoryPath)
        }
        catch {
            Log.critical("Failed to migrate database file: \(error)")
            throw error
        }
    }
    
    public func replicateAllConfigDumpsIfNeeded(userSessionId: SessionId) {
        /// We can be reasonably sure that if the `userProfile` config dump is missing then we probably haven't replicated any
        /// config dumps yet and should do so
        guard
            let hash: [UInt8] = hash(for: userSessionId, variant: .userProfile),
            !dependencies[singleton: .fileManager].fileExists(
                atPath: "\(ExtensionHelper.dumpFilePath(hash))"
            )
        else { return }
        
        /// Load the config dumps from the database
        let dumps: [ConfigDump] = dependencies[singleton: .storage]
            .read { db in try ConfigDump.fetchAll(db) }
            .defaulting(to: [])
        
        /// Persist each dump to disk (if there isn't already one there)
        ///
        /// **Note:** Because it's likely that this function runs in the background it's possible that another thread could trigger
        /// a config update which would result in the dump getting replicated - if that occurs then we don't want to override what
        /// is likely a newer dump
        dumps.forEach { dump in replicate(dump: dump, replaceExisting: false) }
    }
}

// MARK: - ExtensionHelper.UserMetadata

public extension ExtensionHelper {
    struct UserMetadata: Codable {
        public let sessionId: SessionId
        public let ed25519SecretKey: [UInt8]
    }
}
