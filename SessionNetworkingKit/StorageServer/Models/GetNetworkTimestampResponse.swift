// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation

public extension Network.StorageServer {
    class GetNetworkTimestampResponse: BaseResponse {
        enum CodingKeys: String, CodingKey {
            case timestamp
            case version
        }
        
        let timestamp: UInt64
        let version: [UInt64]
        
        // MARK: - Initialization
        
        internal init(
            timestamp: UInt64,
            version: [UInt64],
            hardForkVersion: [Int],
            timeOffset: Int64
        ) {
            self.timestamp = timestamp
            self.version = version
            
            super.init(
                hardForkVersion: hardForkVersion,
                timeOffset: timeOffset
            )
        }
        
        required init(from decoder: Decoder) throws {
            let container: KeyedDecodingContainer<CodingKeys> = try decoder.container(keyedBy: CodingKeys.self)
            
            timestamp = try container.decode(UInt64.self, forKey: .timestamp)
            version = try container.decode([UInt64].self, forKey: .version)
            
            try super.init(from: decoder)
        }
        
        public override func encode(to encoder: any Encoder) throws {
            var container: KeyedEncodingContainer<CodingKeys> = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(timestamp, forKey: .timestamp)
            try container.encode(version, forKey: .version)
            
            try super.encode(to: encoder)
        }
    }
}
