// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB

// MARK: - HTTPRequestMetadata

public typealias HTTPRequestMetadata = String

// MARK: - HTTP.PreparedRequest<R>

public extension HTTP {
    struct PreparedRequest<R> {
        public let request: URLRequest
        public let server: String
        public let publicKey: String
        public let originalType: Decodable.Type
        public let responseType: R.Type
        public let metadata: [HTTPRequestMetadata: Any]
        public let retryCount: Int
        public let timeout: TimeInterval
        fileprivate let responseConverter: ((ResponseInfoType, Any) throws -> R)
        public let outputEventHandler: (((ResponseInfoType, R)) -> Void)?
        public let completionEventHandler: ((Subscribers.Completion<Error>) -> Void)?
        public let cancelEventHandler: (() -> Void)?
        
        // The following types are needed for `BatchRequest` handling
        public let method: HTTPMethod
        private let path: String
        public let endpoint: (any EndpointType)
        public let endpointName: String
        public let batchEndpoints: [any EndpointType]
        public let batchRequestVariant: HTTP.BatchRequest.Child.Variant
        public let batchResponseTypes: [Decodable.Type]
        public let excludedSubRequestHeaders: [String]
        
        /// The `jsonBodyEncoder` is used to simplify the encoding for `BatchRequest`
        private let jsonBodyEncoder: ((inout KeyedEncodingContainer<HTTP.BatchRequest.Child.CodingKeys>, HTTP.BatchRequest.Child.CodingKeys) throws -> ())?
        private let b64: String?
        private let bytes: [UInt8]?
        
