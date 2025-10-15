// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtil
import SessionUtilitiesKit

// MARK: - Size Restrictions

public extension LibSession {
    static var sizeAuthDataBytes: Int { 100 }
    static var sizeSubaccountBytes: Int { 36 }
    static var sizeSubaccountSigBytes: Int { 64 }
    static var sizeSubaccountSignatureBytes: Int { 64 }
}

// MARK: - Group Keys Handling

internal extension LibSession {
    /// `libSession` manages keys entirely so there is no need for a DB presence
    static let columnsRelatedToGroupKeys: [ColumnExpression] = []
}

// MARK: - Incoming Changes

internal extension LibSessionCacheType {
    func handleGroupKeysUpdate(
        _ db: ObservingDatabase,
        in config: LibSession.Config?,
        groupSessionId: SessionId
    ) throws {
        guard case .groupKeys(let conf, let infoConf, let membersConf) = config else {
            throw LibSessionError.invalidConfigObject(wanted: .groupKeys, got: config)
        }
        
        /// If the group had been flagged as "expired" (because it got no config messages when initially polling) then receiving a config
        /// message means the group is no longer expired, so update it's state
        let groupFlaggedAsExpired: Bool = (try? ClosedGroup
            .filter(id: groupSessionId.hexString)
            .select(.expired)
            .asRequest(of: Bool.self)
            .fetchOne(db))
            .defaulting(to: false)
        
        if groupFlaggedAsExpired {
            try ClosedGroup
                .filter(id: groupSessionId.hexString)
                .updateAllAndConfig(
                    db,
                    ClosedGroup.Columns.expired.set(to: false),
                    using: dependencies
                )
        }
        
        /// If two admins rekeyed for different member changes at the same time then there is a "key collision" and the "needs rekey" function
        /// will return true to indicate that a 3rd `rekey` needs to be made to have a final set of keys which includes all members
        ///
        /// **Note:** We don't check `needsDump` in this case because the local state _could_ be persisted yet still require a `rekey`
        /// so we should rely solely on `groups_keys_needs_rekey`
        guard groups_keys_needs_rekey(conf) else { return }
        
        // Performing a `rekey` returns the updated key data which we don't use directly, this updated
        // key will now be returned by `groups_keys_pending_config` which the `ConfigurationSyncJob` uses
        // when generating pending changes for group keys so we don't need to push it directly
        var pushResult: UnsafePointer<UInt8>? = nil
        var pushResultLen: Int = 0
        guard groups_keys_rekey(conf, infoConf, membersConf, &pushResult, &pushResultLen) else {
            throw LibSessionError.failedToRekeyGroup
        }
    }
}

// MARK: - Outgoing Changes

public extension LibSession.Cache {
    func loadAdminKey(
        groupIdentitySeed: Data,
        groupSessionId: SessionId
    ) throws {
        guard let config: LibSession.Config = config(for: .groupKeys, sessionId: groupSessionId) else {
            throw LibSessionError.invalidConfigObject(wanted: .groupKeys, got: nil)
        }
        guard case .groupKeys(let conf, let infoConf, let membersConf) = config else {
            throw LibSessionError.invalidConfigObject(wanted: .groupKeys, got: config)
        }
        
        var identitySeed: [UInt8] = Array(groupIdentitySeed)
        groups_keys_load_admin_key(conf, &identitySeed, infoConf, membersConf)
        try LibSessionError.throwIfNeeded(conf)
    }
}

internal extension LibSession {
    static func rekey(
        _ db: ObservingDatabase,
        groupSessionId: SessionId,
        using dependencies: Dependencies
    ) throws {
        try dependencies.mutate(cache: .libSession) { cache in
            try cache.performAndPushChange(db, for: .groupKeys, sessionId: groupSessionId) { config in
                guard case .groupKeys(let conf, let infoConf, let membersConf) = config else {
                    throw LibSessionError.invalidConfigObject(wanted: .groupKeys, got: config)
                }
                
                // Performing a `rekey` returns the updated key data which we don't use directly, this updated
                // key will now be returned by `groups_keys_pending_config` which the `ConfigurationSyncJob` uses
                // when generating pending changes for group keys so we don't need to push it directly
                var pushResult: UnsafePointer<UInt8>? = nil
                var pushResultLen: Int = 0
                guard groups_keys_rekey(conf, infoConf, membersConf, &pushResult, &pushResultLen) else {
                    throw LibSessionError.failedToRekeyGroup
                }
            }
        }
    }
    
