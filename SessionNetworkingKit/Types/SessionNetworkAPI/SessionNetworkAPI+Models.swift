// Copyright © 2024 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import Combine
import GRDB
import SessionUtilitiesKit

extension SessionNetworkAPI {
    
    // MARK: - Price
    
    public struct Price: Codable, Equatable {
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
    
    // MARK: - Token
    
    public struct Token: Codable, Equatable {
        enum CodingKeys: String, CodingKey {
            case stakingRequirement = "staking_requirement"
            case stakingRewardPool = "staking_reward_pool"
            case contractAddress = "contract_address"
        }
        
        public let stakingRequirement: Double?           // The number of tokens required to stake a node. This is the effective "token amount" per node (SESH)
        public let stakingRewardPool: Double?            // The number of tokens in the staking reward pool (SESH)
        public let contractAddress: String?              // Token contract address (42 char Hexadecimal - Including 0x prefix)
    }
    
    
    // MARK: - Network Info
    
    public struct NetworkInfo: Codable, Equatable {
        enum CodingKeys: String, CodingKey {
            case networkSize = "network_size"                   // The number of nodes in the Session Network (integer)
            case networkStakedTokens = "network_staked_tokens"  //
            case networkStakedUSD = "network_staked_usd"        //
        }
        
        public let networkSize: Int?
        public let networkStakedTokens: Double?
        public let networkStakedUSD: Double?
    }
    
    // MARK: - Info
    
    public struct Info: Codable, Equatable {
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

