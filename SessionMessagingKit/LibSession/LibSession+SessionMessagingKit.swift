// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionNetworkingKit
import SessionUIKit
import SessionUtil
import SessionUtilitiesKit

// MARK: - Cache

public extension Cache {
    static let libSession: CacheConfig<LibSessionCacheType, LibSessionImmutableCacheType> = Dependencies.create(
        identifier: "libSession",
        createInstance: { dependencies, _ in NoopLibSessionCache(using: dependencies) },
        mutableInstance: { $0 },
        immutableInstance: { $0 }
    )
}

// MARK: - Convenience

public extension LibSession {
    static var attachmentEncryptionKeySize: Int { ATTACHMENT_ENCRYPT_KEY_SIZE }
}

public extension LibSession {
    static func parseCommunity(url: String) -> (room: String, server: String, publicKey: String)? {
        var cBaseUrl: [CChar] = [CChar](repeating: 0, count: COMMUNITY_BASE_URL_MAX_LENGTH)
        var cRoom: [CChar] = [CChar](repeating: 0, count: COMMUNITY_ROOM_MAX_LENGTH)
        var cPubkey: [UInt8] = [UInt8](repeating: 0, count: OpenGroup.pubkeyByteLength)
        
        guard
            var cFullUrl: [CChar] = url.cString(using: .utf8),
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
    
    static func communityUrlFor(server: String?, roomToken: String?, publicKey: String?) -> String? {
        guard
            var cBaseUrl: [CChar] = server?.cString(using: .utf8),
            var cRoom: [CChar] = roomToken?.cString(using: .utf8),
            let publicKey: String = publicKey
        else { return nil }
        
        var cPubkey: [UInt8] = Array(Data(hex: publicKey))
        var cFullUrl: [CChar] = [CChar](repeating: 0, count: COMMUNITY_FULL_URL_MAX_LENGTH)
        community_make_full_url(&cBaseUrl, &cRoom, &cPubkey, &cFullUrl)
        
        return String(cString: cFullUrl)
    }
}

// MARK: - ConfigStore

private class ConfigStore {
    private struct Key: Hashable {
        let sessionId: SessionId
        let variant: ConfigDump.Variant
        
        init(sessionId: SessionId, variant: ConfigDump.Variant) {
            self.sessionId = sessionId
            self.variant = variant
        }
    }
    
    private var store: [Key: LibSession.Config] = [:]
    public var isEmpty: Bool { store.isEmpty }
    public var allIds: Set<SessionId> { Set(store.keys.map { $0.sessionId }) }
    
    subscript (sessionId: SessionId, variant: ConfigDump.Variant) -> LibSession.Config? {
        get { return (store[Key(sessionId: sessionId, variant: variant)] ?? nil) }
        set { store[Key(sessionId: sessionId, variant: variant)] = newValue }
    }
    
    subscript (sessionId: SessionId) -> [LibSession.Config] {
        get { return ConfigDump.Variant.allCases.compactMap { store[Key(sessionId: sessionId, variant: $0)] } }
    }
    
    deinit {
        /// Group configs are a little complicated because they contain the info & members confs so we need some special handling to
        /// properly free memory here, firstly we need to retrieve all groupKeys configs
        let groupKeysConfigs: [(key: Key, value: LibSession.Config)] = store
            .filter { _, config in
                switch config {
                    case .groupKeys: return true
                    default: return false
                }
            }
        
        /// Now we remove all configss associated to the same sessionId from the store
        groupKeysConfigs.forEach { key, _ in
            ConfigDump.Variant.allCases.forEach { store.removeValue(forKey: Key(sessionId: key.sessionId, variant: $0)) }
        }
        
        /// Then free the group configs
        groupKeysConfigs.forEach { _, config in
            switch config {
                case .groupKeys(let keysConf, let infoConf, let membersConf):
                    groups_keys_free(keysConf)
                    config_free(infoConf)
                    config_free(membersConf)
                    
                default: break
            }
        }
        
        /// Finally we free any remaining configs
        store.forEach { _, config in
            switch config {
                case .groupKeys: break    // Shouldn't happen
                case .userProfile(let conf), .contacts(let conf), .convoInfoVolatile(let conf),
                    .userGroups(let conf), .local(let conf), .groupInfo(let conf), .groupMembers(let conf):
                    config_free(conf)
            }
        }
        store.removeAll()
    }
}

// MARK: - BehaviourStore

private class BehaviourStore {
    private struct Key: Hashable {
        let sessionId: SessionId
        let variant: ConfigDump.Variant?
        let behaviour: LibSession.CacheBehaviour
        
        init(sessionId: SessionId, variant: ConfigDump.Variant?, behaviour: LibSession.CacheBehaviour) {
            self.sessionId = sessionId
            self.variant = variant
            self.behaviour = behaviour
        }
    }
    
    private var store: [Key: Int] = [:]
    
    public func add(_ behaviour: LibSession.CacheBehaviour, sessionId: SessionId, variant: ConfigDump.Variant?) {
        let key: Key = Key(sessionId: sessionId, variant: variant, behaviour: behaviour)
        store[key] = ((store[key] ?? 0) + 1)
    }
    
    public func remove(_ behaviour: LibSession.CacheBehaviour, sessionId: SessionId, variant: ConfigDump.Variant?) {
        let key: Key = Key(sessionId: sessionId, variant: variant, behaviour: behaviour)
        store[key] = ((store[key] ?? 1) - 1)
        
        if (store[key] ?? 0) <= 0 {
            store.removeValue(forKey: key)
        }
    }
    
    public func hasBehaviour(
        _ behaviour: LibSession.CacheBehaviour,
        for sessionId: SessionId,
        _ variant: ConfigDump.Variant? = nil
    ) -> Bool {
        let variantSpecificKey: Key = Key(sessionId: sessionId, variant: variant, behaviour: behaviour)
        let noVariantKey: Key = Key(sessionId: sessionId, variant: nil, behaviour: behaviour)
        
        return (
            store[variantSpecificKey] != nil ||
            store[noVariantKey] != nil
        )
    }
}

// MARK: - SessionUtil Cache

public extension LibSession {
    typealias MergeResult = (
        sessionId: SessionId,
        variant: ConfigDump.Variant,
        dump: ConfigDump?
    )
    
    enum CacheBehaviour {
        case skipAutomaticConfigSync
        case skipGroupAdminCheck
    }
    
    class Cache: LibSessionCacheType {
        private let configStore: ConfigStore = ConfigStore()
        private let behaviourStore: BehaviourStore = BehaviourStore()
        private var pendingEvents: [ObservedEvent] = []
        
        public let dependencies: Dependencies
        public let userSessionId: SessionId
        public var isEmpty: Bool { configStore.isEmpty }
        public var allDumpSessionIds: Set<SessionId> { configStore.allIds }
        
        // MARK: - Initialization
        
        public init(userSessionId: SessionId, using dependencies: Dependencies) {
            self.userSessionId = userSessionId
            self.dependencies = dependencies
        }
        
        // MARK: - State Management
        
