// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import PromiseKit

public extension HTTP {
    // MARK: - Convenience Aliases
    
    typealias BatchResponse = [(ResponseInfoType, Codable?)]
    typealias BatchResponseTypes = [Codable.Type]
    
    // MARK: - BatchSubResponse<T>
    
    struct BatchSubResponse<T: Codable>: Codable {
        /// The numeric http response code (e.g. 200 for success)
        public let code: Int32
        
        /// Any headers returned by the request
        public let headers: [String: String]
        
        /// The body of the request; will be plain json if content-type is `application/json`, otherwise it will be base64 encoded data
        public let body: T?
        
        /// A flag to indicate that there was a body but it failed to parse
        public let failedToParseBody: Bool
        
        public init(
            code: Int32,
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

public extension HTTP.BatchSubResponse {
    init(from decoder: Decoder) throws {
        let container: KeyedDecodingContainer<CodingKeys> = try decoder.container(keyedBy: CodingKeys.self)
        let body: T? = try? container.decode(T.self, forKey: .body)
        
        self = HTTP.BatchSubResponse(
            code: try container.decode(Int32.self, forKey: .code),
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

public extension Decodable {
    static func decoded(from data: Data, using dependencies: Dependencies = Dependencies()) throws -> Self {
        return try data.decoded(as: Self.self, using: dependencies)
    }
}

public extension Promise where T == (ResponseInfoType, Data?) {
    func decoded(as types: HTTP.BatchResponseTypes, on queue: DispatchQueue? = nil, using dependencies: Dependencies = Dependencies()) -> Promise<HTTP.BatchResponse> {
        self.map(on: queue) { responseInfo, maybeData -> HTTP.BatchResponse in
            // Need to split the data into an array of data so each item can be Decoded correctly
            guard let data: Data = maybeData else { throw HTTPError.parsingFailed }
            guard let jsonObject: Any = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
                throw HTTPError.parsingFailed
            }
            
            let dataArray: [Data]
            
            switch jsonObject {
                case let anyArray as [Any]:
                    dataArray = anyArray.compactMap { try? JSONSerialization.data(withJSONObject: $0) }
                    
                    guard dataArray.count == types.count else { throw HTTPError.parsingFailed }
                    
                case let anyDict as [String: Any]:
                    guard
                        let resultsArray: [Data] = (anyDict["results"] as? [Any])?
                            .compactMap({ try? JSONSerialization.data(withJSONObject: $0) }),
                        resultsArray.count == types.count
                    else { throw HTTPError.parsingFailed }
                    
                    dataArray = resultsArray
                    
                default: throw HTTPError.parsingFailed
            }
            
            do {
                return try zip(dataArray, types)
                    .map { data, type in try type.decoded(from: data, using: dependencies) }
                    .map { data in (responseInfo, data) }
            }
            catch {
                throw HTTPError.parsingFailed
            }
        }
    }
}
