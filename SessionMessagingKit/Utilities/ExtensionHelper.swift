// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionSnodeKit
import SessionUtilitiesKit

// MARK: - Singleton

public extension Singleton {
    static let extensionHelper: SingletonConfig<ExtensionHelperType> = Dependencies.create(
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

public class ExtensionHelper: ExtensionHelperType {
    // stringlint:ignore_start
    private lazy var cacheDirectoryPath: String = "\(dependencies[singleton: .fileManager].appSharedDataDirectoryPath)/extensionCache"
    private lazy var metadataPath: String = "\(cacheDirectoryPath)/metadata"
    private lazy var conversationsPath: String = "\(cacheDirectoryPath)/conversations"
    private let conversationConfigDir: String = "config"
    private let conversationReadDir: String = "read"
    private let conversationUnreadDir: String = "unread"
    private let conversationDedupeDir: String = "dedupe"
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
            let data: Data = "ConvoIdSalt-\(threadId)".data(using: .utf8),
            let hash: [UInt8] = dependencies[singleton: .crypto].generate(
                .hash(message: Array(data))
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
        
        guard dependencies[singleton: .fileManager].createFile(atPath: tmpPath, contents: ciphertext) else {
            throw ExtensionHelperError.failedToWriteToFile
        }
        try? dependencies[singleton: .fileManager].removeItem(atPath: path)
        try dependencies[singleton: .fileManager].moveItem(atPath: tmpPath, toPath: path)
    }
    
    private func read(from path: String) throws -> Data {
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

        guard
            let ciphertext: Data = dependencies[singleton: .fileManager]
                .contents(atPath: path),
            let plaintext: Data = dependencies[singleton: .crypto].generate(
                .plaintextWithXChaCha20(
                    ciphertext: ciphertext,
                    encKey: encKey
                )
            )
        else { throw ExtensionHelperError.failedToReadFromFile }
        
        return plaintext
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
        
        return try? JSONDecoder(using: dependencies)
            .decode(UserMetadata.self, from: plaintext)
    }
    
    // MARK: - Deduping
    
    // stringlint:ignore_contents
    private func dedupeRecordPath(_ threadId: String, _ uniqueIdentifier: String) -> String? {
        guard
            let conversationPath: String = conversationPath(threadId),
            let data: Data = "DedupeRecordSalt-\(uniqueIdentifier)".data(using: .utf8),
            let hash: [UInt8] = dependencies[singleton: .crypto].generate(
                .hash(message: Array(data))
            )
        else { return nil }
        
        return URL(fileURLWithPath: conversationPath)
            .appendingPathComponent(conversationDedupeDir)
            .appendingPathComponent(hash.toHexString())
            .path
    }
    
    public func hasAtLeastOneDedupeRecord(threadId: String) -> Bool {
        guard let conversationPath: String = conversationPath(threadId) else { return false }
        
        return !dependencies[singleton: .fileManager].isDirectoryEmpty(
            atPath: URL(fileURLWithPath: conversationPath)
                .appendingPathComponent(conversationDedupeDir)
                .path
        )
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
    
    // MARK: - Config Dumps
    
    // stringlint:ignore_contents
    private func dumpFilePath(for sessionId: SessionId, variant: ConfigDump.Variant) -> String? {
        guard
            let conversationPath: String = conversationPath(sessionId.hexString),
            let data: Data = "DumpSalt-\(variant)".data(using: .utf8),
            let hash: [UInt8] = dependencies[singleton: .crypto].generate(
                .hash(message: Array(data))
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
        
        return ((try? dependencies[singleton: .fileManager]
            .attributesOfItem(atPath: path)
            .getting(.modificationDate) as? Date)?
            .timeIntervalSince1970)
            .defaulting(to: 0)
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
        catch { Log.error(.cat, "Failed to replicate \(dump.variant) dump for \(dump.sessionId.hexString).") }
    }
    
    public func replicateAllConfigDumpsIfNeeded(userSessionId: SessionId) {
        /// We can be reasonably sure that if the `userProfile` config dump is missing then we probably haven't replicated any
        /// config dumps yet and should do so
        guard
            let path: String = dumpFilePath(for: userSessionId, variant: .userProfile),
            !dependencies[singleton: .fileManager].fileExists(atPath: path)
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
    ) throws {
        guard
            let groupSessionId: SessionId = try? SessionId(from: swarmPublicKey),
            groupSessionId.prefix == .group
        else { return }
        
        let groupEd25519SecretKey: [UInt8]? = cache.secretKey(groupSessionId: groupSessionId)
        
        try ConfigDump.Variant.groupVariants
            .sorted { $0.loadOrder < $1.loadOrder }
            .forEach { variant in
                /// If a file doesn't exist at the path then assume we don't have a config dump and don't do anything (we wouldn't
                /// be able to handle a notification without a valid config anyway)
                guard
                    let path: String = dumpFilePath(for: groupSessionId, variant: variant),
                    let dump: Data = try? read(from: path)
                else { return }
                
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
            }
    }
    
    // MARK: - Messages
    
    // stringlint:ignore_contents
    private func configMessagePath(_ threadId: String, _ uniqueIdentifier: String) -> String? {
        guard
            let conversationPath: String = conversationPath(threadId),
            let data: Data = "ConfigMessageSalt-\(uniqueIdentifier)".data(using: .utf8),
            let hash: [UInt8] = dependencies[singleton: .crypto].generate(
                .hash(message: Array(data))
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
            let data: Data = "ReadMessageSalt-\(uniqueIdentifier)".data(using: .utf8),
            let hash: [UInt8] = dependencies[singleton: .crypto].generate(
                .hash(message: Array(data))
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
            let data: Data = "UnreadMessageSalt-\(uniqueIdentifier)".data(using: .utf8),
            let hash: [UInt8] = dependencies[singleton: .crypto].generate(
                .hash(message: Array(data))
            )
        else { return nil }
        
        return URL(fileURLWithPath: conversationPath)
            .appendingPathComponent(conversationUnreadDir)
            .appendingPathComponent(hash.toHexString())
            .path
    }
    
    public func unreadMessageCount() -> Int? {
        do {
            let conversationHashes: [String] = try dependencies[singleton: .fileManager]
                .contentsOfDirectory(atPath: conversationsPath)
                .filter({ !$0.starts(with: ".") })   // stringlint:ignore
            
            return try conversationHashes.reduce(0) { result, conversationHash in
                let unreadMessagePath: String = URL(fileURLWithPath: conversationsPath)
                    .appendingPathComponent(conversationHash)
                    .appendingPathComponent(conversationUnreadDir)
                    .path
                
                /// Ensure the `unreadMessagePath` exists before trying to count it's contents (if it doesn't then `contentsOfDirectory`
                /// will throw, but that case is actually a valid `0` result
                guard dependencies[singleton: .fileManager].fileExists(atPath: unreadMessagePath) else {
                    return result
                }
                
                let unreadMessageHashes: [String] = try dependencies[singleton: .fileManager]
                    .contentsOfDirectory(atPath: unreadMessagePath)
                    .filter { !$0.starts(with: ".") }    // stringlint:ignore
                
                return (result + unreadMessageHashes.count)
            }
        }
        catch { return nil }
    }
    
    public func saveMessage(_ message: SnodeReceivedMessage?, isUnread: Bool) throws {
        guard
            let message: SnodeReceivedMessage = message,
            let messageAsData: Data = try? JSONEncoder(using: dependencies).encode(message),
            let targetPath: String = {
                switch (message.namespace.isConfigNamespace, isUnread) {
                    case (true, _): return configMessagePath(message.swarmPublicKey, message.hash)
                    case (false, true): return unreadMessagePath(message.swarmPublicKey, message.hash)
                    case (false, false): return readMessagePath(message.swarmPublicKey, message.hash)
                }
            }()
        else { return }
        
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
        typealias MessageData = (namespace: SnodeAPI.Namespace, messages: [SnodeReceivedMessage], lastHash: String?)
        
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
                        .reduce([SnodeAPI.Namespace: [SnodeReceivedMessage]]()) { (result: [SnodeAPI.Namespace: [SnodeReceivedMessage]], hash: String) in
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
                let readMessageHashes: [String] = (try? dependencies[singleton: .fileManager]
                    .contentsOfDirectory(atPath: readMessagePath)
                    .filter { !$0.starts(with: ".") })    // stringlint:ignore
                    .defaulting(to: [])
                let unreadMessageHashes: [String] = (try? dependencies[singleton: .fileManager]
                    .contentsOfDirectory(atPath: unreadMessagePath)
                    .filter { !$0.starts(with: ".") })    // stringlint:ignore
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
                
                allMessagePaths.forEach { path in
                    do {
                        let plaintext: Data = try this.read(from: path)
                        let message: SnodeReceivedMessage = try JSONDecoder(using: dependencies)
                            .decode(SnodeReceivedMessage.self, from: plaintext)
                        
                        SwarmPoller.processPollResponse(
                            db,
                            cat: .cat,
                            source: .pushNotification,
                            swarmPublicKey: message.swarmPublicKey,
                            shouldStoreMessages: true,
                            ignoreDedupeFiles: true,
                            forceSynchronousProcessing: true,
                            sortedMessages: [(message.namespace, [message], nil)],
                            using: dependencies
                        )
                        successStandardCount += 1
                    }
                    catch {
                        failureStandardCount += 1
                        Log.error(.cat, "Discarding standard message due to error: \(error)")
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
    case failedToWriteToFile
    case failedToReadFromFile
    case failedToStoreDedupeRecord
    case failedToRemoveDedupeRecord
    
    // stringlint:ignore_contents
    public var description: String {
        switch self {
            case .noEncryptionKey: return "No encryption key available."
            case .failedToWriteToFile: return "Failed to write to file."
            case .failedToReadFromFile: return "Failed to read from file."
            case .failedToStoreDedupeRecord: return "Failed to store a record for message deduplication."
            case .failedToRemoveDedupeRecord: return "Failed to remove a record for message deduplication."
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
    
    func hasAtLeastOneDedupeRecord(threadId: String) -> Bool
    func dedupeRecordExists(threadId: String, uniqueIdentifier: String) -> Bool
    func createDedupeRecord(threadId: String, uniqueIdentifier: String) throws
    func removeDedupeRecord(threadId: String, uniqueIdentifier: String) throws
    
    // MARK: - Config Dumps
    
    func lastUpdatedTimestamp(for sessionId: SessionId, variant: ConfigDump.Variant) -> TimeInterval
    func replicate(dump: ConfigDump?, replaceExisting: Bool)
    func replicateAllConfigDumpsIfNeeded(userSessionId: SessionId)
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
    ) throws
    
    // MARK: - Messages
    
    func unreadMessageCount() -> Int?
    func saveMessage(_ message: SnodeReceivedMessage?, isUnread: Bool) throws
    func willLoadMessages()
    func loadMessages() async throws
    @discardableResult func waitUntilMessagesAreLoaded(timeout: DispatchTimeInterval) async -> Bool
}

public extension ExtensionHelperType {
    func replicate(dump: ConfigDump?) { replicate(dump: dump, replaceExisting: true) }
}