        public func loadState(_ db: ObservingDatabase, requestId: String?) {
            // Ensure we have the ed25519 key and that we haven't already loaded the state before
            // we continue
            guard configStore.isEmpty else {
                return Log.warn(.libSession, "Ignoring loadState\(requestId.map { " for \($0)" } ?? "") due to existing state")
            }
            
            /// Retrieve the existing dumps from the database
            typealias ConfigInfo = (sessionId: SessionId, variant: ConfigDump.Variant, dump: ConfigDump?)
            let existingDumpsByKey: [String: [ConfigDump]] = ((try? ConfigDump.fetchAll(db)) ?? [])
                .grouped(by: \.sessionId.hexString)
            var configsToLoad: [ConfigInfo] = []
            
            /// Load in the user dumps first (it's possible for a user dump to be missing due to some edge-cases so use
            /// `ConfigDump.Variant.userVariants` to ensure we will at least load a default state and just assume
            /// it will be fixed when we eventually poll for it)
            configsToLoad.append(
                contentsOf: ConfigDump.Variant.userVariants
                    .sorted { $0.loadOrder < $1.loadOrder }
                    .map { variant in
                        (
                            userSessionId,
                            variant,
                            existingDumpsByKey[userSessionId.hexString]?
                                .first(where: { $0.variant == variant })
                        )
                    }
            )
            
            /// Then load in dumps for groups
            ///
            /// Similar to the above it's possible to have a partial group state due to edge-cases where a config could be lost, but also
            /// immediately after creating a group (eg. when a crash happens at the right time), for these cases we again assume they
            /// will be solved eventually via polling so still want to load their states into memory (if we don't then we likely wouldn't be
            /// able to decrypt the poll response and the group would never recover)
            ///
            /// **Note:** We exclude groups in the `invited` state as they should only have their state loaded once the invitation
            /// gets accepted
            let allGroups: [ClosedGroup] = (try? ClosedGroup
                .filter(
                    ClosedGroup.Columns.threadId > SessionId.Prefix.group.rawValue &&
                    ClosedGroup.Columns.threadId < SessionId.Prefix.group.endOfRangeString
                )
                .filter(ClosedGroup.Columns.invited == false)
                .fetchAll(db))
                .defaulting(to: [])
            let groupsByKey: [String: ClosedGroup] = allGroups
                .reduce(into: [:]) { result, group in result[group.threadId] = group }
            allGroups.forEach { group in
                configsToLoad.append(
                    contentsOf: ConfigDump.Variant.groupVariants
                        .sorted { $0.loadOrder < $1.loadOrder }
                        .map { variant in
                            (
                                SessionId(.group, hex: group.threadId),
                                variant,
                                existingDumpsByKey[group.threadId]?
                                    .first(where: { $0.variant == variant })
                            )
                        }
                )
            }
                                            
            /// Now that we have fully populated and sorted `configsToLoad` we should load each into memory
            configsToLoad.forEach { sessionId, variant, dump in
                configStore[sessionId, variant] = try? loadState(
                    for: variant,
                    sessionId: sessionId,
                    userEd25519SecretKey: dependencies[cache: .general].ed25519SecretKey,
                    groupEd25519SecretKey: groupsByKey[sessionId.hexString]?
                        .groupIdentityPrivateKey
                        .map { Array($0) },
                    cachedData: dump?.data
                )
            }
            
            /// There is a bit of an odd discrepancy between `libSession` and the database for the users profile where `libSession`
            /// could have updated display picture information but the database could have old data - this is because we don't update
            /// the values in the database until after the display picture is downloaded
            ///
            /// Due to this we should schedule a `DispalyPictureDownloadJob` for the current users display picture if it happens
            /// to be different from the database value (or the file doesn't exist) to ensure it gets downloaded
            let libSessionProfile: Profile = profile
            let databaseProfile: Profile = Profile.fetchOrCreate(db, id: libSessionProfile.id)
            
            if
                let url: String = libSessionProfile.displayPictureUrl,
                let key: Data = libSessionProfile.displayPictureEncryptionKey,
                !key.isEmpty,
                (
                    databaseProfile.displayPictureUrl != url ||
                    databaseProfile.displayPictureEncryptionKey != key
                ),
                let path: String = try? dependencies[singleton: .displayPictureManager]
                    .path(for: libSessionProfile.displayPictureUrl),
                !dependencies[singleton: .fileManager].fileExists(atPath: path)
            {
                Log.info(.libSession, "Scheduling display picture download due to discrepancy with database")
                dependencies[singleton: .jobRunner].add(
                    db,
                    job: Job(
                        variant: .displayPictureDownload,
                        details: DisplayPictureDownloadJob.Details(
                            target: .profile(id: libSessionProfile.id, url: url, encryptionKey: key),
                            timestamp: libSessionProfile.profileLastUpdated
                        )
                    )
                )
            }
            
            Log.info(.libSession, "Completed loadState\(requestId.map { " for \($0)" } ?? "")")
        }
        
        public func loadDefaultStateFor(
            variant: ConfigDump.Variant,
            sessionId: SessionId,
            userEd25519SecretKey: [UInt8],
            groupEd25519SecretKey: [UInt8]?
        ) {
            configStore[sessionId, variant] = try? loadState(
                for: variant,
                sessionId: sessionId,
                userEd25519SecretKey: userEd25519SecretKey,
                groupEd25519SecretKey: groupEd25519SecretKey,
                cachedData: nil
            )
        }
        
