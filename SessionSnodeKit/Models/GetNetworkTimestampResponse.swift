// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation

extension SnodeAPI {
    public struct GetNetworkTimestampResponse: Decodable {
        enum CodingKeys: String, CodingKey {
            case timestamp
            case version
        }
        
        let timestamp: UInt64
        let version: [UInt64]
    }
}
