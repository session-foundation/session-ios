// Copyright © 2024 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import Combine
import SessionUtil
import SessionUtilitiesKit

// MARK: - Cache

public extension Cache {
    static let libSessionNetwork: CacheConfig<LibSession.NetworkCacheType, LibSession.NetworkImmutableCacheType> = Dependencies.create(
        identifier: "libSessionNetwork",
        createInstance: { dependencies, _ in
            /// The `libSessionNetwork` cache gets warmed during startup and creates a network instance, populates the snode
            /// cache and builds onion requests when created - when running unit tests we don't want to do any of that unless explicitly
            /// desired within the test itself so instead we default to a `NoopNetworkCache` when running unit tests
            guard !SNUtilitiesKit.isRunningTests else { return LibSession.NoopNetworkCache() }
            
            return LibSession.NetworkCache(using: dependencies)
        },
        mutableInstance: { $0 },
        immutableInstance: { $0 }
    )
}

// MARK: - Log.Category

public extension Log.Category {
    static let network: Log.Category = .create("Network", defaultLevel: .info)
}

// MARK: - LibSession.Network

class LibSessionNetwork: NetworkType {
    private let dependencies: Dependencies
    
    // MARK: - Initialization
    
    init(using dependencies: Dependencies) {
        self.dependencies = dependencies
    }
    
    // MARK: - NetworkType

    func getSwarm(for swarmPublicKey: String) -> AnyPublisher<Set<LibSession.Snode>, Error> {
        typealias Output = Result<Set<LibSession.Snode>, Error>
        
        return dependencies
            .mutate(cache: .libSessionNetwork) { $0.getOrCreateNetwork() }
            .tryMapCallbackContext(type: Output.self) { ctx, network in
                let sessionId: SessionId = try SessionId(from: swarmPublicKey)
                
                guard let cSwarmPublicKey: [CChar] = sessionId.publicKeyString.cString(using: .utf8) else {
                    throw LibSessionError.invalidCConversion
                }
                
                network_get_swarm(network, cSwarmPublicKey, { swarmPtr, swarmSize, ctx in
                    guard
                        swarmSize > 0,
                        let cSwarm: UnsafeMutablePointer<network_service_node> = swarmPtr
                    else { return CallbackWrapper<Output>.run(ctx, .failure(SnodeAPIError.unableToRetrieveSwarm)) }
                    
                    var nodes: Set<LibSession.Snode> = []
                    (0..<swarmSize).forEach { index in nodes.insert(LibSession.Snode(cSwarm[index])) }
                    CallbackWrapper<Output>.run(ctx, .success(nodes))
                }, ctx);
            }
            .tryMap { [dependencies = self.dependencies] result in
                dependencies
                    .mutate(cache: .libSessionNetwork) {
                        $0.setSnodeNumber(
                            publicKey: swarmPublicKey,
                            value: (try? result.get())?.count ?? 0
                        )
                    }
                return try result.successOrThrow()
            }
            .eraseToAnyPublisher()
    }
    
    func getRandomNodes(count: Int) -> AnyPublisher<Set<LibSession.Snode>, Error> {
        typealias Output = Result<Set<LibSession.Snode>, Error>
        
        return dependencies
            .mutate(cache: .libSessionNetwork) { $0.getOrCreateNetwork() }
            .tryMapCallbackContext(type: Output.self) { ctx, network in
                network_get_random_nodes(network, UInt16(count), { nodesPtr, nodesSize, ctx in
                    guard
                        nodesSize > 0,
                        let cSwarm: UnsafeMutablePointer<network_service_node> = nodesPtr
                    else { return CallbackWrapper<Output>.run(ctx, .failure(SnodeAPIError.unableToRetrieveSwarm)) }
                    
                    var nodes: Set<LibSession.Snode> = []
                    (0..<nodesSize).forEach { index in nodes.insert(LibSession.Snode(cSwarm[index])) }
                    CallbackWrapper<Output>.run(ctx, .success(nodes))
                }, ctx);
            }
            .tryMap { result in
                switch result {
                    case .failure(let error): throw error
                    case .success(let nodes):
                        guard nodes.count >= count else { throw SnodeAPIError.unableToRetrieveSwarm }
                        
                        return nodes
                }
            }
            .eraseToAnyPublisher()
    }
    