    static func keySupplement(
        _ db: ObservingDatabase,
        groupSessionId: SessionId,
        memberIds: Set<String>,
        using dependencies: Dependencies
    ) throws -> Data {
        return try dependencies.mutate(cache: .libSession) { cache in
            guard let config: LibSession.Config = cache.config(for: .groupKeys, sessionId: groupSessionId) else {
                throw LibSessionError.invalidConfigObject(wanted: .groupKeys, got: nil)
            }
            guard case .groupKeys(let conf, _, _) = config else {
                throw LibSessionError.invalidConfigObject(wanted: .groupKeys, got: config)
            }
            
            return try memberIds.withUnsafeCStrArray { cMemberIds in
                /// Performing a `key_supplement` returns the supplemental key changes, since our state doesn't care about the
                /// `GROUP_KEYS` needed for other members this change won't result in the `GROUP_KEYS` config going into a pending
                /// state or the `ConfigurationSyncJob` getting triggered so return the data so that the caller can push it directly
                var cSupplementData: UnsafeMutablePointer<UInt8>!
                var cSupplementDataLen: Int = 0
                
                guard
                    groups_keys_key_supplement(conf, cMemberIds.baseAddress, cMemberIds.count, &cSupplementData, &cSupplementDataLen),
                    let cSupplementData: UnsafeMutablePointer<UInt8> = cSupplementData
                else { throw LibSessionError.failedToKeySupplementGroup }
                
                // Must free on success
                let supplementData: Data = Data(
                    bytes: cSupplementData,
                    count: cSupplementDataLen
                )
                free(UnsafeMutableRawPointer(mutating: cSupplementData))
                
                return supplementData
            }
        }
    }
    
    static func loadAdminKey(
        _ db: ObservingDatabase,
        groupIdentitySeed: Data,
        groupSessionId: SessionId,
        using dependencies: Dependencies
    ) throws {
        try dependencies.mutate(cache: .libSession) { cache in
            /// Disable the admin check because we are about to convert the user to being an admin and it's guaranteed to fail
            try cache.withCustomBehaviour(.skipGroupAdminCheck, for: groupSessionId) {
                try cache.performAndPushChange(db, for: .groupKeys, sessionId: groupSessionId) { _ in
                    try cache.loadAdminKey(groupIdentitySeed: groupIdentitySeed, groupSessionId: groupSessionId)
                }
            }
        }
    }
    
    static func numKeys(
        groupSessionId: SessionId,
        using dependencies: Dependencies
    ) throws -> Int {
        return try dependencies.mutate(cache: .libSession) { cache in
            guard let config: LibSession.Config = cache.config(for: .groupKeys, sessionId: groupSessionId) else {
                throw LibSessionError.invalidConfigObject(wanted: .groupKeys, got: nil)
            }
            guard case .groupKeys(let conf, _, _) = config else {
                throw LibSessionError.invalidConfigObject(wanted: .groupKeys, got: config)
            }
            
            return Int(groups_keys_size(conf))
        }
    }
    
    static func currentGeneration(
        groupSessionId: SessionId,
        using dependencies: Dependencies
    ) throws -> Int {
        return try dependencies.mutate(cache: .libSession) { cache in
            guard let config: LibSession.Config = cache.config(for: .groupKeys, sessionId: groupSessionId) else {
                throw LibSessionError.invalidConfigObject(wanted: .groupKeys, got: nil)
            }
            guard case .groupKeys(let conf, _, _) = config else {
                throw LibSessionError.invalidConfigObject(wanted: .groupKeys, got: config)
            }
            
            return Int(groups_keys_current_generation(conf))
        }
    }
}

// MARK: - State Accses

public extension LibSession.Cache {
    func latestGroupKey(groupSessionId: SessionId) throws -> [UInt8] {
        guard let config: LibSession.Config = config(for: .groupKeys, sessionId: groupSessionId) else {
            throw LibSessionError.invalidConfigObject(wanted: .groupKeys, got: nil)
        }
        guard case .groupKeys(let conf, _, _) = config else {
            throw LibSessionError.invalidConfigObject(wanted: .groupKeys, got: config)
        }
        
        let result: span_u8 = groups_keys_group_enc_key(conf);
        
        guard result.size > 0 else { throw CryptoError.invalidKey }
        
        return Array(UnsafeBufferPointer(start: result.data, count: result.size))
    }
    
    func isAdmin(groupSessionId: SessionId) -> Bool {
        guard case .groupKeys(let conf, _, _) = config(for: .groupKeys, sessionId: groupSessionId) else {
            return false
        }
        
        return groups_keys_is_admin(conf)
    }
}

extension span_u8: @retroactive CAccessible {}
