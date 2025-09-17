// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation

public extension Network.SessionNetwork {
    struct Price: Codable, Equatable {
        enum CodingKeys: String, CodingKey {
            case tokenUsd = "usd"
            case marketCapUsd = "usd_market_cap"
            case priceTimestamp = "t_price"
            case staleTimestamp = "t_stale"
        }
        
        public let tokenUsd: Double?                     // Current token price (USD)
        public let marketCapUsd: Double?                 // Current market cap value in (USD)
        public let priceTimestamp: Int64?                // The timestamp the price data is accurate at. (seconds)
        public let staleTimestamp: Int64?                // Stale timestamp for the price data. (seconds)
    }
}
