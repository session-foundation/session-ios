// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import SessionUtilitiesKit

// MARK: - ErasedPreparedSendData

public protocol ErasedPreparedSendData {
    var endpoint: OpenGroupAPI.Endpoint { get }
    var batchResponseTypes: [Decodable.Type] { get }
    
    func encodeForBatchRequest(to encoder: Encoder) throws
}

// MARK: - PreparedSendData<R>

public extension OpenGroupAPI {
    struct PreparedSendData<R>: ErasedPreparedSendData {
        internal let request: URLRequest
        internal let server: String
        internal let publicKey: String
        internal let originalType: Decodable.Type
        internal let responseType: R.Type
        internal let timeout: TimeInterval
        fileprivate let responseConverter: ((ResponseInfoType, Any) throws -> R)
        
        // The following types are needed for `BatchRequest` handling
        private let method: HTTPMethod
        private let path: String
        public let endpoint: Endpoint
        internal let batchEndpoints: [Endpoint]
        public let batchResponseTypes: [Decodable.Type]
        
        /// The `jsonBodyEncoder` is used to simplify the encoding for `BatchRequest`
        private let jsonBodyEncoder: ((inout KeyedEncodingContainer<BatchRequest.Child.CodingKeys>, BatchRequest.Child.CodingKeys) throws -> ())?
        private let b64: String?
        private let bytes: [UInt8]?
        
