// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtilitiesKit

public protocol BatchRequestChildRetrievable {
    var requests: [Network.BatchRequest.Child] { get }
}

public extension Network {
    struct BatchRequest: Encodable, BatchRequestChildRetrievable {
        public enum Target {
            case storageServer
            case sogs
            
            var requestsKey: CodingKeys? {
                switch self {
                    case .storageServer: return .requests
                    case .sogs: return nil
                }
            }
            
            public var childRequestLimit: Int {
                switch self {
                    case .sogs: return Int.max
                    case .storageServer:
                        /// The storage server has a limit for the number of requests a `BatchRequest` can have, when
                        /// using this we should avoid trying to make calls that exceed this limit as they will fail
                        return 20
                }
            }
        }
        
        public enum CodingKeys: String, CodingKey {
            // Storage Server keys
            case requests
        }
        
        private let target: Target
        public let requests: [Child]
        
        public init(target: Target, requests: [any ErasedPreparedRequest]) {
            self.target = target
            self.requests = requests.map { Child(request: $0) }
            
            if requests.count > target.childRequestLimit {
                Log.warn("[BatchRequest] Constructed request with \(requests.count) subrequests when the limit is \(target.childRequestLimit)")
            }
        }
        
        // MARK: - Encodable
        
        public func encode(to encoder: Encoder) throws {
            switch target.requestsKey {
                case .requests:
                    var container: KeyedEncodingContainer<CodingKeys> = encoder.container(keyedBy: CodingKeys.self)

                    try container.encode(requests, forKey: .requests)
                    
                case .none:
                    var container: SingleValueEncodingContainer = encoder.singleValueContainer()

                    try container.encode(requests)
            }
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
