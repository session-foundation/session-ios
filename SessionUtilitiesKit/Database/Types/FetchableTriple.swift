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
}
