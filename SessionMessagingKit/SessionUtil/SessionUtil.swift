// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionSnodeKit
import SessionUtil
import SessionUtilitiesKit

// MARK: - Features

public extension Features {
    static func useSharedUtilForUserConfig(_ db: Database? = nil) -> Bool {
        guard Date().timeIntervalSince1970 < 1690761600 else { return true }
        guard !SessionUtil.hasCheckedMigrationsCompleted.wrappedValue else {
            return SessionUtil.userConfigsEnabledIgnoringFeatureFlag
        }
        
        if let db: Database = db {
            return SessionUtil.refreshingUserConfigsEnabled(db)
        }
        
        return Storage.shared
            .read { db in SessionUtil.refreshingUserConfigsEnabled(db) }
            .defaulting(to: false)
    }
}

// MARK: - SessionUtil

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
        
        var result: ConfResult { ConfResult(needsPush: needsPush, needsDump: needsDump) }
    }
    
    public struct OutgoingConfResult {
        let message: SharedConfigMessage
        let namespace: SnodeAPI.Namespace
        let obsoleteHashes: [String]
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
    
    internal static func syncDedupeId(_ publicKey: String) -> String {
        return "EnqueueConfigurationSyncJob-\(publicKey)"
    }
    
    /// Returns `true` if there is a config which needs to be pushed, but returns `false` if the configs are all up to date or haven't been
    /// loaded yet (eg. fresh install)
    public static var needsSync: Bool {
        // FIXME: Remove this once `useSharedUtilForUserConfig` is permanent
        guard SessionUtil.userConfigsEnabled else { return false }
        
        return configStore
            .wrappedValue
            .contains { _, atomicConf in
                guard atomicConf.wrappedValue != nil else { return false }
                
                return config_needs_push(atomicConf.wrappedValue)
            }
    }
    
    public static var libSessionVersion: String { String(cString: LIBSESSION_UTIL_VERSION_STR) }
    
    fileprivate static let hasCheckedMigrationsCompleted: Atomic<Bool> = Atomic(false)
    private static let requiredMigrationsCompleted: Atomic<Bool> = Atomic(false)
    private static let requiredMigrationIdentifiers: Set<String> = [
        TargetMigrations.Identifier.messagingKit.key(with: _013_SessionUtilChanges.self),
        TargetMigrations.Identifier.messagingKit.key(with: _014_GenerateInitialUserConfigDumps.self)
    ]
    
    public static var userConfigsEnabled: Bool {
        return userConfigsEnabled(nil)
    }
    
    public static func userConfigsEnabled(_ db: Database?) -> Bool {
        Features.useSharedUtilForUserConfig(db) &&
        SessionUtil.userConfigsEnabledIgnoringFeatureFlag
    }
    
    public static var userConfigsEnabledIgnoringFeatureFlag: Bool {
        SessionUtil.requiredMigrationsCompleted.wrappedValue
    }
    
    internal static func userConfigsEnabled(
        _ db: Database,
        ignoreRequirementsForRunningMigrations: Bool
    ) -> Bool {
        // First check if we are enabled regardless of what we want to ignore
        guard
            Features.useSharedUtilForUserConfig(db),
            !SessionUtil.requiredMigrationsCompleted.wrappedValue,
            !SessionUtil.refreshingUserConfigsEnabled(db),
            ignoreRequirementsForRunningMigrations,
            let currentlyRunningMigration: (identifier: TargetMigrations.Identifier, migration: Migration.Type) = Storage.shared.currentlyRunningMigration
        else { return true }
        
        let nonIgnoredMigrationIdentifiers: Set<String> = SessionUtil.requiredMigrationIdentifiers
            .removing(currentlyRunningMigration.identifier.key(with: currentlyRunningMigration.migration))
        
        return Storage.appliedMigrationIdentifiers(db)
            .isSuperset(of: nonIgnoredMigrationIdentifiers)
    }
    
    @discardableResult public static func refreshingUserConfigsEnabled(_ db: Database) -> Bool {
        let result: Bool = Storage.appliedMigrationIdentifiers(db)
            .isSuperset(of: SessionUtil.requiredMigrationIdentifiers)
        
        requiredMigrationsCompleted.mutate { $0 = result }
        hasCheckedMigrationsCompleted.mutate { $0 = true }
        
        return result
    }
    
    internal static func lastError(_ conf: UnsafeMutablePointer<config_object>?) -> String {
        return (conf?.pointee.last_error.map { String(cString: $0) } ?? "Unknown")
    }
    
    // MARK: - Loading
    
    public static func clearMemoryState() {
        // Ensure we have a loaded state before we continue
        guard !SessionUtil.configStore.wrappedValue.isEmpty else { return }
        
        SessionUtil.configStore.mutate { confStore in
            confStore.removeAll()
        }
    }
    
    public static func loadState(
        _ db: Database? = nil,
        userPublicKey: String,
        ed25519SecretKey: [UInt8]?
    ) {
        // Ensure we have the ed25519 key and that we haven't already loaded the state before
        // we continue
        guard
            let secretKey: [UInt8] = ed25519SecretKey,
            SessionUtil.configStore.wrappedValue.isEmpty
        else { return }
        
        // If we weren't given a database instance then get one
        guard let db: Database = db else {
            Storage.shared.read { db in
                SessionUtil.loadState(db, userPublicKey: userPublicKey, ed25519SecretKey: secretKey)
            }
            return
        }
        
        // FIXME: Remove this once `useSharedUtilForUserConfig` is permanent
        guard SessionUtil.userConfigsEnabled(db, ignoreRequirementsForRunningMigrations: true) else { return }
        
        // Retrieve the existing dumps from the database
        let existingDumps: Set<ConfigDump> = ((try? ConfigDump.fetchSet(db)) ?? [])
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
    
    private static func loadState(
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

                case .convoInfoVolatile:
                    return convo_info_volatile_init(&conf, &secretKey, cachedDump?.data, (cachedDump?.length ?? 0), error)

                case .userGroups:
                    return user_groups_init(&conf, &secretKey, cachedDump?.data, (cachedDump?.length ?? 0), error)
            }
        }()
        
        guard result == 0 else {
            let errorString: String = (error.map { String(cString: $0) } ?? "unknown error")
            SNLog("[SessionUtil Error] Unable to create \(variant.rawValue) config object: \(errorString)")
            throw SessionUtilError.unableToCreateConfigObject
        }
        
        return conf
    }
    
    internal static func createDump(
        conf: UnsafeMutablePointer<config_object>?,
        for variant: ConfigDump.Variant,
        publicKey: String,
        timestampMs: Int64
    ) throws -> ConfigDump? {
        guard conf != nil else { throw SessionUtilError.nilConfigObject }
        
        // If it doesn't need a dump then do nothing
        guard config_needs_dump(conf) else { return nil }
        
        var dumpResult: UnsafeMutablePointer<UInt8>? = nil
        var dumpResultLen: Int = 0
        try CExceptionHelper.performSafely {
            config_dump(conf, &dumpResult, &dumpResultLen)
        }
        
        guard let dumpResult: UnsafeMutablePointer<UInt8> = dumpResult else { return nil }
        
        let dumpData: Data = Data(bytes: dumpResult, count: dumpResultLen)
        dumpResult.deallocate()
        
        return ConfigDump(
            variant: variant,
            publicKey: publicKey,
            data: dumpData,
            timestampMs: timestampMs
        )
    }
    
    // MARK: - Pushes
    
    public static func pendingChanges(
        _ db: Database,
        publicKey: String
    ) throws -> [OutgoingConfResult] {
        guard Identity.userExists(db) else { throw SessionUtilError.userDoesNotExist }
        
        let userPublicKey: String = getUserHexEncodedPublicKey(db)
        var existingDumpVariants: Set<ConfigDump.Variant> = try ConfigDump
            .select(.variant)
            .filter(ConfigDump.Columns.publicKey == publicKey)
            .asRequest(of: ConfigDump.Variant.self)
            .fetchSet(db)
        
        // Ensure we always check the required user config types for changes even if there is no dump
        // data yet (to deal with first launch cases)
        if publicKey == userPublicKey {
            ConfigDump.Variant.userVariants.forEach { existingDumpVariants.insert($0) }
        }
        
        // Ensure we always check the required user config types for changes even if there is no dump
        // data yet (to deal with first launch cases)
        return try existingDumpVariants
            .compactMap { variant -> OutgoingConfResult? in
                try SessionUtil
                    .config(for: variant, publicKey: publicKey)
                    .wrappedValue
                    .map { conf in
                        // Check if the config needs to be pushed
                        guard config_needs_push(conf) else { return nil }
                        
                        var cPushData: UnsafeMutablePointer<config_push_data>!
                        let configCountInfo: String = {
                            var result: String = "Invalid"
                            
                            try? CExceptionHelper.performSafely {
                                switch variant {
                                    case .userProfile: result = "1 profile"
                                    case .contacts: result = "\(contacts_size(conf)) contacts"
                                    case .userGroups: result = "\(user_groups_size(conf)) group conversations"
                                    case .convoInfoVolatile: result = "\(convo_info_volatile_size(conf)) volatile conversations"
                                }
                            }
                            
                            return result
                        }()
                        
                        do {
                            try CExceptionHelper.performSafely {
                                cPushData = config_push(conf)
                            }
                        }
                        catch {
                            SNLog("[libSession] Failed to generate push data for \(variant) config data, size: \(configCountInfo), error: \(error)")
                            throw error
                        }
                    
                        let pushData: Data = Data(
                            bytes: cPushData.pointee.config,
                            count: cPushData.pointee.config_len
                        )
                        let obsoleteHashes: [String] = [String](
                            pointer: cPushData.pointee.obsolete,
                            count: cPushData.pointee.obsolete_len,
                            defaultValue: []
                        )
                        let seqNo: Int64 = cPushData.pointee.seqno
                        cPushData.deallocate()
                        
                        return OutgoingConfResult(
                            message: SharedConfigMessage(
                                kind: variant.configMessageKind,
                                seqNo: seqNo,
                                data: pushData
                            ),
                            namespace: variant.namespace,
                            obsoleteHashes: obsoleteHashes
                        )
                    }
            }
    }
    
    public static func markingAsPushed(
        message: SharedConfigMessage,
        serverHash: String,
        publicKey: String
    ) -> ConfigDump? {
        return SessionUtil
            .config(for: message.kind.configDumpVariant, publicKey: publicKey)
            .mutate { conf in
                guard conf != nil else { return nil }
                
                // Mark the config as pushed
                var cHash: [CChar] = serverHash.cArray.nullTerminated()
                config_confirm_pushed(conf, message.seqNo, &cHash)
                
                // Update the result to indicate whether the config needs to be dumped
                guard config_needs_dump(conf) else { return nil }
                
                return try? SessionUtil.createDump(
                    conf: conf,
                    for: message.kind.configDumpVariant,
                    publicKey: publicKey,
                    timestampMs: (message.sentTimestamp.map { Int64($0) } ?? 0)
                )
            }
    }
    
    public static func configHashes(for publicKey: String) -> [String] {
        // FIXME: Remove this once `useSharedUtilForUserConfig` is permanent
        guard SessionUtil.userConfigsEnabled else { return [] }
        
        return Storage.shared
            .read { db -> Set<ConfigDump.Variant> in
                guard Identity.userExists(db) else { return [] }
                
                return try ConfigDump
                    .select(.variant)
                    .filter(ConfigDump.Columns.publicKey == publicKey)
                    .asRequest(of: ConfigDump.Variant.self)
                    .fetchSet(db)
            }
            .defaulting(to: [])
            .map { variant -> [String] in
                /// Extract all existing hashes for any dumps associated with the given `publicKey`
                guard
                    let conf = SessionUtil
                        .config(for: variant, publicKey: publicKey)
                        .wrappedValue,
                    let hashList: UnsafeMutablePointer<config_string_list> = config_current_hashes(conf)
                else { return [] }
                
                let result: [String] = [String](
                    pointer: hashList.pointee.value,
                    count: hashList.pointee.len,
                    defaultValue: []
                )
                hashList.deallocate()
                
                return result
            }
            .reduce([], +)
    }
    
    // MARK: - Receiving
    
    public static func handleConfigMessages(
        _ db: Database,
        messages: [SharedConfigMessage],
        publicKey: String
    ) throws {
        // FIXME: Remove this once `useSharedUtilForUserConfig` is permanent
        guard SessionUtil.userConfigsEnabled(db) else { return }
        guard !messages.isEmpty else { return }
        guard !publicKey.isEmpty else { throw MessageReceiverError.noThread }
        
        let groupedMessages: [ConfigDump.Variant: [SharedConfigMessage]] = messages
            .grouped(by: \.kind.configDumpVariant)
        
        let needsPush: Bool = try groupedMessages
            .sorted { lhs, rhs in lhs.key.processingOrder < rhs.key.processingOrder }
            .reduce(false) { prevNeedsPush, next -> Bool in
                let latestConfigSentTimestampMs: Int64 = Int64(next.value.compactMap { $0.sentTimestamp }.max() ?? 0)
                let needsPush: Bool = try SessionUtil
                    .config(for: next.key, publicKey: publicKey)
                    .mutate { conf in
                        // Merge the messages
                        var mergeHashes: [UnsafePointer<CChar>?] = next.value
                            .map { message in (message.serverHash ?? "").cArray.nullTerminated() }
                            .unsafeCopy()
                        var mergeData: [UnsafePointer<UInt8>?] = next.value
                            .map { message -> [UInt8] in message.data.bytes }
                            .unsafeCopy()
                        var mergeSize: [Int] = next.value.map { $0.data.count }
                        config_merge(conf, &mergeHashes, &mergeData, &mergeSize, next.value.count)
                        mergeHashes.forEach { $0?.deallocate() }
                        mergeData.forEach { $0?.deallocate() }
                        
                        // Apply the updated states to the database
                        do {
                            switch next.key {
                                case .userProfile:
                                    try SessionUtil.handleUserProfileUpdate(
                                        db,
                                        in: conf,
                                        mergeNeedsDump: config_needs_dump(conf),
                                        latestConfigSentTimestampMs: latestConfigSentTimestampMs
                                    )
                                    
                                case .contacts:
                                    try SessionUtil.handleContactsUpdate(
                                        db,
                                        in: conf,
                                        mergeNeedsDump: config_needs_dump(conf),
                                        latestConfigSentTimestampMs: latestConfigSentTimestampMs
                                    )
                                    
                                case .convoInfoVolatile:
                                    try SessionUtil.handleConvoInfoVolatileUpdate(
                                        db,
                                        in: conf,
                                        mergeNeedsDump: config_needs_dump(conf)
                                    )
                                    
                                case .userGroups:
                                    try SessionUtil.handleGroupsUpdate(
                                        db,
                                        in: conf,
                                        mergeNeedsDump: config_needs_dump(conf),
                                        latestConfigSentTimestampMs: latestConfigSentTimestampMs
                                    )
                            }
                        }
                        catch {
                            SNLog("[libSession] Failed to process merge of \(next.key) config data")
                            throw error
                        }
                        
                        // Need to check if the config needs to be dumped (this might have changed
                        // after handling the merge changes)
                        guard config_needs_dump(conf) else {
                            try ConfigDump
                                .filter(
                                    ConfigDump.Columns.variant == next.key &&
                                    ConfigDump.Columns.publicKey == publicKey
                                )
                                .updateAll(
                                    db,
                                    ConfigDump.Columns.timestampMs.set(to: latestConfigSentTimestampMs)
                                )
                            
                            return config_needs_push(conf)
                        }
                        
                        try SessionUtil.createDump(
                            conf: conf,
                            for: next.key,
                            publicKey: publicKey,
                            timestampMs: latestConfigSentTimestampMs
                        )?.save(db)
                
                        return config_needs_push(conf)
                    }
                
                // Update the 'needsPush' state as needed
                return (prevNeedsPush || needsPush)
            }
        
        // Now that the local state has been updated, schedule a config sync if needed (this will
        // push any pending updates and properly update the state)
        guard needsPush else { return }
        
        db.afterNextTransactionNestedOnce(dedupeId: SessionUtil.syncDedupeId(publicKey)) { db in
            ConfigurationSyncJob.enqueue(db, publicKey: publicKey)
        }
    }
}