        public init<T: Encodable, E: EndpointType>(
            request: Request<T, E>,
            urlRequest: URLRequest,
            publicKey: String,
            responseType: R.Type,
            metadata: [HTTPRequestMetadata: Any] = [:],
            retryCount: Int = 0,
            timeout: TimeInterval
        ) where R: Decodable {
            let batchRequests: [HTTP.BatchRequest.Child]? = (request.body as? HTTP.BatchRequest)?.requests
            let batchEndpoints: [E] = (batchRequests?
                .compactMap { $0.request.batchRequestEndpoint(of: E.self) })
                .defaulting(to: [])
            let batchResponseTypes: [Decodable.Type]? = (batchRequests?
                .compactMap { batchRequest -> [Decodable.Type]? in
                    guard batchRequest.request.batchRequestEndpoint(of: E.self) != nil else { return nil }
                    
                    return batchRequest.request.batchResponseTypes
                }
                .flatMap { $0 })
            
            self.request = urlRequest
            self.server = request.server
            self.publicKey = publicKey
            self.originalType = responseType
            self.responseType = responseType
            self.metadata = metadata
            self.retryCount = retryCount
            self.timeout = timeout
            self.responseConverter = { _, response in
                guard let validResponse: R = response as? R else { throw HTTPError.invalidResponse }
                
                return validResponse
            }
            
            // When we are making a batch request we also want to call though any sub request event
            // handlers (this allows a lot more reusability for individual requests to manage their
            // own results or custom handling just when triggered via a batch request)
            self.outputEventHandler = {
                guard
                    let subRequestEventHandlers: [(Int, (((ResponseInfoType, Any)) -> Void))] = batchRequests?
                        .enumerated()
                        .compactMap({ index, batchRequest in
                            batchRequest.request.erasedOutputEventHandler.map { (index, $0) }
                        }),
                    !subRequestEventHandlers.isEmpty
                else { return nil }
                
                // Results are returned in the same order they were made in so we can use the matching
                // indexes to get the correct response
                return { data in
                    switch data.1 {
                        case let batchResponse as HTTP.BatchResponse:
                            subRequestEventHandlers.forEach { index, eventHandler in
                                guard batchResponse.count > index else {
                                    SNLog("[PreparedRequest] Unable to handle output events for missing response")
                                    return
                                }
                                
                                eventHandler((data.0, batchResponse[index]))
                            }
                            
                        case let batchResponseMap as HTTP.BatchResponseMap<E>:
                            subRequestEventHandlers.forEach { index, eventHandler in
                                guard
                                    batchEndpoints.count > index,
                                    let targetResponse: Decodable = batchResponseMap[batchEndpoints[index]]
                                else {
                                    SNLog("[PreparedRequest] Unable to handle output events for missing response")
                                    return
                                }
                                
                                eventHandler((data.0, targetResponse))
                            }
                            
                        default: SNLog("[PreparedRequest] Unable to handle output events for unknown batch response type")
                    }
                }
            }()
            self.completionEventHandler = {
                guard
                    let subRequestEventHandlers: [((Subscribers.Completion<Error>) -> Void)] = batchRequests?
                        .compactMap({ $0.request.completionEventHandler }),
                    !subRequestEventHandlers.isEmpty
                else { return nil }
                
                // Since the completion event doesn't provide us with any data we can't return the
                // individual subRequest results here
                return { result in subRequestEventHandlers.forEach { $0(result) } }
            }()
            self.cancelEventHandler = {
                guard
                    let subRequestEventHandlers: [(() -> Void)] = batchRequests?
                        .compactMap({ $0.request.cancelEventHandler }),
                    !subRequestEventHandlers.isEmpty
                else { return nil }
                
                return { subRequestEventHandlers.forEach { $0() } }
            }()
            
            // The following data is needed in this type for handling batch requests
            self.method = request.method
            self.endpoint = request.endpoint
            self.endpointName = "\(E.self)"
            self.path = request.urlPathAndParamsString
            
            self.batchEndpoints = batchEndpoints
            self.batchRequestVariant = E.batchRequestVariant
            self.batchResponseTypes = batchResponseTypes.defaulting(to: [HTTP.BatchSubResponse<R>.self])
            self.excludedSubRequestHeaders = E.excludedSubRequestHeaders
            
            if batchRequests != nil && self.batchEndpoints.count != self.batchResponseTypes.count {
                SNLog("[PreparedRequest] Created with invalid sub requests")
            }
            
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
        
        fileprivate init<U: Decodable>(
            request: URLRequest,
            server: String,
            publicKey: String,
            originalType: U.Type,
            responseType: R.Type,
            metadata: [HTTPRequestMetadata: Any],
            retryCount: Int,
            timeout: TimeInterval,
            responseConverter: @escaping (ResponseInfoType, Any) throws -> R,
            outputEventHandler: (((ResponseInfoType, R)) -> Void)?,
            completionEventHandler: ((Subscribers.Completion<Error>) -> Void)?,
            cancelEventHandler: (() -> Void)?,
            method: HTTPMethod,
            endpoint: (any EndpointType),
            endpointName: String,
            path: String,
            batchEndpoints: [any EndpointType],
            batchRequestVariant: HTTP.BatchRequest.Child.Variant,
            batchResponseTypes: [Decodable.Type],
            excludedSubRequestHeaders: [String],
            jsonBodyEncoder: ((inout KeyedEncodingContainer<HTTP.BatchRequest.Child.CodingKeys>, HTTP.BatchRequest.Child.CodingKeys) throws -> ())?,
            b64: String?,
            bytes: [UInt8]?
        ) {
            self.request = request
            self.server = server
            self.publicKey = publicKey
            self.originalType = originalType
            self.responseType = responseType
            self.metadata = metadata
            self.retryCount = retryCount
            self.timeout = timeout
            self.responseConverter = responseConverter
            self.outputEventHandler = outputEventHandler
            self.completionEventHandler = completionEventHandler
            self.cancelEventHandler = cancelEventHandler
            
            // The following data is needed in this type for handling batch requests
            self.method = method
            self.endpoint = endpoint
            self.endpointName = endpointName
            self.path = path
            self.batchEndpoints = batchEndpoints
            self.batchRequestVariant = batchRequestVariant
            self.batchResponseTypes = batchResponseTypes
            self.excludedSubRequestHeaders = excludedSubRequestHeaders
            self.jsonBodyEncoder = jsonBodyEncoder
            self.b64 = b64
            self.bytes = bytes
        }
    }
}

// MARK: - ErasedPreparedRequest

public protocol ErasedPreparedRequest {
    var endpointName: String { get }
    var batchRequestVariant: HTTP.BatchRequest.Child.Variant { get }
    var batchResponseTypes: [Decodable.Type] { get }
    var excludedSubRequestHeaders: [String] { get }
    
    var erasedOutputEventHandler: (((ResponseInfoType, Any)) -> Void)? { get }
    var completionEventHandler: ((Subscribers.Completion<Error>) -> Void)? { get }
    var cancelEventHandler: (() -> Void)? { get }
    
