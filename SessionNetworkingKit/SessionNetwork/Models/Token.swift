// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation

public extension Network.SessionNetwork {
    struct Token: Codable, Equatable {
        enum CodingKeys: String, CodingKey {
            case stakingRequirement = "staking_requirement"
            case stakingRewardPool = "staking_reward_pool"
            case contractAddress = "contract_address"
        }
        
        public let stakingRequirement: Double?           // The number of tokens required to stake a node. This is the effective "token amount" per node (SESH)
        public let stakingRewardPool: Double?            // The number of tokens in the staking reward pool (SESH)
        public let contractAddress: String?              // Token contract address (42 char Hexadecimal - Including 0x prefix)
    }
}
