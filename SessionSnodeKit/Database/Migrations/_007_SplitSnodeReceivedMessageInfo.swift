// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit

/// This migration splits the old `key` structure used for `SnodeReceivedMessageInfo` into separate columns for more efficient querying
enum _007_SplitSnodeReceivedMessageInfo: Migration {
    static let target: TargetMigrations.Identifier = .snodeKit
    static let identifier: String = "SplitSnodeReceivedMessageInfo"
    static let minExpectedRunDuration: TimeInterval = 0.1
    static let createdTables: [(TableRecord & FetchableRecord).Type] = [SnodeReceivedMessageInfo.self]
    
    static func migrate(_ db: ObservingDatabase, using dependencies: Dependencies) throws {
        /// Fetch the existing values and then drop the table
        let existingValues: [Row] = try Row.fetchAll(db, sql: """
            SELECT key, hash, expirationDateMs, wasDeletedOrInvalid
            FROM snodeReceivedMessageInfo
        """)
        try db.drop(table: "snodeReceivedMessageInfo")
        
        /// Create the new table
        try db.create(table: "snodeReceivedMessageInfo") { t in
            t.column("swarmPublicKey", .text)
                .notNull()
                .indexed()
            t.column("snodeAddress", .text).notNull()
            t.column("namespace", .integer).notNull()
                .indexed()
            t.column("hash", .text)
                .notNull()
                .indexed()
            t.column("expirationDateMs", .integer)
                .notNull()
                .indexed()
            t.column("wasDeletedOrInvalid", .boolean)
                .notNull()
                .indexed()
            
            t.primaryKey(["swarmPublicKey", "snodeAddress", "namespace", "hash"])
        }
        
        /// Convert the old data to the new structure and insert it
        typealias Info = (
            swarmPublicKey: String,
            snodeAddress: String,
            namespace: Int,
            hash: String,
            expirationDateMs: Int64,
            wasDeletedOrInvalid: Bool
        )
        let timestampNowMs: Int64 = Int64(dependencies.dateNow.timeIntervalSince1970 * 1000)
        let updatedValues: [Info] = existingValues.compactMap { info -> Info? in
            /// The old key was a combination of `{snode address}.{publicKey}.{namespace}`
            let key: String = info["key"]
            let keyComponents: [String] = key.components(separatedBy: ".")
            
            /// Because node addresses are likely ip addresses the `keyComponents` array above may have an inconsistent length
            /// as such we need to find the swarm public key and then split again based on that value
            let maybeSwarmPublicKey: String? = {
                /// Legacy versions only included the `publicKey` which isn't supported anymore
                /// so just ignore those
                guard keyComponents.count > 2 else { return nil }
                
                /// If this wasn't associated to a `namespace` the the last value will be the `swarmPublicKey`
                guard (try? SessionId(from: keyComponents[keyComponents.count - 1])) != nil else {
                    /// Otherwise it'll be the 2nd last value
                    guard (try? SessionId(from: keyComponents[keyComponents.count - 2])) != nil else {
                        return nil
                    }
                    
                    return keyComponents[keyComponents.count - 2]
                }
                
                return keyComponents[keyComponents.count - 1]
            }()
            
            /// There was a bug in an old version of the code where it wouldn't correctly prune expired hashes so we may as well
            /// exclude them here as they just take up space otherwise
            guard
                let swarmPublicKey: String = maybeSwarmPublicKey,
                info["expirationDateMs"] > timestampNowMs
            else { return nil }
            
            /// Split on the `swarmPublicKey`
            let swarmPublicKeySplitComponents: [String] = key
                .components(separatedBy: ".\(swarmPublicKey).") // stringlint:ignore
                .filter { !$0.isEmpty }
            
            guard !swarmPublicKeySplitComponents.isEmpty else { return nil }
            
            let targetNamespace: Int = {
                guard swarmPublicKeySplitComponents.count == 2 else {
                    return SnodeAPI.Namespace.default.rawValue
                }
                
                return (Int(swarmPublicKeySplitComponents[1]) ?? SnodeAPI.Namespace.default.rawValue)
            }()
            let wasDeletedOrInvalid: Bool? = info["wasDeletedOrInvalid"]
            
            return (
                swarmPublicKey,
                swarmPublicKeySplitComponents[0],
                targetNamespace,
                info["hash"],
                info["expirationDateMs"],
                (wasDeletedOrInvalid == true)
            )
        }
        
        try updatedValues.forEach {
            try db.execute(
                sql: """
                    INSERT INTO snodeReceivedMessageInfo (
                        swarmPublicKey,
                        snodeAddress,
                        namespace,
                        hash,
                        expirationDateMs,
                        wasDeletedOrInvalid
                    )
                    VALUES (?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    $0.swarmPublicKey,
                    $0.snodeAddress,
                    $0.namespace,
                    $0.hash,
                    $0.expirationDateMs,
                    $0.wasDeletedOrInvalid
                ]
            )
        }
        
        MigrationExecution.updateProgress(1)
    }
}
