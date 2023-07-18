// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation

extension SnodeAPI {
    public struct GetSwarmRequest: Encodable {
        enum CodingKeys: String, CodingKey {
            case pubkey
        }
        
        let pubkey: String
    }
}