        @discardableResult public func loadState(
            for variant: ConfigDump.Variant,
            sessionId: SessionId,
            userEd25519SecretKey: [UInt8],
            groupEd25519SecretKey: [UInt8]?,
            cachedData: Data?
        ) throws -> LibSession.Config {
            guard userEd25519SecretKey.count >= 32 else { throw CryptoError.missingUserSecretKey }
            
            var conf: UnsafeMutablePointer<config_object>? = nil
            var keysConf: UnsafeMutablePointer<config_group_keys>? = nil
            var secretKey: [UInt8] = userEd25519SecretKey
            var error: [CChar] = [CChar](repeating: 0, count: 256)
            let userConfigInitCalls: [ConfigDump.Variant: UserConfigInitialiser] = [
                .userProfile: user_profile_init,
                .contacts: contacts_init,
                .convoInfoVolatile: convo_info_volatile_init,
                .userGroups: user_groups_init,
                .local: local_init
            ]
            let groupConfigInitCalls: [ConfigDump.Variant: GroupConfigInitialiser] = [
                .groupInfo: groups_info_init,
                .groupMembers: groups_members_init
            ]
            
            return try (cachedData.map { Array($0) } ?? []).withUnsafeBufferPointer { dumpPtr in
                switch (variant, groupEd25519SecretKey) {
                    case (.invalid, _):
                        throw LibSessionError.unableToCreateConfigObject(sessionId.hexString)
                            .logging("Unable to create \(variant.rawValue) config object for: \(sessionId.hexString)")
                        
                    case (.userProfile, _), (.contacts, _), (.convoInfoVolatile, _), (.userGroups, _), (.local, _):
                        return try (userConfigInitCalls[variant]?(
                            &conf,
                            &secretKey,
                            dumpPtr.baseAddress,
                            dumpPtr.count,
                            &error
                        ))
                        .toConfig(conf, variant: variant, error: error, sessionId: sessionId)
                        
                    case (.groupInfo, .some(var adminSecretKey)), (.groupMembers, .some(var adminSecretKey)):
                        var identityPublicKey: [UInt8] = sessionId.publicKey
                        
                        return try (groupConfigInitCalls[variant]?(
                            &conf,
                            &identityPublicKey,
                            &adminSecretKey,
                            dumpPtr.baseAddress,
                            dumpPtr.count,
                            &error
                        ))
                        .toConfig(conf, variant: variant, error: error, sessionId: sessionId)
                        
                    case (.groupKeys, .some(var adminSecretKey)):
                        var identityPublicKey: [UInt8] = sessionId.publicKey
                        
                        guard
                            case .groupInfo(let infoConf) = configStore[sessionId, .groupInfo],
                            case .groupMembers(let membersConf) = configStore[sessionId, .groupMembers]
                        else {
                            throw LibSessionError.unableToCreateConfigObject(sessionId.hexString)
                                .logging("Unable to create \(variant.rawValue) config object for \(sessionId), group info \(configStore[sessionId, .groupInfo] != nil ? "loaded" : "not loaded") and member config \(configStore[sessionId, .groupMembers] != nil ? "loaded" : "not loaded")")
                        }
                        
                        return try groups_keys_init(
                            &keysConf,
                            &secretKey,
                            &identityPublicKey,
                            &adminSecretKey,
                            infoConf,
                            membersConf,
                            dumpPtr.baseAddress,
                            dumpPtr.count,
                            &error
                        )
                        .toConfig(keysConf, info: infoConf, members: membersConf, variant: variant, error: error, sessionId: sessionId)
                        
                    /// It looks like C doesn't deal will passing pointers to null variables well so we need to explicitly pass `nil`
                    /// for the admin key in this case
                    case (.groupInfo, .none), (.groupMembers, .none):
                        var identityPublicKey: [UInt8] = sessionId.publicKey
                        
                        return try (groupConfigInitCalls[variant]?(
                            &conf,
                            &identityPublicKey,
                            nil,
                            dumpPtr.baseAddress,
                            dumpPtr.count,
                            &error
                        ))
                        .toConfig(conf, variant: variant, error: error, sessionId: sessionId)
                        
                    /// It looks like C doesn't deal will passing pointers to null variables well so we need to explicitly pass `nil`
                    /// for the admin key in this case
                    case (.groupKeys, .none):
                        var identityPublicKey: [UInt8] = sessionId.publicKey
                        
                        guard
                            case .groupInfo(let infoConf) = configStore[sessionId, .groupInfo],
                            case .groupMembers(let membersConf) = configStore[sessionId, .groupMembers]
                        else {
                            throw LibSessionError.unableToCreateConfigObject(sessionId.hexString)
                                .logging("Unable to create \(variant.rawValue) config object for \(sessionId), group info \(configStore[sessionId, .groupInfo] != nil ? "loaded" : "not loaded") and member config \(configStore[sessionId, .groupMembers] != nil ? "loaded" : "not loaded")")
                        }
                        
                        return try groups_keys_init(
                            &keysConf,
                            &secretKey,
                            &identityPublicKey,
                            nil,
                            infoConf,
                            membersConf,
                            dumpPtr.baseAddress,
                            dumpPtr.count,
                            &error
                        )
                        .toConfig(keysConf, info: infoConf, members: membersConf, variant: variant, error: error, sessionId: sessionId)
                }
            }
        }
        
        public func hasConfig(for variant: ConfigDump.Variant, sessionId: SessionId) -> Bool {
            return (configStore[sessionId, variant] != nil)
        }
        
        public func config(for variant: ConfigDump.Variant, sessionId: SessionId) -> Config? {
            return configStore[sessionId, variant]
        }
        
        public func setConfig(for variant: ConfigDump.Variant, sessionId: SessionId, to config: Config) {
            configStore[sessionId, variant] = config
        }
        
        public func removeConfigs(for sessionId: SessionId) {
            // First retrieve the configs stored for the sessionId
            let configs: [LibSession.Config] = configStore[sessionId]
            let keysConfig: LibSession.Config? = configs.first { config in
                switch config {
                    case .groupKeys: return true
                    default: return false
                }
            }
            
            // Then remove them from the ConfigStore (can't have something else accessing them)
            ConfigDump.Variant.allCases.forEach { configStore[sessionId, $0] = nil }
            
            // Finally we need to free them (if we got a `groupKeys` config then that includes
            // the other confs for that sessionId so we can free them all at once, otherwise loop
            // and freee everything
            switch keysConfig {
                case .groupKeys(let keysConf, let infoConf, let membersConf):
                    groups_keys_free(keysConf)
                    config_free(infoConf)
                    config_free(membersConf)
                
                default:
                    configs.forEach { config in
                        switch config {
                            case .groupKeys: break    // Should be handled above
                            case .userProfile(let conf), .contacts(let conf), .convoInfoVolatile(let conf),
                                .userGroups(let conf), .local(let conf), .groupInfo(let conf),
                                .groupMembers(let conf):
                                config_free(conf)
                        }
                    }
            }
        }
        
        public func createDump(
            config: Config?,
            for variant: ConfigDump.Variant,
            sessionId: SessionId,
            timestampMs: Int64
        ) throws -> ConfigDump? {
            // If it doesn't need a dump then do nothing
            guard
                configNeedsDump(config),
                let dumpData: Data = try config?.dump()
            else { return nil }
            
            return ConfigDump(
                variant: variant,
                sessionId: sessionId.hexString,
                data: dumpData,
                timestampMs: timestampMs
            )
        }
        
        // stringlint:ignore_contents
        public func stateDescriptionForLogs() -> String {
            var info: [String] = []
            
            /// Count the contacts
            switch configStore[userSessionId, .contacts]?.count {
                case .some(..<20): info.append("Contacts: Small")
                case .some(20..<100): info.append("Contacts: Medium")
                case .some(_): info.append("Contacts: Large")
                case .none: info.append("Contacts: Unknown")
            }
            
            /// Count the OneToOne conversations (visible contacts)
            if
                case .contacts(let conf) = configStore[userSessionId, .contacts],
                let contactData: [String: ContactData] = try? extractContacts(from: conf)
            {
                let visibleContacts: [ContactData] = contactData.values
                    .filter { $0.priority >= LibSession.visiblePriority }
                
                switch visibleContacts.count {
                    case ..<20: info.append("OneToOne: Small")
                    case 20..<100: info.append("OneToOne: Medium")
                    case _: info.append("OneToOne: Large")
                }
            }
            else {
                info.append("OneToOne: Unknown")
            }
            
            /// Count the Group & Community conversations
            if
                case .userGroups(let conf) = configStore[userSessionId, .userGroups],
                let groupInfo: LibSession.ExtractedUserGroups = try? LibSession.extractUserGroups(from: conf, using: dependencies)
            {
                let visibleGroups: [LibSession.GroupInfo] = groupInfo.groups
                    .filter { $0.priority >= LibSession.visiblePriority }
                let visibleCommunities: [LibSession.CommunityInfo] = groupInfo.communities
                    .filter { $0.priority >= LibSession.visiblePriority }
                
                switch visibleGroups.count {
                    case ..<5: info.append("Groups: Small")
                    case 5..<20: info.append("Groups: Medium")
                    case _: info.append("Groups: Large")
                }
                
                switch visibleCommunities.count {
                    case ..<5: info.append("Communities: Small")
                    case 5..<20: info.append("Communities: Medium")
                    case _: info.append("Communities: Large")
                }
            }
            else {
                info.append("Groups: Unknown")
                info.append("Communities: Unknown")
            }
            
            return info.joined(separator: "\n")
        }
        
        // MARK: - Pushes
        
        public func syncAllPendingPushesAsync() {
            Task.detached(priority: .medium) { [allIds = configStore.allIds, dependencies] in
                for sessionId in allIds {
                    await ConfigurationSyncJob.enqueue(
                        swarmPublicKey: sessionId.hexString,
                        using: dependencies
                    )
                }
            }
        }
        
        public func withCustomBehaviour(
            _ behaviour: CacheBehaviour,
            for sessionId: SessionId,
            variant: ConfigDump.Variant?,
            change: @escaping () throws -> ()
        ) throws {
            behaviourStore.add(behaviour, sessionId: sessionId, variant: variant)
            try change()
            behaviourStore.remove(behaviour, sessionId: sessionId, variant: variant)
        }
        