    func send<E: EndpointType>(
        endpoint: E,
        destination: Network.Destination,
        body: Data?,
        requestTimeout: TimeInterval,
        requestAndPathBuildTimeout: TimeInterval?
    ) -> AnyPublisher<(ResponseInfoType, Data?), Error> {
        switch destination {
            case .server, .serverUpload, .serverDownload, .cached:
                return sendRequest(
                    endpoint: endpoint,
                    destination: destination,
                    body: body,
                    requestTimeout: requestTimeout,
                    requestAndPathBuildTimeout: requestAndPathBuildTimeout
                )
            
            case .snode:
                guard body != nil else { return Fail(error: NetworkError.invalidPreparedRequest).eraseToAnyPublisher() }
                
                return sendRequest(
                    endpoint: endpoint,
                    destination: destination,
                    body: body,
                    requestTimeout: requestTimeout,
                    requestAndPathBuildTimeout: requestAndPathBuildTimeout
                )
                
            case .randomSnode(let swarmPublicKey, let retryCount):
                guard (try? SessionId(from: swarmPublicKey)) != nil else {
                    return Fail(error: SessionIdError.invalidSessionId).eraseToAnyPublisher()
                }
                guard body != nil else { return Fail(error: NetworkError.invalidPreparedRequest).eraseToAnyPublisher() }
                
                return getSwarm(for: swarmPublicKey)
                    .tryFlatMapWithRandomSnode(retry: retryCount, using: dependencies) { [weak self] snode in
                        try self.validOrThrow().sendRequest(
                            endpoint: endpoint,
                            destination: .snode(snode, swarmPublicKey: swarmPublicKey),
                            body: body,
                            requestTimeout: requestTimeout,
                            requestAndPathBuildTimeout: requestAndPathBuildTimeout
                        )
                    }
                
            case .randomSnodeLatestNetworkTimeTarget(let swarmPublicKey, let retryCount, let bodyWithUpdatedTimestampMs):
                guard (try? SessionId(from: swarmPublicKey)) != nil else {
                    return Fail(error: SessionIdError.invalidSessionId).eraseToAnyPublisher()
                }
                guard body != nil else { return Fail(error: NetworkError.invalidPreparedRequest).eraseToAnyPublisher() }
                
                return getSwarm(for: swarmPublicKey)
                    .tryFlatMapWithRandomSnode(retry: retryCount, using: dependencies) { [weak self, dependencies] snode in
                        try Network.SnodeAPI
                            .preparedGetNetworkTime(from: snode, using: dependencies)
                            .send(using: dependencies)
                            .tryFlatMap { _, timestampMs in
                                guard
                                    let updatedEncodable: Encodable = bodyWithUpdatedTimestampMs(timestampMs, dependencies),
                                    let updatedBody: Data = try? JSONEncoder(using: dependencies).encode(updatedEncodable)
                                else { throw NetworkError.invalidPreparedRequest }
                                
                                return try self.validOrThrow().sendRequest(
                                        endpoint: endpoint,
                                        destination: .snode(snode, swarmPublicKey: swarmPublicKey),
                                        body: updatedBody,
                                        requestTimeout: requestTimeout,
                                        requestAndPathBuildTimeout: requestAndPathBuildTimeout
                                    )
                                    .map { info, response -> (ResponseInfoType, Data?) in
                                        (
                                            Network.SnodeAPI.LatestTimestampResponseInfo(
                                                code: info.code,
                                                headers: info.headers,
                                                timestampMs: timestampMs
                                            ),
                                            response
                                        )
                                    }
                            }
                    }
        }
    }
    
    func checkClientVersion(ed25519SecretKey: [UInt8]) -> AnyPublisher<(ResponseInfoType, Network.FileServer.AppVersionResponse), Error> {
        typealias Output = (success: Bool, timeout: Bool, statusCode: Int, headers: [String: String], data: Data?)
        
        return dependencies
            .mutate(cache: .libSessionNetwork) { $0.getOrCreateNetwork() }
            .tryMapCallbackContext(type: Output.self) { ctx, network in
                guard ed25519SecretKey.count == 64 else { throw LibSessionError.invalidCConversion }
                
                var cEd25519SecretKey: [UInt8] = Array(ed25519SecretKey)
                
                network_get_client_version(
                    network,
                    CLIENT_PLATFORM_IOS,
                    &cEd25519SecretKey,
                    Int64(floor(Network.defaultTimeout * 1000)),
                    0,
                    { success, timeout, statusCode, cHeaders, cHeaderVals, headerLen, dataPtr, dataLen, ctx in
                        let headers: [String: String] = CallbackWrapper<Output>
                            .headers(cHeaders, cHeaderVals, headerLen)
                        let data: Data? = dataPtr.map { Data(bytes: $0, count: dataLen) }
                        CallbackWrapper<Output>.run(ctx, (success, timeout, Int(statusCode), headers, data))
                    },
                    ctx
                )
            }
            .tryMap { [dependencies] success, timeout, statusCode, headers, maybeData -> (any ResponseInfoType, Network.FileServer.AppVersionResponse) in
                try LibSessionNetwork.throwErrorIfNeeded(success, timeout, statusCode, headers, maybeData, using: dependencies)
                
                guard let data: Data = maybeData else { throw NetworkError.parsingFailed }
                
                return (
                    Network.ResponseInfo(code: statusCode),
                    try Network.FileServer.AppVersionResponse.decoded(from: data, using: dependencies)
                )
            }
            .eraseToAnyPublisher()
    }
    
