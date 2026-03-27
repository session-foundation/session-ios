// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB

public typealias FetchablePairConformance = (Sendable & Codable & Equatable & Hashable)

public struct FetchablePair<First: FetchablePairConformance, Second: FetchablePairConformance>: FetchablePairConformance, FetchableRecord, ColumnExpressible {
    public typealias Columns = CodingKeys
    public enum CodingKeys: String, CodingKey, ColumnExpression, CaseIterable {
        case first
        case second
    }
    
    public let first: First
    public let second: Second
    
    public init(row: Row) throws {
        /// We don't care about the column names for this type so just map the values directly
        guard
            let firstDBValue = row.databaseValues.first,
            let secondDBValue = row.databaseValues.last
        else { throw StorageError.decodingFailed }
        
        first = try FetchablePair.decode(First.self, from: firstDBValue)
        second = try FetchablePair.decode(Second.self, from: secondDBValue)
    }
    
    private static func decode<T: FetchablePairConformance>(_ type: T.Type, from dbValue: DatabaseValue) throws -> T {
        if
            let convertibleType = T.self as? any DatabaseValueConvertible.Type,
            let value: T = convertibleType.fromDatabaseValue(dbValue) as? T
        {
            return value
        }

        if let value: T = dbValue.storage.value as? T {
            return value
        }

        throw StorageError.decodingFailed
    }
}