        internal init<T: Encodable>(
            request: Request<T, Endpoint>,
            urlRequest: URLRequest,
            publicKey: String,
            responseType: R.Type,
            timeout: TimeInterval
        ) where R: Decodable {
            self.request = urlRequest
            self.server = request.server
            self.publicKey = publicKey
            self.originalType = responseType
            self.responseType = responseType
            self.timeout = timeout
            self.responseConverter = { _, response in
                guard let validResponse: R = response as? R else { throw HTTPError.invalidResponse }
                
                return validResponse
            }
            
            // The following data is needed in this type for handling batch requests
            self.method = request.method
            self.endpoint = request.endpoint
            self.path = request.urlPathAndParamsString
            self.batchEndpoints = ((request.body as? BatchRequest)?
                .requests
                .map { $0.request.endpoint })
                .defaulting(to: [])
            self.batchResponseTypes = ((request.body as? BatchRequest)?
                .requests
                .flatMap { $0.request.batchResponseTypes })
                .defaulting(to: [HTTP.BatchSubResponse<R>.self])
            
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
        
        private init<U: Decodable>(
            request: URLRequest,
            server: String,
            publicKey: String,
            originalType: U.Type,
            responseType: R.Type,
            timeout: TimeInterval,
            responseConverter: @escaping (ResponseInfoType, Any) throws -> R,
            method: HTTPMethod,
            endpoint: Endpoint,
            path: String,
            batchEndpoints: [Endpoint],
            batchResponseTypes: [Decodable.Type],
            jsonBodyEncoder: ((inout KeyedEncodingContainer<BatchRequest.Child.CodingKeys>, BatchRequest.Child.CodingKeys) throws -> ())?,
            b64: String?,
            bytes: [UInt8]?
        ) {
            self.request = request
            self.server = server
            self.publicKey = publicKey
            self.originalType = originalType
            self.responseType = responseType
            self.timeout = timeout
            self.responseConverter = responseConverter
            
            // The following data is needed in this type for handling batch requests
            self.method = method
            self.endpoint = endpoint
            self.path = path
            self.batchEndpoints = batchEndpoints
            self.batchResponseTypes = batchResponseTypes
            self.jsonBodyEncoder = jsonBodyEncoder
            self.b64 = b64
            self.bytes = bytes
        }
        
        // MARK: - ErasedPreparedSendData
        
        public func encodeForBatchRequest(to encoder: Encoder) throws {
            var container: KeyedEncodingContainer<BatchRequest.Child.CodingKeys> = encoder.container(keyedBy: BatchRequest.Child.CodingKeys.self)
            
            // Exclude request signature headers (not used for sub-requests)
            let batchRequestHeaders: [String: String] = (request.allHTTPHeaderFields ?? [:])
                .filter { key, _ in
                    key.lowercased() != HTTPHeader.sogsPubKey.lowercased() &&
                    key.lowercased() != HTTPHeader.sogsTimestamp.lowercased() &&
                    key.lowercased() != HTTPHeader.sogsNonce.lowercased() &&
                    key.lowercased() != HTTPHeader.sogsSignature.lowercased()
                }
            
            if !batchRequestHeaders.isEmpty {
                try container.encode(batchRequestHeaders, forKey: .headers)
            }

            try container.encode(method, forKey: .method)
            try container.encode(path, forKey: .path)
            try jsonBodyEncoder?(&container, .json)
            try container.encodeIfPresent(b64, forKey: .b64)
            try container.encodeIfPresent(bytes, forKey: .bytes)
        }
    }
}

public extension OpenGroupAPI.PreparedSendData {
    func map<O>(transform: @escaping (ResponseInfoType, R) throws -> O) -> OpenGroupAPI.PreparedSendData<O> {
        return OpenGroupAPI.PreparedSendData(
            request: request,
            server: server,
            publicKey: publicKey,
            originalType: originalType,
            responseType: O.self,
            timeout: timeout,
            responseConverter: { info, response in
                let validResponse: R = try responseConverter(info, response)
                
                return try transform(info, validResponse)
            },
            method: method,
            endpoint: endpoint,
            path: path,
            batchEndpoints: batchEndpoints,
            batchResponseTypes: batchResponseTypes,
            jsonBodyEncoder: jsonBodyEncoder,
            b64: b64,
            bytes: bytes
        )
    }
}

// MARK: - Convenience

public extension Publisher where Output == (ResponseInfoType, Data?), Failure == Error {
    func decoded<R>(
        with preparedData: OpenGroupAPI.PreparedSendData<R>,
        using dependencies: Dependencies
    ) -> AnyPublisher<(ResponseInfoType, R), Error> {
        self
            .tryMap { responseInfo, maybeData -> (ResponseInfoType, R) in
                // Depending on the 'originalType' we need to process the response differently
                let targetData: Any = try {
                    switch preparedData.originalType {
                        case is OpenGroupAPI.BatchResponse.Type:
                            let responses: [Decodable] = try HTTP.BatchResponse.decodingResponses(
                                from: maybeData,
                                as: preparedData.batchResponseTypes,
                                requireAllResults: true,
                                using: dependencies
                            )
                            
                            return OpenGroupAPI.BatchResponse(
                                info: responseInfo,
                                data: Swift.zip(preparedData.batchEndpoints, responses)
                                    .reduce(into: [:]) { result, next in
                                        result[next.0] = next.1
                                    }
                            )
                            
                        case is NoResponse.Type: return NoResponse()
                        case is Optional<Data>.Type: return maybeData as Any
                        case is Data.Type: return try maybeData ?? { throw HTTPError.parsingFailed }()
                        
                        case is _OptionalProtocol.Type:
                            guard let data: Data = maybeData else { return maybeData as Any }
                            
                            return try preparedData.originalType.decoded(from: data, using: dependencies)
                        
                        default:
                            guard let data: Data = maybeData else { throw HTTPError.parsingFailed }
                            
                            return try preparedData.originalType.decoded(from: data, using: dependencies)
                    }
                }()
                
                // Generate and return the converted data
                let convertedData: R = try preparedData.responseConverter(responseInfo, targetData)
                
                return (responseInfo, convertedData)
            }
            .eraseToAnyPublisher()
    }
}

// MARK: - _OptionalProtocol

/// This protocol should only be used within this file and is used to distinguish between `Any.Type` and `Optional<Any>.Type` as
/// it seems that `is Optional<Any>.Type` doesn't work nicely but this protocol works nicely as long as the case is under any explicit
/// `Optional<T>` handling that we need
private protocol _OptionalProtocol {}

extension Optional: _OptionalProtocol {}