        public func performAndPushChange(
            _ db: ObservingDatabase,
            for variant: ConfigDump.Variant,
            sessionId: SessionId,
            change: (Config?) throws -> ()
        ) throws {
            // To prevent crashes by trying to make an invalid change due to incorrect state being
            // provided by a client, if we want to change one of the group configs then check if we
            // are a group admin first
            switch variant {
                case .groupInfo, .groupMembers, .groupKeys:
                    guard
                        behaviourStore.hasBehaviour(.skipGroupAdminCheck, for: sessionId, variant) ||
                        isAdmin(groupSessionId: sessionId)
                    else { throw LibSessionError.attemptedToModifyGroupWithoutAdminKey.logging(as: .critical) }

                    
                default: break
            }
            
            do {
                guard let config: Config = configStore[sessionId, variant] else {
                    throw LibSessionError.invalidConfigObject(wanted: variant, got: nil)
                }
                
                // Peform the change
                try change(config)
                
                // Store the pending changes locally and clear them from the instance
                let pendingEvents: [ObservedEvent] = self.pendingEvents
                self.pendingEvents = []
                
                // If an error occurred during the change then actually throw it to prevent
                // any database change from completing
                try LibSessionError.throwIfNeeded(config)
                
                // Create a mutation for the change and upsert it if needed
                try Mutation(
                    config: config,
                    sessionId: sessionId,
                    skipAutomaticConfigSync: behaviourStore
                        .hasBehaviour(.skipAutomaticConfigSync, for: sessionId, variant),
                    pendingEvents: pendingEvents,
                    cache: self,
                    using: dependencies
                ).upsert(db)
            }
            catch {
                Log.error(.libSession, "Failed to update/dump updated \(variant) config data due to error: \(error)")
                self.pendingEvents = []
                throw error
            }
        }
        
        public func perform(
            for variant: ConfigDump.Variant,
            sessionId: SessionId,
            change: (Config?) throws -> ()
        ) throws -> LibSession.Mutation {
            // To prevent crashes by trying to make an invalid change due to incorrect state being
            // provided by a client, if we want to change one of the group configs then check if we
            // are a group admin first
            switch variant {
                case .groupInfo, .groupMembers, .groupKeys:
                    guard
                        behaviourStore.hasBehaviour(.skipGroupAdminCheck, for: sessionId, variant) ||
                            isAdmin(groupSessionId: sessionId)
                    else { throw LibSessionError.attemptedToModifyGroupWithoutAdminKey.logging(as: .critical) }
                    
                    
                default: break
            }
            
            do {
                guard let config: Config = configStore[sessionId, variant] else {
                    throw LibSessionError.invalidConfigObject(wanted: variant, got: nil)
                }
                
                // Peform the change
                try change(config)
                
                // Store the pending changes locally and clear them from the instance
                let pendingEvents: [ObservedEvent] = self.pendingEvents
                self.pendingEvents = []
                
                // If an error occurred during the change then actually throw it to prevent
                // any database change from completing
                try LibSessionError.throwIfNeeded(config)
                
                // Create a mutation for the change
                return try Mutation(
                    config: config,
                    sessionId: sessionId,
                    skipAutomaticConfigSync: behaviourStore
                        .hasBehaviour(.skipAutomaticConfigSync, for: sessionId, variant),
                    pendingEvents: pendingEvents,
                    cache: self,
                    using: dependencies
                )
            }
            catch {
                Log.error(.libSession, "Failed to update/dump updated \(variant) config data due to error: \(error)")
                self.pendingEvents = []
                throw error
            }
        }
        
        public func pendingPushes(swarmPublicKey: String) throws -> PendingPushes {
            guard dependencies[cache: .general].userExists else { throw LibSessionError.userDoesNotExist }
            
            // Get a list of the different config variants for the provided publicKey
            let targetSessionId: SessionId = try SessionId(from: swarmPublicKey)
            let targetVariants: [(sessionId: SessionId, variant: ConfigDump.Variant)] = {
                switch (swarmPublicKey, targetSessionId) {
                    case (userSessionId.hexString, _):
                        return ConfigDump.Variant.userVariants.map { (userSessionId, $0) }
                        
                    case (_, let sessionId) where sessionId.prefix == .group:
                        // Only admins can push changes or delete obsolete configs so do
                        // nothing if the current user isn't an admin
                        guard isAdmin(groupSessionId: targetSessionId) else { return [] }
                        
                        return ConfigDump.Variant.groupVariants.map { (sessionId, $0) }
                        
                    default: return []
                }
            }()
            
            // Extract any pending changes from the cached config entry for each variant
            return try targetVariants
                .sorted { (lhs: (SessionId, ConfigDump.Variant), rhs: (SessionId, ConfigDump.Variant)) in
                    lhs.1.sendOrder < rhs.1.sendOrder
                }
                .reduce(into: PendingPushes()) { result, info in
                    guard let config: Config = configStore[info.sessionId, info.variant] else { return }
                    
                    /// Only generate the push data if we need to do a push
                    guard config.needsPush else { return }
                    
                    /// Try to generate the push data (will throw if there is an error)
                    try result.append(config.push(variant: info.variant))
                }
        }
        
        public func createDumpMarkingAsPushed(
            data: [(pushData: PendingPushes.PushData, hash: String?)],
            sentTimestamp: Int64,
            swarmPublicKey: String
        ) throws -> [ConfigDump] {
            let sessionId: SessionId = try SessionId(from: swarmPublicKey)
            
            return try data
                .grouped(by: \.pushData.variant)
                .compactMap { variant, data -> ConfigDump? in
                    // Make sure we don't somehow have a different `seqNo` in one of the values, and
                    // that all of the values were successfully pushed
                    guard let seqNo: Int64 = data.first?.pushData.seqNo else { return nil }
                    guard !data.contains(where: { $0.pushData.seqNo != seqNo }) else {
                        throw LibSessionError.foundMultipleSequenceNumbersWhenPushing
                    }
                    
                    let hashes: [String] = data.compactMap({ _, hash in hash })
                    guard hashes.count == data.count else {
                        throw LibSessionError.partialMultiConfigPushFailure
                    }
                    guard let config: Config = configStore[sessionId, variant] else { return nil }
                    
                    // Mark the config as pushed
                    try config.confirmPushed(seqNo: seqNo, hashes: hashes)
                    
                    // Update the result to indicate whether the config needs to be dumped
                    guard configNeedsDump(config) else { return nil }
                    
                    return try? createDump(
                        config: config,
                        for: variant,
                        sessionId: sessionId,
                        timestampMs: sentTimestamp
                    )
                }
        }
        
        public func addEvent(_ event: ObservedEvent) {
            pendingEvents.append(event)
        }
        
        // MARK: - Config Message Handling
        
        public func configNeedsDump(_ config: LibSession.Config?) -> Bool {
            switch config {
                case .none: return false
                case .userProfile(let conf), .contacts(let conf), .convoInfoVolatile(let conf),
                    .userGroups(let conf), .local(let conf), .groupInfo(let conf), .groupMembers(let conf):
                    return config_needs_dump(conf)
                case .groupKeys(let conf, _, _): return groups_keys_needs_dump(conf)
            }
        }
        