    func batchRequestEndpoint<E: EndpointType>(of type: E.Type) -> E?
    func encodeForBatchRequest(to encoder: Encoder) throws
}

extension HTTP.PreparedRequest: ErasedPreparedRequest {
    public var erasedOutputEventHandler: (((ResponseInfoType, Any)) -> Void)? {
        guard let outputEventHandler: (((ResponseInfoType, R)) -> Void) = self.outputEventHandler else {
            return nil
        }
        
        return { data in
            guard let subResponse: HTTP.BatchSubResponse<R> = data.1 as? HTTP.BatchSubResponse<R> else {
                guard let directResponse: R = data.1 as? R else { return }
                
                outputEventHandler((data.0, directResponse))
                return
            }
            guard let value: R = subResponse.body else { return }
            
            outputEventHandler((subResponse, value))
        }
    }
    
    public func batchRequestEndpoint<E: EndpointType>(of type: E.Type) -> E? {
        return (endpoint as? E)
    }
    
    public func encodeForBatchRequest(to encoder: Encoder) throws {
        var container: KeyedEncodingContainer<HTTP.BatchRequest.Child.CodingKeys> = encoder.container(keyedBy: HTTP.BatchRequest.Child.CodingKeys.self)
        
        switch batchRequestVariant {
            case .unsupported:
                SNLog("Attempted to encode unsupported request type \(endpointName) as a batch subrequest")
                
            case .sogs:
                // Exclude request signature headers (not used for sub-requests)
                let excludedSubRequestHeaders: [String] = excludedSubRequestHeaders.map { $0.lowercased() }
                let batchRequestHeaders: [String: String] = (request.allHTTPHeaderFields ?? [:])
                    .filter { key, _ in !excludedSubRequestHeaders.contains(key.lowercased()) }
                
                if !batchRequestHeaders.isEmpty {
                    try container.encode(batchRequestHeaders, forKey: .headers)
                }
                
                try container.encode(method, forKey: .method)
                try container.encode(path, forKey: .path)
                try jsonBodyEncoder?(&container, .json)
                try container.encodeIfPresent(b64, forKey: .b64)
                try container.encodeIfPresent(bytes, forKey: .bytes)
                
            case .storageServer:
                try container.encode(method, forKey: .method)
                try jsonBodyEncoder?(&container, .params)
        }
    }
}

// MARK: - Transformations

public extension HTTP.PreparedRequest {
    func signed(
        _ db: Database,
        with requestSigner: (Database, HTTP.PreparedRequest<R>, Dependencies) throws -> URLRequest,
        using dependencies: Dependencies
    ) throws -> HTTP.PreparedRequest<R> {
        return HTTP.PreparedRequest(
            request: try requestSigner(db, self, dependencies),
            server: server,
            publicKey: publicKey,
            originalType: originalType,
            responseType: responseType,
            metadata: metadata,
            retryCount: retryCount,
            timeout: timeout,
            responseConverter: responseConverter,
            outputEventHandler: outputEventHandler,
            completionEventHandler: completionEventHandler,
            cancelEventHandler: cancelEventHandler,
            method: method,
            endpoint: endpoint,
            endpointName: endpointName,
            path: path,
            batchEndpoints: batchEndpoints,
            batchRequestVariant: batchRequestVariant,
            batchResponseTypes: batchResponseTypes,
            excludedSubRequestHeaders: excludedSubRequestHeaders,
            jsonBodyEncoder: jsonBodyEncoder,
            b64: b64,
            bytes: bytes
        )
    }
    
    func map<O>(transform: @escaping (ResponseInfoType, R) throws -> O) -> HTTP.PreparedRequest<O> {
        let originalResponseConverter: ((ResponseInfoType, Any) throws -> R) = self.responseConverter
        let responseConverter: ((ResponseInfoType, Any) throws -> O) = { info, response in
            let validResponse: R = try originalResponseConverter(info, response)
            
            return try transform(info, validResponse)
        }
        
        return HTTP.PreparedRequest<O>(
            request: request,
            server: server,
            publicKey: publicKey,
            originalType: originalType,
            responseType: O.self,
            metadata: metadata,
            retryCount: retryCount,
            timeout: timeout,
            responseConverter: responseConverter,
            outputEventHandler: self.outputEventHandler.map { eventHandler in
                { data in
                    guard let validResponse: R = try? originalResponseConverter(data.0, data.1) else { return }
                    
                    eventHandler((data.0, validResponse))
                }
            },
            completionEventHandler: completionEventHandler,
            cancelEventHandler: cancelEventHandler,
            method: method,
            endpoint: endpoint,
            endpointName: endpointName,
            path: path,
            batchEndpoints: batchEndpoints,
            batchRequestVariant: batchRequestVariant,
            batchResponseTypes: batchResponseTypes,
            excludedSubRequestHeaders: excludedSubRequestHeaders,
            jsonBodyEncoder: jsonBodyEncoder,
            b64: b64,
            bytes: bytes
        )
    }
    
