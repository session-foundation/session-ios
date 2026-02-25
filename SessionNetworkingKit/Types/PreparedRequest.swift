// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import SessionUtilitiesKit

// MARK: - Network.PreparedRequest<R>

public extension Network {
    struct PreparedRequest<R> {
        public let endpoint: (any EndpointType)
        public let destination: Destination
        public let body: Data?
        public let category: RequestCategory
        public let requestTimeout: TimeInterval
        public let overallTimeout: TimeInterval?
        public let retryCount: Int
        public let additionalSignatureData: Any?
        public let originalType: Decodable.Type
        public let responseType: R.Type
        fileprivate let responseConverter: ((ResponseInfoType, Any) throws -> R)
        public let postSendAction: (() -> Void)?
        
        // The following types are needed for `BatchRequest` handling
        public let method: HTTPMethod
        public let path: String
        public let endpointName: String
        public let headers: [HTTPHeader: String]
        public let batchEndpoints: [any EndpointType]
        public let batchRequestVariant: Network.BatchRequest.Child.Variant
        public let batchResponseTypes: [Decodable.Type]
        public let requireAllBatchResponses: Bool
        public let excludedSubRequestHeaders: [HTTPHeader]
        
        private let jsonKeyedBodyEncoder: ((inout KeyedEncodingContainer<Network.BatchRequest.Child.CodingKeys>, Network.BatchRequest.Child.CodingKeys) throws -> ())?
        private let jsonBodyEncoder: ((inout SingleValueEncodingContainer) throws -> ())?
        private let b64: String?
        private let bytes: [UInt8]?
        
        public init<T: Encodable, E: EndpointType>(
            request: Request<T, E>,
            responseType: R.Type,
            requireAllBatchResponses: Bool = true,
            using dependencies: Dependencies
        ) throws where R: Decodable {
            try self.init(
                request: request,
                responseType: responseType,
                additionalSignatureData: NoSignature.null,
                requireAllBatchResponses: requireAllBatchResponses,
                using: dependencies
            )
        }
        
        public init<T: Encodable, E: EndpointType, S>(
            request: Request<T, E>,
            responseType: R.Type,
            additionalSignatureData: S?,
            requireAllBatchResponses: Bool = true,
            using dependencies: Dependencies
        ) throws where R: Decodable {
            let batchRequests: [Network.BatchRequest.Child]? = (request.body as? BatchRequestChildRetrievable)?.requests
            let batchEndpoints: [E] = (batchRequests?
                .compactMap { $0.request.batchRequestEndpoint(of: E.self) })
                .defaulting(to: [])
            let batchResponseTypes: [Decodable.Type]? = (batchRequests?
                .compactMap { batchRequest -> [Decodable.Type]? in
                    guard batchRequest.request.batchRequestEndpoint(of: E.self) != nil else { return nil }
                    
                    return batchRequest.request.batchResponseTypes
                }
                .flatMap { $0 })
            
            self.endpoint = request.endpoint
            self.destination = request.destination
            self.body = try request.bodyData(using: dependencies)
            self.category = request.category
            self.requestTimeout = request.requestTimeout
            self.overallTimeout = request.overallTimeout
            self.retryCount = request.retryCount
            self.additionalSignatureData = additionalSignatureData
            self.originalType = R.self
            self.responseType = responseType
            
            // When we are making a batch request we also want to call though any sub request event
            // handlers (this allows a lot more reusability for individual requests to manage their
            // own results or custom handling just when triggered via a batch request)
            self.responseConverter = PreparedRequest.batchResponseConverter(
                batchRequests: batchRequests,
                batchEndpoints: batchEndpoints
            )
            self.postSendAction = nil
            
            // The following data is needed in this type for handling batch requests
            self.method = request.destination.method
            self.endpointName = E.name
            self.path = Destination.generatePathWithParamsAndFragments(
                endpoint: endpoint,
                queryParameters: request.destination.queryParameters,
                fragmentParameters: request.destination.fragmentParameters
            )
            self.headers = request.destination.headers
            
            self.batchEndpoints = batchEndpoints
            self.batchRequestVariant = E.batchRequestVariant
            self.batchResponseTypes = batchResponseTypes.defaulting(to: [Network.BatchSubResponse<R>.self])
            self.requireAllBatchResponses = requireAllBatchResponses
            self.excludedSubRequestHeaders = E.excludedSubRequestHeaders
            
            if batchRequests != nil && self.batchEndpoints.count != self.batchResponseTypes.count {
                Log.error("[PreparedRequest] Created with invalid sub requests")
            }
            
            // Note: Need to differentiate between JSON, b64 string and bytes body values to ensure
            // they are encoded correctly so the server knows how to handle them
            switch request.body {
                case let bodyString as String:
                    self.jsonKeyedBodyEncoder = nil
                    self.jsonBodyEncoder = nil
                    self.b64 = bodyString
                    self.bytes = nil
                    
                case let bodyBytes as [UInt8]:
                    self.jsonKeyedBodyEncoder = nil
                    self.jsonBodyEncoder = nil
                    self.b64 = nil
                    self.bytes = bodyBytes
                    
                default:
                    self.jsonKeyedBodyEncoder = { [body = request.body] container, key in
                        try container.encodeIfPresent(body, forKey: key)
                    }
                    self.jsonBodyEncoder = { [body = request.body] container in
                        try container.encode(body)
                    }
                    self.b64 = nil
                    self.bytes = nil
            }
        }
        
