// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionSnodeKit
import SessionUtil
import SessionUtilitiesKit

public enum SessionUtil {
    public struct ConfResult {
        let needsPush: Bool
        let needsDump: Bool
    }
    
    public struct IncomingConfResult {
        let needsPush: Bool
        let needsDump: Bool
        let messageHashes: [String]
        let latestSentTimestamp: TimeInterval
    }
    
    public struct OutgoingConfResult {
        let message: SharedConfigMessage
        let namespace: SnodeAPI.Namespace
        let destination: Message.Destination
        let oldMessageHashes: [String]?
    }
    
    // MARK: - Configs
    
    fileprivate static var configStore: Atomic<[ConfigKey: Atomic<UnsafeMutablePointer<config_object>?>]> = Atomic([:])
    
    public static func config(for variant: ConfigDump.Variant, publicKey: String) -> Atomic<UnsafeMutablePointer<config_object>?> {
        let key: ConfigKey = ConfigKey(variant: variant, publicKey: publicKey)
        
        return (
            SessionUtil.configStore.wrappedValue[key] ??
            Atomic(nil)
        )
    }
    
    // MARK: - Variables
    
    /// Returns `true` if there is a config which needs to be pushed, but returns `false` if the configs are all up to date or haven't been
    /// loaded yet (eg. fresh install)
    public static var needsSync: Bool {
        return configStore
            .wrappedValue
            .contains { _, atomicConf in config_needs_push(atomicConf.wrappedValue) }
    }
    
    // MARK: - Loading
    
    public static func loadState(
        userPublicKey: String,
        ed25519SecretKey: [UInt8]?
    ) {
        guard let secretKey: [UInt8] = ed25519SecretKey else { return }
        
        // Retrieve the existing dumps from the database
        let existingDumps: Set<ConfigDump> = Storage.shared
            .read { db in try ConfigDump.fetchSet(db) }
            .defaulting(to: [])
        let existingDumpVariants: Set<ConfigDump.Variant> = existingDumps
            .map { $0.variant }
            .asSet()
        let missingRequiredVariants: Set<ConfigDump.Variant> = ConfigDump.Variant.userVariants
            .asSet()
            .subtracting(existingDumpVariants)
        
        // Create the 'config_object' records for each dump
        SessionUtil.configStore.mutate { confStore in
            existingDumps.forEach { dump in
                confStore[ConfigKey(variant: dump.variant, publicKey: dump.publicKey)] = Atomic(
                    try? SessionUtil.loadState(
                        for: dump.variant,
                        secretKey: secretKey,
                        cachedData: dump.data
                    )
                )
            }
            
            missingRequiredVariants.forEach { variant in
                confStore[ConfigKey(variant: variant, publicKey: userPublicKey)] = Atomic(
                    try? SessionUtil.loadState(
                        for: variant,
                        secretKey: secretKey,
                        cachedData: nil
                    )
                )
            }
        }
    }
    
    internal static func loadState(
        for variant: ConfigDump.Variant,
        secretKey ed25519SecretKey: [UInt8],
        cachedData: Data?
    ) throws -> UnsafeMutablePointer<config_object>? {
        // Setup initial variables (including getting the memory address for any cached data)
        var conf: UnsafeMutablePointer<config_object>? = nil
        let error: UnsafeMutablePointer<CChar>? = nil
        let cachedDump: (data: UnsafePointer<UInt8>, length: Int)? = cachedData?.withUnsafeBytes { unsafeBytes in
            return unsafeBytes.baseAddress.map {
                (
                    $0.assumingMemoryBound(to: UInt8.self),
                    unsafeBytes.count
                )
            }
        }
        
        // No need to deallocate the `cachedDump.data` as it'll automatically be cleaned up by
        // the `cachedDump` lifecycle, but need to deallocate the `error` if it gets set
        defer {
            error?.deallocate()
        }
        
        // Try to create the object
        var secretKey: [UInt8] = ed25519SecretKey
        let result: Int32 = {
            switch variant {
                case .userProfile:
                    return user_profile_init(&conf, &secretKey, cachedDump?.data, (cachedDump?.length ?? 0), error)
                    
                case .contacts:
                    return contacts_init(&conf, &secretKey, cachedDump?.data, (cachedDump?.length ?? 0), error)
            }
        }()
        
        guard result == 0 else {
            let errorString: String = (error.map { String(cString: $0) } ?? "unknown error")
            SNLog("[SessionUtil Error] Unable to create \(variant.rawValue) config object: \(errorString)")
            throw SessionUtilError.unableToCreateConfigObject
        }
        
        return conf
    }
    