    func handleEvents(
        receiveOutput: (((ResponseInfoType, R)) -> Void)? = nil,
        receiveCompletion: ((Subscribers.Completion<Error>) -> Void)? = nil,
        receiveCancel: (() -> Void)? = nil
    ) -> HTTP.PreparedRequest<R> {
        let outputEventHandler: (((ResponseInfoType, R)) -> Void)? = {
            switch (self.outputEventHandler, receiveOutput) {
                case (.none, .none): return nil
                case (.some(let eventHandler), .none): return eventHandler
                case (.none, .some(let eventHandler)): return eventHandler
                case (.some(let originalEventHandler), .some(let eventHandler)):
                    return { data in
                        originalEventHandler(data)
                        eventHandler(data)
                    }
            }
        }()
        let completionEventHandler: ((Subscribers.Completion<Error>) -> Void)? = {
            switch (self.completionEventHandler, receiveCompletion) {
                case (.none, .none): return nil
                case (.some(let eventHandler), .none): return eventHandler
                case (.none, .some(let eventHandler)): return eventHandler
                case (.some(let originalEventHandler), .some(let eventHandler)):
                    return { result in
                        originalEventHandler(result)
                        eventHandler(result)
                    }
            }
        }()
        let cancelEventHandler: (() -> Void)? = {
            switch (self.cancelEventHandler, receiveCancel) {
                case (.none, .none): return nil
                case (.some(let eventHandler), .none): return eventHandler
                case (.none, .some(let eventHandler)): return eventHandler
                case (.some(let originalEventHandler), .some(let eventHandler)):
                    return {
                        originalEventHandler()
                        eventHandler()
                    }
            }
        }()
        
        return HTTP.PreparedRequest(
            request: request,
            server: server,
            publicKey: publicKey,
            originalType: originalType,
            responseType: responseType,
            metadata: metadata,
            retryCount: retryCount,
            timeout: timeout,
            responseConverter: responseConverter,
            outputEventHandler: outputEventHandler,
            completionEventHandler: completionEventHandler,
            cancelEventHandler: cancelEventHandler,
            method: method,
            endpoint: endpoint,
            endpointName: endpointName,
            path: path,
            batchEndpoints: batchEndpoints,
            batchRequestVariant: batchRequestVariant,
            batchResponseTypes: batchResponseTypes,
            excludedSubRequestHeaders: excludedSubRequestHeaders,
            jsonBodyEncoder: jsonBodyEncoder,
            b64: b64,
            bytes: bytes
        )
    }
}

// MARK: - Decoding

public extension Decodable {
    static func decoded(from data: Data, using dependencies: Dependencies = Dependencies()) throws -> Self {
        return try data.decoded(as: Self.self, using: dependencies)
    }
}

public extension Publisher where Output == (ResponseInfoType, Data?), Failure == Error {
    func decoded<R>(
        with preparedRequest: HTTP.PreparedRequest<R>,
        using dependencies: Dependencies
    ) -> AnyPublisher<(ResponseInfoType, R), Error> {
        self
            .tryMap { responseInfo, maybeData -> (ResponseInfoType, R) in
                // Depending on the 'originalType' we need to process the response differently
                let targetData: Any = try {
                    switch preparedRequest.originalType {
                        case let erasedBatchResponse as ErasedBatchResponseMap.Type:
                            let responses: HTTP.BatchResponse = try HTTP.BatchResponse.decodingResponses(
                                from: maybeData,
                                as: preparedRequest.batchResponseTypes,
                                requireAllResults: true,
                                using: dependencies
                            )
                            
                            return try erasedBatchResponse.from(
                                batchEndpoints: preparedRequest.batchEndpoints,
                                responses: responses
                            )
                            
                        case is NoResponse.Type: return NoResponse()
                        case is Optional<Data>.Type: return maybeData as Any
                        case is Data.Type: return try maybeData ?? { throw HTTPError.parsingFailed }()
                        
                        case is _OptionalProtocol.Type:
                            guard let data: Data = maybeData else { return maybeData as Any }
                            
                            return try preparedRequest.originalType.decoded(from: data, using: dependencies)
                        
                        default:
                            guard let data: Data = maybeData else { throw HTTPError.parsingFailed }
                            
                            return try preparedRequest.originalType.decoded(from: data, using: dependencies)
                    }
                }()
                
                // Generate and return the converted data
                let convertedData: R = try preparedRequest.responseConverter(responseInfo, targetData)
                
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

