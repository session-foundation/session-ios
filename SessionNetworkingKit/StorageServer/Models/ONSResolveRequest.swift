// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation

extension SnodeAPI {
    public struct ONSResolveRequest: Encodable {
        enum CodingKeys: String, CodingKey {
            case type
            case base64EncodedNameHash = "name_hash"
        }
        
        let type: Int64
        let base64EncodedNameHash: String
    }
}