    internal static func saveState(
        _ db: Database,
        keepingExistingMessageHashes: Bool,
        configDump: ConfigDump?
    ) throws {
        guard let configDump: ConfigDump = configDump else { return }
        
        // If we want to keep the existing message hashes then we need
        // to fetch them from the db and create a new 'ConfigDump' instance
        let targetDump: ConfigDump = try {
            guard keepingExistingMessageHashes else { return configDump }
            
            let existingCombinedMessageHashes: String? = try ConfigDump
                .filter(
                    ConfigDump.Columns.variant == configDump.variant &&
                    ConfigDump.Columns.publicKey == configDump.publicKey
                )
                .select(.combinedMessageHashes)
                .asRequest(of: String.self)
                .fetchOne(db)
            
            return ConfigDump(
                variant: configDump.variant,
                publicKey: configDump.publicKey,
                data: configDump.data,
                messageHashes: ConfigDump.messageHashes(from: existingCombinedMessageHashes)
            )
        }()
        
        // Actually save the dump
        try targetDump.save(db)
    }
    
    internal static func createDump(
        conf: UnsafeMutablePointer<config_object>?,
        for variant: ConfigDump.Variant,
        publicKey: String,
        messageHashes: [String]?
    ) throws -> ConfigDump? {
        guard conf != nil else { throw SessionUtilError.nilConfigObject }
        
        // If it doesn't need a dump then do nothing
        guard config_needs_dump(conf) else { return nil }
        
        var dumpResult: UnsafeMutablePointer<UInt8>? = nil
        var dumpResultLen: Int = 0
        config_dump(conf, &dumpResult, &dumpResultLen)
        
        guard let dumpResult: UnsafeMutablePointer<UInt8> = dumpResult else { return nil }
        
        let dumpData: Data = Data(bytes: dumpResult, count: dumpResultLen)
        dumpResult.deallocate()
        
        return ConfigDump(
            variant: variant,
            publicKey: publicKey,
            data: dumpData,
            messageHashes: messageHashes
        )
    }
    
    // MARK: - Pushes
    
    public static func pendingChanges(
        _ db: Database,
        userPublicKey: String,
        ed25519SecretKey: [UInt8]
    ) throws -> [OutgoingConfResult] {
        let existingDumpInfo: Set<DumpInfo> = try ConfigDump
            .select(.variant, .publicKey, .combinedMessageHashes)
            .asRequest(of: DumpInfo.self)
            .fetchSet(db)
        
        // Ensure we always check the required user config types for changes even if there is no dump
        // data yet (to deal with first launch cases)
        return existingDumpInfo
            .inserting(
                contentsOf: DumpInfo.requiredUserConfigDumpInfo(userPublicKey: userPublicKey)
                    .filter { requiredInfo -> Bool in
                        !existingDumpInfo.contains(where: {
                            $0.variant == requiredInfo.variant &&
                            $0.publicKey == requiredInfo.publicKey
                        })
                    }
            )
            .compactMap { dumpInfo -> OutgoingConfResult? in
                let key: ConfigKey = ConfigKey(variant: dumpInfo.variant, publicKey: dumpInfo.publicKey)
                let atomicConf: Atomic<UnsafeMutablePointer<config_object>?> = (
                    SessionUtil.configStore.wrappedValue[key] ??
                    Atomic(nil)
                )
                
                // Check if the config needs to be pushed
                guard config_needs_push(atomicConf.wrappedValue) else { return nil }
                
                var toPush: UnsafeMutablePointer<UInt8>? = nil
                var toPushLen: Int = 0
                let seqNo: Int64 = atomicConf.mutate { config_push($0, &toPush, &toPushLen) }
                
                guard let toPush: UnsafeMutablePointer<UInt8> = toPush else { return nil }
                
                let pushData: Data = Data(bytes: toPush, count: toPushLen)
                toPush.deallocate()
                
                return OutgoingConfResult(
                    message: SharedConfigMessage(
                        kind: dumpInfo.variant.configMessageKind,
                        seqNo: seqNo,
                        data: pushData
                    ),
                    namespace: dumpInfo.variant.namespace,
                    destination: (dumpInfo.publicKey == userPublicKey ?
                        Message.Destination.contact(publicKey: userPublicKey) :
                        Message.Destination.closedGroup(groupPublicKey: dumpInfo.publicKey)
                    ),
                    oldMessageHashes: dumpInfo.messageHashes
                )
            }
    }
    
    public static func markAsPushed(
        message: SharedConfigMessage,
        publicKey: String
    ) -> Bool {
        let key: ConfigKey = ConfigKey(variant: message.kind.configDumpVariant, publicKey: publicKey)
        let atomicConf: Atomic<UnsafeMutablePointer<config_object>?> = (
            SessionUtil.configStore.wrappedValue[key] ??
            Atomic(nil)
        )
        
        // Mark the config as pushed
        config_confirm_pushed(atomicConf.wrappedValue, message.seqNo)
        
        // Update the result to indicate whether the config needs to be dumped
        return config_needs_dump(atomicConf.wrappedValue)
    }
    
    // MARK: - Receiving
    
