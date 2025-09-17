// Copyright © 2024 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import Combine
import SessionUtil
import SessionUtilitiesKit

// MARK: - Log.Category

public extension Log.Category {
    static let network: Log.Category = .create("Network", defaultLevel: .info)
}

// MARK: - LibSessionNetwork

actor LibSessionNetwork: NetworkType {
    fileprivate typealias Response = (
        success: Bool,
        timeout: Bool,
        statusCode: Int,
        headers: [String: String],
        data: Data?
    )
    
    private static var snodeCachePath: String { "\(SessionFileManager.nonInjectedAppSharedDataDirectoryPath)/snodeCache" }
    
    private let dependencies: Dependencies
    private let dependenciesPtr: UnsafeMutableRawPointer
    private var network: UnsafeMutablePointer<network_object_v2>? = nil
    nonisolated private let internalNetworkStatus: CurrentValueAsyncStream<NetworkStatus> = CurrentValueAsyncStream(.unknown)
    private let singlePathMode: Bool
    
    public private(set) var isSuspended: Bool = false
    nonisolated public var networkStatus: AsyncStream<NetworkStatus> { internalNetworkStatus.stream }
    nonisolated public let syncState: NetworkSyncState = NetworkSyncState()
    
    @available(*, deprecated, message: "We want to shift from Combine to Async/Await when possible")
    private let networkInstance: CurrentValueSubject<UnsafeMutablePointer<network_object_v2>?, Error> = CurrentValueSubject(nil)
    
    @available(*, deprecated, message: "This probably isn't needed but in order to isolate the async from sync states I've added it")
    nonisolated private let syncDependencies: Dependencies
    
    // MARK: - Initialization
    
    init(singlePathMode: Bool, using dependencies: Dependencies) {
        self.dependencies = dependencies
        self.dependenciesPtr = Unmanaged.passRetained(dependencies).toOpaque()
        self.singlePathMode = singlePathMode
        self.syncDependencies = dependencies
        
        /// Create the network object
        Task { [self] in
            /// If the app has been set to `forceOffline` then we need to explicitly set the network status to disconnected (because
            /// it'll never be set otherwise)
            if dependencies[feature: .forceOffline] {
                await setNetworkStatus(status: .disconnected)
            }
            
            /// Create the `network` instance so it can do any setup required
            _ = try? await getOrCreateNetwork()
        }
    }
    
    deinit {
        // Send completion events to the observables (so they can resubscribe to a future instance)
        Task { [status = internalNetworkStatus] in
            await status.send(.disconnected)
            await status.finishCurrentStreams()
        }
        
        // Finish the `networkInstance` (since it's a `CurrentValueSubject` we want to ensure it doesn't
        // hold the `network` instance since we are about to free it below
        self.networkInstance.send(nil)
        self.networkInstance.send(completion: .finished)
        
        // Clear the network changed callbacks (just in case, since we are going to free the
        // dependenciesPtr) and then free the network object
        switch network {
            case .none: break
            case .some(let network):
                session_network_set_status_changed_callback(network, nil, nil)
                session_network_free(network)
        }
        
        // Finally we need to make sure to clean up the unbalanced retain to the dependencies
        Unmanaged<Dependencies>.fromOpaque(dependenciesPtr).release()
    }
    
    // MARK: - NetworkType

    func getActivePaths() async throws -> [LibSession.Path] {
        let network = try await getOrCreateNetwork()
        
        var cPathsPtr: UnsafeMutablePointer<session_path_info>?
        var cPathsLen: Int = 0
        session_network_get_active_paths(network, &cPathsPtr, &cPathsLen)
        defer {
            if let paths = cPathsPtr {
                session_network_paths_free(paths)
            }
        }
        
        guard
            cPathsLen > 0,
            let cPaths: UnsafeMutablePointer<session_path_info> = cPathsPtr
        else { return [] }
        
        return (0..<cPathsLen).map { index in
            var nodes: [LibSession.Snode] = []
            var category: Network.RequestCategory?
            var destinationPubkey: String?
            var destinationAddress: String?
            
            if cPaths[index].nodes_count > 0, let cNodes: UnsafePointer<network_service_node> = cPaths[index].nodes {
                nodes = (0..<cPaths[index].nodes_count).map { LibSession.Snode(cNodes[$0]) }
            }
            
            if let onionMeta: UnsafePointer<session_onion_path_metadata> = cPaths[index].onion_metadata {
                category = Network.RequestCategory(onionMeta.get(\.category))
            }
            else if let lokinetMeta: UnsafePointer<session_lokinet_tunnel_metadata> = cPaths[index].lokinet_metadata {
                destinationPubkey = lokinetMeta.get(\.destination_pubkey)
                destinationAddress = lokinetMeta.get(\.destination_snode_address)
            }
            
            return LibSession.Path(
                nodes: nodes,
                category: category,
                destinationPubkey: destinationPubkey,
                destinationSnodeAddress: destinationAddress
            )
        }
    }
    
    func getSwarm(for swarmPublicKey: String) async throws -> Set<LibSession.Snode> {
        typealias Continuation = CheckedContinuation<Set<LibSession.Snode>, Error>
        
        let network = try await getOrCreateNetwork()
        let sessionId: SessionId = try SessionId(from: swarmPublicKey)
        
        guard let cSwarmPublicKey: [CChar] = sessionId.publicKeyString.cString(using: .utf8) else {
            throw LibSessionError.invalidCConversion
        }
        
        return try await withCheckedThrowingContinuation { continuation in
            let context = LibSessionNetwork.ContinuationBox(continuation).unsafePointer()
            
            session_network_get_swarm(network, cSwarmPublicKey, { swarmPtr, swarmSize, ctx in
                guard let box = LibSessionNetwork.ContinuationBox<Continuation>.from(unsafePointer: ctx) else {
                    return
                }
                
                guard
                    swarmSize > 0,
                    let cSwarm: UnsafeMutablePointer<network_service_node> = swarmPtr
                else { return box.continuation.resume(throwing: SnodeAPIError.unableToRetrieveSwarm) }
                
                var nodes: Set<LibSession.Snode> = []
                (0..<swarmSize).forEach { index in nodes.insert(LibSession.Snode(cSwarm[index])) }
                box.continuation.resume(returning: nodes)
            }, context)
        }
    }
    
    func getRandomNodes(count: Int) async throws -> Set<LibSession.Snode> {
        typealias Continuation = CheckedContinuation<Set<LibSession.Snode>, Error>
        
        let network = try await getOrCreateNetwork()
        
        let nodes: Set<LibSession.Snode> = try await withCheckedThrowingContinuation { continuation in
            let context = LibSessionNetwork.ContinuationBox(continuation).unsafePointer()
            
            session_network_get_random_nodes(network, UInt16(count), { nodesPtr, nodesSize, ctx in
                guard let box = LibSessionNetwork.ContinuationBox<Continuation>.from(unsafePointer: ctx) else {
                    return
                }
                
                guard
                    nodesSize > 0,
                    let cSwarm: UnsafeMutablePointer<network_service_node> = nodesPtr
                else { return box.continuation.resume(throwing: SnodeAPIError.unableToRetrieveSwarm) }
                
                var nodes: Set<LibSession.Snode> = []
                (0..<nodesSize).forEach { index in nodes.insert(LibSession.Snode(cSwarm[index])) }
                box.continuation.resume(returning: nodes)
            }, context);
        }
        
        guard nodes.count >= count else {
            throw SnodeAPIError.unableToRetrieveSwarm
        }
        
        return nodes
    }
    
    nonisolated func send<E: EndpointType>(
        endpoint: E,
        destination: Network.Destination,
        body: Data?,
        category: Network.RequestCategory,
        requestTimeout: TimeInterval,
        overallTimeout: TimeInterval?
    ) -> AnyPublisher<(ResponseInfoType, Data?), Error> {
        typealias FinalRequestInfo = (
            network: UnsafeMutablePointer<network_object_v2>,
            body: Data?,
            destination: Network.Destination
        )
        typealias Output = (success: Bool, timeout: Bool, statusCode: Int, headers: [String: String], data: Data?)
        
        guard !syncState.isSuspended else {
            Log.warn(.network, "Attempted to access suspended network.")
            return Fail(error: NetworkError.suspended)
                .eraseToAnyPublisher()
        }
        
        guard !syncDependencies[feature: .forceOffline] else {
            return Fail(error: NetworkError.serviceUnavailable)
                .delay(for: .seconds(1), scheduler: DispatchQueue.global(qos: .userInitiated))
                .eraseToAnyPublisher()
        }
        
        return networkInstance
            .compactMap { $0 }
            .first()
            .tryFlatMap { [dependencies] network -> AnyPublisher<FinalRequestInfo, Error> in
                switch destination {
                    case .snode, .server, .serverUpload, .serverDownload, .cached:
                        return Just((network, body, destination))
                            .setFailureType(to: Error.self)
                            .eraseToAnyPublisher()
                        
                    case .randomSnode(let swarmPublicKey):
                        guard body != nil else { throw NetworkError.invalidPreparedRequest }
                        
                        let swarmSessionId: SessionId = try SessionId(from: swarmPublicKey)
                        
                        guard let cSwarmPublicKey: [CChar] = swarmSessionId.publicKeyString.cString(using: .utf8) else {
                            throw LibSessionError.invalidCConversion
                        }
                        
                        return FutureBox<Set<LibSession.Snode>>
                            .create { ctx in
                                session_network_get_swarm(network, cSwarmPublicKey, { swarmPtr, swarmSize, ctx in
                                    guard
                                        swarmSize > 0,
                                        let cSwarm: UnsafeMutablePointer<network_service_node> = swarmPtr
                                    else {
                                        return LibSessionNetwork.FutureBox<Set<LibSession.Snode>>.fail(
                                            error: SnodeAPIError.unableToRetrieveSwarm,
                                            ptr: ctx
                                        )
                                    }
                                    
                                    var nodes: Set<LibSession.Snode> = []
                                    (0..<swarmSize).forEach { index in nodes.insert(LibSession.Snode(cSwarm[index])) }
                                    LibSessionNetwork.FutureBox<Set<LibSession.Snode>>.resolve(
                                        result: nodes,
                                        ptr: ctx
                                    )
                                }, ctx)
                            }
                            .tryMap { [dependencies] nodes in
                                try dependencies.randomElement(nodes) ?? {
                                    throw SnodeAPIError.ranOutOfRandomSnodes(nil)
                                }()
                            }
                            .map { node in
                                (
                                    network,
                                    body,
                                    Network.Destination.snode(node, swarmPublicKey: swarmPublicKey)
                                )
                            }
                            .eraseToAnyPublisher()
                }
            }
            .tryMapCallbackContext(type: Output.self) { ctx, finalRequestInfo in
                /// If it's a cached request then just return the cached result immediately
                if case .cached(let success, let timeout, let statusCode, let headers, let data) = destination {
                    return CallbackWrapper<Output>.run(ctx, (success, timeout, statusCode, headers, data))
                }
                
                /// Define the callback to avoid dupolication
                typealias ResponseCallback = session_network_response_t
                let cCallback: ResponseCallback = { success, timeout, statusCode, cHeaders, cHeadersLen, dataPtr, dataLen, ctx in
                    let headers: [String: String] = LibSessionNetwork.headers(cHeaders, cHeadersLen)
                    let data: Data? = dataPtr.map { Data(bytes: $0, count: dataLen) }
                    CallbackWrapper<Output>.run(ctx, (success, timeout, Int(statusCode), headers, data))
                }
                let request: LibSessionNetwork.Request<Data> = LibSessionNetwork.Request(
                    endpoint: endpoint,
                    body: finalRequestInfo.body,
                    category: category,
                    requestTimeout: requestTimeout,
                    overallTimeout: overallTimeout
                )
                
                switch finalRequestInfo.destination {
                    case .snode(let snode, _):
                        try LibSessionNetwork.withSnodeRequestParams(request, snode) { paramsPtr in
                            session_network_send_request(finalRequestInfo.network, paramsPtr, cCallback, ctx)
                        }
                        
                    case .server(let info), .serverUpload(let info, _), .serverDownload(let info):
                        let uploadFileName: String? = {
                            switch destination {
                                case .serverUpload(_, let fileName): return fileName
                                default: return nil
                            }
                        }()
                        
                        try LibSessionNetwork.withServerRequestParams(request, info, uploadFileName) { paramsPtr in
                            session_network_send_request(finalRequestInfo.network, paramsPtr, cCallback, ctx)
                        }
                        
                    /// Some destinations are for convenience and redirect to "proper" destination types so if one of them gets here
                    /// then it is invalid
                    default: throw NetworkError.invalidPreparedRequest
                }
            }
            .tryMap { [dependencies] success, timeout, statusCode, headers, maybeData -> (any ResponseInfoType, Data) in
                let response: Response = (success, timeout, statusCode, headers, maybeData)
                try LibSessionNetwork.throwErrorIfNeeded(response, using: dependencies)
                
                guard let data: Data = maybeData else { throw NetworkError.parsingFailed }
                
                return (Network.ResponseInfo(code: statusCode, headers: headers), data)
            }
            .eraseToAnyPublisher()
    }
    
    func send<E: EndpointType>(
        endpoint: E,
        destination: Network.Destination,
        body: Data?,
        category: Network.RequestCategory,
        requestTimeout: TimeInterval,
        overallTimeout: TimeInterval?
    ) async throws -> (info: ResponseInfoType, value: Data?) {
        switch destination {
            case .snode, .server, .serverUpload, .serverDownload, .cached:
                return try await sendRequest(
                    endpoint: endpoint,
                    destination: destination,
                    body: body,
                    category: category,
                    requestTimeout: requestTimeout,
                    overallTimeout: overallTimeout
                )
                
            case .randomSnode(let swarmPublicKey):
                guard body != nil else { throw NetworkError.invalidPreparedRequest }
                
                let swarm: Set<LibSession.Snode> = try await getSwarm(for: swarmPublicKey)
                let swarmDrainer: SwarmDrainer = SwarmDrainer(swarm: swarm, using: dependencies)
                let snode: LibSession.Snode = try await swarmDrainer.selectNextNode()
                
                return try await self.sendRequest(
                    endpoint: endpoint,
                    destination: .snode(snode, swarmPublicKey: swarmPublicKey),
                    body: body,
                    category: category,
                    requestTimeout: requestTimeout,
                    overallTimeout: overallTimeout
                )
        }
    }
    
    func checkClientVersion(ed25519SecretKey: [UInt8]) async throws -> (info: ResponseInfoType, value: Network.FileServer.AppVersionResponse) {
        typealias Continuation = CheckedContinuation<Response, Error>
        
        let network = try await getOrCreateNetwork()
        var cEd25519SecretKey: [UInt8] = Array(ed25519SecretKey)
        
        guard ed25519SecretKey.count == 64 else { throw LibSessionError.invalidCConversion }
        let paramsPtr: UnsafeMutablePointer<session_request_params> = try session_file_server_get_client_version(
            CLIENT_PLATFORM_IOS,
            &cEd25519SecretKey,
            Int64(floor(Network.defaultTimeout * 1000)),
            0
        ) ?? { throw NetworkError.invalidPreparedRequest }()
        defer { session_request_params_free(paramsPtr) }
        
        let result: Response = try await withCheckedThrowingContinuation { continuation in
            let box = LibSessionNetwork.ContinuationBox(continuation)
            session_network_send_request(network, paramsPtr, box.cCallback, box.unsafePointer())
        }
        
        try LibSessionNetwork.throwErrorIfNeeded(result, using: dependencies)
        let data: Data = try result.data ?? { throw NetworkError.parsingFailed }()
        
        return (
            Network.ResponseInfo(code: result.statusCode),
            try Network.FileServer.AppVersionResponse.decoded(from: data, using: dependencies)
        )
    }
    
    public func resetNetworkStatus() async {
        guard !isSuspended, let network = try? await getOrCreateNetwork() else { return }
        
        let status: NetworkStatus = NetworkStatus(status: session_network_get_status(network))
        
        Log.info(.network, "Network status changed to: \(status)")
        await internalNetworkStatus.send(status)
    }
    
    public func setNetworkStatus(status: NetworkStatus) async {
        guard status == .disconnected || !isSuspended else {
            Log.warn(.network, "Attempted to update network status to '\(status)' for suspended network, closing connections again.")
            
            switch network {
                case .none: return
                case .some(let network): return session_network_close_connections(network)
            }
        }
        
        /// If we have set the `forceOffline` flag then don't allow non-disconnected status updates
        guard status == .disconnected || !dependencies[feature: .forceOffline] else { return }
        
        /// Notify any subscribers
        Log.info(.network, "Network status changed to: \(status)")
        await internalNetworkStatus.send(status)
    }
    
    public func suspendNetworkAccess() async {
        Log.info(.network, "Network access suspended.")
        isSuspended = true
        syncState.update(isSuspended: true)
        await setNetworkStatus(status: .disconnected)
        
        switch network {
            case .none: break
            case .some(let network): session_network_suspend(network)
        }
    }
    
    public func resumeNetworkAccess(autoReconnect: Bool) async {
        isSuspended = false
        syncState.update(isSuspended: false)
        Log.info(.network, "Network access resumed.")
        
        switch network {
            case .none: break
            case .some(let network): session_network_resume(network, autoReconnect)
        }
    }
    
    public func finishCurrentObservations() async {
        await internalNetworkStatus.finishCurrentStreams()
    }
    
    public func clearCache() async {
        switch network {
            case .none: break
            case .some(let network): session_network_clear_cache(network)
        }
    }
    
    // MARK: - Internal Functions
    
    private func getOrCreateNetwork() async throws -> UnsafeMutablePointer<network_object_v2> {
        guard !isSuspended else {
            Log.warn(.network, "Attempted to access suspended network.")
            throw NetworkError.suspended
        }
        
        switch (network, dependencies[feature: .forceOffline]) {
            case (_, true):
                try await Task.sleep(for: .seconds(1))
                throw NetworkError.serviceUnavailable
                
            case (.some(let existingNetwork), _): return existingNetwork
            
            case (.none, _):
                guard let cCachePath: [CChar] = LibSessionNetwork.snodeCachePath.cString(using: .utf8) else {
                    Log.error(.network, "Unable to create network object: \(LibSessionError.invalidCConversion)")
                    throw NetworkError.invalidState
                }
                
                var error: [CChar] = [CChar](repeating: 0, count: 256)
                var network: UnsafeMutablePointer<network_object_v2>?
                var cDevnetNodes: [network_service_node] = []
                var config: session_network_config = session_network_config_default()
                config.cache_refresh_using_legacy_endpoint = true
                config.onionreq_single_path_mode = singlePathMode
                
                switch (dependencies[feature: .serviceNetwork], dependencies[feature: .devnetConfig], dependencies[feature: .devnetConfig].isValid) {
                    case (.mainnet, _, _): config.netid = SESSION_NETWORK_MAINNET
                    case (.testnet, _, _), (_, _, false):
                        config.netid = SESSION_NETWORK_TESTNET
                        config.enforce_subnet_diversity = false /// On testnet we can't do this as nodes share IPs
                        
                    case (.devnet, let devnetConfig, true):
                        config.netid = SESSION_NETWORK_DEVNET
                        config.enforce_subnet_diversity = false /// Devnet nodes likely share IPs as well
                        cDevnetNodes = [LibSession.Snode(devnetConfig).cSnode]
                }
                
                switch dependencies[feature: .router] {
                    case .onionRequests: config.router = SESSION_NETWORK_ROUTER_ONION_REQUESTS
                    case .lokinet: config.router = SESSION_NETWORK_ROUTER_LOKINET
                    case .direct: config.router = SESSION_NETWORK_ROUTER_DIRECT
                }
                
                /// If it's not the main app then we want to run in "Single Path Mode" (no use creating extra paths in the extensions)
                if !dependencies[singleton: .appContext].isMainApp {
                    config.onionreq_single_path_mode = true
                }
                
                try cCachePath.withUnsafeBufferPointer { cachePtr in
                    try cDevnetNodes.withUnsafeBufferPointer { devnetNodesPtr in
                        config.cache_dir = cachePtr.baseAddress
                        
                        /// Only set the devnet pointers if we are in devnet mode
                        if config.netid == SESSION_NETWORK_DEVNET {
                            config.devnet_seed_nodes = devnetNodesPtr.baseAddress
                            config.devnet_seed_nodes_size = devnetNodesPtr.count
                        }
                        
                        guard session_network_init(&network, &config, &error) else {
                            Log.error(.network, "Unable to create network object: \(String(cString: error))")
                            throw NetworkError.invalidState
                        }
                    }
                }
                
                /// Store the newly created network
                self.network = network
                self.networkInstance.send(network)
                
                session_network_set_status_changed_callback(network, { cStatus, ctx in
                    guard let ctx: UnsafeMutableRawPointer = ctx else { return }
                    
                    let status: NetworkStatus = NetworkStatus(status: cStatus)
                    let dependencies: Dependencies = Unmanaged<Dependencies>.fromOpaque(ctx).takeUnretainedValue()
                    
                    // Kick off a task so we don't hold up the libSession thread that triggered the update
                    Task { [network = dependencies[singleton: .network]] in
                        await network.setNetworkStatus(status: status)
                    }
                }, dependenciesPtr)
                
                return try network ?? { throw NetworkError.invalidState }()
        }
    }
    
    private func sendRequest<T: Encodable>(
        endpoint: (any EndpointType),
        destination: Network.Destination,
        body: T?,
        category: Network.RequestCategory,
        requestTimeout: TimeInterval,
        overallTimeout: TimeInterval?
    ) async throws -> (info: ResponseInfoType, value: Data?) {
        typealias Continuation = CheckedContinuation<Response, Error>
        
        let network = try await getOrCreateNetwork()
        let result: Response = try await withCheckedThrowingContinuation { continuation in
            let box = LibSessionNetwork.ContinuationBox(continuation)
            
            /// If it's a cached request then just return the cached result immediately
            if case .cached(let success, let timeout, let statusCode, let headers, let data) = destination {
                return box.continuation.resume(returning: (success, timeout, Int(statusCode), headers, data))
            }
            
            /// Define the callback to avoid dupolication
            let context = box.unsafePointer()
            let request: Request<T> = Request(
                endpoint: endpoint,
                body: body,
                category: category,
                requestTimeout: requestTimeout,
                overallTimeout: overallTimeout
            )
            
            do {
                switch destination {
                    case .snode(let snode, _):
                        try LibSessionNetwork.withSnodeRequestParams(request, snode) { paramsPtr in
                            session_network_send_request(network, paramsPtr, box.cCallback, context)
                        }
                        
                    case .server(let info), .serverUpload(let info, _), .serverDownload(let info):
                        let uploadFileName: String? = {
                            switch destination {
                                case .serverUpload(_, let fileName): return fileName
                                default: return nil
                            }
                        }()
                        
                        try LibSessionNetwork.withServerRequestParams(request, info, uploadFileName) { paramsPtr in
                            session_network_send_request(network, paramsPtr, box.cCallback, context)
                        }
                        
                    /// Some destinations are for convenience and redirect to "proper" destination types so if one of them gets here
                    /// then it is invalid
                    default: throw NetworkError.invalidPreparedRequest
                }
            }
            catch { box.continuation.resume(throwing: error) }
        }
        
        try LibSessionNetwork.throwErrorIfNeeded(result, using: dependencies)
        return (Network.ResponseInfo(code: result.statusCode, headers: result.headers), result.data)
    }
    
    private static func throwErrorIfNeeded(_ response: Response, using dependencies: Dependencies) throws {
        guard !response.success || response.statusCode < 200 || response.statusCode > 299 else { return }
        guard !response.timeout else {
            switch response.data.map({ String(data: $0, encoding: .ascii) }) {
                case .none: throw NetworkError.timeout(error: "\(NetworkError.unknown)", rawData: response.data)
                case .some(let responseString):
                    throw NetworkError.timeout(error: responseString, rawData: response.data)
            }
        }
        
        /// Handle status codes with specific meanings
        switch (response.statusCode, response.data.map { String(data: $0, encoding: .ascii) }) {
            case (400, .none):
                throw NetworkError.badRequest(error: "\(NetworkError.unknown)", rawData: response.data)
                
            case (400, .some(let responseString)):
                throw NetworkError.badRequest(error: responseString, rawData: response.data)
                
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
                
                throw SnodeAPIError.nodeNotFound(String(responseString.suffix(64)))
                
            case (504, _): throw NetworkError.gatewayTimeout
            case (_, .none): throw NetworkError.unknown
            case (_, .some(let responseString)):
                throw NetworkError.requestFailed(error: responseString, rawData: response.data)
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

private extension LibSessionNetwork {
    class ContinuationBox<T> {
        let continuation: T
        
        init(_ continuation: T) {
            self.continuation = continuation
        }
        
        // MARK: - Functions
        
        public func unsafePointer() -> UnsafeMutableRawPointer { Unmanaged.passRetained(self).toOpaque() }
        public static func from(unsafePointer: UnsafeMutableRawPointer?) -> ContinuationBox<T>? {
            guard let ptr: UnsafeMutableRawPointer = unsafePointer else { return nil }
            
            return Unmanaged<ContinuationBox<T>>.fromOpaque(ptr).takeRetainedValue()
        }
    }
    
    class FutureBox<T> {
        var promise: ((Result<T, any Error>) -> Void)?
        
        static func create(_ closure: @escaping (UnsafeMutableRawPointer) -> Void) -> AnyPublisher<T, Error> {
            let box: FutureBox<T> = FutureBox()
            
            return Future { [box] promise in
                box.promise = promise
                
                let ptr = Unmanaged.passRetained(box).toOpaque()
                closure(ptr)
            }.eraseToAnyPublisher()
        }
        
        init() {}
        
        // MARK: - Functions
        
        public static func resolve(result: T, ptr: UnsafeMutableRawPointer?) {
            guard let ptr: UnsafeMutableRawPointer = ptr else { return }
            
            Unmanaged<FutureBox<T>>
                .fromOpaque(ptr)
                .takeRetainedValue()
                .promise?(.success(result))
        }
        
        public static func fail(error: Error, ptr: UnsafeMutableRawPointer?) {
            guard let ptr: UnsafeMutableRawPointer = ptr else { return }
            
            Unmanaged<FutureBox<T>>
                .fromOpaque(ptr)
                .takeRetainedValue()
                .promise?(.failure(error))
        }
    }
}

extension LibSessionNetwork.ContinuationBox where T == CheckedContinuation<LibSessionNetwork.Response, Error> {
    var cCallback: session_network_response_t {
        return { success, timeout, statusCode, cHeaders, cHeadersLen, dataPtr, dataLen, ctx in
            guard let box = LibSessionNetwork.ContinuationBox<T>.from(unsafePointer: ctx) else {
                return
            }
            
            let headers: [String: String] = LibSessionNetwork.headers(cHeaders, cHeadersLen)
            let data: Data? = dataPtr.map { Data(bytes: $0, count: dataLen) }
            box.continuation.resume(returning: (success, timeout, Int(statusCode), headers, data))
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
    public struct Path {
        public let nodes: [LibSession.Snode]
        public let category: Network.RequestCategory?
        public let destinationPubkey: String?
        public let destinationSnodeAddress: String?
    }
}

extension LibSession {
    public struct Snode: Codable, Hashable, CustomStringConvertible {
        public let ed25519PubkeyHex: String
        public let ip: String
        public let httpsPort: UInt16
        public let omqPort: UInt16
        public let version: String
        public let swarmId: UInt64
        
        public var httpsAddress: String { "\(ip):\(httpsPort)" }
        public var omqAddress: String { "\(ip):\(omqPort)" }
        public var description: String { omqAddress }
        
        public var cSnode: network_service_node {
            var result: network_service_node = network_service_node()
            result.set(\.ed25519_pubkey_hex, to: ed25519PubkeyHex)
            result.ipString = ip
            result.set(\.https_port, to: httpsPort)
            result.set(\.omq_port, to: omqPort)
            result.versionString = version
            result.set(\.swarm_id, to: swarmId)
            
            return result
        }
        
        init(_ cSnode: network_service_node) {
            ed25519PubkeyHex = cSnode.get(\.ed25519_pubkey_hex)
            ip = cSnode.ipString
            httpsPort = cSnode.get(\.https_port)
            omqPort = cSnode.get(\.omq_port)
            version = cSnode.versionString
            swarmId = cSnode.get(\.swarm_id)
        }
        
        internal init(_ config: ServiceNetwork.DevnetConfiguration) {
            self.ed25519PubkeyHex = config.pubkey
            self.ip = config.ip
            self.httpsPort = config.httpPort
            self.omqPort = config.omqPort
            self.version = ""
            self.swarmId = 0
        }
        
        internal init(
            ed25519PubkeyHex: String,
            ip: String,
            httpsPort: UInt16,
            quicPort: UInt16,
            version: String,
            swarmId: UInt64
        ) {
            self.ed25519PubkeyHex = ed25519PubkeyHex
            self.ip = ip
            self.httpsPort = httpsPort
            self.omqPort = quicPort
            self.version = version
            self.swarmId = swarmId
        }
        
        public func hash(into hasher: inout Hasher) {
            ed25519PubkeyHex.hash(into: &hasher)
            ip.hash(into: &hasher)
            httpsPort.hash(into: &hasher)
            omqPort.hash(into: &hasher)
            version.hash(into: &hasher)
            swarmId.hash(into: &hasher)
        }
        
        public static func == (lhs: Snode, rhs: Snode) -> Bool {
            return (
                lhs.ed25519PubkeyHex == rhs.ed25519PubkeyHex &&
                lhs.ip == rhs.ip &&
                lhs.httpsPort == rhs.httpsPort &&
                lhs.omqPort == rhs.omqPort &&
                lhs.version == rhs.version &&
                lhs.swarmId == rhs.swarmId
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
    
    var versionString: String {
        get { "\(version.0).\(version.1).\(version.2)" }
        set {
            let versionParts: [UInt16] = newValue
                .components(separatedBy: ".")
                .compactMap { UInt16($0) }
            
            guard versionParts.count == 3 else { return }
            
            self.version = (versionParts[0], versionParts[1], versionParts[2])
        }
    }
}

// MARK: - Convenience

private extension LibSessionNetwork {
    struct Request<T: Encodable> {
        let endpoint: (any EndpointType)
        let body: T?
        let category: Network.RequestCategory
        let requestTimeout: TimeInterval
        let overallTimeout: TimeInterval?
    }
    
    static func withSnodeRequestParams<T: Encodable, Result>(
        _ request: Request<T>,
        _ node: LibSession.Snode,
        _ callback: (UnsafePointer<session_request_params>) -> Result
    ) throws -> Result {
        var cSnode = node.cSnode
        
        return try withBodyPointer(request.body) { cBodyPtr, bodySize in
            withUnsafePointer(to: &cSnode) { cSnodePtr in
                request.endpoint.path.withCString { cEndpoint in
                    let params: session_request_params = session_request_params(
                        snode_dest: cSnodePtr,
                        server_dest: nil,
                        remote_addr_dest: nil,
                        endpoint: cEndpoint,
                        body: cBodyPtr,
                        body_size: bodySize,
                        category: request.category.libSessionValue,
                        request_timeout_ms: UInt64(Int64(floor(request.requestTimeout * 1000))),
                        overall_timeout_ms: UInt64(floor((request.overallTimeout ?? 0) * 1000)),
                        upload_file_name: nil,
                        request_id: nil
                    )
                    
                    return withUnsafePointer(to: params) { paramsPtr in
                        callback(paramsPtr)
                    }
                }
            }
        }
    }
    
    static func withServerRequestParams<T: Encodable, Result>(
        _ request: Request<T>,
        _ info: Network.Destination.ServerInfo,
        _ uploadFileName: String?,
        _ callback: (UnsafePointer<session_request_params>) -> Result
    ) throws -> Result {
        return try withBodyPointer(request.body) { cBodyPtr, bodySize in
            let pathWithParams: String = Network.Destination.generatePathWithParams(
                endpoint: request.endpoint,
                queryParameters: info.queryParameters
            )
            
            return try pathWithParams.withCString { cEndpoint in
                try withFileNamePtr(uploadFileName) { cUploadFileNamePtr in
                    try info.withServerInfoPointer { cServerDestinationPtr in
                        let params: session_request_params = session_request_params(
                            snode_dest: nil,
                            server_dest: cServerDestinationPtr,
                            remote_addr_dest: nil,
                            endpoint: cEndpoint,
                            body: cBodyPtr,
                            body_size: bodySize,
                            category: request.category.libSessionValue,
                            request_timeout_ms: UInt64(floor(request.requestTimeout * 1000)),
                            overall_timeout_ms: UInt64(floor((request.overallTimeout ?? 0) * 1000)),
                            upload_file_name: cUploadFileNamePtr,
                            request_id: nil
                        )
                        
                        return withUnsafePointer(to: params) { paramsPtr in
                            callback(paramsPtr)
                        }
                    }
                }
            }
        }
    }
    
    private static func withFileNamePtr<Result>(
        _ uploadFilename: String?,
        _ closure: (UnsafePointer<Int8>?) throws -> Result
    ) throws -> Result {
        switch uploadFilename {
            case .none: return try closure(nil)
            case .some(let filename): return try filename.withCString { try closure($0) }
        }
    }

    private static func withBodyPointer<T: Encodable, Result>(
        _ body: T?,
        _ closure: (UnsafePointer<UInt8>?, Int) throws -> Result
    ) throws -> Result {
        let maybeBodyData: Data?
        
        switch body {
            case .none: maybeBodyData = nil
            case let data as Data: maybeBodyData = data
            case let bytes as [UInt8]: maybeBodyData = Data(bytes)
            default:
                guard let encodedBody: Data = try? JSONEncoder().encode(body) else {
                    throw SnodeAPIError.invalidPayload
                }
                
                maybeBodyData = encodedBody
        }
        
        guard let bodyData: Data = maybeBodyData, !bodyData.isEmpty else {
            return try closure(nil, 0)
        }
        
        return try bodyData.withUnsafeBytes { (rawPtr: UnsafeRawBufferPointer) in
            let ptr: UnsafePointer<UInt8>? = rawPtr.baseAddress?.assumingMemoryBound(to: UInt8.self)
            return try closure(ptr, bodyData.count)
        }
    }
}

private extension Network.Destination.ServerInfo {
    func withServerInfoPointer<Result>(_ body: (UnsafePointer<network_v2_server_destination>) -> Result) throws -> Result {
        let x25519PublicKey: String = String(x25519PublicKey.suffix(64)) // Quick way to drop '05' prefix if present
        
        guard let host: String = self.host else { throw NetworkError.invalidURL }
        guard x25519PublicKey.count == 64 || x25519PublicKey.count == 66 else {
            throw LibSessionError.invalidCConversion
        }
        
        let targetScheme: String = (self.scheme ?? "https")
        let port: UInt16 = UInt16(self.port ?? (targetScheme == "https" ? 443 : 80))
        let headersArray: [String] = headers.flatMap { [$0.key, $0.value] }
        
        // Use scoped closure to avoid manual memory management (crazy nesting but it ends up safer)
        return try method.rawValue.withCString { cMethodPtr in
            try targetScheme.withCString { cTargetSchemePtr in
                try host.withCString { cHostPtr in
                    try x25519PublicKey.withCString { cX25519PubkeyPtr in
                        try headersArray.withUnsafeCStrArray { headersArrayPtr in
                            let cServerDest = network_v2_server_destination(
                                method: cMethodPtr,
                                protocol: cTargetSchemePtr,
                                host: cHostPtr,
                                port: port,
                                x25519_pubkey_hex: cX25519PubkeyPtr,
                                headers_kv_pairs: headersArrayPtr.baseAddress,
                                headers_kv_pairs_len: headersArray.count
                            )
                            
                            return withUnsafePointer(to: cServerDest) { ptr in
                                body(ptr)
                            }
                        }
                    }
                }
            }
        }
    }
}

private extension LibSessionNetwork {
    static func headers(_ cHeaders: UnsafePointer<UnsafePointer<CChar>?>?, _ count: Int) -> [String: String] {
        let headersArray: [String] = ([String](cStringArray: cHeaders, count: count) ?? [])
        
        return stride(from: 0, to: headersArray.count, by: 2)
            .reduce(into: [:]) { result, index in
                if (index + index) < headersArray.count {
                    result[headersArray[index]] = headersArray[index + 1]
                }
            }
    }
}

public extension LibSession {
    actor NoopNetwork: NetworkType {
        public let isSuspended: Bool = false
        nonisolated public let networkStatus: AsyncStream<NetworkStatus> = .makeStream().stream
        nonisolated public let syncState: NetworkSyncState = NetworkSyncState()
        
        public init() {}
        
        public func getActivePaths() async throws -> [LibSession.Path] { return [] }
        public func getSwarm(for swarmPublicKey: String) async throws -> Set<LibSession.Snode> { return [] }
        public func getRandomNodes(count: Int) async throws -> Set<LibSession.Snode> { return [] }
        
        nonisolated public func send<E: EndpointType>(
            endpoint: E,
            destination: Network.Destination,
            body: Data?,
            category: Network.RequestCategory,
            requestTimeout: TimeInterval,
            overallTimeout: TimeInterval?
        ) -> AnyPublisher<(ResponseInfoType, Data?), Error> {
            return Fail(error: NetworkError.invalidState).eraseToAnyPublisher()
        }
        
        public func send<E: EndpointType>(
            endpoint: E,
            destination: Network.Destination,
            body: Data?,
            category: Network.RequestCategory,
            requestTimeout: TimeInterval,
            overallTimeout: TimeInterval?
        ) async throws -> (info: ResponseInfoType, value: Data?) {
            return (Network.ResponseInfo(code: -1), nil)
        }
        
        public func checkClientVersion(ed25519SecretKey: [UInt8]) async throws -> (info: ResponseInfoType, value: Network.FileServer.AppVersionResponse) {
            return (
                Network.ResponseInfo(code: -1),
                Network.FileServer.AppVersionResponse(
                    version: "",
                    updated: nil,
                    name: nil,
                    notes: nil,
                    assets: nil,
                    prerelease: nil
                )
            )
        }
        
        public func resetNetworkStatus() async {}
        public func setNetworkStatus(status: NetworkStatus) async {}
        public func suspendNetworkAccess() async {}
        public func resumeNetworkAccess(autoReconnect: Bool) async {}
        public func finishCurrentObservations() async {}
        public func clearCache() async {}
    }
}

extension session_network_config: @retroactive CAccessible, @retroactive CMutable {}
extension session_onion_path_metadata: @retroactive CAccessible {}
extension session_lokinet_tunnel_metadata: @retroactive CAccessible {}