        public func activeHashes(for swarmPublicKey: String) -> [String] {
            guard let sessionId: SessionId = try? SessionId(from: swarmPublicKey) else { return [] }
            
            /// We `mutate` because `libSession` isn't thread safe and we don't want to worry about another thread messing
            /// with the hashes while we retrieve them
            return configStore[sessionId]
                .compactMap { config in config.activeHashes() }
                .reduce([], +)
        }
        
        public func currentConfigState(
            swarmPublicKey: String,
            variants: Set<ConfigDump.Variant>
        ) throws -> [ConfigDump.Variant: [ObservableKey: Any]] {
            guard !variants.isEmpty else { return [:] }
            guard !swarmPublicKey.isEmpty else { throw MessageError.invalidConfigMessageHandling }
            
            return try variants.reduce(into: [:]) { result, variant in
                let sessionId: SessionId = SessionId(hex: swarmPublicKey, dumpVariant: variant)
                
                switch configStore[sessionId, variant] {
                    case .userProfile:
                        result[variant] = [
                            .profile(userSessionId.hexString): profile,
                            .setting(.checkForCommunityMessageRequests): get(.checkForCommunityMessageRequests),
                            .proAccessExpiryUpdated: proAccessExpiryTimestampMs
                        ]
                        
                    case .contacts(let conf):
                        result[variant] = try extractContacts(from: conf).reduce(into: [:]) { result, next in
                            result[.contact(next.key)] = next.value.contact
                            result[.profile(next.key)] = next.value.profile
                        }
                        
                    case .userGroups(let conf):
                        let extractedUserGroups: ExtractedUserGroups = try extractUserGroups(from: conf, using: dependencies)
                        var userGroupEvents: [ObservableKey: Any] = [:]
                        
                        extractedUserGroups.groups.forEach { info in
                            userGroupEvents[.groupInfo(groupId: info.groupSessionId)] = info
                        }
                        
                        result[variant] = userGroupEvents
                        
                    default: break
                }
            }
        }
        
        public func mergeConfigMessages(
            swarmPublicKey: String,
            messages: [ConfigMessageReceiveJob.Details.MessageInfo]
        ) throws -> [ConfigDump.Variant: Int64] {
            guard !messages.isEmpty else { return [:] }
            guard !swarmPublicKey.isEmpty else { throw MessageError.invalidConfigMessageHandling }
            
            return try messages
                .grouped(by: { ConfigDump.Variant(namespace: $0.namespace) })
                .sorted { lhs, rhs in lhs.key.namespace.processingOrder < rhs.key.namespace.processingOrder }
                .reduce(into: [:]) { result, next in
                    let (variant, messages): (ConfigDump.Variant, [ConfigMessageReceiveJob.Details.MessageInfo]) = next
                    let sessionId: SessionId = SessionId(hex: swarmPublicKey, dumpVariant: variant)
                    let config: Config? = configStore[sessionId, variant]
                    
                    do {
                        // Merge the messages (if it doesn't merge anything then don't bother trying
                        // to handle the result)
                        Log.info(.libSession, "Attempting to merge \(variant) config messages")
                        guard let latestServerTimestampMs: Int64 = try config?.merge(messages) else {
                            return
                        }
                        
                        result[variant] = latestServerTimestampMs
                    }
                    catch {
                        Log.error(.libSession, "Failed to process merge of \(variant) config data")
                        throw error
                    }
                }
        }
        
        public func handleConfigMessages(
            _ db: ObservingDatabase,
            swarmPublicKey: String,
            messages: [ConfigMessageReceiveJob.Details.MessageInfo]
        ) throws {
            let oldStateMap: [ConfigDump.Variant: [ObservableKey: Any]] = try currentConfigState(
                swarmPublicKey: swarmPublicKey,
                variants: Set(messages.map { ConfigDump.Variant(namespace: $0.namespace) })
            )
            let latestServerTimestampsMs: [ConfigDump.Variant: Int64] = try mergeConfigMessages(
                swarmPublicKey: swarmPublicKey,
                messages: messages
            )
            let results: [MergeResult] = try latestServerTimestampsMs
                .sorted { lhs, rhs in lhs.key.namespace.processingOrder < rhs.key.namespace.processingOrder }
                .compactMap { variant, latestServerTimestampMs in
                    let sessionId: SessionId = SessionId(hex: swarmPublicKey, dumpVariant: variant)
                    let config: Config? = configStore[sessionId, variant]
                    let oldState: [ObservableKey: Any] = (oldStateMap[variant] ?? [:])
                    
                    // Apply the updated states to the database
                    switch variant {
                        case .userProfile:
                            try handleUserProfileUpdate(
                                db,
                                in: config,
                                oldState: oldState
                            )
                            
                        case .contacts:
                            try handleContactsUpdate(
                                db,
                                in: config,
                                oldState: oldState
                            )
                            
                        case .convoInfoVolatile:
                            try handleConvoInfoVolatileUpdate(
                                db,
                                in: config
                            )
                            
                        case .userGroups:
                            try handleUserGroupsUpdate(
                                db,
                                in: config,
                                oldState: oldState
                            )
                            
                        case .groupInfo:
                            try handleGroupInfoUpdate(
                                db,
                                in: config,
                                groupSessionId: sessionId
                            )
                            
                        case .groupMembers:
                            try handleGroupMembersUpdate(
                                db,
                                in: config,
                                groupSessionId: sessionId,
                                serverTimestampMs: latestServerTimestampMs
                            )
                            
                        case .groupKeys:
                            try handleGroupKeysUpdate(
                                db,
                                in: config,
                                groupSessionId: sessionId
                            )
                            
                        case .local: Log.error(.libSession, "Tried to process merge of local config")
                        case .invalid: Log.error(.libSession, "Failed to process merge of invalid config namespace")
                    }
                    
                    // Need to check if the config needs to be dumped (this might have changed
                    // after handling the merge changes)
                    guard configNeedsDump(config) else {
                        try ConfigDump
                            .filter(
                                ConfigDump.Columns.variant == variant &&
                                ConfigDump.Columns.publicKey == sessionId.hexString
                            )
                            .updateAll(
                                db,
                                ConfigDump.Columns.timestampMs.set(to: latestServerTimestampMs)
                            )
                        return nil
                    }
                    
                    let dump: ConfigDump? = try createDump(
                        config: config,
                        for: variant,
                        sessionId: sessionId,
                        timestampMs: latestServerTimestampMs
                    )
                    try dump?.upsert(db)
                    
                    return (sessionId, variant, dump)
                }
            
            let needsPush: Bool = (try? SessionId(from: swarmPublicKey)).map {
                configStore[$0].contains(where: { $0.needsPush }) &&
                !behaviourStore.hasBehaviour(.skipAutomaticConfigSync, for: $0)
            }.defaulting(to: false)
            
            /// If we don't need to push and there were no merge results then no need to do anything else
            guard
                needsPush ||
                results.contains(where: { $0.dump != nil })
            else { return }
            
            db.afterCommit { [dependencies] in
                if needsPush {
                    Task.detached(priority: .medium) { [dependencies] in
                        await ConfigurationSyncJob.enqueue(
                            swarmPublicKey: swarmPublicKey,
                            using: dependencies
                        )
                    }
                }
                
                Task.detached(priority: .medium) { [dependencies] in
                    /// Replicate any dumps
                    for result in results {
                        switch result.dump {
                            case .some(let dump):
                                dependencies[singleton: .extensionHelper].replicate(dump: dump)
                            
                            case .none:
                                dependencies[singleton: .extensionHelper].refreshDumpModifiedDate(
                                    sessionId: result.sessionId,
                                    variant: result.variant
                                )
                        }
                    }
                }
            }
        }
    }
}

// MARK: - SessionUtilCacheType

/// This is a read-only version of the Cache designed to avoid unintentionally mutating the instance in a non-thread-safe way
public protocol LibSessionImmutableCacheType: ImmutableCacheType {
    var userSessionId: SessionId { get }
    var isEmpty: Bool { get }
    var allDumpSessionIds: Set<SessionId> { get }
    
