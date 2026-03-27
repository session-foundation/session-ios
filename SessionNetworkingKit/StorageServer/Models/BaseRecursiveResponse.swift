// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation

extension Network.StorageServer {
    public class BaseRecursiveResponse<T: BaseSwarmItem>: BaseResponse {
        private enum CodingKeys: String, CodingKey {
            case swarm
        }
        
        internal let swarm: [String: T]
        
        // MARK: - Initialization
        
        internal init(
            swarm: [String: T],
            hardFork: [Int],
            timeOffset: Int64
        ) {
            self.swarm = swarm
            
            super.init(hardForkVersion: hardFork, timeOffset: timeOffset)
        }
        
        required init(from decoder: Decoder) throws {
            let container: KeyedDecodingContainer<CodingKeys> = try decoder.container(keyedBy: CodingKeys.self)
            
            swarm = try container.decode([String: T].self, forKey: .swarm)
            
            try super.init(from: decoder)
        }
        
        public override func encode(to encoder: any Encoder) throws {
            var container: KeyedEncodingContainer<CodingKeys> = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(swarm, forKey: .swarm)
            
            try super.encode(to: encoder)
        }
    }
}
