// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit

internal struct ConfigDump: Codable, Equatable, Hashable, Identifiable, FetchableRecord, PersistableRecord, TableRecord, ColumnExpressible {
    public static var databaseTableName: String { "configDump" }
    
    public typealias Columns = CodingKeys
    public enum CodingKeys: String, CodingKey, ColumnExpression {
        case variant
        case data
    }
    
    enum Variant: String, Codable, DatabaseValueConvertible, CaseIterable {
        case userProfile
    }
    
    var id: Variant { variant }
    
    /// The type of config this dump is for
    public let variant: Variant
    
    /// The data for this dump
    public let data: Data
}