    func hasConfig(for variant: ConfigDump.Variant, sessionId: SessionId) -> Bool
}

/// The majority `libSession` functions can only be accessed via the mutable cache because `libSession` isn't thread safe so if we try
/// to read/write values while another thread is touching the same data then the app can crash due to bad memory issues
public protocol LibSessionCacheType: LibSessionImmutableCacheType, MutableCacheType {
    var dependencies: Dependencies { get }
    var userSessionId: SessionId { get }
    var isEmpty: Bool { get }
    var allDumpSessionIds: Set<SessionId> { get }
    
    // MARK: - State Management
    
    func loadState(_ db: ObservingDatabase, requestId: String?)
    func loadDefaultStateFor(
        variant: ConfigDump.Variant,
        sessionId: SessionId,
        userEd25519SecretKey: [UInt8],
        groupEd25519SecretKey: [UInt8]?
    )
    @discardableResult func loadState(
        for variant: ConfigDump.Variant,
        sessionId: SessionId,
        userEd25519SecretKey: [UInt8],
        groupEd25519SecretKey: [UInt8]?,
        cachedData: Data?
    ) throws -> LibSession.Config
    func hasConfig(for variant: ConfigDump.Variant, sessionId: SessionId) -> Bool
    func config(for variant: ConfigDump.Variant, sessionId: SessionId) -> LibSession.Config?
    func setConfig(for variant: ConfigDump.Variant, sessionId: SessionId, to config: LibSession.Config)
    func removeConfigs(for sessionId: SessionId)
    func createDump(
        config: LibSession.Config?,
        for variant: ConfigDump.Variant,
        sessionId: SessionId,
        timestampMs: Int64
    ) throws -> ConfigDump?
    
    func stateDescriptionForLogs() -> String
    
    // MARK: - Pushes
    
    func syncAllPendingPushesAsync()
    func withCustomBehaviour(
        _ behaviour: LibSession.CacheBehaviour,
        for sessionId: SessionId,
        variant: ConfigDump.Variant?,
        change: @escaping () throws -> ()
    ) throws
    func performAndPushChange(
        _ db: ObservingDatabase,
        for variant: ConfigDump.Variant,
        sessionId: SessionId,
        change: @escaping (LibSession.Config?) throws -> ()
    ) throws
    func perform(
        for variant: ConfigDump.Variant,
        sessionId: SessionId,
        change: @escaping (LibSession.Config?) throws -> ()
    ) throws -> LibSession.Mutation
    func pendingPushes(swarmPublicKey: String) throws -> LibSession.PendingPushes
    func createDumpMarkingAsPushed(
        data: [(pushData: LibSession.PendingPushes.PushData, hash: String?)],
        sentTimestamp: Int64,
        swarmPublicKey: String
    ) throws -> [ConfigDump]
    func addEvent(_ event: ObservedEvent)
    
    // MARK: - Config Message Handling
    
    func configNeedsDump(_ config: LibSession.Config?) -> Bool
    func activeHashes(for swarmPublicKey: String) -> [String]
    
    func mergeConfigMessages(
        swarmPublicKey: String,
        messages: [ConfigMessageReceiveJob.Details.MessageInfo]
    ) throws -> [ConfigDump.Variant: Int64]
    func handleConfigMessages(
        _ db: ObservingDatabase,
        swarmPublicKey: String,
        messages: [ConfigMessageReceiveJob.Details.MessageInfo]
    ) throws
    
    // MARK: - SettingFetcher
    
    func has(_ key: Setting.EnumKey) -> Bool
    func get(_ key: Setting.BoolKey) -> Bool
    func get<T: LibSessionConvertibleEnum>(_ key: Setting.EnumKey) -> T?
    
    // MARK: - State Access
    
    func set(_ key: Setting.BoolKey, _ value: Bool?)
    func set<T: LibSessionConvertibleEnum>(_ key: Setting.EnumKey, _ value: T?)
    
    var displayName: String? { get }
    var proConfig: SessionPro.ProConfig? { get }
    var proAccessExpiryTimestampMs: UInt64 { get }
    
    /// This function should not be called outside of the `Profile.updateIfNeeded` function to avoid duplicating changes and events,
    /// as a result this function doesn't emit profile change events itself (use `Profile.updateLocal` instead)
    func updateProfile(
        displayName: Update<String>,
        displayPictureUrl: Update<String?>,
        displayPictureEncryptionKey: Update<Data?>,
        proProfileFeatures: Update<SessionPro.ProfileFeatures>,
        isReuploadProfilePicture: Bool
    ) throws
    func updateProConfig(proConfig: SessionPro.ProConfig)
    func removeProConfig()
    func updateProAccessExpiryTimestampMs(_ proAccessExpiryTimestampMs: UInt64)
    
    func canPerformChange(
        threadId: String,
        threadVariant: SessionThread.Variant,
        changeTimestampMs: Int64
    ) -> Bool
    func conversationInConfig(
        threadId: String,
        threadVariant: SessionThread.Variant,
        visibleOnly: Bool,
        openGroupUrlInfo: LibSession.OpenGroupUrlInfo?
    ) -> Bool
    func conversationDisplayName(
        threadId: String,
        threadVariant: SessionThread.Variant,
        contactProfile: Profile?,
        visibleMessage: VisibleMessage?,
        openGroupName: String?,
        openGroupUrlInfo: LibSession.OpenGroupUrlInfo?
    ) -> String
    func conversationLastRead(
        threadId: String,
        threadVariant: SessionThread.Variant,
        openGroupUrlInfo: LibSession.OpenGroupUrlInfo?
    ) -> Int64?
    func proProofMetadata(threadId: String) -> LibSession.ProProofMetadata?
    
    /// Returns whether the specified conversation is a message request
    ///
    /// **Note:** Defaults to `true` on failure
    func isMessageRequest(
        threadId: String,
        threadVariant: SessionThread.Variant
    ) -> Bool
    func pinnedPriority(
        threadId: String,
        threadVariant: SessionThread.Variant,
        openGroupUrlInfo: LibSession.OpenGroupUrlInfo?
    ) -> Int32
    func disappearingMessagesConfig(
        threadId: String,
        threadVariant: SessionThread.Variant
    ) -> DisappearingMessagesConfiguration?
    
    func isContactBlocked(contactId: String) -> Bool
    func isContactApproved(contactId: String) -> Bool
    func profile(
        contactId: String,
        threadId: String?,
        threadVariant: SessionThread.Variant?,
        visibleMessage: VisibleMessage?
    ) -> Profile?
    func displayPictureUrl(threadId: String, threadVariant: SessionThread.Variant) -> String?
    
