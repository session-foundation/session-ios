// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation

public extension Network.SnodeAPI {
    struct GetNetworkTimestampResponse: Decodable {
        enum CodingKeys: String, CodingKey {
            case timestamp
            case version
        }
        
        let timestamp: UInt64
        let version: [UInt64]
    }
}
