// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB

public typealias FetchableTripleConformance = (Sendable & Codable & Equatable & Hashable)

public struct FetchableTriple<First: FetchableTripleConformance, Second: FetchableTripleConformance, Third: FetchableTripleConformance>: FetchableTripleConformance, FetchableRecord, ColumnExpressible {
    public typealias Columns = CodingKeys
    public enum CodingKeys: String, CodingKey, ColumnExpression, CaseIterable {
        case first
        case second
        case third
    }
    
    public let first: First
    public let second: Second
    public let third: Third
    
    public init(row: Row) throws {
        /// We don't care about the column names for this type so just map the values directly
        guard row.databaseValues.count == 3 else { throw StorageError.decodingFailed }
        
        first = try FetchableTriple.decode(First.self, from: row.databaseValues[row.databaseValues.startIndex])
        second = try FetchableTriple.decode(Second.self, from: row.databaseValues[row.databaseValues.startIndex.advanced(by: 1)])
        third = try FetchableTriple.decode(Third.self, from: row.databaseValues[row.databaseValues.startIndex.advanced(by: 2)])
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