    // MARK: - Internal Functions

    private func sendRequest<T: Encodable>(
        endpoint: (any EndpointType),
        destination: Network.Destination,
        body: T?,
        requestTimeout: TimeInterval,
        requestAndPathBuildTimeout: TimeInterval?
    ) -> AnyPublisher<(ResponseInfoType, Data?), Error> {
        typealias Output = (success: Bool, timeout: Bool, statusCode: Int, headers: [String: String], data: Data?)
        
        return dependencies
            .mutate(cache: .libSessionNetwork) { $0.getOrCreateNetwork() }
            .tryMapCallbackContext(type: Output.self) { ctx, network in
                // Prepare the parameters
                let cPayloadBytes: [UInt8]
                
                switch body {
                    case .none: cPayloadBytes = []
                    case let data as Data: cPayloadBytes = Array(data)
                    case let bytes as [UInt8]: cPayloadBytes = bytes
                    default:
                        guard let encodedBody: Data = try? JSONEncoder().encode(body) else {
                            throw SnodeAPIError.invalidPayload
                        }
                        
                        cPayloadBytes = Array(encodedBody)
                }
                
                // Trigger the request
                switch destination {
                    // These types should be processed and converted to a 'snode' destination before
                    // they get here
                    case .randomSnode, .randomSnodeLatestNetworkTimeTarget:
                        throw NetworkError.invalidPreparedRequest
                    
                    case .snode(let snode, let swarmPublicKey):
                        let cSwarmPublicKey: [CChar]? = try swarmPublicKey.map {
                            _ = try SessionId(from: $0)
                            
                            // Quick way to drop '05' prefix if present
                            return $0.suffix(64).cString(using: .utf8)
                        }.flatMap { $0 }
                        
                        network_send_onion_request_to_snode_destination(
                            network,
                            snode.cSnode,
                            cPayloadBytes,
                            cPayloadBytes.count,
                            cSwarmPublicKey,
                            Int64(floor(requestTimeout * 1000)),
                            Int64(floor((requestAndPathBuildTimeout ?? 0) * 1000)),
                            { success, timeout, statusCode, cHeaders, cHeaderVals, headerLen, dataPtr, dataLen, ctx in
                                let headers: [String: String] = CallbackWrapper<Output>
                                    .headers(cHeaders, cHeaderVals, headerLen)
                                let data: Data? = dataPtr.map { Data(bytes: $0, count: dataLen) }
                                CallbackWrapper<Output>.run(ctx, (success, timeout, Int(statusCode), headers, data))
                            },
                            ctx
                        )
                    
                    case .server(let info):
                        try info.withUnsafePointer(endpoint: endpoint) { cServerDestination in
                            network_send_onion_request_to_server_destination(
                                network,
                                cServerDestination,
                                cPayloadBytes,
                                cPayloadBytes.count,
                                Int64(floor(requestTimeout * 1000)),
                                Int64(floor((requestAndPathBuildTimeout ?? 0) * 1000)),
                                { success, timeout, statusCode, cHeaders, cHeaderVals, headerLen, dataPtr, dataLen, ctx in
                                    let headers: [String: String] = CallbackWrapper<Output>
                                        .headers(cHeaders, cHeaderVals, headerLen)
                                    let data: Data? = dataPtr.map { Data(bytes: $0, count: dataLen) }
                                    CallbackWrapper<Output>.run(ctx, (success, timeout, Int(statusCode), headers, data))
                                },
                                ctx
                            )
                        }
                    
                    case .serverUpload(let info, let fileName):
                        guard !cPayloadBytes.isEmpty else { throw NetworkError.invalidPreparedRequest }
                        
                        try info.withUnsafePointer(endpoint: endpoint) { cServerDestination in
                            network_upload_to_server(
                                network,
                                cServerDestination,
                                cPayloadBytes,
                                cPayloadBytes.count,
                                fileName?.cString(using: .utf8),
                                Int64(floor(requestTimeout * 1000)),
                                Int64(floor((requestAndPathBuildTimeout ?? 0) * 1000)),
                                { success, timeout, statusCode, cHeaders, cHeaderVals, headerLen, dataPtr, dataLen, ctx in
                                    let headers: [String: String] = CallbackWrapper<Output>
                                        .headers(cHeaders, cHeaderVals, headerLen)
                                    let data: Data? = dataPtr.map { Data(bytes: $0, count: dataLen) }
                                    CallbackWrapper<Output>.run(ctx, (success, timeout, Int(statusCode), headers, data))
                                },
                                ctx
                            )
                        }
                    
                    case .serverDownload(let info):
                        try info.withUnsafePointer(endpoint: endpoint) { cServerDestination in
                            network_download_from_server(
                                network,
                                cServerDestination,
                                Int64(floor(requestTimeout * 1000)),
                                Int64(floor((requestAndPathBuildTimeout ?? 0) * 1000)),
                                { success, timeout, statusCode, cHeaders, cHeaderVals, headerLen, dataPtr, dataLen, ctx in
                                    let headers: [String: String] = CallbackWrapper<Output>
                                        .headers(cHeaders, cHeaderVals, headerLen)
                                    let data: Data? = dataPtr.map { Data(bytes: $0, count: dataLen) }
                                    CallbackWrapper<Output>.run(ctx, (success, timeout, Int(statusCode), headers, data))
                                },
                                ctx
                            )
                        }
                    
                    case .cached(let success, let timeout, let statusCode, let headers, let data):
                        CallbackWrapper<Output>.run(ctx, (success, timeout, statusCode, headers, data))
                }
            }
            .tryMap { [dependencies] success, timeout, statusCode, headers, data -> (any ResponseInfoType, Data?) in
                try LibSessionNetwork.throwErrorIfNeeded(success, timeout, statusCode, headers, data, using: dependencies)
                return (Network.ResponseInfo(code: statusCode, headers: headers), data)
            }
            .eraseToAnyPublisher()
    }
    
