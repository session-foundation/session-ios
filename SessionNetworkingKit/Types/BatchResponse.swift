// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import SessionUtilitiesKit

public extension Network {
    // MARK: - Network.BatchResponse

    struct BatchResponse: Decodable, Collection {
        public let data: [Any]
        
        // MARK: - Collection Conformance
        
        public var startIndex: Int { data.startIndex }
        public var endIndex: Int { data.endIndex }
        public var count: Int { data.count }
        
        public subscript(index: Int) -> Any { data[index] }
        public func index(after i: Int) -> Int { return data.index(after: i) }
        
        // MARK: - Initialization
        
        init(data: [Any]) {
            self.data = data
        }
        
        public init(from decoder: Decoder) throws {
#if DEBUG
            preconditionFailure("The `Network.BatchResponse` type cannot be decoded directly, this is simply here to allow for `PreparedSendData<Network.BatchResponse>` support")
#else
            data = []
#endif
        }
    }
    
    // MARK: - BatchResponseMap<E>
    
    struct BatchResponseMap<E: EndpointType>: Decodable, ErasedBatchResponseMap {
        public let data: [E: Any]
        
        public subscript(position: E) -> Any? {
            get { return data[position] }
        }
        
        public var count: Int { data.count }
        public var keys: Dictionary<E, Any>.Keys { data.keys }
        public var values: Dictionary<E, Any>.Values { data.values }
        
        // MARK: - Initialization
        
        init(data: [E: Any]) {
            self.data = data
        }
        
        public init(from decoder: Decoder) throws {
#if DEBUG
            preconditionFailure("The `Network.BatchResponseMap` type cannot be decoded directly, this is simply here to allow for `PreparedSendData<Network.BatchResponseMap>` support")
#else
            data = [:]
#endif
        }
        
        // MARK: - ErasedBatchResponseMap
        
        public static func from(
            batchEndpoints: [any EndpointType],
            response: Network.BatchResponse
        ) throws -> Self {
            let convertedEndpoints: [E] = batchEndpoints.compactMap { $0 as? E }
            
            guard convertedEndpoints.count == response.data.count else { throw NetworkError.parsingFailed }
            
            return BatchResponseMap(
                data: zip(convertedEndpoints, response.data)
                    .reduce(into: [:]) { result, next in
                        result[next.0] = next.1
                    }
            )
        }
    }
    
    // MARK: - BatchSubResponse<T>
    
    struct BatchSubResponse<T>: ErasedBatchSubResponse {
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
        
        public var erasedBody: Any? { body }
        
        /// A flag to indicate that there was a body but it failed to parse
        public let failedToParseBody: Bool
        
        public init(
            code: Int,
            headers: [String: String] = [:],
            body: T? = nil,
            failedToParseBody: Bool
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
        response: Network.BatchResponse
    ) throws -> Self
}

// MARK: - BatchSubResponse<T> Coding

extension Network.BatchSubResponse: Encodable where T: Encodable {}
extension Network.BatchSubResponse: Decodable {
    public init(from decoder: Decoder) throws {
        let container: KeyedDecodingContainer<CodingKeys> = try decoder.container(keyedBy: CodingKeys.self)
        let body: T? = ((try? (T.self as? Decodable.Type)?.decoded(with: container, forKey: .body)) as? T)
        
        self = Network.BatchSubResponse(
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

// MARK: - ErasedBatchSubResponse

public protocol ErasedBatchSubResponse: ResponseInfoType {
    var code: Int { get }
    var erasedBody: Any? { get }
    var failedToParseBody: Bool { get }
}

// MARK: - Convenience

internal extension Network.BatchResponse {
    /// Re-serialise one sub-response so it can be decoded as its own type, **failing the whole response rather than losing it**
    ///
    /// Two hazards live in this one call, and neither is what it looks like:
    ///
    /// - **Losing an element is not survivable.** `decodingResponses` pairs sub-responses to their expected types by
    ///   **position** (`zip` below), and callers pair them to *their* requests by position too. Dropping one silently shifts
    ///   every later response onto the wrong request, which **misattributes** rather than fails - on the config path that means
    ///   expiry detection reporting hashes it never asked about, and configs re-stored that were never lost. Nothing throws and
    ///   nothing looks wrong. So this maps rather than compact-maps: a sub-response we can't handle fails the response.
    ///
    /// - **`data(withJSONObject:)` RAISES rather than throws.** For an invalid top-level type it raises
    ///   `NSInvalidArgumentException`, which is an Objective-C exception - `try?` cannot catch it and the process aborts. Every
    ///   element `JSONSerialization.jsonObject` can produce is either a container (valid, always serialises) or a **scalar**
    ///   (`NSNumber`/`NSString`/`NSNull`/`NSCFBoolean` - never valid), so a response like `{"results":[1]}` is not a parse
    ///   failure, it is a **crash**. `isValidJSONObject` is the same predicate the raise is guarded on, so checking it first is
    ///   what converts that into a recoverable error
    private static func reserialised(subResponse: Any) throws -> Data {
        guard JSONSerialization.isValidJSONObject(subResponse) else { throw NetworkError.parsingFailed }

        return try JSONSerialization.data(withJSONObject: subResponse)
    }

    // stringlint:ignore_contents
    static func decodingResponses(
        from data: Data?,
        as types: [Decodable.Type],
        requireAllResults: Bool,
        using dependencies: Dependencies
    ) throws -> Network.BatchResponse {
        // Need to split the data into an array of data so each item can be Decoded correctly
        guard let data: Data = data else { throw NetworkError.parsingFailed }
        guard let jsonObject: Any = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            throw NetworkError.parsingFailed
        }
        
        let dataArray: [Data]
        
        switch jsonObject {
            /// The **SOGS** shape - `sogs/routes/general.py` returns a plain list rather than wrapping it, which is the only
            /// reason this branch exists alongside the one below
            case let anyArray as [Any]:
                /// Same handling as the storage-server branch, and for the same two reasons - a lost sub-response shifts every
                /// later one onto the wrong request, and `data(withJSONObject:)` raises rather than throws. See
                /// `reserialised(subResponse:)`
                dataArray = try anyArray.map { try Self.reserialised(subResponse: $0) }

                guard !requireAllResults || dataArray.count == types.count else {
                    throw NetworkError.parsingFailed
                }

            /// The **storage server** shape - `batch` and `sequence` both wrap their sub-results in `results`, and there is no
            /// bare-array response path from it, so this is the branch every config poll and config recovery takes
            case let anyDict as [String: Any]:
                guard let subResponses: [Any] = anyDict["results"] as? [Any] else { throw NetworkError.parsingFailed }

                /// `map`, not `compactMap` - see `reserialised(subResponse:)` for why losing one is worse than failing all of
                /// them, and why this cannot be left to `try?`
                let resultsArray: [Data] = try subResponses.map { try Self.reserialised(subResponse: $0) }

                guard !requireAllResults || resultsArray.count == types.count else { throw NetworkError.parsingFailed }

                dataArray = resultsArray
                
            default: throw NetworkError.parsingFailed
        }
        
        return Network.BatchResponse(
            data: try zip(dataArray, types)
                .map { data, type in try type.decoded(from: data, using: dependencies) }
        )
    }
}