        fileprivate init<U: Decodable>(
            endpoint: (any EndpointType),
            destination: Destination,
            body: Data?,
            category: Network.RequestCategory,
            requestTimeout: TimeInterval,
            overallTimeout: TimeInterval?,
            retryCount: Int,
            additionalSignatureData: Any?,
            originalType: U.Type,
            responseType: R.Type,
            responseConverter: @escaping (ResponseInfoType, Any) throws -> R,
            postSendAction: (() -> Void)?,
            method: HTTPMethod,
            endpointName: String,
            headers: [HTTPHeader: String],
            path: String,
            batchEndpoints: [any EndpointType],
            batchRequestVariant: Network.BatchRequest.Child.Variant,
            batchResponseTypes: [Decodable.Type],
            requireAllBatchResponses: Bool,
            excludedSubRequestHeaders: [HTTPHeader],
            jsonKeyedBodyEncoder: ((inout KeyedEncodingContainer<Network.BatchRequest.Child.CodingKeys>, Network.BatchRequest.Child.CodingKeys) throws -> ())?,
            jsonBodyEncoder: ((inout SingleValueEncodingContainer) throws -> ())?,
            b64: String?,
            bytes: [UInt8]?
        ) {
            self.endpoint = endpoint
            self.destination = destination
            self.body = body
            self.category = category
            self.requestTimeout = requestTimeout
            self.overallTimeout = overallTimeout
            self.retryCount = retryCount
            self.additionalSignatureData = additionalSignatureData
            self.originalType = originalType
            self.responseType = responseType
            self.responseConverter = responseConverter
            self.postSendAction = postSendAction
            
            // The following data is needed in this type for handling batch requests
            self.method = method
            self.endpointName = endpointName
            self.headers = headers
            self.path = path
            self.batchEndpoints = batchEndpoints
            self.batchRequestVariant = batchRequestVariant
            self.batchResponseTypes = batchResponseTypes
            self.requireAllBatchResponses = requireAllBatchResponses
            self.excludedSubRequestHeaders = excludedSubRequestHeaders
            self.jsonKeyedBodyEncoder = jsonKeyedBodyEncoder
            self.jsonBodyEncoder = jsonBodyEncoder
            self.b64 = b64
            self.bytes = bytes
        }
        
        // MARK: - Functions
        
