// Copyright © 2026 Session Technology Foundation. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit

/// The raw swarm message for something this client positively identified but can't process, retained so a newer client (or a
/// future database import) can replay it through its normal receive path
///
/// **Note:** The table and column names are deliberately identical across the iOS, Android and Desktop clients so a future import
/// can read one shape from all of them, which is why they don't follow this client's usual camelCase convention
public struct UnsupportedMessageRecord: Codable, Equatable, FetchableRecord, MutablePersistableRecord, TableRecord, ColumnExpressible {
    public static var databaseTableName: String { "unsupported_message" }

    /// Upper bound on the total cost of retained rows, where each row costs `length(data) + 256` (the 256 is added by the
    /// `unsupported_message_stats` triggers so that many tiny rows can't take far more space on disk than the budget allows)
    public static let maxRetainedBytes: Int64 = (256 * 1024 * 1024)
    
    /// `newerFormat` rows can be deposited by anyone, so they are also capped by count
    public static let maxNewerFormatCount: Int64 = 10_000

    public typealias Columns = CodingKeys
    public enum CodingKeys: String, CodingKey, ColumnExpression {
        case id
        case kind
        case swarmPublicKey = "swarm_public_key"
        case namespace
        case hash
        case sender
        case sentTimestampMs = "sent_timestamp_ms"
        case serverTimestampMs = "server_timestamp_ms"
        case serverExpiryMs = "server_expiry_ms"
        case data
        case placeholderMessageId = "placeholder_message_id"
        case expiresAtMs = "expires_at_ms"
        case receivedAtMs = "received_at_ms"
        case lastAttemptVersion = "last_attempt_version"
    }

    public enum Kind: String, Codable, DatabaseValueConvertible {
        /// A one-to-one message in a newer wire format which this client can't decrypt at all, so there is no sender or
        /// conversation associated to it
        case newerFormat

        /// A message which decrypted successfully (so has an authenticated sender) but contains a content type this client
        /// doesn't know
        case unknownType
    }

    public var id: Int64?
    public let kind: Kind
    public let swarmPublicKey: String
    public let namespace: Int
    public let hash: String

    /// The authenticated sender and the sender's sent timestamp, which identify the message for an unsend request (both `nil`
    /// for a `newerFormat` message as they are inside the encryption)
    public let sender: String?
    public let sentTimestampMs: Int64?

    public let serverTimestampMs: Int64
    public let serverExpiryMs: Int64?
    public let data: Data
    public var placeholderMessageId: Int64?
    public let expiresAtMs: Int64?
    public let receivedAtMs: Int64
    public var lastAttemptVersion: String

    public init(
        id: Int64? = nil,
        kind: Kind,
        swarmPublicKey: String,
        namespace: Int,
        hash: String,
        sender: String?,
        sentTimestampMs: Int64?,
        serverTimestampMs: Int64,
        serverExpiryMs: Int64?,
        data: Data,
        placeholderMessageId: Int64?,
        expiresAtMs: Int64?,
        receivedAtMs: Int64,
        lastAttemptVersion: String
    ) {
        self.id = id
        self.kind = kind
        self.swarmPublicKey = swarmPublicKey
        self.namespace = namespace
        self.hash = hash
        self.sender = sender
        self.sentTimestampMs = sentTimestampMs
        self.serverTimestampMs = serverTimestampMs
        self.serverExpiryMs = serverExpiryMs
        self.data = data
        self.placeholderMessageId = placeholderMessageId
        self.expiresAtMs = expiresAtMs
        self.receivedAtMs = receivedAtMs
        self.lastAttemptVersion = lastAttemptVersion
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        self.id = inserted.rowID
    }
}

// MARK: - Convenience

public extension UnsupportedMessageRecord {
    static func currentVersion(using dependencies: Dependencies) -> String {
        let versionInfo = dependencies[cache: .appVersion]

        return "\(versionInfo.appVersion)-\(versionInfo.buildNumber)"
    }

    /// Remove rows whose message has expired, then evict the oldest rows until both limits are met
    ///
    /// `newerFormat` rows are evicted before `unknownType` rows as anyone can deposit a message with the newer-format prefix
    /// into a one-to-one namespace, whereas an `unknownType` message came from an authenticated sender
    ///
    /// **Note:** This runs on every insert so it reads the trigger-maintained totals in `unsupported_message_stats` rather than
    /// scanning the table
    static func enforceLimits(_ db: ObservingDatabase, using dependencies: Dependencies) throws {
        let nowMs: Int64 = dependencies.networkOffsetTimestampMs()
        
        try UnsupportedMessageRecord
            .filter(Columns.expiresAtMs <= nowMs)
            .deleteAll(db)
        
        let newerFormatCount: Int64 = (try Int64.fetchOne(
            db,
            sql: "SELECT newer_format_count FROM unsupported_message_stats WHERE id = 1"
        ) ?? 0)
        
        if newerFormatCount > maxNewerFormatCount {
            try deleteOldest(db, kind: .newerFormat, count: (newerFormatCount - maxNewerFormatCount))
        }
        
        for kind in [Kind.newerFormat, Kind.unknownType] {
            while try totalCostBytes(db) > maxRetainedBytes {
                guard try deleteOldest(db, kind: kind, count: 100) > 0 else { break }
            }
        }
    }
    
    private static func totalCostBytes(_ db: ObservingDatabase) throws -> Int64 {
        return (try Int64.fetchOne(db, sql: "SELECT total_bytes FROM unsupported_message_stats WHERE id = 1") ?? 0)
    }
    
    @discardableResult private static func deleteOldest(_ db: ObservingDatabase, kind: Kind, count: Int64) throws -> Int {
        let ids: [Int64] = try UnsupportedMessageRecord
            .select(.id)
            .filter(Columns.kind == kind)
            .order(Columns.id)
            .limit(Int(count))
            .asRequest(of: Int64.self)
            .fetchAll(db)
        
        guard !ids.isEmpty else { return 0 }
        
        try UnsupportedMessageRecord
            .filter(ids.contains(Columns.id))
            .deleteAll(db)
        
        return ids.count
    }
}