    func hasCredentials(groupSessionId: SessionId) -> Bool
    func secretKey(groupSessionId: SessionId) -> [UInt8]?
    func latestGroupKey(groupSessionId: SessionId) throws -> [UInt8]
    func allActiveGroupKeys(groupSessionId: SessionId) throws -> [[UInt8]]
    func isAdmin(groupSessionId: SessionId) -> Bool
    func loadAdminKey(
        groupIdentitySeed: Data,
        groupSessionId: SessionId
    ) throws
    func markAsInvited(groupSessionIds: [String]) throws
    func markAsKicked(groupSessionIds: [String]) throws
    func wasKickedFromGroup(groupSessionId: SessionId) -> Bool
    func groupName(groupSessionId: SessionId) -> String?
    func groupIsDestroyed(groupSessionId: SessionId) -> Bool
    func groupInfo(for groupIds: Set<String>) -> [LibSession.GroupInfo?]
    func groupDeleteBefore(groupSessionId: SessionId) -> TimeInterval?
    func groupDeleteAttachmentsBefore(groupSessionId: SessionId) -> TimeInterval?
    
    func authData(groupSessionId: SessionId) -> GroupAuthData
}

public extension LibSessionCacheType {
    func withCustomBehaviour(_ behaviour: LibSession.CacheBehaviour, for sessionId: SessionId, change: @escaping () throws -> ()) throws {
        try withCustomBehaviour(behaviour, for: sessionId, variant: nil, change: change)
    }
    
    func performAndPushChange(
        _ db: ObservingDatabase,
        for variant: ConfigDump.Variant,
        sessionId: SessionId,
        change: @escaping () throws -> ()
    ) throws {
        try performAndPushChange(db, for: variant, sessionId: sessionId, change: { _ in try change() })
    }
    
    func performAndPushChange(
        _ db: ObservingDatabase,
        for variant: ConfigDump.Variant,
        change: @escaping (LibSession.Config?) throws -> ()
    ) throws {
        guard ConfigDump.Variant.userVariants.contains(variant) else { throw LibSessionError.invalidConfigAccess }
        
        try performAndPushChange(db, for: variant, sessionId: userSessionId, change: change)
    }
    
    func performAndPushChange(
        _ db: ObservingDatabase,
        for variant: ConfigDump.Variant,
        change: @escaping () throws -> ()
    ) throws {
        guard ConfigDump.Variant.userVariants.contains(variant) else { throw LibSessionError.invalidConfigAccess }
        
        try performAndPushChange(db, for: variant, sessionId: userSessionId, change: { _ in try change() })
    }
    
    func perform(
        for variant: ConfigDump.Variant,
        change: @escaping (LibSession.Config?) throws -> ()
    ) throws -> LibSession.Mutation {
        guard ConfigDump.Variant.userVariants.contains(variant) else { throw LibSessionError.invalidConfigAccess }
        
        return try perform(for: variant, sessionId: userSessionId, change: change)
    }
    
    func perform(
        for variant: ConfigDump.Variant,
        change: @escaping () throws -> ()
    ) throws -> LibSession.Mutation {
        guard ConfigDump.Variant.userVariants.contains(variant) else { throw LibSessionError.invalidConfigAccess }
        
        return try perform(for: variant, sessionId: userSessionId, change: { _ in try change() })
    }
    
    func loadState(_ db: ObservingDatabase) {
        loadState(db, requestId: nil)
    }
    
    func addEvent<T: Hashable & Sendable>(key: ObservableKey, value: T?) {
        addEvent(ObservedEvent(key: key, value: value))
    }
    
    func addEvent<T: Hashable & Sendable>(key: Setting.BoolKey, value: T?) {
        addEvent(ObservedEvent(key: .setting(key), value: value))
    }
    
    func addEvent<T: Hashable & Sendable>(key: Setting.EnumKey, value: T?) {
        addEvent(ObservedEvent(key: .setting(key), value: value))
    }
    
    func updateProfile(displayName: String) throws {
        try updateProfile(
            displayName: .set(to: displayName),
            displayPictureUrl: .useExisting,
            displayPictureEncryptionKey: .useExisting,
            proProfileFeatures: .useExisting,
            isReuploadProfilePicture: false
        )
    }
    
    var profile: Profile {
        return profile(contactId: userSessionId.hexString, threadId: nil, threadVariant: nil, visibleMessage: nil)
            .defaulting(to: Profile.defaultFor(userSessionId.hexString))
    }

    func profile(contactId: String) -> Profile? {
        return profile(contactId: contactId, threadId: nil, threadVariant: nil, visibleMessage: nil)
    }
}

private final class NoopLibSessionCache: LibSessionCacheType, NoopDependency {
    let dependencies: Dependencies
    let userSessionId: SessionId = .invalid
    let isEmpty: Bool = true
    let allDumpSessionIds: Set<SessionId> = []
    
    init(using dependencies: Dependencies) {
        self.dependencies = dependencies
    }
    
    // MARK: - State Management
    
    func loadState(_ db: ObservingDatabase, requestId: String?) {}
    func loadDefaultStateFor(
        variant: ConfigDump.Variant,
        sessionId: SessionId,
        userEd25519SecretKey: [UInt8],
        groupEd25519SecretKey: [UInt8]?
    ) {}
    @discardableResult func loadState(
        for variant: ConfigDump.Variant,
        sessionId: SessionId,
        userEd25519SecretKey: [UInt8],
        groupEd25519SecretKey: [UInt8]?,
        cachedData: Data?
    ) throws -> LibSession.Config { throw LibSessionError.invalidConfigObject(wanted: .invalid, got: nil) }
    func loadAdminKey(
        groupIdentitySeed: Data,
        groupSessionId: SessionId
    ) throws {}
    func hasConfig(for variant: ConfigDump.Variant, sessionId: SessionId) -> Bool { return false }
    func config(for variant: ConfigDump.Variant, sessionId: SessionId) -> LibSession.Config? { return nil }
    func setConfig(for variant: ConfigDump.Variant, sessionId: SessionId, to config: LibSession.Config) {}
    func removeConfigs(for sessionId: SessionId) {}
    func createDump(
        config: LibSession.Config?,
        for variant: ConfigDump.Variant,
        sessionId: SessionId,
        timestampMs: Int64
    ) throws -> ConfigDump? {
        return nil
    }
    func stateDescriptionForLogs() -> String { return "" }
    
    // MARK: - Pushes
    
    func syncAllPendingPushesAsync() {}
    func withCustomBehaviour(
        _ behaviour: LibSession.CacheBehaviour,
        for sessionId: SessionId,
        variant: ConfigDump.Variant?,
        change: @escaping () throws -> ()
    ) throws {}
    func performAndPushChange(
        _ db: ObservingDatabase,
        for variant: ConfigDump.Variant,
        sessionId: SessionId,
        change: (LibSession.Config?) throws -> ()
    ) throws {}
    func perform(
        for variant: ConfigDump.Variant,
        sessionId: SessionId,
        change: (LibSession.Config?) throws -> ()
    ) throws -> LibSession.Mutation {
        return try LibSession.Mutation(
            config: nil,
            sessionId: .invalid,
            skipAutomaticConfigSync: false,
            pendingEvents: [],
            cache: self,
            using: dependencies
        )
    }
    
    func pendingPushes(swarmPublicKey: String) throws -> LibSession.PendingPushes {
        return LibSession.PendingPushes()
    }
    
    func createDumpMarkingAsPushed(
        data: [(pushData: LibSession.PendingPushes.PushData, hash: String?)],
        sentTimestamp: Int64,
        swarmPublicKey: String
    ) throws -> [ConfigDump] {
        return []
    }
    func addEvent(_ event: ObservedEvent) {}
    
    // MARK: - Config Message Handling
    
    func configNeedsDump(_ config: LibSession.Config?) -> Bool { return false }
    func activeHashes(for swarmPublicKey: String) -> [String] { return [] }
    func mergeConfigMessages(
        swarmPublicKey: String,
        messages: [ConfigMessageReceiveJob.Details.MessageInfo]
    ) throws -> [ConfigDump.Variant: Int64] { return [:] }
    func handleConfigMessages(
        _ db: ObservingDatabase,
        swarmPublicKey: String,
        messages: [ConfigMessageReceiveJob.Details.MessageInfo]
    ) throws {}
    