    private static func throwErrorIfNeeded(
        _ success: Bool,
        _ timeout: Bool,
        _ statusCode: Int,
        _ headers: [String: String],
        _ data: Data?,
        using dependencies: Dependencies
    ) throws {
        guard !success || statusCode < 200 || statusCode > 299 else { return }
        guard !timeout else {
            switch data.map({ String(data: $0, encoding: .ascii) }) {
                case .none: throw NetworkError.timeout(error: "\(NetworkError.unknown)", rawData: data)
                case .some(let responseString): throw NetworkError.timeout(error: responseString, rawData: data)
            }
        }
        
        /// Handle status codes with specific meanings
        switch (statusCode, data.map { String(data: $0, encoding: .ascii) }) {
            case (400, .none): throw NetworkError.badRequest(error: "\(NetworkError.unknown)", rawData: data)
            case (400, .some(let responseString)): throw NetworkError.badRequest(error: responseString, rawData: data)
                
            case (401, _):
                Log.warn(.network, "Unauthorised (Failed to verify the signature).")
                throw NetworkError.unauthorised
            
            case (403, _): throw NetworkError.forbidden
            case (404, _): throw NetworkError.notFound
                
            /// A snode will return a `406` but onion requests v4 seems to return `425` so handle both
            case (406, _), (425, _):
                Log.warn(.network, "The user's clock is out of sync with the service node network.")
                throw SnodeAPIError.clockOutOfSync
            
            case (421, _): throw SnodeAPIError.unassociatedPubkey
            case (429, _): throw SnodeAPIError.rateLimited
            case (500, _): throw NetworkError.internalServerError
            case (503, _): throw NetworkError.serviceUnavailable
            case (502, .none): throw NetworkError.badGateway
            case (502, .some(let responseString)):
                guard responseString.count >= 64 && Hex.isValid(String(responseString.suffix(64))) else {
                    throw NetworkError.badGateway
                }
                
                let nodeHex: String = String(responseString.suffix(64))
                
                for path in dependencies[cache: .libSessionNetwork].currentPaths {
                    if let index: Int = path.firstIndex(where: { $0.ed25519PubkeyHex == nodeHex }) {
                        throw SnodeAPIError.nodeNotFound(index, nodeHex)
                    }
                }
                
                throw SnodeAPIError.nodeNotFound(nil, nodeHex)
                
            case (504, _): throw NetworkError.gatewayTimeout
            case (_, .none): throw NetworkError.unknown
            case (_, .some(let responseString)): throw NetworkError.requestFailed(error: responseString, rawData: data)
        }
    }
}

// MARK: - LibSessionNetwork.CallbackWrapper

private extension LibSessionNetwork {
    class CallbackWrapper<Output> {
        public let promise: (Result<Output, Error>) -> Void
        
        init(promise: @escaping (Result<Output, Error>) -> Void) {
            self.promise = promise
        }
        
        // MARK: - Functions
        
        public static func run(_ ctx: UnsafeMutableRawPointer?, _ output: Output) {
            guard let ctx: UnsafeMutableRawPointer = ctx else {
                return Log.error(.network, "CallbackWrapper called with null context.")
            }
            
            /// Dispatch async so we don't block libSession's internals with Swift logic (which can block other requests)
            let wrapper: CallbackWrapper<Output> = Unmanaged<CallbackWrapper<Output>>.fromOpaque(ctx).takeRetainedValue()
            DispatchQueue.global(qos: .default).async { [wrapper] in
                wrapper.promise(.success(output))
            }
        }
        
