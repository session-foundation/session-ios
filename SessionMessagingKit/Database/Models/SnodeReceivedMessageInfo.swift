// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import GRDB
import SessionNetworkingKit
import SessionUtilitiesKit

// MARK: - Cache

public extension Cache {
    static let snodeCursorResets: CacheConfig<SnodeCursorResetsCacheType, SnodeCursorResetsImmutableCacheType> = Dependencies.create(
        identifier: "snodeCursorResets",
        createInstance: { _, _ in SnodeReceivedMessageInfo.CursorResets() },
        mutableInstance: { $0 },
        immutableInstance: { $0 }
    )
}

// MARK: - SnodeReceivedMessageInfo

public struct SnodeReceivedMessageInfo: Codable, FetchableRecord, MutablePersistableRecord, TableRecord, ColumnExpressible {
    public static var databaseTableName: String { "snodeReceivedMessageInfo" }
    
    public typealias Columns = CodingKeys
    public enum CodingKeys: String, CodingKey, ColumnExpression {
        case swarmPublicKey
        case snodeAddress
        case namespace
        case hash
        case expirationDateMs
        case wasDeletedOrInvalid
    }
    
    /// The public key for the swarm this message info was retrieved from
    public let swarmPublicKey: String
    
    /// The address for the snode this message info was retrieved from (in the form of `{server}:{port}`)
    public let snodeAddress: String
    
    /// The namespace this message info was retrieved from
    public let namespace: Int
    
    /// The is the hash for the received message
    public let hash: String
    
    /// This is the timestamp (in milliseconds since epoch) when the message hash should expire
    ///
    /// **Note:** If no value exists this will default to 15 days from now (since the service node caches messages for
    /// 14 days for standard messages)
    public let expirationDateMs: Int64
    
    /// This flag indicates whether the message associated with this message hash was deleted or whether this message
    /// hash is potentially invalid (if a poll results in 100% of the `SnodeReceivedMessageInfo` entries being seen as
    /// duplicates then we assume that the `lastHash` value provided when retrieving messages was invalid and mark
    /// it as such)
    ///
    /// This flag can also be used to refetch messages from a swarm without impacting the hash-based deduping mechanism
    /// as if a hash with this value set to `true` is received when pollig then the value gets reset to `false`
    ///
    /// **Note:** When retrieving the `lastNotExpired` we will ignore any entries where this flag is `true`
    public var wasDeletedOrInvalid: Bool
}

// MARK: - Convenience

public extension SnodeReceivedMessageInfo {
    init(
        snode: LibSession.Snode,
        swarmPublicKey: String,
        namespace: Network.StorageServer.Namespace,
        hash: String,
        expirationDateMs: Int64?
    ) {
        self.swarmPublicKey = swarmPublicKey
        self.snodeAddress = snode.omqAddress
        self.namespace = namespace.rawValue
        self.hash = hash
        self.expirationDateMs = (expirationDateMs ?? 0)
        self.wasDeletedOrInvalid = false
    }
}

public extension Network.StorageServer.Message {
    var info: SnodeReceivedMessageInfo? {
        snode.map { snode in
            SnodeReceivedMessageInfo(
                snode: snode,
                swarmPublicKey: swarmPublicKey,
                namespace: namespace,
                hash: hash,
                expirationDateMs: expirationTimestampMs
            )
        }
    }
}

// MARK: - GRDB Interactions

public extension SnodeReceivedMessageInfo {
    /// This method fetches the last non-expired hash from the database for message retrieval
    static func fetchLastNotExpired(
        _ db: ObservingDatabase,
        for snode: LibSession.Snode,
        namespace: Network.StorageServer.Namespace,
        swarmPublicKey: String,
        using dependencies: Dependencies
    ) throws -> SnodeReceivedMessageInfo? {
        let currentOffsetTimestampMs: Int64 = dependencies.networkOffsetTimestampMs()

        return try SnodeReceivedMessageInfo
            .filter(SnodeReceivedMessageInfo.Columns.wasDeletedOrInvalid == false)
            .filter(
                SnodeReceivedMessageInfo.Columns.swarmPublicKey == swarmPublicKey &&
                SnodeReceivedMessageInfo.Columns.snodeAddress == snode.omqAddress &&
                SnodeReceivedMessageInfo.Columns.namespace == namespace.rawValue
            )
            .filter(SnodeReceivedMessageInfo.Columns.expirationDateMs > currentOffsetTimestampMs)
            .order(Column.rowID.desc)
            .fetchOne(db)
    }
    
    static func handlePotentialDeletedOrInvalidHash(
        potentiallyInvalidHashes: [String],
        using dependencies: Dependencies
    ) async {
        try? await dependencies[singleton: .storage].write { db in
            try? SnodeReceivedMessageInfo.handlePotentialDeletedOrInvalidHash(
                db,
                potentiallyInvalidHashes: potentiallyInvalidHashes
            )
        }
    }
    
    /// There are some cases where the latest message can be removed from a swarm, if we then try to poll for that message the swarm
    /// will see it as invalid and start returning messages from the beginning which can result in a lot of wasted, duplicate downloads
    ///
    /// This method should be called when deleting a message, handling an UnsendRequest or when receiving a poll response which
    /// contains solely duplicate messages (for the specific service node - if even one message in a response is new for that service
    /// node then this shouldn't be called if if the message has already been received and processed by a separate service node)
    static func handlePotentialDeletedOrInvalidHash(
        _ db: ObservingDatabase,
        potentiallyInvalidHashes: [String],
        otherKnownValidHashes: [String] = []
    ) throws {
        if !potentiallyInvalidHashes.isEmpty {
            _ = try SnodeReceivedMessageInfo
                .filter(potentiallyInvalidHashes.contains(SnodeReceivedMessageInfo.Columns.hash))
                .updateAll(
                    db,
                    SnodeReceivedMessageInfo.Columns.wasDeletedOrInvalid.set(to: true)
                )
        }
        
        // If we have any server hashes which we know are valid (eg. we fetched the oldest messages) then
        // mark them all as valid to prevent the case where we just slowly work backwards from the latest
        // message, polling for one earlier each time
        if !otherKnownValidHashes.isEmpty {
            _ = try SnodeReceivedMessageInfo
                .filter(otherKnownValidHashes.contains(SnodeReceivedMessageInfo.Columns.hash))
                .updateAll(
                    db,
                    SnodeReceivedMessageInfo.Columns.wasDeletedOrInvalid.set(to: false)
                )
        }
    }
    
