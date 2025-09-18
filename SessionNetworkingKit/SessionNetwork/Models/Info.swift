// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation

public extension Network.SessionNetwork {
    struct Info: Codable, Equatable {
        enum CodingKeys: String, CodingKey {
            case timestamp = "t"
            case statusCode = "status_code"
            case price
            case token
            case network
        }
        
        public let timestamp: Int64?                         // Request timestamp. (seconds)
        public let statusCode: Int?                          // Status code of the request.
        public let price: Price?
        public let token: Token?
        public let network: NetworkInfo?
    }
}