    public static func handleConfigMessages(
        _ db: Database,
        messages: [SharedConfigMessage],
        publicKey: String
    ) throws {
        guard !messages.isEmpty else { return }
        guard !publicKey.isEmpty else { throw MessageReceiverError.noThread }
        
        let groupedMessages: [SharedConfigMessage.Kind: [SharedConfigMessage]] = messages
            .grouped(by: \.kind)
        
        // Merge the config messages into the current state
        let results: [ConfigDump.Variant: IncomingConfResult] = groupedMessages
            .reduce(into: [:]) { result, next in
                let key: ConfigKey = ConfigKey(variant: next.key.configDumpVariant, publicKey: publicKey)
                let atomicConf: Atomic<UnsafeMutablePointer<config_object>?> = (
                    SessionUtil.configStore.wrappedValue[key] ??
                    Atomic(nil)
                )
                var needsPush: Bool = false
                var needsDump: Bool = false
                let messageHashes: [String] = next.value.compactMap { $0.serverHash }
                let messageSentTimestamp: TimeInterval = TimeInterval(
                    (next.value.compactMap { $0.sentTimestamp }.max() ?? 0) / 1000
                )
                
                // Block the config while we are merging
                atomicConf.mutate { conf in
                    var mergeData: [UnsafePointer<UInt8>?] = next.value
                        .map { message -> [UInt8] in message.data.bytes }
                        .unsafeCopy()
                    var mergeSize: [Int] = messages.map { $0.data.count }
                    config_merge(conf, &mergeData, &mergeSize, messages.count)
                    mergeData.forEach { $0?.deallocate() }
                    
                    // Get the state of this variant
                    needsPush = config_needs_push(conf)
                    needsDump = config_needs_dump(conf)
                }
                
                // Return the current state of the config
                result[next.key.configDumpVariant] = IncomingConfResult(
                    needsPush: needsPush,
                    needsDump: needsDump,
                    messageHashes: messageHashes,
                    latestSentTimestamp: messageSentTimestamp
                )
            }
        
        // Process the results from the merging
        try results.forEach { variant, result in
            let key: ConfigKey = ConfigKey(variant: variant, publicKey: publicKey)
            let atomicConf: Atomic<UnsafeMutablePointer<config_object>?> = (
                SessionUtil.configStore.wrappedValue[key] ??
                Atomic(nil)
            )
            
            // Apply the updated states to the database
            switch variant {
                case .userProfile:
                    try SessionUtil.handleUserProfileUpdate(
                        db,
                        in: atomicConf,
                        needsDump: result.needsDump,
                        latestConfigUpdateSentTimestamp: result.latestSentTimestamp
                    )
                    
                case .contacts:
                    try SessionUtil.handleContactsUpdate(
                        db,
                        in: atomicConf,
                        needsDump: result.needsDump
                    )
            }
            
            // We need to get the existing message hashes and combine them with the latest from the
            // service node to ensure the next push will properly clean up old messages
            let oldMessageHashes: Set<String> = try ConfigDump
                .filter(
                    ConfigDump.Columns.variant == variant &&
                    ConfigDump.Columns.publicKey == publicKey
                )
                .select(.combinedMessageHashes)
                .asRequest(of: String.self)
                .fetchOne(db)
                .map { ConfigDump.messageHashes(from: $0) }
                .defaulting(to: [])
                .asSet()
            let allMessageHashes: [String] = Array(oldMessageHashes
                .inserting(contentsOf: result.messageHashes.asSet()))
            let messageHashesChanged: Bool = (oldMessageHashes != result.messageHashes.asSet())
            
            // Now that the changes are applied, update the cached dumps
            switch (result.needsDump, messageHashesChanged) {
                case (true, _):
                    // The config data had changes so regenerate the dump and save it
                    try atomicConf
                        .mutate { conf -> ConfigDump? in
                            try SessionUtil.createDump(
                                conf: conf,
                                for: variant,
                                publicKey: publicKey,
                                messageHashes: allMessageHashes
                            )
                        }?
                        .save(db)
                    
                case (false, true):
                    // The config data didn't change but there were different messages on the service node
                    // so just update the message hashes so the next sync can properly remove any old ones
                    try ConfigDump
                        .filter(
                            ConfigDump.Columns.variant == variant &&
                            ConfigDump.Columns.publicKey == publicKey
                        )
                        .updateAll(
                            db,
                            ConfigDump.Columns.combinedMessageHashes
                                .set(to: ConfigDump.combinedMessageHashes(from: allMessageHashes))
                        )
                    
                default: break
            }
        
        // Now that the local state has been updated, trigger a config sync (this will push any
        // pending updates and properly update the state)
        if results.contains(where: { $0.value.needsPush }) {
            ConfigurationSyncJob.enqueue(db)
        }
        
    }
}

// MARK: - Internal Convenience

fileprivate extension SessionUtil {
    struct ConfigKey: Hashable {
        let variant: ConfigDump.Variant
        let publicKey: String
    }
    
    struct DumpInfo: FetchableRecord, Decodable, Hashable {
        let variant: ConfigDump.Variant
        let publicKey: String
        private let combinedMessageHashes: String?
        
        var messageHashes: [String]? { ConfigDump.messageHashes(from: combinedMessageHashes) }
        
        // MARK: - Convenience
        
        static func requiredUserConfigDumpInfo(userPublicKey: String) -> Set<DumpInfo> {
            return ConfigDump.Variant.userVariants
                .map { DumpInfo(variant: $0, publicKey: userPublicKey, combinedMessageHashes: nil) }
                .asSet()
        }
    }
}
