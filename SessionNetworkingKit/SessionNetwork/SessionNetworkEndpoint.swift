// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation

public extension Network.SessionNetwork {
    public enum Endpoint: EndpointType {
        case info
        case price
        case token
        
        public static var name: String { "SessionNetwork.Endpoint" }
        
        public var path: String {
            switch self {
                case .info: return "info"
                case .price: return "price"
                case .token: return "token"
            }
        }
    }
}
