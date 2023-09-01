// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionSnodeKit
import SessionUtil
import SessionUtilitiesKit

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
    
    // MARK: - Variables
    
    internal static func syncDedupeId(_ publicKey: String) -> String {
        return "EnqueueConfigurationSyncJob-\(publicKey)"
    }
    
    public static var libSessionVersion: String { String(cString: LIBSESSION_UTIL_VERSION_STR) }
    
    // MARK: - Loading
    
    public static func clearMemoryState(using dependencies: Dependencies) {
        dependencies.mutate(cache: .sessionUtil) { cache in
            cache.removeAll()
        }
    }
    
    public static func loadState(_ db: Database, using dependencies: Dependencies) {
        // Ensure we have the ed25519 key and that we haven't already loaded the state before
        // we continue
        guard
            let ed25519SecretKey: [UInt8] = Identity.fetchUserEd25519KeyPair(db, using: dependencies)?.secretKey,
            dependencies[cache: .sessionUtil].isEmpty
        else { return }
        
        // Retrieve the existing dumps from the database
        let currentUserPublicKey: String = getUserHexEncodedPublicKey(db, using: dependencies)
        let existingDumps: [ConfigDump] = ((try? ConfigDump.fetchSet(db)) ?? [])
            .sorted { lhs, rhs in lhs.variant.loadOrder < rhs.variant.loadOrder }
        let existingDumpVariants: Set<ConfigDump.Variant> = existingDumps
            .map { $0.variant }
            .asSet()
        let missingRequiredVariants: Set<ConfigDump.Variant> = ConfigDump.Variant.userVariants
            .subtracting(existingDumpVariants)
        let groupsByKey: [String: Data] = (try? ClosedGroup
            .filter(ids: existingDumps.map { $0.publicKey })
            .fetchAll(db)
            .reduce(into: [:]) { result, next in result[next.threadId] = next.groupIdentityPrivateKey })
            .defaulting(to: [:])
        
        // Create the config records for each dump
        dependencies.mutate(cache: .sessionUtil) { cache in
            existingDumps.forEach { dump in
                cache.setConfig(
                    for: dump.variant,
                    publicKey: dump.publicKey,
                    to: try? SessionUtil.loadState(
                        for: dump.variant,
                        publicKey: dump.publicKey,
                        userEd25519SecretKey: ed25519SecretKey,
                        groupEd25519SecretKey: groupsByKey[dump.publicKey].map { Array($0) },
                        cachedData: dump.data,
                        cache: cache
                    )
                )
            }
            
            missingRequiredVariants.forEach { variant in
                cache.setConfig(
                    for: variant,
                    publicKey: currentUserPublicKey,
                    to: try? SessionUtil.loadState(
                        for: variant,
                        publicKey: currentUserPublicKey,
                        userEd25519SecretKey: ed25519SecretKey,
                        groupEd25519SecretKey: nil,
                        cachedData: nil,
                        cache: cache
                    )
                )
            }
        }
    }
    
    private static func loadState(
        for variant: ConfigDump.Variant,
        publicKey: String,
        userEd25519SecretKey: [UInt8],
        groupEd25519SecretKey: [UInt8]?,
        cachedData: Data?,
        cache: SessionUtilCacheType
    ) throws -> Config {
        // Setup initial variables (including getting the memory address for any cached data)
        var conf: UnsafeMutablePointer<config_object>? = nil
        var keysConf: UnsafeMutablePointer<config_group_keys>? = nil
        var secretKey: [UInt8]? = userEd25519SecretKey
        var error: [CChar] = [CChar](repeating: 0, count: 256)
        let cachedDump: (data: UnsafePointer<UInt8>, length: Int)? = cachedData?.withUnsafeBytes { unsafeBytes in
            return unsafeBytes.baseAddress.map {
                (
                    $0.assumingMemoryBound(to: UInt8.self),
                    unsafeBytes.count
                )
            }
        }
        
        // Try to create the object
        return try {
            switch variant {
                case .userProfile:
                    return try user_profile_init(
                        &conf,
                        &secretKey,
                        cachedDump?.data,
                        (cachedDump?.length ?? 0),
                        &error
                    )
                    .returning(
                        Config.from(conf),
                        orThrow: "Unable to create \(variant.rawValue) config object",
                        error: error
                    )

                case .contacts:
                    return try contacts_init(
                        &conf,
                        &secretKey,
                        cachedDump?.data,
                        (cachedDump?.length ?? 0),
                        &error
                    )
                    .returning(
                        Config.from(conf),
                        orThrow: "Unable to create \(variant.rawValue) config object",
                        error: error
                    )

                case .convoInfoVolatile:
                    return try convo_info_volatile_init(
                        &conf,
                        &secretKey,
                        cachedDump?.data,
                        (cachedDump?.length ?? 0),
                        &error
                    )
                    .returning(
                        Config.from(conf),
                        orThrow: "Unable to create \(variant.rawValue) config object",
                        error: error
                    )

                case .userGroups:
                    return try user_groups_init(
                        &conf,
                        &secretKey,
                        cachedDump?.data,
                        (cachedDump?.length ?? 0),
                        &error
                    )
                    .returning(
                        Config.from(conf),
                        orThrow: "Unable to create \(variant.rawValue) config object",
                        error: error
                    )

                case .groupInfo:
                    return try groups_info_init(
                        &conf,
                        &secretKey,
                        &secretKey,
                        cachedDump?.data,
                        (cachedDump?.length ?? 0),
                        &error
                    )
                    .returning(
                        Config.from(conf),
                        orThrow: "Unable to create \(variant.rawValue) config object",
                        error: error
                    )

                case .groupMembers:
                    return try groups_members_init(
                        &conf,
                        &secretKey,
                        &secretKey,
                        cachedDump?.data,
                        (cachedDump?.length ?? 0),
                        &error
                    )
                    .returning(
                        Config.from(conf),
                        orThrow: "Unable to create \(variant.rawValue) config object",
                        error: error
                    )

                case .groupKeys:
                    var identityPublicKey: [UInt8] = Array(Data(hex: publicKey))
                    var adminSecretKey: [UInt8]? = groupEd25519SecretKey
                    let infoConfig: Config? = cache
                        .config(for: .groupInfo, publicKey: publicKey)
                        .wrappedValue
                    let membersConfig: Config? = cache
                        .config(for: .groupMembers, publicKey: publicKey)
                        .wrappedValue
                    
                    guard
                        case .object(let infoConf) = infoConfig,
                        case .object(let membersConf) = membersConfig
                    else {
                        SNLog("[SessionUtil Error] Unable to create \(variant.rawValue) config object: Group info and member config states not loaded")
                        throw SessionUtilError.unableToCreateConfigObject
                    }
                    
                    return try groups_keys_init(
                        &keysConf,
                        &secretKey,
                        &identityPublicKey,
                        &adminSecretKey,
                        infoConf,
                        membersConf,
                        cachedDump?.data,
                        (cachedDump?.length ?? 0),
                        &error
                    )
                    .returning(
                        Config.from(keysConf, info: infoConf, members: membersConf),
                        orThrow: "Unable to create \(variant.rawValue) config object",
                        error: error
                    )
            }
        }()
    }
    
    internal static func createDump(
        config: Config?,
        for variant: ConfigDump.Variant,
        publicKey: String,
        timestampMs: Int64
    ) throws -> ConfigDump? {
        // If it doesn't need a dump then do nothing
        guard
            config.needsDump,
            let dumpData: Data = try config?.dump()
        else { return nil }
        
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
        publicKey: String,
        using dependencies: Dependencies
    ) throws -> [OutgoingConfResult] {
        guard Identity.userExists(db, using: dependencies) else { throw SessionUtilError.userDoesNotExist }
        
        // Get a list of the different config variants for the provided publicKey
        let currenUserPublicKey: String = getUserHexEncodedPublicKey(db, using: dependencies)
        let targetVariants: Set<ConfigDump.Variant> = {
            switch (publicKey, SessionId.Prefix(from: publicKey)) {
                case (currenUserPublicKey, _): return ConfigDump.Variant.userVariants
                case (_, .group): return ConfigDump.Variant.groupVariants
                default: return []
            }
        }()
        
        // Extract any pending changes from the cached config entry for each variant
        return try targetVariants
            .compactMap { variant -> OutgoingConfResult? in
                try dependencies[cache: .sessionUtil]
                    .config(for: variant, publicKey: publicKey)
                    .wrappedValue
                    .map { config -> OutgoingConfResult? in
                        // Check if the config needs to be pushed
                        guard config.needsPush else { return nil }
                        
                        var result: (data: Data, seqNo: Int64, obsoleteHashes: [String])!
                        let configCountInfo: String = {
                            var result: String = "Invalid"
                            
                            try? CExceptionHelper.performSafely {
                                switch (config, variant) {
                                    case (_, .userProfile): result = "1 profile"
                                    case (.object(let conf), .contacts):
                                        result = "\(contacts_size(conf)) contacts"
                                        
                                    case (.object(let conf), .userGroups):
                                        result = "\(user_groups_size(conf)) group conversations"
                                        
                                    case (.object(let conf), .convoInfoVolatile):
                                        result = "\(convo_info_volatile_size(conf)) volatile conversations"

                                    case (_, .groupInfo): result = "1 group info"
                                    case (.object(let conf), .groupMembers):
                                        result = "\(groups_members_size(conf)) group members"
                                        
                                    case (.groupKeys(let conf, _, _), .groupKeys):
                                        result = "\(groups_keys_size(conf)) group keys"
                                        
                                    default: break
                                }
                            }
                            
                            return result
                        }()
                        
                        do { result = try config.push() }
                        catch {
                            SNLog("[libSession] Failed to generate push data for \(variant) config data, size: \(configCountInfo), error: \(error)")
                            throw error
                        }
                        
                        return OutgoingConfResult(
                            message: SharedConfigMessage(
                                kind: variant.configMessageKind,
                                seqNo: result.seqNo,
                                data: result.data
                            ),
                            namespace: variant.namespace,
                            obsoleteHashes: result.obsoleteHashes
                        )
                    }
            }
    }
    
    public static func markingAsPushed(
        message: SharedConfigMessage,
        serverHash: String,
        publicKey: String,
        using dependencies: Dependencies
    ) -> ConfigDump? {
        return dependencies[cache: .sessionUtil]
            .config(for: message.kind.configDumpVariant, publicKey: publicKey)
            .mutate { config -> ConfigDump? in
                guard config != nil else { return nil }
                
                // Mark the config as pushed
                config?.confirmPushed(seqNo: message.seqNo, hash: serverHash)
                
                // Update the result to indicate whether the config needs to be dumped
                guard config.needsPush else { return nil }
                
                return try? SessionUtil.createDump(
                    config: config,
                    for: message.kind.configDumpVariant,
                    publicKey: publicKey,
                    timestampMs: (message.sentTimestamp.map { Int64($0) } ?? 0)
                )
            }
    }
    
    public static func configHashes(
        for publicKey: String,
        using dependencies: Dependencies
    ) -> [String] {
        return dependencies[singleton: .storage]
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
                dependencies[cache: .sessionUtil]
                    .config(for: variant, publicKey: publicKey)
                    .wrappedValue
                    .map { $0.currentHashes() }
                    .defaulting(to: [])
            }
            .reduce([], +)
    }
    
    // MARK: - Receiving
    
    public static func handleConfigMessages(
        _ db: Database,
        messages: [SharedConfigMessage],
        publicKey: String,
        using dependencies: Dependencies = Dependencies()
    ) throws {
        guard !messages.isEmpty else { return }
        guard !publicKey.isEmpty else { throw MessageReceiverError.noThread }
        
        let groupedMessages: [ConfigDump.Variant: [SharedConfigMessage]] = messages
            .sorted { lhs, rhs in lhs.seqNo < rhs.seqNo }
            .grouped(by: \.kind.configDumpVariant)
        
        let needsPush: Bool = try groupedMessages
            .sorted { lhs, rhs in lhs.key.processingOrder < rhs.key.processingOrder }
            .reduce(false) { prevNeedsPush, next -> Bool in
                let latestConfigSentTimestampMs: Int64 = Int64(next.value.compactMap { $0.sentTimestamp }.max() ?? 0)
                let needsPush: Bool = try dependencies[cache: .sessionUtil]
                    .config(for: next.key, publicKey: publicKey)
                    .mutate { config in
                        // Merge the messages
                        config?.merge(next.value)
                        
                        // Apply the updated states to the database
                        do {
                            switch next.key {
                                case .userProfile:
                                    try SessionUtil.handleUserProfileUpdate(
                                        db,
                                        in: config,
                                        latestConfigSentTimestampMs: latestConfigSentTimestampMs,
                                        using: dependencies
                                    )
                                    
                                case .contacts:
                                    try SessionUtil.handleContactsUpdate(
                                        db,
                                        in: config,
                                        latestConfigSentTimestampMs: latestConfigSentTimestampMs,
                                        using: dependencies
                                    )
                                    
                                case .convoInfoVolatile:
                                    try SessionUtil.handleConvoInfoVolatileUpdate(
                                        db,
                                        in: config,
                                        using: dependencies
                                    )
                                    
                                case .userGroups:
                                    try SessionUtil.handleUserGroupsUpdate(
                                        db,
                                        in: config,
                                        latestConfigSentTimestampMs: latestConfigSentTimestampMs,
                                        using: dependencies
                                    )
                                    
                                case .groupInfo:
                                    try SessionUtil.handleGroupInfoUpdate(
                                        db,
                                        in: config,
                                        latestConfigSentTimestampMs: latestConfigSentTimestampMs,
                                        using: dependencies
                                    )
                                    
                                case .groupMembers:
                                    try SessionUtil.handleGroupMembersUpdate(
                                        db,
                                        in: config,
                                        latestConfigSentTimestampMs: latestConfigSentTimestampMs,
                                        using: dependencies
                                    )
                                    
                                case .groupKeys:
                                    try SessionUtil.handleGroupKeysUpdate(
                                        db,
                                        in: config,
                                        latestConfigSentTimestampMs: latestConfigSentTimestampMs,
                                        using: dependencies
                                    )
                            }
                        }
                        catch {
                            SNLog("[libSession] Failed to process merge of \(next.key) config data")
                            throw error
                        }
                        
                        // Need to check if the config needs to be dumped (this might have changed
                        // after handling the merge changes)
                        guard config.needsDump else {
                            try ConfigDump
                                .filter(
                                    ConfigDump.Columns.variant == next.key &&
                                    ConfigDump.Columns.publicKey == publicKey
                                )
                                .updateAll(
                                    db,
                                    ConfigDump.Columns.timestampMs.set(to: latestConfigSentTimestampMs)
                                )
                            
                            return config.needsPush
                        }
                        
                        try SessionUtil.createDump(
                            config: config,
                            for: next.key,
                            publicKey: publicKey,
                            timestampMs: latestConfigSentTimestampMs
                        )?.save(db)
                
                        return config.needsPush
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

// MARK: - Convenience

private extension Int32 {
    func returning(_ config: SessionUtil.Config?, orThrow description: String, error: [CChar]) throws -> SessionUtil.Config {
        guard self == 0, let config: SessionUtil.Config = config else {
            SNLog("[SessionUtil Error] \(description): \(String(cString: error))")
            throw SessionUtilError.unableToCreateConfigObject
        }
        
        return config
    }
}

// MARK: - SessionUtil Cache

public extension SessionUtil {
    class Cache: SessionUtilCacheType {
        public struct Key: Hashable {
            let variant: ConfigDump.Variant
            let publicKey: String
        }
        
        private var configStore: [SessionUtil.Cache.Key: Atomic<SessionUtil.Config?>] = [:]
        
        public var isEmpty: Bool { configStore.isEmpty }
        
        /// Returns `true` if there is a config which needs to be pushed, but returns `false` if the configs are all up to date or haven't been
        /// loaded yet (eg. fresh install)
        public var needsSync: Bool { configStore.contains { _, atomicConf in atomicConf.needsPush } }
        
        // MARK: - Functions
        
        public func setConfig(for variant: ConfigDump.Variant, publicKey: String, to config: SessionUtil.Config?) {
            configStore[Key(variant: variant, publicKey: publicKey)] = config.map { Atomic($0) }
        }
        
        public func config(
            for variant: ConfigDump.Variant,
            publicKey: String
        ) -> Atomic<Config?> {
            return (
                configStore[Key(variant: variant, publicKey: publicKey)] ??
                Atomic(nil)
            )
        }
        
        public func removeAll() {
            configStore.removeAll()
        }
    }
}

public extension Cache {
    static let sessionUtil: CacheInfo.Config<SessionUtilCacheType, SessionUtilImmutableCacheType> = CacheInfo.create(
        createInstance: { _ in SessionUtil.Cache() },
        mutableInstance: { $0 },
        immutableInstance: { $0 }
    )
}

// MARK: - SessionUtilCacheType

/// This is a read-only version of the `SessionUtil.Cache` designed to avoid unintentionally mutating the instance in a
/// non-thread-safe way
public protocol SessionUtilImmutableCacheType: ImmutableCacheType {
    var isEmpty: Bool { get }
    var needsSync: Bool { get }
    
    func config(for variant: ConfigDump.Variant, publicKey: String) -> Atomic<SessionUtil.Config?>
}

public protocol SessionUtilCacheType: SessionUtilImmutableCacheType, MutableCacheType {
    var isEmpty: Bool { get }
    var needsSync: Bool { get }
    
    func setConfig(for variant: ConfigDump.Variant, publicKey: String, to config: SessionUtil.Config?)
    func config(for variant: ConfigDump.Variant, publicKey: String) -> Atomic<SessionUtil.Config?>
    func removeAll()
}