        public func unsafePointer() -> UnsafeMutableRawPointer { Unmanaged.passRetained(self).toOpaque() }
        
        public func run(_ output: Output) {
            promise(.success(output))
        }
    }
}

// MARK: - Publisher Convenience

fileprivate extension Publisher {
    func tryMapCallbackContext<T>(
        maxPublishers: Subscribers.Demand = .unlimited,
        type: T.Type,
        _ transform: @escaping (UnsafeMutableRawPointer, Self.Output) throws -> Void
    ) -> AnyPublisher<T, Error> {
        return self
            .mapError { _ in NetworkError.unknown }
            .flatMap { value -> Future<T, Error> in
                Future<T, Error> { promise in
                    let wrapper: LibSessionNetwork.CallbackWrapper<T> = LibSessionNetwork.CallbackWrapper(
                        promise: promise
                    )
                    let ctx: UnsafeMutableRawPointer = wrapper.unsafePointer()
                    
                    do { try transform(ctx, value) }
                    catch {
                        Unmanaged<LibSessionNetwork.CallbackWrapper<T>>.fromOpaque(ctx).release()
                        promise(.failure(error))
                    }
                }
            }
            .eraseToAnyPublisher()
    }
}

// MARK: - Optional Convenience

private extension Optional where Wrapped == LibSessionNetwork {
    func validOrThrow() throws -> Wrapped {
        switch self {
            case .none: throw NetworkError.invalidState
            case .some(let value): return value
        }
    }
}

// MARK: - NetworkStatus Convenience

private extension NetworkStatus {
    init(status: CONNECTION_STATUS) {
        switch status {
            case CONNECTION_STATUS_CONNECTING: self = .connecting
            case CONNECTION_STATUS_CONNECTED: self = .connected
            case CONNECTION_STATUS_DISCONNECTED: self = .disconnected
            default: self = .unknown
        }
    }
}

// MARK: - Snode

extension LibSession {
    public struct Snode: Codable, Hashable, CustomStringConvertible {
        public let ip: String
        public let quicPort: UInt16
        public let ed25519PubkeyHex: String
        
        public var address: String { "\(ip):\(quicPort)" }
        public var description: String { address }
        
        public var cSnode: network_service_node {
            var result: network_service_node = network_service_node()
            result.ipString = ip
            result.set(\.quic_port, to: quicPort)
            result.set(\.ed25519_pubkey_hex, to: ed25519PubkeyHex)
            
            return result
        }
        
        init(_ cSnode: network_service_node) {
            ip = cSnode.ipString
            quicPort = cSnode.get(\.quic_port)
            ed25519PubkeyHex = cSnode.get(\.ed25519_pubkey_hex)
        }
        
        internal init(ip: String, quicPort: UInt16, ed25519PubkeyHex: String) {
            self.ip = ip
            self.quicPort = quicPort
            self.ed25519PubkeyHex = ed25519PubkeyHex
        }
        
        public func hash(into hasher: inout Hasher) {
            ip.hash(into: &hasher)
            quicPort.hash(into: &hasher)
            ed25519PubkeyHex.hash(into: &hasher)
        }
        
        public static func == (lhs: Snode, rhs: Snode) -> Bool {
            return (
                lhs.ip == rhs.ip &&
                lhs.quicPort == rhs.quicPort &&
                lhs.ed25519PubkeyHex == rhs.ed25519PubkeyHex
            )
        }
    }
}

// MARK: - Convenience C Access

extension network_service_node: @retroactive CAccessible, @retroactive CMutable {
    var ipString: String {
        get { "\(ip.0).\(ip.1).\(ip.2).\(ip.3)" }
        set {
            let ipParts: [UInt8] = newValue
                .components(separatedBy: ".")
                .compactMap { UInt8($0) }
            
            guard ipParts.count == 4 else { return }
            
            self.ip = (ipParts[0], ipParts[1], ipParts[2], ipParts[3])
        }
    }
}

// MARK: - Convenience