    static func updateExpirationDates(
        groupedExpiryResult: [UInt64: [String]],
        using dependencies: Dependencies
    ) async {
        try? await dependencies[singleton: .storage].write { db in
            try groupedExpiryResult.forEach { updatedExpiry, hashes in
                try SnodeReceivedMessageInfo
                    .filter(hashes.contains(SnodeReceivedMessageInfo.Columns.hash))
                    .updateAll(
                        db,
                        SnodeReceivedMessageInfo.Columns.expirationDateMs
                            .set(to: updatedExpiry)
                    )
            }
        }
    }
    
    func storeUpdatedLastHash(_ db: ObservingDatabase) -> Bool {
        do {
            _ = try self.inserted(db)
            return true
        }
        catch { return false }
    }

    /// Store this message's hash as the swarm's cursor, unless the cursor was reset after `resetGeneration` was read
    ///
    /// A poll reads the generation before it reads its cursors, and passes it here. A reset that lands while that poll's
    /// retrieve is in flight would otherwise be undone the moment the poll stores the newest hash it received, and the history
    /// the reset asked for is never fetched. The check runs in the same write transaction as the insert, and every reset
    /// bumps the generation inside its own write transaction, so no reset can land between the two.
    ///
    /// `nil` means the caller is not a poll and has no generation to hold the write to
    func storeUpdatedLastHash(
        _ db: ObservingDatabase,
        unlessResetSince resetGeneration: UInt64?,
        using dependencies: Dependencies
    ) -> Bool {
        if
            let resetGeneration: UInt64 = resetGeneration,
            dependencies[cache: .snodeCursorResets].generation(for: swarmPublicKey) != resetGeneration
        { return false }

        return storeUpdatedLastHash(db)
    }

    /// Make the next poll of `swarmPublicKey` fetch `namespace` from the beginning, keeping the records so the hashes still
    /// deduplicate what comes back
    static func invalidateCursor(
        _ db: ObservingDatabase,
        swarmPublicKey: String,
        namespace: Network.StorageServer.Namespace,
        using dependencies: Dependencies
    ) throws {
        try SnodeReceivedMessageInfo
            .filter(SnodeReceivedMessageInfo.Columns.swarmPublicKey == swarmPublicKey)
            .filter(SnodeReceivedMessageInfo.Columns.namespace == namespace.rawValue)
            .updateAllAndConfig(
                db,
                SnodeReceivedMessageInfo.Columns.wasDeletedOrInvalid.set(to: true),
                using: dependencies
            )
        dependencies.mutate(cache: .snodeCursorResets) { $0.recordReset(for: swarmPublicKey) }
    }

    /// Make the next poll of `swarmPublicKey` fetch every namespace from the beginning, dropping the records entirely
    static func deleteCursor(
        _ db: ObservingDatabase,
        swarmPublicKey: String,
        using dependencies: Dependencies
    ) throws {
        try SnodeReceivedMessageInfo
            .filter(SnodeReceivedMessageInfo.Columns.swarmPublicKey == swarmPublicKey)
            .deleteAll(db)
        dependencies.mutate(cache: .snodeCursorResets) { $0.recordReset(for: swarmPublicKey) }
    }

    /// Make the next poll of every swarm fetch from the beginning
    static func deleteAllCursors(_ db: ObservingDatabase, using dependencies: Dependencies) throws {
        _ = try SnodeReceivedMessageInfo.deleteAll(db)
        dependencies.mutate(cache: .snodeCursorResets) { $0.recordResetOfEverySwarm() }
    }
}

// MARK: - SnodeReceivedMessageInfo.CursorResets

public extension SnodeReceivedMessageInfo {
    /// How many times each swarm's cursor has been reset this process
    ///
    /// A count rather than the cursor's value, because the value cannot tell a reset apart from no change: a cursor that was
    /// already empty reads the same after a reset as before it. In memory, since the only thing it has to outlast is a poll
    /// in flight, and a relaunch leaves none
    final class CursorResets: SnodeCursorResetsCacheType {
        private var resets: [String: UInt64] = [:]
        private var resetsOfEverySwarm: UInt64 = 0

        public func generation(for swarmPublicKey: String) -> UInt64 {
            return resets[swarmPublicKey, default: 0] &+ resetsOfEverySwarm
        }

        public func recordReset(for swarmPublicKey: String) {
            resets[swarmPublicKey, default: 0] &+= 1
        }

        public func recordResetOfEverySwarm() {
            resetsOfEverySwarm &+= 1
        }
    }
}

// MARK: - SnodeCursorResetsCacheType

public protocol SnodeCursorResetsImmutableCacheType: ImmutableCacheType {
    /// Changes whenever the swarm's cursor is reset
    func generation(for swarmPublicKey: String) -> UInt64
}

public protocol SnodeCursorResetsCacheType: SnodeCursorResetsImmutableCacheType, MutableCacheType {
    func recordReset(for swarmPublicKey: String)
    func recordResetOfEverySwarm()
}
