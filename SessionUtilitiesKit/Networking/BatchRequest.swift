// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation

public extension HTTP {
    struct BatchRequest: Encodable {
        let requests: [Child]
        
        public init(requests: [any ErasedPreparedRequest]) {
            self.requests = requests.map { Child(request: $0) }
        }
        
        // MARK: - Encodable
        
        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()

            try container.encode(requests)
        }
        
        // MARK: - BatchRequest.Child
        
        public struct Child: Encodable {
            public enum Variant {
                case unsupported
                case sogs
                case storageServer
            }
            
            enum CodingKeys: String, CodingKey {
                case method
                
                // SOGS keys
                case path
                case headers
                case json
                case b64
                case bytes
                
                // Storage Server keys
                case params
            }
            
            let request: any ErasedPreparedRequest
            
            public func encode(to encoder: Encoder) throws {
                try request.encodeForBatchRequest(to: encoder)
            }
        }
    }
}