// MARK: - Internal Convenience

fileprivate extension SessionUtil {
    struct ConfigKey: Hashable {
        let variant: ConfigDump.Variant
        let publicKey: String
    }
}

// MARK: - Convenience

public extension SessionUtil {
    static func parseCommunity(url: String) -> (room: String, server: String, publicKey: String)? {
        var cFullUrl: [CChar] = url.cArray.nullTerminated()
        var cBaseUrl: [CChar] = [CChar](repeating: 0, count: COMMUNITY_BASE_URL_MAX_LENGTH)
        var cRoom: [CChar] = [CChar](repeating: 0, count: COMMUNITY_ROOM_MAX_LENGTH)
        var cPubkey: [UInt8] = [UInt8](repeating: 0, count: OpenGroup.pubkeyByteLength)
        
        guard
            community_parse_full_url(&cFullUrl, &cBaseUrl, &cRoom, &cPubkey) &&
            !String(cString: cRoom).isEmpty &&
            !String(cString: cBaseUrl).isEmpty &&
            cPubkey.contains(where: { $0 != 0 })
        else { return nil }
        
        // Note: Need to store them in variables instead of returning directly to ensure they
        // don't get freed from memory early (was seeing this happen intermittently during
        // unit tests...)
        let room: String = String(cString: cRoom)
        let baseUrl: String = String(cString: cBaseUrl)
        let pubkeyHex: String = Data(cPubkey).toHexString()
        
        return (room, baseUrl, pubkeyHex)
    }
    
    static func communityUrlFor(server: String, roomToken: String, publicKey: String) -> String {
        var cBaseUrl: [CChar] = server.cArray.nullTerminated()
        var cRoom: [CChar] = roomToken.cArray.nullTerminated()
        var cPubkey: [UInt8] = Data(hex: publicKey).cArray
        var cFullUrl: [CChar] = [CChar](repeating: 0, count: COMMUNITY_FULL_URL_MAX_LENGTH)
        community_make_full_url(&cBaseUrl, &cRoom, &cPubkey, &cFullUrl)
        
        return String(cString: cFullUrl)
    }
}
