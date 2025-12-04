// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionNetworkingKit
import SessionUtilitiesKit

// MARK: - Singleton

public extension Singleton {
    static let extensionHelper: SingletonConfig<ExtensionHelperType> = Dependencies.create(
        identifier: "extensionHelper",
        // TODO: [Database Relocation] Might be good to add a mechanism to check if we can access the AppGroup and, if not, create a NoopExtensionHelper (to better support side-loading the app)
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

public class ExtensionHelper: ExtensionHelperType {
    // stringlint:ignore_start
    private lazy var cacheDirectoryPath: String = "\(dependencies[singleton: .fileManager].appSharedDataDirectoryPath)/extensionCache"
    private lazy var metadataPath: String = "\(cacheDirectoryPath)/metadata"
    private lazy var conversationsPath: String = "\(cacheDirectoryPath)/conversations"
    private lazy var notificationSettingsPath: String = "\(cacheDirectoryPath)/notificationSettings"
    private let conversationConfigDir: String = "config"
    private let conversationReadDir: String = "read"
    private let conversationUnreadDir: String = "unread"
    private let conversationDedupeDir: String = "dedupe"
    private let conversationMessageRequestStub: String = "messageRequest"
    private let encryptionKeyLength: Int = 32
    // stringlint:ignore_stop
    
    private let dependencies: Dependencies
    private lazy var messagesLoadedStream: CurrentValueAsyncStream<Bool> = CurrentValueAsyncStream(false)
    
    // MARK: - Initialization
    
    init(using dependencies: Dependencies) {
        self.dependencies = dependencies
    }
    
    // MARK: - File Management
    
    // stringlint:ignore_contents
    private func conversationPath(_ threadId: String) -> String? {
        guard
            let hash: [UInt8] = dependencies[singleton: .crypto].generate(
                .hash(message: Array("ConvoIdSalt-\(threadId)".utf8))
            )
        else { return nil }
        
        return URL(fileURLWithPath: conversationsPath)
            .appendingPathComponent(hash.toHexString())
            .path
    }
    
    private func write(data: Data, to path: String) throws {
        /// Load in the data and `encKey` and reset the `encKey` as soon as the function ends
        guard
            var encKey: [UInt8] = (try? dependencies[singleton: .keychain]
                .getOrGenerateEncryptionKey(
                    forKey: .extensionEncryptionKey,
                    length: encryptionKeyLength,
                    cat: .cat
                )).map({ Array($0) })
        else { throw ExtensionHelperError.noEncryptionKey }
        defer { encKey.resetBytes(in: 0..<encKey.count) }
        
        /// Ensure the directory exists
        let parentDirectory: String = URL(fileURLWithPath: path)
            .deletingLastPathComponent()
            .path
        try? dependencies[singleton: .fileManager].ensureDirectoryExists(at: parentDirectory)
        try? dependencies[singleton: .fileManager].protectFileOrFolder(at: parentDirectory)
        
        /// Generate the `ciphertext`
        let ciphertext: Data = try dependencies[singleton: .crypto].tryGenerate(
            .ciphertextWithXChaCha20(
                plaintext: data,
                encKey: encKey
            )
        )
        
        /// Write the data to a temporary file first, then remove any existing file and move the temporary file to the final path
        let tmpPath: String = dependencies[singleton: .fileManager].temporaryFilePath(fileExtension: nil)
        
        do { try dependencies[singleton: .fileManager].write(data: ciphertext, toPath: tmpPath) }
        catch { throw ExtensionHelperError.failedToWriteToFile(error) }
        _ = try dependencies[singleton: .fileManager].replaceItem(atPath: path, withItemAtPath: tmpPath)
        
        /// Need to update the `fileProtectionType` of the written file because as of `iOS 26` it seems to retain the setting
        /// from the original storage directory instead if inheriting the setting of the current directory (and since we write to a temporary
        /// directory it defaults to having `complete` protection instead of `completeUntilFirstUserAuthentication`)
        try? dependencies[singleton: .fileManager].protectFileOrFolder(at: path)
    }
    
    private func read(from path: String) throws -> Data {
        /// Load in the data and `encKey` and reset the `encKey` as soon as the function ends
        guard var encKey: [UInt8] = (try? dependencies[singleton: .keychain].getOrGenerateEncryptionKey(
            forKey: .extensionEncryptionKey,
            length: encryptionKeyLength,
            cat: .cat
        )).map({ Array($0) }) else {
            Log.error(.cat, "Failed to retrieve encryption key")
            throw ExtensionHelperError.noEncryptionKey
        }
        defer { encKey.resetBytes(in: 0..<encKey.count) }

        let ciphertext: Data
        
        do { ciphertext = try dependencies[singleton: .fileManager].contents(atPath: path) }
        catch {
            Log.error(.cat, "Failed to read contents of file due to error: \(error)")
            throw ExtensionHelperError.failedToReadFromFile
        }
        
        guard let plaintext: Data = dependencies[singleton: .crypto].generate(
            .plaintextWithXChaCha20(
                ciphertext: ciphertext,
                encKey: encKey
            )
        ) else {
            Log.error(.cat, "Failed to decrypt contents of file")
            throw ExtensionHelperError.failedToReadFromFile
        }
        
        return plaintext
    }
    
    private func createdTimestamp(for path: String) -> TimeInterval? {
        guard dependencies[singleton: .fileManager].fileExists(atPath: path) else { return nil }
        
        return ((try? dependencies[singleton: .fileManager]
            .attributesOfItem(atPath: path)
            .getting(.creationDate) as? Date)?
            .timeIntervalSince1970)
    }
    
    public func lastModifiedTimestamp(for path: String) -> TimeInterval? {
        guard dependencies[singleton: .fileManager].fileExists(atPath: path) else { return nil }
        
        return ((try? dependencies[singleton: .fileManager]
            .attributesOfItem(atPath: path)
            .getting(.modificationDate) as? Date)?
            .timeIntervalSince1970)
    }
    
    private func refreshModifiedDate(at path: String) throws {
        guard dependencies[singleton: .fileManager].fileExists(atPath: path) else { return }
        
        try dependencies[singleton: .fileManager].setAttributes(
            [.modificationDate: dependencies.dateNow],
            ofItemAtPath: path
        )
    }
    
    public func deleteCache() {
        try? dependencies[singleton: .fileManager].removeItem(atPath: cacheDirectoryPath)
    }
    
    // MARK: - User Metadata
    
    public func saveUserMetadata(
        sessionId: SessionId,
        ed25519SecretKey: [UInt8],
        unreadCount: Int?
    ) throws {
        let metadata: UserMetadata = UserMetadata(
            sessionId: sessionId,
            ed25519SecretKey: ed25519SecretKey,
            unreadCount: (unreadCount ?? 0)
        )
        
        guard let metadataAsData: Data = try? JSONEncoder(using: dependencies).encode(metadata) else { return }
        
        try write(data: metadataAsData, to: metadataPath)
    }
    
    public func loadUserMetadata() -> UserMetadata? {
        guard let plaintext: Data = try? read(from: metadataPath) else { return nil }
        
        do {
            return try JSONDecoder(using: dependencies)
                .decode(UserMetadata.self, from: plaintext)
        }
        catch {
            Log.error(.cat, "Failed to parse UserMetadata")
            return nil
        }
    }
    
    // MARK: - Deduping
    
    // stringlint:ignore_contents
    private func dedupeRecordPath(_ threadId: String, _ uniqueIdentifier: String) -> String? {
        guard
            let conversationPath: String = conversationPath(threadId),
            let hash: [UInt8] = dependencies[singleton: .crypto].generate(
                .hash(message: Array("DedupeRecordSalt-\(uniqueIdentifier)".utf8))
            )
        else { return nil }
        
        return URL(fileURLWithPath: conversationPath)
            .appendingPathComponent(conversationDedupeDir)
            .appendingPathComponent(hash.toHexString())
            .path
    }
    
    // stringlint:ignore_contents
    private func lastClearedRecordPath(conversationPath: String) -> String? {
        guard
            let hash: [UInt8] = dependencies[singleton: .crypto].generate(
                .hash(message: Array("LastClearedSalt-\(conversationPath)".utf8))
            )
        else { return nil }
        
        return URL(fileURLWithPath: conversationPath)
            .appendingPathComponent(conversationDedupeDir)
            .appendingPathComponent(hash.toHexString())
            .path
    }
    
    private func dedupeRecordTimestampsSinceLastCleared(conversationPath: String) -> [TimeInterval] {
        /// Using `lastModified` for the `lastClearedRecord` because if the file already existed when clearing then it's
        /// `created` timestamp wouldn't get updated
        let lastClearedPath: String? = lastClearedRecordPath(conversationPath: conversationPath)
        let lastClearedTimestamp: TimeInterval = lastClearedPath
            .map { lastModifiedTimestamp(for: $0) }
            .defaulting(to: 0)
        let dedupePath: String = URL(fileURLWithPath: conversationPath)
            .appendingPathComponent(conversationDedupeDir)
            .path
        
        return (try? dependencies[singleton: .fileManager]
            .contentsOfDirectory(atPath: dedupePath))
            .defaulting(to: [])
            .compactMap { fileHash in
                let filePath: String = URL(fileURLWithPath: dedupePath).appendingPathComponent(fileHash).path
                
                /// Ignore the `lastClearedPath` since it doesn't represent a message and add a `100 millisecond` buffer
                /// to account for different write times of the separate files
                guard
                    filePath != lastClearedPath,
                    let fileCreatedTimestamp: TimeInterval = createdTimestamp(for: filePath),
                    fileCreatedTimestamp >= (lastClearedTimestamp - 0.1)
                else { return nil }
                    
                return fileCreatedTimestamp
            }
    }
    
    public func hasDedupeRecordSinceLastCleared(threadId: String) -> Bool {
        guard let conversationPath: String = conversationPath(threadId) else { return false }
        
        return (dedupeRecordTimestampsSinceLastCleared(conversationPath: conversationPath).count > 0)
    }
    
    public func dedupeRecordExists(threadId: String, uniqueIdentifier: String) -> Bool {
        guard let path: String = dedupeRecordPath(threadId, uniqueIdentifier) else { return false }
        
        return dependencies[singleton: .fileManager].fileExists(atPath: path)
    }
    
    public func createDedupeRecord(threadId: String, uniqueIdentifier: String) throws {
        guard let path: String = dedupeRecordPath(threadId, uniqueIdentifier) else {
            throw ExtensionHelperError.failedToStoreDedupeRecord
        }
        
        try write(data: Data(), to: path)
    }
    
    public func removeDedupeRecord(threadId: String, uniqueIdentifier: String) throws {
        guard let path: String = dedupeRecordPath(threadId, uniqueIdentifier) else {
            throw ExtensionHelperError.failedToRemoveDedupeRecord
        }
        
        try dependencies[singleton: .fileManager].removeItem(atPath: path)
        
        /// Also remove the directory if it's empty
        let parentDirectory: String = URL(fileURLWithPath: path)
            .deletingLastPathComponent()
            .path
        
        if dependencies[singleton: .fileManager].isDirectoryEmpty(atPath: parentDirectory) {
            try? dependencies[singleton: .fileManager].removeItem(atPath: parentDirectory)
        }
    }
    
    public func upsertLastClearedRecord(threadId: String) throws {
        guard
            let conversationPath: String = conversationPath(threadId),
            let path: String = lastClearedRecordPath(conversationPath: conversationPath)
        else { throw ExtensionHelperError.failedToUpdateLastClearedRecord }
        
        try write(data: Data(), to: path)
    }
    
    // MARK: - Config Dumps
    
    // stringlint:ignore_contents
    private func dumpFilePath(for sessionId: SessionId, variant: ConfigDump.Variant) -> String? {
        guard
            let conversationPath: String = conversationPath(sessionId.hexString),
            let hash: [UInt8] = dependencies[singleton: .crypto].generate(
                .hash(message: Array("DumpSalt-\(variant)".utf8))
            )
        else { return nil }
        
        return URL(fileURLWithPath: conversationPath)
            .appendingPathComponent("dumps")
            .appendingPathComponent(hash.toHexString())
            .path
    }
    
    public func lastUpdatedTimestamp(
        for sessionId: SessionId,
        variant: ConfigDump.Variant
    ) -> TimeInterval {
        guard let path: String = dumpFilePath(for: sessionId, variant: variant) else { return 0 }
        
        return lastModifiedTimestamp(for: path).defaulting(to: 0)
    }
    
    public func replicate(dump: ConfigDump?, replaceExisting: Bool) {
        guard
            let dump: ConfigDump = dump,
            let path: String = dumpFilePath(for: dump.sessionId, variant: dump.variant)
        else { return }
        
        /// Only continue if we want to replace an existing dump, or one doesn't exist
        guard
            replaceExisting ||
            !dependencies[singleton: .fileManager].fileExists(atPath: path)
        else { return }
        
        /// Write the dump data to disk
        do { try write(data: dump.data, to: path) }
        catch { Log.error(.cat, "Failed to replicate \(dump.variant) dump for \(dump.sessionId.hexString) due to error: \(error).") }
    }
    
    public func replicateAllConfigDumpsIfNeeded(
        userSessionId: SessionId,
        allDumpSessionIds: Set<SessionId>
    ) {
        struct ReplicatedDumpInfo {
            struct DumpState {
                let variant: ConfigDump.Variant
                let filePathGenerated: Bool
                let fileExists: Bool
                let correctFileProtectionType: Bool
            }
            
            let sessionId: SessionId
            let states: [DumpState]
        }
        
        /// In order to ensure the dump replication process is as robust as possible we want a self-healing mechanism to restore
        /// any dumps which have somehow been lost of failed to replicate
        ///
        /// If a single dump is missing from the expected set for that `SessionId` then we re-replicate the entire set just in case the
        /// state is somehow invalid
        let missingReplicatedDumpInfo: [ReplicatedDumpInfo] = [(userSessionId, ConfigDump.Variant.userVariants)]
            .appending(
                contentsOf: allDumpSessionIds
                    .filter { $0 != userSessionId }
                    .map { ($0, ConfigDump.Variant.groupVariants) }
            )
            .reduce(into: []) { result, next in
                result.append(
                    ReplicatedDumpInfo(
                        sessionId: next.0,
                        states: next.1.map { variant in
                            let maybePath: String? = dumpFilePath(for: next.0, variant: variant)
                            let maybeFileExists: Bool? = maybePath.map {
                                dependencies[singleton: .fileManager].fileExists(atPath: $0)
                            }
                            let fileProtectionType: FileProtectionType? = maybePath.map { path in
                                guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else {
                                    return nil
                                }
                                
                                return (attributes[.protectionKey] as? FileProtectionType)
                            }
                            
                            return ReplicatedDumpInfo.DumpState(
                                variant: variant,
                                filePathGenerated: (maybePath != nil),
                                fileExists: (maybeFileExists ?? false),
                                correctFileProtectionType: (fileProtectionType == .completeUntilFirstUserAuthentication)
                            )
                        }
                    )
                )
            }
            .filter { info in
                info.states.contains(where: {
                    !$0.filePathGenerated ||
                    !$0.fileExists ||
                    !$0.correctFileProtectionType
                })
            }
        
        /// No need to read from the database if there are no missing dumps
        guard !missingReplicatedDumpInfo.isEmpty else { return }
        
        /// Add logs indicating the failures
        let formatter: ListFormatter = ListFormatter()
        missingReplicatedDumpInfo.forEach { info in
            if info.states.contains(where: { !$0.filePathGenerated }) {
                Log.warn(.cat, "Will replicate dumps for \(info.sessionId.hexString) due to failure to generate dump a file path.")
                return
            }
            
            let missingDumps: [ConfigDump.Variant] = info.states
                .filter { !$0.fileExists }
                .map { $0.variant }
            Log.warn(.cat, "Found missing replicated dumps (\(formatter.string(from: missingDumps) ?? "unknown")) for \(info.sessionId.hexString); triggering replication.")
            
            let incorrectProtectionDumps: [ConfigDump.Variant] = info.states
                .filter { $0.fileExists && !$0.correctFileProtectionType }
                .map { $0.variant }
            Log.warn(.cat, "Found dumps with incorrect file protection type (\(formatter.string(from: incorrectProtectionDumps) ?? "unknown")) for \(info.sessionId.hexString); triggering replication.")
        }
        
        /// Load the config dumps from the database
        let fetchTimestamp: TimeInterval = dependencies.dateNow.timeIntervalSince1970
        let missingDumpIds: Set<String> = Set(missingReplicatedDumpInfo.map { $0.sessionId.hexString })
        
        dependencies[singleton: .storage].readAsync(
            retrieve: { db in
                try ConfigDump
                    .filter(missingDumpIds.contains(ConfigDump.Columns.publicKey))
                    .fetchAll(db)
            },
            completion: { [weak self] result in
                guard
                    let self = self,
                    let dumps: [ConfigDump] = try? result.successOrThrow()
                else { return }
                
                /// Persist each dump to disk (if there isn't already one there, or it was updated before the dump was fetched from
                /// the database)
                ///
                /// **Note:** Because it's likely that this function runs in the background it's possible that another thread could trigger
                /// a config update which would result in the dump getting replicated - if that occurs then we don't want to override what
                /// is likely a newer dump, but do need to replace what might be an invalid dump file (hence the timestamp check)
                dumps.forEach { dump in
                    let dumpLastUpdated: TimeInterval = self.lastUpdatedTimestamp(
                        for: dump.sessionId,
                        variant: dump.variant
                    )
                    
                    self.replicate(
                        dump: dump,
                        replaceExisting: (dumpLastUpdated < fetchTimestamp)
                    )
                }
            }
        )
    }
    
    public func refreshDumpModifiedDate(sessionId: SessionId, variant: ConfigDump.Variant) {
        guard let path: String = dumpFilePath(for: sessionId, variant: variant) else { return }
        
        try? refreshModifiedDate(at: path)
    }
    
    public func loadUserConfigState(
        into cache: LibSessionCacheType,
        userSessionId: SessionId,
        userEd25519SecretKey: [UInt8]
    ) {
        ConfigDump.Variant.userVariants
            .sorted { $0.loadOrder < $1.loadOrder }
            .forEach { variant in
                guard
                    let path: String = dumpFilePath(for: userSessionId, variant: variant),
                    let dump: Data = try? read(from: path),
                    let config: LibSession.Config = try? cache.loadState(
                        for: variant,
                        sessionId: userSessionId,
                        userEd25519SecretKey: userEd25519SecretKey,
                        groupEd25519SecretKey: nil,
                        cachedData: dump
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
    }
    
    public func loadGroupConfigStateIfNeeded(
        into cache: LibSessionCacheType,
        swarmPublicKey: String,
        userEd25519SecretKey: [UInt8]
    ) throws -> [ConfigDump.Variant: Bool] {
        guard
            let groupSessionId: SessionId = try? SessionId(from: swarmPublicKey),
            groupSessionId.prefix == .group
        else { return [:] }
        
        let groupEd25519SecretKey: [UInt8]? = cache.secretKey(groupSessionId: groupSessionId)
        var results: [ConfigDump.Variant: Bool] = [:]
        
        try ConfigDump.Variant.groupVariants
            .sorted { $0.loadOrder < $1.loadOrder }
            .forEach { variant in
                /// If a file doesn't exist at the path then assume we don't have a config dump and don't do anything (we wouldn't
                /// be able to handle a notification without a valid config anyway)
                guard
                    let path: String = dumpFilePath(for: groupSessionId, variant: variant),
                    let dump: Data = try? read(from: path)
                else { return results[variant] = false }
                
                cache.setConfig(
                    for: variant,
                    sessionId: groupSessionId,
                    to: try cache.loadState(
                        for: variant,
                        sessionId: groupSessionId,
                        userEd25519SecretKey: userEd25519SecretKey,
                        groupEd25519SecretKey: groupEd25519SecretKey,
                        cachedData: dump
                    )
                )
                results[variant] = true
            }
        
        return results
    }
    
    // MARK: - Notification Settings
    
    private struct NotificationSettings: Codable {
        let threadId: String
        let mentionsOnly: Bool
        let mutedUntil: TimeInterval?
    }
    
    public func replicate(settings: [String: Preferences.NotificationSettings], replaceExisting: Bool) throws {
        /// Only continue if we want to replace an existing file, or one doesn't exist
        guard
            replaceExisting ||
            !dependencies[singleton: .fileManager].fileExists(atPath: notificationSettingsPath)
        else { return }
        
        /// Generate the data (we can exclude anything which has default settings as that would just be redudant data)
        let allSettings: [NotificationSettings] = settings
            .filter { _, value in
                value.mentionsOnly ||
                value.mutedUntil != nil
            }
            .map { key, value in
                NotificationSettings(
                    threadId: key,
                    mentionsOnly: value.mentionsOnly,
                    mutedUntil: value.mutedUntil
                )
            }
        
        guard let settingsAsData: Data = try? JSONEncoder(using: dependencies).encode(allSettings) else {
            return
        }
        
        try write(data: settingsAsData, to: notificationSettingsPath)
    }
    
    public func loadNotificationSettings(
        previewType: Preferences.NotificationPreviewType,
        sound: Preferences.Sound
    ) -> [String: Preferences.NotificationSettings]? {
        guard
            let plaintext: Data = try? read(from: notificationSettingsPath),
            let allSettings: [NotificationSettings] = try? JSONDecoder(using: dependencies)
                .decode([NotificationSettings].self, from: plaintext)
        else { return nil }
        
        return allSettings.reduce(into: [:]) { result, settings in
            result[settings.threadId] = Preferences.NotificationSettings(
                previewType: previewType,
                sound: sound,
                mentionsOnly: settings.mentionsOnly,
                mutedUntil: settings.mutedUntil
            )
        }
    }
    
    // MARK: - Messages
    
    // stringlint:ignore_contents
    private func configMessagePath(_ threadId: String, _ uniqueIdentifier: String) -> String? {
        guard
            let conversationPath: String = conversationPath(threadId),
            let hash: [UInt8] = dependencies[singleton: .crypto].generate(
                .hash(message: Array("ConfigMessageSalt-\(uniqueIdentifier)".utf8))
            )
        else { return nil }
        
        return URL(fileURLWithPath: conversationPath)
            .appendingPathComponent(conversationConfigDir)
            .appendingPathComponent(hash.toHexString())
            .path
    }
    
    // stringlint:ignore_contents
    private func readMessagePath(_ threadId: String, _ uniqueIdentifier: String) -> String? {
        guard
            let conversationPath: String = conversationPath(threadId),
            let hash: [UInt8] = dependencies[singleton: .crypto].generate(
                .hash(message: Array("ReadMessageSalt-\(uniqueIdentifier)".utf8))
            )
        else { return nil }
        
        return URL(fileURLWithPath: conversationPath)
            .appendingPathComponent(conversationReadDir)
            .appendingPathComponent(hash.toHexString())
            .path
    }
    
    // stringlint:ignore_contents
    private func unreadMessagePath(_ threadId: String, _ uniqueIdentifier: String) -> String? {
        guard
            let conversationPath: String = conversationPath(threadId),
            let hash: [UInt8] = dependencies[singleton: .crypto].generate(
                .hash(message: Array("UnreadMessageSalt-\(uniqueIdentifier)".utf8))
            )
        else { return nil }
        
        return URL(fileURLWithPath: conversationPath)
            .appendingPathComponent(conversationUnreadDir)
            .appendingPathComponent(hash.toHexString())
            .path
    }
    
    // stringlint:ignore_contents
    private func messageRequestStubPath(_ conversationHash: String) -> String? {
        guard
            let messageRequestStubHash: [UInt8] = dependencies[singleton: .crypto].generate(
                .hash(message: Array(Data(hex: conversationHash)) + Array(conversationMessageRequestStub.utf8))
            )
        else { return nil }
        
        return URL(fileURLWithPath: conversationsPath)
            .appendingPathComponent(conversationHash)
            .appendingPathComponent(conversationUnreadDir)
            .appendingPathComponent(messageRequestStubHash.toHexString())
            .path
    }
    
    public func unreadMessageCount() -> Int? {
        do {
            let conversationHashes: [String] = try dependencies[singleton: .fileManager]
                .contentsOfDirectory(atPath: conversationsPath)
                .filter({ !$0.starts(with: ".") })   // stringlint:ignore
            
            return try conversationHashes.reduce(0) { (result: Int, conversationHash: String) -> Int in
                let unreadMessagePath: String = URL(fileURLWithPath: conversationsPath)
                    .appendingPathComponent(conversationHash)
                    .appendingPathComponent(conversationUnreadDir)
                    .path
                
                /// Ensure the `unreadMessagePath` exists before trying to count it's contents (if it doesn't then `contentsOfDirectory`
                /// will throw, but that case is actually a valid `0` result
                guard
                    dependencies[singleton: .fileManager].fileExists(atPath: unreadMessagePath),
                    let messageRequestStubPath: String = messageRequestStubPath(conversationHash)
                else { return result }
                
                /// Retrieve the full list of file hashes
                let unreadMessageHashes: [String] = try dependencies[singleton: .fileManager]
                    .contentsOfDirectory(atPath: unreadMessagePath)
                    .filter { !$0.starts(with: ".") }    // stringlint:ignore
                
                /// For message request conversations, only increment the unread count by 1, regardless of how many actual
                /// unread messages exist
                ///
                /// **Note:** Only increment if the user hasn't seen the message requests banner since this notification arrived. We
                /// determine this by checking if the number of unread message records equals the number of dedupe records created since
                /// the conversation was last cleared and `messageRequestStub` was created (When the app opens, these dedupe
                /// files are automatically removed which is why we need the convoluted logic)
                guard !dependencies[singleton: .fileManager].fileExists(atPath: messageRequestStubPath) else {
                    let dedupeFileCreatedTimestamps: [TimeInterval] = dedupeRecordTimestampsSinceLastCleared(
                        conversationPath: URL(fileURLWithPath: conversationsPath)
                            .appendingPathComponent(conversationHash)
                            .path
                    )
                    let numConsideredeDedupeRecords: Int = (MessageDeduplication.doesCreateLegacyRecords ?
                        (dedupeFileCreatedTimestamps.count / 2) :
                        dedupeFileCreatedTimestamps.count
                    )
                    
                    /// If the number of dedupe records don't match the number of unread messages (minus 1 to account for the stub
                    /// file) then the user has seen the message requests banner since they received the PN for this message request
                    guard numConsideredeDedupeRecords == (unreadMessageHashes.count - 1) else {
                        return result
                    }
                    
                    /// OItherwise they haven't so this should increment the count by 1
                    return (result + 1)
                }
                
                /// Otherwise we just add the number of files
                return (result + unreadMessageHashes.count)
            }
        }
        catch { return nil }
    }
    
    public func saveMessage(
        _ message: SnodeReceivedMessage?,
        threadId: String,
        isUnread: Bool,
        isMessageRequest: Bool
    ) throws {
        guard
            let message: SnodeReceivedMessage = message,
            let messageAsData: Data = try? JSONEncoder(using: dependencies).encode(message),
            let targetPath: String = {
                switch (message.namespace.isConfigNamespace, isUnread) {
                    case (true, _): return configMessagePath(threadId, message.hash)
                    case (false, true): return unreadMessagePath(threadId, message.hash)
                    case (false, false): return readMessagePath(threadId, message.hash)
                }
            }()
        else { return }
        
        /// If this is an unread message for a message request then we need to write a file to indicate the conversation is a message
        /// request so we can correctly calculate the unread count (since message requests with unread messages only count a
        /// single message)
        if isUnread && isMessageRequest {
            let maybeStubPath: String? = conversationPath(threadId)
                .map { URL(fileURLWithPath: $0).lastPathComponent }
                .map { messageRequestStubPath($0) }
            
            if
                let stubPath: String = maybeStubPath,
                !dependencies[singleton: .fileManager].fileExists(atPath: stubPath)
            {
                try write(data: Data(), to: stubPath)
            }
        }
        
        try write(data: messageAsData, to: targetPath)
    }
    
    public func willLoadMessages() {
        /// We want to synchronously reset the `messagesLoadedStream` value to `false`
        let semaphore: DispatchSemaphore = DispatchSemaphore(value: 0)
        Task {
            await messagesLoadedStream.send(false)
            semaphore.signal()
        }
        semaphore.wait()
    }
    
    public func loadMessages() async throws {
        typealias MessageData = (namespace: Network.SnodeAPI.Namespace, messages: [SnodeReceivedMessage], lastHash: String?)
        
        /// Retrieve all conversation file paths
        ///
        /// This will ignore any hidden files (just in case) and will also insert the current users conversation (ie. `Note to Self`) at
        /// the first position as that's where user config messages will be sotred
        let userSessionId: SessionId = dependencies[cache: .general].sessionId
        let currentUserConversationHash: String? = conversationPath(userSessionId.hexString)
            .map { URL(fileURLWithPath: $0).lastPathComponent }
        let conversationHashes: [String] = (try? dependencies[singleton: .fileManager]
            .contentsOfDirectory(atPath: conversationsPath)
            .filter { hash in
                !hash.starts(with: ".") &&    // stringlint:ignore
                hash != currentUserConversationHash
            })
            .defaulting(to: [])
            .inserting(currentUserConversationHash, at: 0)
        var successConfigCount: Int = 0
        var failureConfigCount: Int = 0
        var successStandardCount: Int = 0
        var failureStandardCount: Int = 0
        
        try await dependencies[singleton: .storage].writeAsync { [weak self, dependencies] db in
            guard let this = self else { return }
            
            /// Process each conversation individually
            conversationHashes.forEach { conversationHash in
                /// Retrieve and process any config messages
                ///
                /// For config message changes we want to load in every config for a conversation and process them all at once
                /// to ensure that we don't miss any changes and ensure they are processed in the order they were received, if an
                /// error occurs then we want to just discard all of the config changes as otherwise we could end up in a weird state
                let configsPath: String = URL(fileURLWithPath: this.conversationsPath)
                    .appendingPathComponent(conversationHash)
                    .appendingPathComponent(this.conversationConfigDir)
                    .path
                let configMessageHashes: [String] = (try? dependencies[singleton: .fileManager]
                    .contentsOfDirectory(atPath: configsPath)
                    .filter { !$0.starts(with: ".") })    // stringlint:ignore
                    .defaulting(to: [])
                
                do {
                    let sortedMessages: [MessageData] = try configMessageHashes
                        .reduce([Network.SnodeAPI.Namespace: [SnodeReceivedMessage]]()) { (result: [Network.SnodeAPI.Namespace: [SnodeReceivedMessage]], hash: String) in
                            let path: String = URL(fileURLWithPath: this.conversationsPath)
                                .appendingPathComponent(conversationHash)
                                .appendingPathComponent(this.conversationConfigDir)
                                .appendingPathComponent(hash)
                                .path
                            let plaintext: Data = try this.read(from: path)
                            let message: SnodeReceivedMessage = try JSONDecoder(using: dependencies)
                                .decode(SnodeReceivedMessage.self, from: plaintext)
                            
                            return result.appending(message, toArrayOn: message.namespace)
                        }
                        .map { namespace, messages -> MessageData in (namespace, messages, nil) }
                        .sorted { lhs, rhs in lhs.namespace.processingOrder < rhs.namespace.processingOrder }
                    
                    /// Process the message (inserting into the database if needed (messages are processed per conversaiton so
                    /// all have the same `swarmPublicKey`)
                    switch sortedMessages.first?.messages.first?.swarmPublicKey {
                        case .none: break
                        case .some(let swarmPublicKey):
                            SwarmPoller.processPollResponse(
                                db,
                                cat: .cat,
                                source: .pushNotification,
                                swarmPublicKey: swarmPublicKey,
                                shouldStoreMessages: true,
                                ignoreDedupeFiles: true,
                                forceSynchronousProcessing: true,
                                sortedMessages: sortedMessages,
                                using: dependencies
                            )
                    }
                    
                    successConfigCount += configMessageHashes.count
                }
                catch {
                    failureConfigCount += configMessageHashes.count
                    Log.error(.cat, "Discarding some config message changes due to error: \(error)")
                }
                
                /// Remove the config message files now that they are processed
                try? dependencies[singleton: .fileManager].removeItem(atPath: configsPath)
                
                /// Retrieve and process any standard messages
                ///
                /// Since there is no guarantee that we will have received a push notification for every message, or even that push
                /// notifications will be received in the correct order, we can just process standard messages individually
                let readMessagePath: String = URL(fileURLWithPath: this.conversationsPath)
                    .appendingPathComponent(conversationHash)
                    .appendingPathComponent(this.conversationReadDir)
                    .path
                let unreadMessagePath: String = URL(fileURLWithPath: this.conversationsPath)
                    .appendingPathComponent(conversationHash)
                    .appendingPathComponent(this.conversationUnreadDir)
                    .path
                let messageRequestStubPath: String? = this.messageRequestStubPath(conversationHash)
                let readMessageHashes: [String] = (try? dependencies[singleton: .fileManager]
                    .contentsOfDirectory(atPath: readMessagePath)
                    .filter { !$0.starts(with: ".") })    // stringlint:ignore
                    .defaulting(to: [])
                let unreadMessageHashes: [String] = (try? dependencies[singleton: .fileManager]
                    .contentsOfDirectory(atPath: unreadMessagePath)
                    .filter {
                        !$0.starts(with: ".") &&    // stringlint:ignore
                        $0 != messageRequestStubPath.map { URL(fileURLWithPath: $0) }?.lastPathComponent
                    })
                    .defaulting(to: [])
                let allMessagePaths: [String] = (
                    readMessageHashes.map { hash in
                        URL(fileURLWithPath: this.conversationsPath)
                            .appendingPathComponent(conversationHash)
                            .appendingPathComponent(this.conversationReadDir)
                            .appendingPathComponent(hash)
                            .path
                    } +
                    unreadMessageHashes.map { hash in
                        URL(fileURLWithPath: this.conversationsPath)
                            .appendingPathComponent(conversationHash)
                            .appendingPathComponent(this.conversationUnreadDir)
                            .appendingPathComponent(hash)
                            .path
                    }
                )
                
                let sortedMessages: [MessageData] = allMessagePaths
                    .reduce([Network.SnodeAPI.Namespace: [SnodeReceivedMessage]]()) { (result: [Network.SnodeAPI.Namespace: [SnodeReceivedMessage]], path: String) in
                        do {
                            let plaintext: Data = try this.read(from: path)
                            let message: SnodeReceivedMessage = try JSONDecoder(using: dependencies)
                                .decode(SnodeReceivedMessage.self, from: plaintext)
                            
                            return result.appending(message, toArrayOn: message.namespace)
                        }
                        catch {
                            failureStandardCount += 1
                            Log.error(.cat, "Discarding standard message due to error: \(error)")
                            return result
                        }
                    }
                    .map { namespace, messages -> MessageData in
                        /// We need to sort the messages as we don't know what order they were read from disk in and some
                        /// messages (eg. a `VisibleMessage` and it's corresponding `UnsendRequest`) need to be
                        /// processed in a particular order or they won't behave correctly, luckily the `SnodeReceivedMessage.timestampMs`
                        /// is the "network offset" timestamp when the message was sent to the storage server (rather than the
                        /// "sent timestamp" on the message, which for an `UnsendRequest` will match it's associate message)
                        /// so we can just sort by that
                        (
                            namespace,
                            messages.sorted { $0.timestampMs < $1.timestampMs },
                            nil
                        )
                    }
                    .sorted { lhs, rhs in lhs.namespace.processingOrder < rhs.namespace.processingOrder }
                
                /// Process the message (inserting into the database if needed (messages are processed per conversaiton so
                /// all have the same `swarmPublicKey`)
                switch sortedMessages.first?.messages.first?.swarmPublicKey {
                    case .none: break
                    case .some(let swarmPublicKey):
                        let (_, _, result) = SwarmPoller.processPollResponse(
                            db,
                            cat: .cat,
                            source: .pushNotification,
                            swarmPublicKey: swarmPublicKey,
                            shouldStoreMessages: true,
                            ignoreDedupeFiles: true,
                            forceSynchronousProcessing: true,
                            sortedMessages: sortedMessages,
                            using: dependencies
                        )
                        successStandardCount += result.validMessageCount
                        
                        if result.validMessageCount != result.rawMessageCount {
                            failureStandardCount += (result.rawMessageCount - result.validMessageCount)
                            Log.error(.cat, "Discarding some standard messages due to error: \(MessageReceiverError.failedToProcess)")
                        }
                }
                
                /// Remove the standard message files now that they are processed
                try? dependencies[singleton: .fileManager].removeItem(atPath: readMessagePath)
                try? dependencies[singleton: .fileManager].removeItem(atPath: unreadMessagePath)
            }
        }
        
        Log.info(.cat, "Finished: Successfully processed \(successStandardCount)/\(successStandardCount + failureStandardCount) standard messages, \(successConfigCount)/\(failureConfigCount) config messages.")
        await messagesLoadedStream.send(true)
    }
    
    @discardableResult public func waitUntilMessagesAreLoaded(timeout: DispatchTimeInterval) async -> Bool {
        return await withThrowingTaskGroup(of: Bool.self) { [weak self] group in
            group.addTask {
                guard await self?.messagesLoadedStream.currentValue != true else { return true }
                _ = await self?.messagesLoadedStream.stream.first { $0 == true }
                return true
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                return false
            }
            
            let result = await group.nextResult()
            group.cancelAll()
            
            switch result {
                case .success(true): return true
                default: return false
            }
        }
    }
}

// MARK: - ExtensionHelper.UserMetadata

public extension ExtensionHelper {
    struct UserMetadata: Codable {
        public let sessionId: SessionId
        public let ed25519SecretKey: [UInt8]
        public let unreadCount: Int
    }
}

// MARK: - ExtensionHelperError

public enum ExtensionHelperError: Error, CustomStringConvertible {
    case noEncryptionKey
    case failedToWriteToFile(Error)
    case failedToReadFromFile
    case failedToStoreDedupeRecord
    case failedToRemoveDedupeRecord
    case failedToUpdateLastClearedRecord
    
    // stringlint:ignore_contents
    public var description: String {
        switch self {
            case .noEncryptionKey: return "No encryption key available."
            case .failedToWriteToFile(let other): return "Failed to write to file (\(other))."
            case .failedToReadFromFile: return "Failed to read from file."
            case .failedToStoreDedupeRecord: return "Failed to store a record for message deduplication."
            case .failedToRemoveDedupeRecord: return "Failed to remove a record for message deduplication."
            case .failedToUpdateLastClearedRecord: return "Failed to update the last cleared record."
        }
    }
}

// MARK: - ExtensionHelperType

public protocol ExtensionHelperType {
    func deleteCache()
    
    // MARK: - User Metadata
    
    func saveUserMetadata(
        sessionId: SessionId,
        ed25519SecretKey: [UInt8],
        unreadCount: Int?
    ) throws
    func loadUserMetadata() -> ExtensionHelper.UserMetadata?
    
    // MARK: - Deduping
    
    func hasDedupeRecordSinceLastCleared(threadId: String) -> Bool
    func dedupeRecordExists(threadId: String, uniqueIdentifier: String) -> Bool
    func createDedupeRecord(threadId: String, uniqueIdentifier: String) throws
    func removeDedupeRecord(threadId: String, uniqueIdentifier: String) throws
    func upsertLastClearedRecord(threadId: String) throws
    
    // MARK: - Config Dumps
    
    func lastUpdatedTimestamp(for sessionId: SessionId, variant: ConfigDump.Variant) -> TimeInterval
    func replicate(dump: ConfigDump?, replaceExisting: Bool)
    func replicateAllConfigDumpsIfNeeded(userSessionId: SessionId, allDumpSessionIds: Set<SessionId>)
    func refreshDumpModifiedDate(sessionId: SessionId, variant: ConfigDump.Variant)
    func loadUserConfigState(
        into cache: LibSessionCacheType,
        userSessionId: SessionId,
        userEd25519SecretKey: [UInt8]
    )
    func loadGroupConfigStateIfNeeded(
        into cache: LibSessionCacheType,
        swarmPublicKey: String,
        userEd25519SecretKey: [UInt8]
    ) throws -> [ConfigDump.Variant: Bool]
    
    // MARK: - Notification Settings
    
    func replicate(settings: [String: Preferences.NotificationSettings], replaceExisting: Bool) throws
    func loadNotificationSettings(
        previewType: Preferences.NotificationPreviewType,
        sound: Preferences.Sound
    ) -> [String: Preferences.NotificationSettings]?
    
    // MARK: - Messages
    
    func unreadMessageCount() -> Int?
    func saveMessage(
        _ message: SnodeReceivedMessage?,
        threadId: String,
        isUnread: Bool,
        isMessageRequest: Bool
    ) throws
    func willLoadMessages()
    func loadMessages() async throws
    @discardableResult func waitUntilMessagesAreLoaded(timeout: DispatchTimeInterval) async -> Bool
}

public extension ExtensionHelperType {
    func replicate(dump: ConfigDump?) { replicate(dump: dump, replaceExisting: true) }
}
