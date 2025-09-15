// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation

extension Network.SOGS {
    public struct Capabilities: Codable, Equatable {
        public let capabilities: [Network.SOGS.Capability.Variant]
        public let missing: [Network.SOGS.Capability.Variant]?

        // MARK: - Initialization

        public init(capabilities: [Network.SOGS.Capability.Variant], missing: [Network.SOGS.Capability.Variant]? = nil) {
            self.capabilities = capabilities
            self.missing = missing
        }
    }
}

//public struct Capability: Codable, FetchableRecord, PersistableRecord, TableRecord, ColumnExpressible {
//    public static var databaseTableName: String { "capability" }
//    
//    public typealias Columns = CodingKeys
//    public enum CodingKeys: String, CodingKey, ColumnExpression {
//        case openGroupServer
//        case variant
//        case isMissing
//    }
//    
//    public enum Variant: Equatable, Hashable, CaseIterable, Codable, DatabaseValueConvertible {
//        public static var allCases: [Variant] {
//            [.sogs, .blind, .reactions]
//        }
//        
//        case sogs
//        case blind
//        case reactions
//        
//        /// Fallback case if the capability isn't supported by this version of the app
//        case unsupported(String)
//        
//        // MARK: - Convenience
//        
//        public var rawValue: String {
//            switch self {
//                case .unsupported(let originalValue): return originalValue
//                default: return "\(self)"
//            }
//        }
//        
//        // MARK: - Initialization
//        
//        public init(from valueString: String) {
//            let maybeValue: Variant? = Variant.allCases.first { $0.rawValue == valueString }
//            
//            self = (maybeValue ?? .unsupported(valueString))
//        }
//    }
//    
//    public let openGroupServer: String
//    public let variant: Variant
//    public let isMissing: Bool
//    
//    // MARK: - Initialization
//    
//    public init(
//        openGroupServer: String,
//        variant: Variant,
//        isMissing: Bool
//    ) {
//        self.openGroupServer = openGroupServer
//        self.variant = variant
//        self.isMissing = isMissing
//    }
//}