        public func generateUrl() throws -> URL {
            switch destination {
                case .server(let info), .serverUpload(let info, _):
                    let pathWithParamsAndFrags: String = Destination.generatePathWithParamsAndFragments(
                        endpoint: endpoint,
                        queryParameters: info.queryParameters,
                        fragmentParameters: info.fragmentParameters
                    )
                    
                    guard let url: URL = URL(string: "\(info.server)\(pathWithParamsAndFrags)") else {
                        throw NetworkError.invalidURL
                    }
                    
                    return url
                
                default: throw NetworkError.invalidURL
            }
        }
        
        public func withPostSendAction(_ postSendAction: @escaping () -> Void) -> PreparedRequest<R> {
            return PreparedRequest(
                endpoint: endpoint,
                destination: destination,
                body: body,
                category: category,
                requestTimeout: requestTimeout,
                overallTimeout: overallTimeout,
                retryCount: retryCount,
                additionalSignatureData: additionalSignatureData,
                originalType: originalType,
                responseType: responseType,
                responseConverter: responseConverter,
                postSendAction: postSendAction,
                method: method,
                endpointName: endpointName,
                headers: headers,
                path: path,
                batchEndpoints: batchEndpoints,
                batchRequestVariant: batchRequestVariant,
                batchResponseTypes: batchResponseTypes,
                requireAllBatchResponses: requireAllBatchResponses,
                excludedSubRequestHeaders: excludedSubRequestHeaders,
                jsonKeyedBodyEncoder: jsonKeyedBodyEncoder,
                jsonBodyEncoder: jsonBodyEncoder,
                b64: b64,
                bytes: bytes
            )
        }
    }
}

// MARK: - ErasedPreparedRequest

public protocol ErasedPreparedRequest {
    var endpointName: String { get }
    var batchRequestVariant: Network.BatchRequest.Child.Variant { get }
    var batchResponseTypes: [Decodable.Type] { get }
    var excludedSubRequestHeaders: [HTTPHeader] { get }
    
    var erasedResponseConverter: ((ResponseInfoType, Any) throws -> Any) { get }
    
    func batchRequestEndpoint<E: EndpointType>(of type: E.Type) -> E?
    func encodeForBatchRequest(to encoder: Encoder) throws
}

extension Network.PreparedRequest: ErasedPreparedRequest {
    public var erasedResponseConverter: ((ResponseInfoType, Any) throws -> Any) {
        let originalType: Decodable.Type = self.originalType
        let converter: ((ResponseInfoType, Any) throws -> R) = self.responseConverter
        
        return { info, data in
            switch data {
                case let subResponse as ErasedBatchSubResponse:
                    return Network.BatchSubResponse(
                        code: subResponse.code,
                        headers: subResponse.headers,
                        body: try originalType.from(subResponse.erasedBody).map { try converter(info, $0) },
                        failedToParseBody: subResponse.failedToParseBody
                    )
                    
                default: return try originalType.from(data).map { try converter(info, $0) } as Any
            }
        }
    }
    
    public func batchRequestEndpoint<E: EndpointType>(of type: E.Type) -> E? {
        return (endpoint as? E)
    }
    
    public func encodeForBatchRequest(to encoder: Encoder) throws {
        var container: KeyedEncodingContainer<Network.BatchRequest.Child.CodingKeys> = encoder.container(keyedBy: Network.BatchRequest.Child.CodingKeys.self)
        
        switch batchRequestVariant {
            case .unsupported:
                Log.critical("Attempted to encode unsupported request type \(endpointName) as a batch subrequest")
                
            case .sogs:
                // Exclude request signature headers (not used for sub-requests)
                let excludedSubRequestHeaders: [HTTPHeader] = excludedSubRequestHeaders
                let batchRequestHeaders: [HTTPHeader: String] = headers
                    .filter { key, _ in !excludedSubRequestHeaders.contains(key) }
                
                if !batchRequestHeaders.isEmpty {
                    try container.encode(batchRequestHeaders, forKey: .headers)
                }
                
                try container.encode(method, forKey: .method)
                try container.encode(path, forKey: .path)
                try jsonKeyedBodyEncoder?(&container, .json)
                try container.encodeIfPresent(b64, forKey: .b64)
                try container.encodeIfPresent(bytes, forKey: .bytes)
                
            case .storageServer:
                try container.encode(endpoint.path, forKey: .method)
                try jsonKeyedBodyEncoder?(&container, .params)
                
        }
    }
}