private extension Network.Destination.ServerInfo {
    func withUnsafePointer<Result>(endpoint: (any EndpointType), _ body: (network_server_destination) throws -> Result) throws -> Result {
        let x25519PublicKey: String = String(x25519PublicKey.suffix(64)) // Quick way to drop '05' prefix if present
        
        guard let host: String = self.host else { throw NetworkError.invalidURL }
        guard x25519PublicKey.count == 64 || x25519PublicKey.count == 66 else {
            throw LibSessionError.invalidCConversion
        }
        
        let targetScheme: String = (self.scheme ?? "https")
        let pathWithParams: String = Network.Destination.generatePathWithParamsAndFragments(
            endpoint: endpoint,
            queryParameters: queryParameters,
            fragmentParameters: fragmentParameters
        )
        let port: UInt16 = UInt16(self.port ?? (targetScheme == "https" ? 443 : 80))
        let headerKeys: [String] = headers.map { $0.key }
        let headerValues: [String] = headers.map { $0.value }
        let headersSize = headerKeys.count
        
        // Use scoped closure to avoid manual memory management (crazy nesting but it ends up safer)
        return try method.rawValue.withCString { cMethodPtr in
            try targetScheme.withCString { cTargetSchemePtr in
                try host.withCString { cHostPtr in
                    try pathWithParams.withCString { cPathWithParamsPtr in
                        try x25519PublicKey.withCString { cX25519PubkeyPtr in
                            try headerKeys.withUnsafeCStrArray { headerKeysPtr in
                                try headerValues.withUnsafeCStrArray { headerValuesPtr in
                                    let cServerDest = network_server_destination(
                                        method: cMethodPtr,
                                        protocol: cTargetSchemePtr,
                                        host: cHostPtr,
                                        endpoint: cPathWithParamsPtr,
                                        port: port,
                                        x25519_pubkey: cX25519PubkeyPtr,
                                        headers: headerKeysPtr.baseAddress,
                                        header_values: headerValuesPtr.baseAddress,
                                        headers_size: headersSize
                                    )
                                    
                                    return try body(cServerDest)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

private extension LibSessionNetwork.CallbackWrapper {
    static func headers(
        _ cHeaders: UnsafePointer<UnsafePointer<CChar>?>?,
        _ cHeaderVals: UnsafePointer<UnsafePointer<CChar>?>?,
        _ count: Int
    ) -> [String: String] {
        let headers: [String] = ([String](cStringArray: cHeaders, count: count) ?? [])
        let headerVals: [String] = ([String](cStringArray: cHeaderVals, count: count) ?? [])
        
        return zip(headers, headerVals)
            .reduce(into: [:]) { result, next in result[next.0] = next.1 }
    }
}

// MARK: - LibSession.NetworkCache

public extension LibSession {
    class NetworkCache: NetworkCacheType {
        private static var snodeCachePath: String { "\(SessionFileManager.nonInjectedAppSharedDataDirectoryPath)/snodeCache" }
        
        private let dependencies: Dependencies
        private let dependenciesPtr: UnsafeMutableRawPointer
        private var network: UnsafeMutablePointer<network_object>? = nil
        private let _paths: CurrentValueSubject<[[Snode]], Never> = CurrentValueSubject([])
        private let _networkStatus: CurrentValueSubject<NetworkStatus, Never> = CurrentValueSubject(.unknown)
        private let _snodeNumber: CurrentValueSubject<[String: Int], Never> = .init([:])
        
        public var isSuspended: Bool = false
        public var networkStatus: AnyPublisher<NetworkStatus, Never> { _networkStatus.eraseToAnyPublisher() }
        
        public var paths: AnyPublisher<[[Snode]], Never> { _paths.eraseToAnyPublisher() }
        public var hasPaths: Bool { !_paths.value.isEmpty }
        public var currentPaths: [[Snode]] { _paths.value }
        public var pathsDescription: String { _paths.value.prettifiedDescription }
        public var snodeNumber: [String: Int] { _snodeNumber.value }
        
        // MARK: - Initialization
        
        public init(using dependencies: Dependencies) {
            self.dependencies = dependencies
            self.dependenciesPtr = Unmanaged.passRetained(dependencies).toOpaque()
            
            // Create the network object
            getOrCreateNetwork().sinkUntilComplete()
            
            // If the app has been set to 'forceOffline' then we need to explicitly set the network status
            // to disconnected (because it'll never be set otherwise)
            if dependencies[feature: .forceOffline] {
                DispatchQueue.global(qos: .default).async { [dependencies] in
                    dependencies.mutate(cache: .libSessionNetwork) { $0.setNetworkStatus(status: .disconnected) }
                }
            }
        }
        
        deinit {
            // Send completion events to the observables (so they can resubscribe to a future instance)
            _paths.send(completion: .finished)
            _networkStatus.send(completion: .finished)
            _snodeNumber.send(completion: .finished)
            
            // Clear the network changed callbacks (just in case, since we are going to free the
            // dependenciesPtr) and then free the network object
            switch network {
                case .none: break
                case .some(let network):
                    network_set_status_changed_callback(network, nil, nil)
                    network_set_paths_changed_callback(network, nil, nil)
                    network_free(network)
            }
            
            // Finally we need to make sure to clean up the unbalanced retain to the dependencies
            Unmanaged<Dependencies>.fromOpaque(dependenciesPtr).release()
        }
        
        // MARK: - Functions
        
        public func suspendNetworkAccess() {
            isSuspended = true
            Log.info(.network, "Network access suspended.")
            
            switch network {
                case .none: break
                case .some(let network): network_suspend(network)
            }
            
            dependencies.notifyAsync(key: .networkLifecycle(.suspended))
        }
        
        public func resumeNetworkAccess() {
            isSuspended = false
            
            switch network {
                case .none: break
                case .some(let network): network_resume(network)
            }
            
            Log.info(.network, "Network access resumed.")
            dependencies.notifyAsync(key: .networkLifecycle(.resumed))
        }
        
        public func getOrCreateNetwork() -> AnyPublisher<UnsafeMutablePointer<network_object>?, Error> {
            guard !isSuspended else {
                Log.warn(.network, "Attempted to access suspended network.")
                return Fail(error: NetworkError.suspended).eraseToAnyPublisher()
            }
            
            switch (network, dependencies[feature: .forceOffline]) {
                case (_, true):
                    return Fail(error: NetworkError.serviceUnavailable)
                        .delay(for: .seconds(1), scheduler: DispatchQueue.global(qos: .userInitiated))
                        .eraseToAnyPublisher()
                    
                case (.some(let existingNetwork), _):
                    return Just(existingNetwork)
                        .setFailureType(to: Error.self)
                        .eraseToAnyPublisher()
                
                case (.none, _):
                    let useTestnet: Bool = (dependencies[feature: .serviceNetwork] == .testnet)
                    let isMainApp: Bool = dependencies[singleton: .appContext].isMainApp
                    var error: [CChar] = [CChar](repeating: 0, count: 256)
                    var network: UnsafeMutablePointer<network_object>?
                    
                    guard let cCachePath: [CChar] = NetworkCache.snodeCachePath.cString(using: .utf8) else {
                        Log.error(.network, "Unable to create network object: \(LibSessionError.invalidCConversion)")
                        return Fail(error: NetworkError.invalidState).eraseToAnyPublisher()
                    }
                    
                    guard network_init(&network, cCachePath, useTestnet, !isMainApp, true, &error) else {
                        Log.error(.network, "Unable to create network object: \(String(cString: error))")
                        return Fail(error: NetworkError.invalidState).eraseToAnyPublisher()
                    }
                    
                    // Store the newly created network
                    self.network = network
                    
                    /// Register the callbacks in the next run loop (this needs to happen in a subsequent run loop because it mutates the
                    /// `libSessionNetwork` cache and this function gets called during init so could end up with weird order-of-execution issues)
                    ///
                    /// **Note:** We do it this way because `DispatchQueue.async` can be optimised out if the code is already running in a
                    /// queue with the same `qos`, this approach ensures the code will run in a subsequent run loop regardless
                    let concurrentQueue = DispatchQueue(label: "Network.callback.registration", attributes: .concurrent)
                    concurrentQueue.async(flags: .barrier) { [weak self] in
                        guard
                            let network: UnsafeMutablePointer<network_object> = self?.network,
                            let dependenciesPtr: UnsafeMutableRawPointer = self?.dependenciesPtr
                        else { return }
                        
                        // Register for network status changes
                        network_set_status_changed_callback(network, { cStatus, ctx in
                            guard let ctx: UnsafeMutableRawPointer = ctx else { return }
                            
                            let status: NetworkStatus = NetworkStatus(status: cStatus)
                            let dependencies: Dependencies = Unmanaged<Dependencies>.fromOpaque(ctx).takeUnretainedValue()
                            
                            // Dispatch async so we don't hold up the libSession thread that triggered the update
                            // or have a reentrancy issue with the mutable cache
                            DispatchQueue.global(qos: .default).async {
                                dependencies.mutate(cache: .libSessionNetwork) { $0.setNetworkStatus(status: status) }
                            }
                        }, dependenciesPtr)
                        
                        // Register for path changes
                        network_set_paths_changed_callback(network, { pathsPtr, pathsLen, ctx in
                            guard let ctx: UnsafeMutableRawPointer = ctx else { return }
                            
                            var paths: [[Snode]] = []
                            
                            if let cPathsPtr: UnsafeMutablePointer<onion_request_path> = pathsPtr {
                                var cPaths: [onion_request_path] = []
                                
                                (0..<pathsLen).forEach { index in
                                    cPaths.append(cPathsPtr[index])
                                }
                                
                                // Copy the nodes over as the memory will be freed after the callback is run
                                paths = cPaths.map { cPath in
                                    var nodes: [Snode] = []
                                    (0..<cPath.nodes_count).forEach { index in
                                        nodes.append(Snode(cPath.nodes[index]))
                                    }
                                    return nodes
                                }
                                
                                // Need to free the nodes within the path as we are the owner
                                cPaths.forEach { cPath in
                                    free(UnsafeMutableRawPointer(mutating: cPath.nodes))
                                }
                            }
                            
                            // Need to free the pathsPtr as we are the owner
                            free(UnsafeMutableRawPointer(mutating: pathsPtr))
                            
                            // Dispatch async so we don't hold up the libSession thread that triggered the update
                            // or have a reentrancy issue with the mutable cache
                            let dependencies: Dependencies = Unmanaged<Dependencies>.fromOpaque(ctx).takeUnretainedValue()
                            
                            DispatchQueue.global(qos: .default).async {
                                dependencies.mutate(cache: .libSessionNetwork) { $0.setPaths(paths: paths) }
                            }
                        }, dependenciesPtr)
                    }
                    
                    return Just(network)
                        .setFailureType(to: Error.self)
                        .eraseToAnyPublisher()
            }
        }
        
        public func setNetworkStatus(status: NetworkStatus) {
            guard status == .disconnected || !isSuspended else {
                Log.warn(.network, "Attempted to update network status to '\(status)' for suspended network, closing connections again.")
                
                switch network {
                    case .none: return
                    case .some(let network): return network_close_connections(network)
                }
            }
            
            // Notify any subscribers
            Log.info(.network, "Network status changed to: \(status)")
            _networkStatus.send(status)
        }
        
        public func setPaths(paths: [[Snode]]) {
            // Notify any subscribers
            _paths.send(paths)
        }
        
        public func setSnodeNumber(publicKey: String, value: Int) {
            var snodeNumber = _snodeNumber.value
            snodeNumber[publicKey] = value
            _snodeNumber.send(snodeNumber)
        }
        
        public func clearCallbacks() {
            switch network {
                case .none: break
                case .some(let network):
                    network_set_status_changed_callback(network, nil, nil)
                    network_set_paths_changed_callback(network, nil, nil)
            }
        }
        
        public func clearSnodeCache() {
            switch network {
                case .none: break
                case .some(let network): network_clear_cache(network)
            }
        }
        
        public func snodeCacheSize() -> Int {
            switch network {
                case .none: return 0
                case .some(let network): return network_get_snode_cache_size(network)
            }
        }
    }
    
    // MARK: - NetworkCacheType

    /// This is a read-only version of the Cache designed to avoid unintentionally mutating the instance in a non-thread-safe way
    protocol NetworkImmutableCacheType: ImmutableCacheType {
        var isSuspended: Bool { get }
        var networkStatus: AnyPublisher<NetworkStatus, Never> { get }
        
        var paths: AnyPublisher<[[Snode]], Never> { get }
        var hasPaths: Bool { get }
        var currentPaths: [[Snode]] { get }
        var pathsDescription: String { get }
        var snodeNumber: [String: Int] { get }
    }

    protocol NetworkCacheType: NetworkImmutableCacheType, MutableCacheType {
        var isSuspended: Bool { get }
        var networkStatus: AnyPublisher<NetworkStatus, Never> { get }
        
        var paths: AnyPublisher<[[Snode]], Never> { get }
        var hasPaths: Bool { get }
        var currentPaths: [[Snode]] { get }
        var pathsDescription: String { get }
        var snodeNumber: [String: Int] { get }
        
        func suspendNetworkAccess()
        func resumeNetworkAccess()
        func getOrCreateNetwork() -> AnyPublisher<UnsafeMutablePointer<network_object>?, Error>
        func setNetworkStatus(status: NetworkStatus)
        func setPaths(paths: [[Snode]])
        func setSnodeNumber(publicKey: String, value: Int)
        func clearCallbacks()
        func clearSnodeCache()
        func snodeCacheSize() -> Int
    }
    
    class NoopNetworkCache: NetworkCacheType, NoopDependency {
        public var isSuspended: Bool { return false }
        public var networkStatus: AnyPublisher<NetworkStatus, Never> {
            Just(NetworkStatus.unknown).eraseToAnyPublisher()
        }
        
        public var paths: AnyPublisher<[[Snode]], Never> { Just([]).eraseToAnyPublisher() }
        public var hasPaths: Bool { return false }
        public var currentPaths: [[LibSession.Snode]] { [] }
        public var pathsDescription: String { "" }
        public var snodeNumber: [String: Int] { [:] }
        
        public func suspendNetworkAccess() {}
        public func resumeNetworkAccess() {}
        public func getOrCreateNetwork() -> AnyPublisher<UnsafeMutablePointer<network_object>?, Error> {
            return Fail(error: NetworkError.invalidState)
                .eraseToAnyPublisher()
        }
        
        public func setNetworkStatus(status: NetworkStatus) {}
        public func setPaths(paths: [[LibSession.Snode]]) {}
        public func setSnodeNumber(publicKey: String, value: Int) {}
        public func clearCallbacks() {}
        public func clearSnodeCache() {}
        public func snodeCacheSize() -> Int { 0 }
    }
}
