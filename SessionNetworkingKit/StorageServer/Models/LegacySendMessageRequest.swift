// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation

extension Network.SnodeAPI {
    /// This is the legacy unauthenticated message store request
    struct LegacySendMessagesRequest: Encodable {
        enum CodingKeys: String, CodingKey {
            case namespace
        }
        
        let message: SnodeMessage
        let namespace: Network.SnodeAPI.Namespace
        
        // MARK: - Coding
        
        public func encode(to encoder: Encoder) throws {
            var container: KeyedEncodingContainer<CodingKeys> = encoder.container(keyedBy: CodingKeys.self)
            
            try message.encode(to: encoder)
            try container.encode(namespace, forKey: .namespace)
        }
    }
}
