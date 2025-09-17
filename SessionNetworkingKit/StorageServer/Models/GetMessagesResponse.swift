// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation

extension Network.StorageServer {
    public class GetMessagesResponse: BaseResponse {
        private enum CodingKeys: String, CodingKey {
            case messages
            case more
        }
        
        public class RawMessage: Codable {
            private enum CodingKeys: String, CodingKey {
                case base64EncodedDataString = "data"
                case expirationMs = "expiration"
                case hash
                case timestampMs = "timestamp"
            }
            
            public let base64EncodedDataString: String
            public let expirationMs: Int64?
            public let hash: String
            public let timestampMs: Int64
            
            public init(
                base64EncodedDataString: String,
                expirationMs: Int64?,
                hash: String,
                timestampMs: Int64
            ) {
                self.base64EncodedDataString = base64EncodedDataString
                self.expirationMs = expirationMs
                self.hash = hash
                self.timestampMs = timestampMs
            }
        }
        
        public let messages: [RawMessage]
        public let more: Bool
        
        // MARK: - Initialization
        
        internal init(
            messages: [RawMessage],
            more: Bool,
            hardForkVersion: [Int],
            timeOffset: Int64
        ) {
            self.messages = messages
            self.more = more
            
            super.init(
                hardForkVersion: hardForkVersion,
                timeOffset: timeOffset
            )
        }
        
        required init(from decoder: Decoder) throws {
            let container: KeyedDecodingContainer<CodingKeys> = try decoder.container(keyedBy: CodingKeys.self)
            
            messages = try container.decode([RawMessage].self, forKey: .messages)
            more = try container.decode(Bool.self, forKey: .more)
            
            try super.init(from: decoder)
        }
        
        public override func encode(to encoder: any Encoder) throws {
            var container: KeyedEncodingContainer<CodingKeys> = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(messages, forKey: .messages)
            try container.encode(more, forKey: .more)
            
            try super.encode(to: encoder)
        }
    }
}