// MARK: - Transformations

public extension Network.PreparedRequest {
    func signed(
        with requestSigner: (Network.PreparedRequest<R>, Dependencies) throws -> Network.Destination,
        using dependencies: Dependencies
    ) throws -> Network.PreparedRequest<R> {
        let signedDestination: Network.Destination = try requestSigner(self, dependencies)
        
        return Network.PreparedRequest(
            endpoint: endpoint,
            destination: signedDestination,
            body: body,
            category: category,
            requestTimeout: requestTimeout,
            overallTimeout: overallTimeout,
            retryCount: retryCount,
            additionalSignatureData: additionalSignatureData,
            originalType: originalType,
            responseType: responseType,
            responseConverter: responseConverter,
            postSendAction: postSendAction,
            method: method,
            endpointName: endpointName,
            headers: signedDestination.headers,
            path: path,
            batchEndpoints: batchEndpoints,
            batchRequestVariant: batchRequestVariant,
            batchResponseTypes: batchResponseTypes,
            requireAllBatchResponses: requireAllBatchResponses,
            excludedSubRequestHeaders: excludedSubRequestHeaders,
            jsonKeyedBodyEncoder: jsonKeyedBodyEncoder,
            jsonBodyEncoder: jsonBodyEncoder,
            b64: b64,
            bytes: bytes
        )
    }
    
    func discardingResponse() -> Network.PreparedRequest<Void> {
        return tryMap { _, _ in () }
    }
    
    /// Due to the way prepared requests work we need to cast between different types and as a result can't avoid potentially
    /// throwing when mapping so the `map` function just calls through to the `tryMap` function, but we have both to make
    /// the interface more consistent for dev use
    func map<O>(transform: @escaping (ResponseInfoType, R) -> O) -> Network.PreparedRequest<O> {
        return tryMap(transform: transform)
    }
    
    func tryMap<O>(transform: @escaping (ResponseInfoType, R) throws -> O) -> Network.PreparedRequest<O> {
        let originalConverter: ((ResponseInfoType, Any) throws -> R) = self.responseConverter
        let responseConverter: ((ResponseInfoType, Any) throws -> O) = { info, response in
            let validResponse: R = try originalConverter(info, response)
            
            return try transform(info, validResponse)
        }
        
        return Network.PreparedRequest<O>(
            endpoint: endpoint,
            destination: destination,
            body: body,
            category: category,
            requestTimeout: requestTimeout,
            overallTimeout: overallTimeout,
            retryCount: retryCount,
            additionalSignatureData: additionalSignatureData,
            originalType: originalType,
            responseType: O.self,
            responseConverter: responseConverter,
            postSendAction: postSendAction,
            method: method,
            endpointName: endpointName,
            headers: headers,
            path: path,
            batchEndpoints: batchEndpoints,
            batchRequestVariant: batchRequestVariant,
            batchResponseTypes: batchResponseTypes,
            requireAllBatchResponses: requireAllBatchResponses,
            excludedSubRequestHeaders: excludedSubRequestHeaders,
            jsonKeyedBodyEncoder: jsonKeyedBodyEncoder,
            jsonBodyEncoder: jsonBodyEncoder,
            b64: b64,
            bytes: bytes
        )
    }
    