    // MARK: - SettingFetcher
    
    func has(_ key: Setting.EnumKey) -> Bool { return false }
    func get(_ key: Setting.BoolKey) -> Bool { return false }
    func get<T: LibSessionConvertibleEnum>(_ key: Setting.EnumKey) -> T? { return nil }
    
    // MARK: - State Access
    
    var displayName: String? { return nil }
    var proConfig: SessionPro.ProConfig? { return nil }
    var proAccessExpiryTimestampMs: UInt64 { return 0 }
    
    func set(_ key: Setting.BoolKey, _ value: Bool?) {}
    func set<T: LibSessionConvertibleEnum>(_ key: Setting.EnumKey, _ value: T?) {}
    func updateProfile(
        displayName: Update<String>,
        displayPictureUrl: Update<String?>,
        displayPictureEncryptionKey: Update<Data?>,
        proProfileFeatures: Update<SessionPro.ProfileFeatures>,
        isReuploadProfilePicture: Bool
    ) throws {}
    func updateProConfig(proConfig: SessionPro.ProConfig) {}
    func removeProConfig() {}
    func updateProAccessExpiryTimestampMs(_ proAccessExpiryTimestampMs: UInt64) {}
    
    func canPerformChange(
        threadId: String,
        threadVariant: SessionThread.Variant,
        changeTimestampMs: Int64
    ) -> Bool { return false }
    func conversationInConfig(
        threadId: String,
        threadVariant: SessionThread.Variant,
        visibleOnly: Bool,
        openGroupUrlInfo: LibSession.OpenGroupUrlInfo?
    ) -> Bool { return false }
    func conversationDisplayName(
        threadId: String,
        threadVariant: SessionThread.Variant,
        contactProfile: Profile?,
        visibleMessage: VisibleMessage?,
        openGroupName: String?,
        openGroupUrlInfo: LibSession.OpenGroupUrlInfo?
    ) -> String { return "" }
    func conversationLastRead(
        threadId: String,
        threadVariant: SessionThread.Variant,
        openGroupUrlInfo: LibSession.OpenGroupUrlInfo?
    ) -> Int64? { return nil }
    func proProofMetadata(threadId: String) -> LibSession.ProProofMetadata? { return nil }
    
    func isMessageRequest(
        threadId: String,
        threadVariant: SessionThread.Variant
    ) -> Bool { return false }
    func pinnedPriority(
        threadId: String,
        threadVariant: SessionThread.Variant,
        openGroupUrlInfo: LibSession.OpenGroupUrlInfo?
    ) -> Int32 { return LibSession.defaultNewThreadPriority }
    func disappearingMessagesConfig(
        threadId: String,
        threadVariant: SessionThread.Variant
    ) -> DisappearingMessagesConfiguration? { return nil }
    
    func isContactBlocked(contactId: String) -> Bool { return false }
    func isContactApproved(contactId: String) -> Bool { return false }
    func profile(
        contactId: String,
        threadId: String?,
        threadVariant: SessionThread.Variant?,
        visibleMessage: VisibleMessage?
    ) -> Profile? { return nil }
    func displayPictureUrl(threadId: String, threadVariant: SessionThread.Variant) -> String? {
        return nil
    }
    
    func hasCredentials(groupSessionId: SessionId) -> Bool { return false }
    func secretKey(groupSessionId: SessionId) -> [UInt8]? { return nil }
    func latestGroupKey(groupSessionId: SessionId) throws -> [UInt8] { throw CryptoError.invalidKey }
    func allActiveGroupKeys(groupSessionId: SessionId) throws -> [[UInt8]] { throw CryptoError.invalidKey }
    func isAdmin(groupSessionId: SessionId) -> Bool { return false }
    func markAsInvited(groupSessionIds: [String]) throws {}
    func markAsKicked(groupSessionIds: [String]) throws {}
    func wasKickedFromGroup(groupSessionId: SessionId) -> Bool { return false }
    func groupName(groupSessionId: SessionId) -> String? { return nil }
    func groupIsDestroyed(groupSessionId: SessionId) -> Bool { return false }
    func groupInfo(for groupIds: Set<String>) -> [LibSession.GroupInfo?] { return [] }
    func groupDeleteBefore(groupSessionId: SessionId) -> TimeInterval? { return nil }
    func groupDeleteAttachmentsBefore(groupSessionId: SessionId) -> TimeInterval? { return nil }
    
    func authData(groupSessionId: SessionId) -> GroupAuthData {
        return GroupAuthData(groupIdentityPrivateKey: nil, authData: nil)
    }
}

// MARK: - Convenience

private extension Optional where Wrapped == Int32 {
    func toConfig(
        _ maybeConf: UnsafeMutablePointer<config_object>?,
        variant: ConfigDump.Variant,
        error: [CChar],
        sessionId: SessionId
    ) throws -> LibSession.Config {
        guard self == 0, let conf: UnsafeMutablePointer<config_object> = maybeConf else {
            throw LibSessionError.unableToCreateConfigObject(sessionId.hexString)
                .logging("Unable to create \(variant.rawValue) config object: \(String(cString: error))")
        }
        
        switch variant {
            case .userProfile: return .userProfile(conf)
            case .contacts: return .contacts(conf)
            case .convoInfoVolatile: return .convoInfoVolatile(conf)
            case .userGroups: return .userGroups(conf)
            case .local: return .local(conf)
            case .groupInfo: return .groupInfo(conf)
            case .groupMembers: return .groupMembers(conf)
            
            case .groupKeys, .invalid: throw LibSessionError.unableToCreateConfigObject(sessionId.hexString)
        }
    }
}

private extension Int32 {
    func toConfig(
        _ maybeConf: UnsafeMutablePointer<config_group_keys>?,
        info: UnsafeMutablePointer<config_object>,
        members: UnsafeMutablePointer<config_object>,
        variant: ConfigDump.Variant,
        error: [CChar],
        sessionId: SessionId
    ) throws -> LibSession.Config {
        guard self == 0, let conf: UnsafeMutablePointer<config_group_keys> = maybeConf else {
            throw LibSessionError.unableToCreateConfigObject(sessionId.hexString)
                .logging("Unable to create \(variant.rawValue) config object: \(String(cString: error))")
        }

        switch variant {
            case .groupKeys: return .groupKeys(conf, info: info, members: members)
            default: throw LibSessionError.unableToCreateConfigObject(sessionId.hexString)
        }
    }
}

public extension SessionId {
    init(hex: String, dumpVariant: ConfigDump.Variant) {
        switch (try? SessionId(from: hex), dumpVariant) {
            case (.some(let sessionId), _): self = sessionId
            case (_, .userProfile), (_, .contacts), (_, .convoInfoVolatile), (_, .userGroups), (_, .local):
                self = SessionId(.standard, hex: hex)
                
            case (_, .groupInfo), (_, .groupMembers), (_, .groupKeys):
                self = SessionId(.group, hex: hex)
                
            case (_, .invalid): self = SessionId.invalid
        }
    }
}

public extension LibSessionError {
    // stringlint:ignore_contents
    static func invalidConfigObject(wanted: ConfigDump.Variant, got other: LibSession.Config?) -> Error {
        return LibSessionError.invalidConfigObject(wanted.rawValue, (other?.variant.rawValue ?? "null"))
    }
}
