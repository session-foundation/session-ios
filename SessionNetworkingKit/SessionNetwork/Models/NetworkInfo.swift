// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation

public extension Network.SessionNetwork {
    struct NetworkInfo: Codable, Equatable {
        enum CodingKeys: String, CodingKey {
            case networkSize = "network_size"                   // The number of nodes in the Session Network (integer)
            case networkStakedTokens = "network_staked_tokens"  //
            case networkStakedUSD = "network_staked_usd"        //
        }
        
        public let networkSize: Int?
        public let networkStakedTokens: Double?
        public let networkStakedUSD: Double?
    }
}