    private static func batchResponseConverter<E: EndpointType>(
        batchRequests: [Network.BatchRequest.Child]?,
        batchEndpoints: [E]
    ) -> (ResponseInfoType, Any) throws -> R {
        guard
            let subRequestResponseConverters: [(Int, ((ResponseInfoType, Any) throws -> Any))] = batchRequests?
                .enumerated()
                .compactMap({ ($0.0, $0.1.request.erasedResponseConverter) }),
            !subRequestResponseConverters.isEmpty
        else {
            return { info, response in
                guard let validResponse: R = response as? R else { throw NetworkError.invalidResponse }
                
                return validResponse
            }
        }
        
        // Results are returned in the same order they were made in so we can use the matching
        // indexes to get the correct response
        return { info, response in
            let convertedResponse: Any = try {
                switch response {
                    case let batchResponse as Network.BatchResponse:
                        return Network.BatchResponse(
                            data: try subRequestResponseConverters
                                .map { index, responseConverter in
                                    guard batchResponse.count > index else {
                                        throw NetworkError.invalidResponse
                                    }
                                    
                                    return try responseConverter(info, batchResponse[index])
                                }
                        )
                    
                    case let batchResponseMap as Network.BatchResponseMap<E>:
                        return Network.BatchResponseMap(
                            data: try subRequestResponseConverters
                                .reduce(into: [E: Any]()) { result, subResponse in
                                    let index: Int = subResponse.0
                                    let responseConverter: ((ResponseInfoType, Any) throws -> Any) = subResponse.1
                                    
                                    guard
                                        batchEndpoints.count > index,
                                        let targetResponse: Any = batchResponseMap[batchEndpoints[index]]
                                    else { throw NetworkError.invalidResponse }
                                    
                                    let endpoint: E = batchEndpoints[index]
                                    result[endpoint] = try responseConverter(info, targetResponse)
                                }
                        )
                    
                    default: throw NetworkError.invalidResponse
                }
            }()
            
            guard let validResponse: R = convertedResponse as? R else {
                Log.error("[PreparedRequest] Unable to convert responses for missing response")
                throw NetworkError.invalidResponse
            }
            
            return validResponse
        }
    }
}

// MARK: - Decoding

public extension Decodable {
    fileprivate static func from(_ value: Any?) -> Self? {
        return (value as? Self)
    }
    
    static func decoded(from data: Data, using dependencies: Dependencies) throws -> Self {
        return try data.decoded(as: Self.self, using: dependencies)
    }
}

public extension Network.PreparedRequest {
    func decode(
        info: ResponseInfoType,
        data: Data?,
        using dependencies: Dependencies
    ) throws -> (originalData: Any, convertedData: R) {
        // Depending on the 'originalType' we need to process the response differently
        let targetData: Any = try {
            switch originalType {
                case let erasedBatchResponse as ErasedBatchResponseMap.Type:
                    let response: Network.BatchResponse = try Network.BatchResponse.decodingResponses(
                        from: data,
                        as: batchResponseTypes,
                        requireAllResults: requireAllBatchResponses,
                        using: dependencies
                    )
                    
                    return try erasedBatchResponse.from(
                        batchEndpoints: batchEndpoints,
                        response: response
                    )
                
                case is Network.BatchResponse.Type:
                    return try Network.BatchResponse.decodingResponses(
                        from: data,
                        as: batchResponseTypes,
                        requireAllResults: requireAllBatchResponses,
                        using: dependencies
                    )
                    
                case is NoResponse.Type: return NoResponse()
                case is Optional<Data>.Type: return data as Any
                case is Data.Type: return try data ?? { throw NetworkError.parsingFailed }()
                
                case is _OptionalProtocol.Type:
                    guard let data: Data = data else { return data as Any }
                    
                    return try originalType.decoded(from: data, using: dependencies)
                
                default:
                    guard let data: Data = data else { throw NetworkError.parsingFailed }
                    
                    return try originalType.decoded(from: data, using: dependencies)
            }
        }()
        
        // Generate and return the converted data
        return (targetData, try responseConverter(info, targetData))
    }
}

// MARK: - _OptionalProtocol

/// This protocol should only be used within this file and is used to distinguish between `Any.Type` and `Optional<Any>.Type` as
/// it seems that `is Optional<Any>.Type` doesn't work nicely but this protocol works nicely as long as the case is under any explicit
/// `Optional<T>` handling that we need
private protocol _OptionalProtocol {}

extension Optional: _OptionalProtocol {}
