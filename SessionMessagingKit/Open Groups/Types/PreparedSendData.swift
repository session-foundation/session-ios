// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import SessionUtilitiesKit

public extension OpenGroupAPI {
    struct PreparedSendData<R> {
        internal let request: URLRequest
        internal let endpoint: Endpoint
        internal let server: String
        internal let publicKey: String
        internal let originalType: Decodable.Type
        internal let responseType: R.Type
        internal let timeout: TimeInterval
        internal let responseConverter: ((ResponseInfoType, Any) throws -> R)
        
        internal init(
            request: URLRequest,
            endpoint: Endpoint,
            server: String,
            publicKey: String,
            responseType: R.Type,
            timeout: TimeInterval
        ) where R: Decodable {
            self.request = request
            self.endpoint = endpoint
            self.server = server
            self.publicKey = publicKey
            self.originalType = responseType
            self.responseType = responseType
            self.timeout = timeout
            self.responseConverter = { _, response in
                guard let validResponse: R = response as? R else { throw HTTPError.invalidResponse }
                
                return validResponse
            }
        }
        
        private init<U: Decodable>(
            request: URLRequest,
            endpoint: Endpoint,
            server: String,
            publicKey: String,
            originalType: U.Type,
            responseType: R.Type,
            timeout: TimeInterval,
            responseConverter: @escaping (ResponseInfoType, Any) throws -> R
        ) {
            self.request = request
            self.endpoint = endpoint
            self.server = server
            self.publicKey = publicKey
            self.originalType = originalType
            self.responseType = responseType
            self.timeout = timeout
            self.responseConverter = responseConverter
        }
    }
}

public extension OpenGroupAPI.PreparedSendData {
    func map<O>(transform: @escaping (ResponseInfoType, R) throws -> O) -> OpenGroupAPI.PreparedSendData<O> {
        return OpenGroupAPI.PreparedSendData(
            request: request,
            endpoint: endpoint,
            server: server,
            publicKey: publicKey,
            originalType: originalType,
            responseType: O.self,
            timeout: timeout,
            responseConverter: { info, response in
                let validResponse: R = try responseConverter(info, response)
                
                return try transform(info, validResponse)
            }
        )
    }
}

// MARK: - Convenience

public extension Publisher where Output == (ResponseInfoType, Data?), Failure == Error {
    func decoded<R>(
        with preparedData: OpenGroupAPI.PreparedSendData<R>,
        using dependencies: Dependencies = Dependencies()
    ) -> AnyPublisher<(ResponseInfoType, R), Error> {
        self
            .tryMap { responseInfo, maybeData -> (ResponseInfoType, R) in
                // Depending on the 'originalType' we need to process the response differently
                let targetData: Any = try {
                    switch preparedData.originalType {
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
