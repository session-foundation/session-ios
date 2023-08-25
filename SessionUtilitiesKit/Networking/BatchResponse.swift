// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine

public extension HTTP {
    // MARK: - HTTP.BatchResponse
    
    typealias BatchResponse = [Decodable]
    
    // MARK: - BatchResponseMap<E>
    
    struct BatchResponseMap<E: EndpointType>: Decodable, ErasedBatchResponseMap {
        public let data: [E: Decodable]
        
        public subscript(position: E) -> Decodable? {
            get { return data[position] }
        }
        
        public var count: Int { data.count }
        public var keys: Dictionary<E, Decodable>.Keys { data.keys }
        public var values: Dictionary<E, Decodable>.Values { data.values }
        
        // MARK: - Initialization
        
        init(data: [E: Decodable]) {
            self.data = data
        }
        
        public init(from decoder: Decoder) throws {
#if DEBUG
            preconditionFailure("The `HTTP.BatchResponseMap` type cannot be decoded directly, this is simply here to allow for `PreparedSendData<HTTP.BatchResponseMap>` support")
#else
            data = [:]
#endif
        }
        
        // MARK: - ErasedBatchResponseMap
        
        public static func from(
            batchEndpoints: [any EndpointType],
            responses: [Decodable]
        ) throws -> Self {
            let convertedEndpoints: [E] = batchEndpoints.compactMap { $0 as? E }
            
            guard convertedEndpoints.count == responses.count else { throw HTTPError.parsingFailed }
            
            return BatchResponseMap(
                data: zip(convertedEndpoints, responses)
                    .reduce(into: [:]) { result, next in
                        result[next.0] = next.1
                    }
            )
        }
    }
    
    // MARK: - BatchSubResponse<T>
    
    struct BatchSubResponse<T>: ResponseInfoType {
        public enum CodingKeys: String, CodingKey {
            case code
            case headers
            case body
        }
        
        /// The numeric http response code (e.g. 200 for success)
        public let code: Int
        
        /// Any headers returned by the request
        public let headers: [String: String]
        
        /// The body of the request; will be plain json if content-type is `application/json`, otherwise it will be base64 encoded data
        public let body: T?
        
        /// A flag to indicate that there was a body but it failed to parse
        public let failedToParseBody: Bool
        
        public init(
            code: Int,
            headers: [String: String] = [:],
            body: T? = nil,
            failedToParseBody: Bool = false
        ) {
            self.code = code
            self.headers = headers
            self.body = body
            self.failedToParseBody = failedToParseBody
        }
    }
}

// MARK: - ErasedBatchResponseMap

public protocol ErasedBatchResponseMap {
    static func from(
        batchEndpoints: [any EndpointType],
        responses: [Decodable]
    ) throws -> Self
}

// MARK: - BatchSubResponse<T> Coding

extension HTTP.BatchSubResponse: Encodable where T: Encodable {}
extension HTTP.BatchSubResponse: Decodable {
    public init(from decoder: Decoder) throws {
        let container: KeyedDecodingContainer<CodingKeys> = try decoder.container(keyedBy: CodingKeys.self)
        let body: T? = ((try? (T.self as? Decodable.Type)?.decoded(with: container, forKey: .body)) as? T)
        
        self = HTTP.BatchSubResponse(
            code: try container.decode(Int.self, forKey: .code),
            headers: ((try? container.decode([String: String].self, forKey: .headers)) ?? [:]),
            body: body,
            failedToParseBody: (
                body == nil &&
                T.self != NoResponse.self &&
                !(T.self is ExpressibleByNilLiteral.Type)
            )
        )
    }
}

// MARK: - Convenience

internal extension HTTP.BatchResponse {
    static func decodingResponses(
        from data: Data?,
        as types: [Decodable.Type],
        requireAllResults: Bool,
        using dependencies: Dependencies = Dependencies()
    ) throws -> HTTP.BatchResponse {
        // Need to split the data into an array of data so each item can be Decoded correctly
        guard let data: Data = data else { throw HTTPError.parsingFailed }
        guard let jsonObject: Any = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            throw HTTPError.parsingFailed
        }
        
        let dataArray: [Data]
        
        switch jsonObject {
            case let anyArray as [Any]:
                dataArray = anyArray.compactMap { try? JSONSerialization.data(withJSONObject: $0) }
                
                guard !requireAllResults || dataArray.count == types.count else {
                    throw HTTPError.parsingFailed
                }
                
            case let anyDict as [String: Any]:
                guard
                    let resultsArray: [Data] = (anyDict["results"] as? [Any])?
                        .compactMap({ try? JSONSerialization.data(withJSONObject: $0) }),
                    (
                        !requireAllResults ||
                        resultsArray.count == types.count
                    )
                else { throw HTTPError.parsingFailed }
                
                dataArray = resultsArray
                
            default: throw HTTPError.parsingFailed
        }
        
        return try zip(dataArray, types)
            .map { data, type in try type.decoded(from: data, using: dependencies) }
    }
}

public extension Publisher where Output == (ResponseInfoType, Data?), Failure == Error {
    func decoded(
        as types: [Decodable.Type],
        requireAllResults: Bool = true,
        using dependencies: Dependencies = Dependencies()
    ) -> AnyPublisher<(ResponseInfoType, HTTP.BatchResponse), Error> {
        self
            .tryMap { responseInfo, maybeData -> (ResponseInfoType, HTTP.BatchResponse) in
                (
                    responseInfo,
                    try HTTP.BatchResponse.decodingResponses(
                        from: maybeData,
                        as: types,
                        requireAllResults: requireAllResults,
                        using: dependencies
                    )
                )
            }
            .eraseToAnyPublisher()
    }
}
