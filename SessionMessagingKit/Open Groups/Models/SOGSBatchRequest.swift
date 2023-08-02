// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import SessionUtilitiesKit

public extension OpenGroupAPI {
    internal struct BatchRequest: Encodable {
        let requests: [Child]
        
        init(requests: [ErasedPreparedSendData]) {
            self.requests = requests.map { Child(request: $0) }
        }
        
        // MARK: - Encodable
        
        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()

            try container.encode(requests)
        }
        
        // MARK: - BatchRequest.Child
        
        struct Child: Encodable {
            enum CodingKeys: String, CodingKey {
                case method
                case path
                case headers
                case json
                case b64
                case bytes
            }
            
            let request: ErasedPreparedSendData
            
            func encode(to encoder: Encoder) throws {
                try request.encodeForBatchRequest(to: encoder)
            }
        }
    }
    
    struct BatchResponse: Decodable {
        let info: ResponseInfoType
        let data: [Endpoint: Decodable]
        
        public subscript(position: Endpoint) -> Decodable? {
            get { return data[position] }
        }
        
        public var count: Int { data.count }
        public var keys: Dictionary<Endpoint, Decodable>.Keys { data.keys }
        public var values: Dictionary<Endpoint, Decodable>.Values { data.values }
        
        // MARK: - Initialization
        
        internal init(
            info: ResponseInfoType,
            data: [Endpoint: Decodable]
        ) {
            self.info = info
            self.data = data
        }
        
        public init(from decoder: Decoder) throws {
#if DEBUG
            preconditionFailure("The `OpenGroupAPI.BatchResponse` type cannot be decoded directly, this is simply here to allow for `PreparedSendData<OpenGroupAPI.BatchResponse>` support")
#else
            info = HTTP.ResponseInfo(code: 0, headers: [:])
            data = [:]
#endif
        }
    }
}
