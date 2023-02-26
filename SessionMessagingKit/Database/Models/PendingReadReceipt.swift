// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit

public struct PendingReadReceipt: Codable, Equatable, Hashable, FetchableRecord, PersistableRecord, TableRecord, ColumnExpressible {
    public static var databaseTableName: String { "pendingReadReceipt" }
    public static let threadForeignKey = ForeignKey([Columns.threadId], to: [SessionThread.Columns.id])
    
    public typealias Columns = CodingKeys
    public enum CodingKeys: String, CodingKey, ColumnExpression {
        case threadId
        case interactionTimestampMs
        case readTimestampMs
        case serverExpirationTimestamp
    }
    
    /// The id for the thread this ReadReceipt belongs to
    public let threadId: String
    
    /// The timestamp in milliseconds since epoch for the interaction this read receipt relates to
    public let interactionTimestampMs: Int64
    
    /// The timestamp in milliseconds since epoch that the interaction this read receipt relates to was read
    public let readTimestampMs: Int64
    
    /// The timestamp for when this message will expire on the server (will be used for garbage collection)
    public let serverExpirationTimestamp: TimeInterval
    
    // MARK: - Initialization
    
    public init(
        threadId: String,
        interactionTimestampMs: Int64,
        readTimestampMs: Int64,
        serverExpirationTimestamp: TimeInterval
    ) {
        self.threadId = threadId
        self.interactionTimestampMs = interactionTimestampMs
        self.readTimestampMs = readTimestampMs
        self.serverExpirationTimestamp = serverExpirationTimestamp
    }
}
