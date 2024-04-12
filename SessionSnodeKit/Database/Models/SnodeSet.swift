// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit

public struct SnodeSet: Codable, FetchableRecord, EncodableRecord, PersistableRecord, TableRecord, ColumnExpressible {
    public static let onionRequestPathPrefix = "OnionRequestPath-"  // stringlint:disable
    public static var databaseTableName: String { "snodeSet" }
    static let node = hasOne(Snode.self, using: Snode.snodeSetForeignKey)
        
    public typealias Columns = CodingKeys
    public enum CodingKeys: String, CodingKey, ColumnExpression {
        case key
        case nodeIndex
        case ip
        case lmqPort
    }
    
    public let key: String
    public let nodeIndex: Int
    public let ip: String
    public let lmqPort: UInt16
    
    public var node: QueryInterfaceRequest<Snode> {
        request(for: SnodeSet.node)
    }
}
