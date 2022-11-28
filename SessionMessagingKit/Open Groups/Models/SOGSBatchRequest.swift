// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import PromiseKit
import SessionUtilitiesKit

internal extension OpenGroupAPI {
    struct BatchRequest: Encodable {
        let requests: [Child]
        
        init(requests: [Info]) {
            self.requests = requests.map { $0.child }
        }
        
        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            
            try container.encode(requests)
        }
        
        // MARK: - BatchRequest.Info
        
        struct Info {
            public let endpoint: any EndpointType
            public let responseType: Codable.Type
            fileprivate let child: Child
            
            public init<T: Encodable, E: EndpointType, R: Codable>(request: Request<T, E>, responseType: R.Type) {
                self.endpoint = request.endpoint
                self.responseType = HTTP.BatchSubResponse<R>.self
                self.child = Child(request: request)
            }
            
            public init<T: Encodable, E: EndpointType>(request: Request<T, E>) {
                self.init(
                    request: request,
                    responseType: NoResponse.self
                )
            }
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
            
            let method: HTTPMethod
            let path: String
            let headers: [String: String]?
            
            /// The `jsonBodyEncoder` is used to avoid having to make `Child` a generic type (haven't found a good way
            /// to keep `Child` encodable using protocols unfortunately so need this work around)
            private let jsonBodyEncoder: ((inout KeyedEncodingContainer<CodingKeys>, CodingKeys) throws -> ())?
            private let b64: String?
            private let bytes: [UInt8]?
            
            internal init<T: Encodable, E: EndpointType>(request: Request<T, E>) {
                self.method = request.method
                self.path = request.urlPathAndParamsString
                self.headers = (request.headers.isEmpty ? nil : request.headers.toHTTPHeaders())
                
                // Note: Need to differentiate between JSON, b64 string and bytes body values to ensure
                // they are encoded correctly so the server knows how to handle them
                switch request.body {
                    case let bodyString as String:
                        self.jsonBodyEncoder = nil
                        self.b64 = bodyString
                        self.bytes = nil
                        
                    case let bodyBytes as [UInt8]:
                        self.jsonBodyEncoder = nil
                        self.b64 = nil
                        self.bytes = bodyBytes
                        
                    default:
                        self.jsonBodyEncoder = { [body = request.body] container, key in
                            try container.encodeIfPresent(body, forKey: key)
                        }
                        self.b64 = nil
                        self.bytes = nil
                }
            }
            
            func encode(to encoder: Encoder) throws {
                var container: KeyedEncodingContainer<CodingKeys> = encoder.container(keyedBy: CodingKeys.self)

                try container.encode(method, forKey: .method)
                try container.encode(path, forKey: .path)
                try container.encodeIfPresent(headers, forKey: .headers)
                try jsonBodyEncoder?(&container, .json)
                try container.encodeIfPresent(b64, forKey: .b64)
                try container.encodeIfPresent(bytes, forKey: .bytes)
            }
        }
    }
}

// MARK: - Convenience

internal extension Promise where T == HTTP.BatchResponse {
    func map<E: EndpointType>(
        requests: [OpenGroupAPI.BatchRequest.Info],
        toHashMapFor endpointType: E.Type
    ) -> Promise<[E: (ResponseInfoType, Codable?)]> {
        return self.map { result in
            result.enumerated()
                .reduce(into: [:]) { prev, next in
                    guard let endpoint: E = requests[next.offset].endpoint as? E else { return }
                    
                    prev[endpoint] = next.element
                }
        }
    }
}
