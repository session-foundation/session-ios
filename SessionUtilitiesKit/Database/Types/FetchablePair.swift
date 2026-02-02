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
            let firstValue: First = row.databaseValues.first?.storage.value as? First,
            let secondValue: Second = row.databaseValues.last?.storage.value as? Second
        else { throw StorageError.decodingFailed }
        
        first = firstValue
        second = secondValue
    }
}
