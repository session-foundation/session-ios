// Copyright © 2024 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import Combine
import SessionUtil
import SessionUtilitiesKit
import SignalCoreKit

// MARK: - LibSession

public extension LibSession {
    typealias CSNode = network_service_node
    
    private static let desiredLogCategories: [LogCategory] = [.network]
    
    private static var networkCache: Atomic<UnsafeMutablePointer<network_object>?> = Atomic(nil)
    private static var snodeCachePath: String { "\(OWSFileSystem.appSharedDataDirectoryPath())/snodeCache" }
    private static var lastPaths: Atomic<[Set<CSNode>]> = Atomic([])
    private static var lastNetworkStatus: Atomic<NetworkStatus> = Atomic(.unknown)
    private static var pathsChangedCallbacks: Atomic<[UUID: ([Set<CSNode>], UUID) -> ()]> = Atomic([:])
    private static var networkStatusCallbacks: Atomic<[UUID: (NetworkStatus) -> ()]> = Atomic([:])
    
    static var hasPaths: Bool { !lastPaths.wrappedValue.isEmpty }
    static var pathsDescription: String { lastPaths.wrappedValue.prettifiedDescription }
    
    typealias NodesCallback = (UnsafeMutablePointer<CSNode>?, Int) -> Void
    typealias NetworkCallback = (Bool, Bool, Int16, Data?) -> Void
    private class CWrapper<Callback> {
        let callback: Callback
        private var pointersToDeallocate: [UnsafeRawPointer?] = []
        
        public init(_ callback: Callback) {
            self.callback = callback
        }
        
        public func addUnsafePointerToCleanup<T>(_ pointer: UnsafePointer<T>?) {
            pointersToDeallocate.append(UnsafeRawPointer(pointer))
        }
        
        deinit {
            pointersToDeallocate.forEach { $0?.deallocate() }
        }
    }
    
    // MARK: - Public Interface
    
    static func createNetworkIfNeeded(using dependencies: Dependencies = Dependencies()) {
        getOrCreateNetwork()
            .subscribe(on: DispatchQueue.global(qos: .default), using: dependencies)
            .sinkUntilComplete()
    }
    
    static func onNetworkStatusChanged(callback: @escaping (NetworkStatus) -> ()) -> UUID {
        let callbackId: UUID = UUID()
        networkStatusCallbacks.mutate { $0[callbackId] = callback }
        
        // Trigger the callback immediately with the most recent status
        callback(lastNetworkStatus.wrappedValue)
        
        return callbackId
    }
    
    static func removeNetworkChangedCallback(callbackId: UUID?) {
        guard let callbackId: UUID = callbackId else { return }
        
        networkStatusCallbacks.mutate { $0.removeValue(forKey: callbackId) }
    }
    
    static func onPathsChanged(skipInitialCallbackIfEmpty: Bool = false, callback: @escaping ([Set<CSNode>], UUID) -> ()) -> UUID {
        let callbackId: UUID = UUID()
        pathsChangedCallbacks.mutate { $0[callbackId] = callback }
        
        // Trigger the callback immediately with the most recent status
        let lastPaths: [Set<CSNode>] = self.lastPaths.wrappedValue
        if !lastPaths.isEmpty || !skipInitialCallbackIfEmpty {
            callback(lastPaths, callbackId)
        }
        
        return callbackId
    }
    
    static func removePathsChangedCallback(callbackId: UUID?) {
        guard let callbackId: UUID = callbackId else { return }
        
        pathsChangedCallbacks.mutate { $0.removeValue(forKey: callbackId) }
    }
    
    static func addNetworkLogger() {
        getOrCreateNetwork().first().sinkUntilComplete(receiveValue: { network in
            network_add_logger(network, { lvl, namePtr, nameLen, msgPtr, msgLen in
                guard
                    LibSession.desiredLogCategories.contains(LogCategory(namePtr, nameLen)),
                    let msg: String = String(pointer: msgPtr, length: msgLen, encoding: .utf8)
                else { return }
                
                let trimmedLog: String = msg.trimmingCharacters(in: .whitespacesAndNewlines)
                switch lvl {
                    case LOG_LEVEL_TRACE: OWSLogger.verbose(trimmedLog)
                    case LOG_LEVEL_DEBUG: OWSLogger.debug(trimmedLog)
                    case LOG_LEVEL_INFO: OWSLogger.info(trimmedLog)
                    case LOG_LEVEL_WARN: OWSLogger.warn(trimmedLog)
                    case LOG_LEVEL_ERROR: OWSLogger.error(trimmedLog)
                    case LOG_LEVEL_CRITICAL: OWSLogger.error(trimmedLog)
                    case LOG_LEVEL_OFF: break
                    default: break
                }
                
                #if DEBUG
                print(trimmedLog)
                #endif
            })
        })
    }
    
    static func clearSnodeCache() {
        guard let network: UnsafeMutablePointer<network_object> = networkCache.wrappedValue else { return }
        
        network_clear_cache(network)
    }
    
    static func getSwarm(swarmPublicKey: String) -> AnyPublisher<Set<CSNode>, Error> {
        return getOrCreateNetwork()
            .flatMap { network in
                Deferred {
                    Future<Set<CSNode>, Error> { resolver in
                        let cSwarmPublicKey: [CChar] = swarmPublicKey.cArray.nullTerminated()
                        let callbackWrapper: CWrapper<NodesCallback> = CWrapper { swarmPtr, swarmSize in
                            guard
                                swarmSize > 0,
                                let cSwarm: UnsafeMutablePointer<CSNode> = swarmPtr
                            else { return resolver(Result.failure(SnodeAPIError.unableToRetrieveSwarm)) }
                            
                            var nodes: Set<CSNode> = []
                            (0..<swarmSize).forEach { index in nodes.insert(cSwarm[index]) }
                            resolver(Result.success(nodes))
                        }
                        let cWrapperPtr: UnsafeMutableRawPointer = Unmanaged.passRetained(callbackWrapper).toOpaque()
                        
                        network_get_swarm(network, cSwarmPublicKey, { swarmPtr, swarmSize, ctx in
                            Unmanaged<CWrapper<NodesCallback>>.fromOpaque(ctx!).takeRetainedValue()
                                .callback(swarmPtr, swarmSize)
                        }, cWrapperPtr);
                    }
                }
            }
            .eraseToAnyPublisher()
    }
    
    static func getRandomNodes(count: Int) -> AnyPublisher<Set<CSNode>, Error> {
        return getOrCreateNetwork()
            .flatMap { network in
                Deferred {
                    Future<Set<CSNode>, Error> { resolver in
                        let callbackWrapper: CWrapper<NodesCallback> = CWrapper { nodesPtr, nodesSize in
                            guard
                                nodesSize >= count,
                                let cSwarm: UnsafeMutablePointer<CSNode> = nodesPtr
                            else { return resolver(Result.failure(SnodeAPIError.unableToRetrieveSwarm)) }
                            
                            var nodes: Set<CSNode> = []
                            (0..<nodesSize).forEach { index in nodes.insert(cSwarm[index]) }
                            resolver(Result.success(nodes))
                        }
                        let cWrapperPtr: UnsafeMutableRawPointer = Unmanaged.passRetained(callbackWrapper).toOpaque()
                        
                        network_get_random_nodes(network, UInt16(count), { nodesPtr, nodesSize, ctx in
                            Unmanaged<CWrapper<NodesCallback>>.fromOpaque(ctx!).takeRetainedValue()
                                .callback(nodesPtr, nodesSize)
                        }, cWrapperPtr);
                    }
                }
            }
            .eraseToAnyPublisher()
    }
    
    static func sendOnionRequest<T: Encodable>(
        to destination: OnionRequestAPIDestination,
        body: T?,
        swarmPublicKey: String?,
        timeout: TimeInterval,
        using dependencies: Dependencies
    ) -> AnyPublisher<(ResponseInfoType, Data?), Error> {
        return getOrCreateNetwork()
            .tryFlatMap { network in
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
                
                return Deferred {
                    Future<(ResponseInfoType, Data?), Error> { resolver in
                        let callbackWrapper: CWrapper<NetworkCallback> = CWrapper { success, timeout, statusCode, data in
                            switch processError(success, timeout, statusCode, data, using: dependencies) {
                                case .some(let error): resolver(Result.failure(error))
                                case .none: resolver(Result.success((Network.ResponseInfo(code: Int(statusCode), headers: [:]), data)))
                            }
                        }
                        let cWrapperPtr: UnsafeMutableRawPointer = Unmanaged.passRetained(callbackWrapper).toOpaque()
                        
                        // Trigger the request
                        switch destination {
                            case .snode(let snode):
                                let cSwarmPublicKey: UnsafePointer<CChar>? = swarmPublicKey.map {
                                    $0.cArray.nullTerminated().unsafeCopy()
                                }
                                callbackWrapper.addUnsafePointerToCleanup(cSwarmPublicKey)
                                
                                network_send_onion_request_to_snode_destination(
                                    network,
                                    snode,
                                    cPayloadBytes,
                                    cPayloadBytes.count,
                                    cSwarmPublicKey,
                                    Int64(floor(timeout * 1000)),
                                    { success, timeout, statusCode, dataPtr, dataLen, ctx in
                                        let data: Data? = dataPtr.map { Data(bytes: $0, count: dataLen) }
                                        Unmanaged<CWrapper<NetworkCallback>>.fromOpaque(ctx!).takeRetainedValue()
                                            .callback(success, timeout, statusCode, data)
                                    },
                                    cWrapperPtr
                                )
                                
                            case .server(let method, let scheme, let host, let endpoint, let port, let headers, let x25519PublicKey):
                                let targetScheme: String = (scheme ?? "https")
                                let cMethod: UnsafePointer<CChar>? = (method ?? "GET").cArray
                                    .nullTerminated()
                                    .unsafeCopy()
                                let cTargetScheme: UnsafePointer<CChar>? = targetScheme.cArray
                                    .nullTerminated()
                                    .unsafeCopy()
                                let cHost: UnsafePointer<CChar>? = host.cArray
                                    .nullTerminated()
                                    .unsafeCopy()
                                let cEndpoint: UnsafePointer<CChar>? = endpoint.cArray
                                    .nullTerminated()
                                    .unsafeCopy()
                                let cX25519Pubkey: UnsafePointer<CChar>? = x25519PublicKey.cArray
                                    .nullTerminated()
                                    .unsafeCopy()
                                let headerInfo: [(key: String, value: String)]? = headers?.map { ($0.key, $0.value) }
                                let cHeaderKeysContent: [UnsafePointer<CChar>?] = (headerInfo ?? [])
                                    .map { $0.key.cArray.nullTerminated() }
                                    .unsafeCopy()
                                let cHeaderValuesContent: [UnsafePointer<CChar>?] = (headerInfo ?? [])
                                    .map { $0.value.cArray.nullTerminated() }
                                    .unsafeCopy()
                                let cHeaderKeys: UnsafeMutablePointer<UnsafePointer<CChar>?>? = cHeaderKeysContent
                                    .unsafeCopy()
                                let cHeaderValues: UnsafeMutablePointer<UnsafePointer<CChar>?>? = cHeaderValuesContent
                                    .unsafeCopy()
                                let cServerDestination = network_server_destination(
                                    method: cMethod,
                                    protocol: cTargetScheme,
                                    host: cHost,
                                    endpoint: cEndpoint,
                                    port: (port ?? (targetScheme == "https" ? 443 : 80)),
                                    x25519_pubkey: cX25519Pubkey,
                                    headers: cHeaderKeys,
                                    header_values: cHeaderValues,
                                    headers_size: (headerInfo ?? []).count
                                )
                                
                                // Add a cleanup callback to deallocate the header arrays
                                callbackWrapper.addUnsafePointerToCleanup(cMethod)
                                callbackWrapper.addUnsafePointerToCleanup(cTargetScheme)
                                callbackWrapper.addUnsafePointerToCleanup(cHost)
                                callbackWrapper.addUnsafePointerToCleanup(cEndpoint)
                                callbackWrapper.addUnsafePointerToCleanup(cX25519Pubkey)
                                cHeaderKeysContent.forEach { callbackWrapper.addUnsafePointerToCleanup($0) }
                                cHeaderValuesContent.forEach { callbackWrapper.addUnsafePointerToCleanup($0) }
                                callbackWrapper.addUnsafePointerToCleanup(cHeaderKeys)
                                callbackWrapper.addUnsafePointerToCleanup(cHeaderValues)
                                
                                network_send_onion_request_to_server_destination(
                                    network,
                                    cServerDestination,
                                    cPayloadBytes,
                                    cPayloadBytes.count,
                                    Int64(floor(timeout * 1000)),
                                    { success, timeout, statusCode, dataPtr, dataLen, ctx in
                                        let data: Data? = dataPtr.map { Data(bytes: $0, count: dataLen) }
                                        Unmanaged<CWrapper<NetworkCallback>>.fromOpaque(ctx!).takeRetainedValue()
                                            .callback(success, timeout, statusCode, data)
                                    },
                                    cWrapperPtr
                                )
                        }
                    }
                }
            }
            .eraseToAnyPublisher()
    }
    
    // MARK: - Internal Functions
    
    private static func getOrCreateNetwork() -> AnyPublisher<UnsafeMutablePointer<network_object>?, Error> {
        guard networkCache.wrappedValue == nil else {
            return Just(networkCache.wrappedValue)
                .setFailureType(to: Error.self)
                .eraseToAnyPublisher()
        }
        
        return Deferred {
            Future<UnsafeMutablePointer<network_object>?, Error> { resolver in
                let network: UnsafeMutablePointer<network_object>? = networkCache.mutate { cachedNetwork in
                    // It's possible for two threads to get past the initial `wrappedValue` check so just
                    // in case check and return the cached value if set
                    if let existingNetwork: UnsafeMutablePointer<network_object> = cachedNetwork {
                        return existingNetwork
                    }
                    
                    // Otherwise create a new network
                    var error: [CChar] = [CChar](repeating: 0, count: 256)
                    var network: UnsafeMutablePointer<network_object>?
                    let cCachePath: [CChar] = snodeCachePath.cArray.nullTerminated()
                    
                    guard network_init(&network, cCachePath, Features.useTestnet, true, &error) else {
                        SNLog("[LibQuic Error] Unable to create network object: \(String(cString: error))")
                        return nil
                    }
                    
                    // Register for network status changes
                    network_set_status_changed_callback(network, { status, _ in
                        LibSession.updateNetworkStatus(cStatus: status)
                    }, nil)
                    
                    // Register for path changes
                    network_set_paths_changed_callback(network, { pathsPtr, pathsLen, _ in
                        LibSession.updatePaths(cPathsPtr: pathsPtr, pathsLen: pathsLen)
                    }, nil)
                    
                    cachedNetwork = network
                    return network
                }
                
                switch network {
                    case .none: resolver(Result.failure(SnodeAPIError.invalidNetwork))
                    case .some(let network): resolver(Result.success(network))
                }
            }
        }.eraseToAnyPublisher()
    }
    
    private static func updateNetworkStatus(cStatus: CONNECTION_STATUS) {
        let status: NetworkStatus = NetworkStatus(status: cStatus)
        
        SNLog("Network status changed to: \(status)")
        lastNetworkStatus.mutate { lastNetworkStatus in
            lastNetworkStatus = status
            
            networkStatusCallbacks.wrappedValue.forEach { _, callback in
                callback(status)
            }
        }
    }
    
    private static func updatePaths(cPathsPtr: UnsafeMutablePointer<onion_request_path>?, pathsLen: Int) {
        var paths: [Set<CSNode>] = []
        
        if let cPathsPtr: UnsafeMutablePointer<onion_request_path> = cPathsPtr {
            var cPaths: [onion_request_path] = []
            
            (0..<pathsLen).forEach { index in
                cPaths.append(cPathsPtr[index])
            }
            
            // Copy the nodes over as the memory will be freed after the callback is run
            paths = cPaths.map { cPath in
                var nodes: Set<CSNode> = []
                (0..<cPath.nodes_count).forEach { index in
                    nodes.insert(cPath.nodes[index].copy())
                }
                return nodes
            }
        }
        
        lastPaths.mutate { lastPaths in
            lastPaths = paths
            
            pathsChangedCallbacks.wrappedValue.forEach { id, callback in
                callback(paths, id)
            }
        }
    }
    
    private static func processError(
        _ success: Bool,
        _ timeout: Bool,
        _ statusCode: Int16,
        _ data: Data?,
        using dependencies: Dependencies
    ) -> Error? {
        guard !success || statusCode < 200 || statusCode > 299 else { return nil }
        guard !timeout else { return NetworkError.timeout }
        
        /// Handle status codes with specific meanings
        switch (statusCode, data.map { String(data: $0, encoding: .ascii) }) {
            case (400, .none):
                return NetworkError.badRequest(error: NetworkError.unknown.errorDescription ?? "Bad Request", rawData: data)
                
            case (400, .some(let responseString)): return NetworkError.badRequest(error: responseString, rawData: data)
                
            case (401, _):
                SNLog("Unauthorised (Failed to verify the signature).")
                return NetworkError.unauthorised
                
            case (404, _): return NetworkError.notFound
                
            /// A snode will return a `406` but onion requests v4 seems to return `425` so handle both
            case (406, _), (425, _):
                SNLog("The user's clock is out of sync with the service node network.")
                return SnodeAPIError.clockOutOfSync
            
            case (421, _): return SnodeAPIError.unassociatedPubkey
            case (429, _): return SnodeAPIError.rateLimited
            case (500, _), (502, _), (503, _): return SnodeAPIError.internalServerError
            case (_, .none): return NetworkError.unknown
            case (_, .some(let responseString)):
                // An internal server error could return HTML data, this is an attempt to intercept that case
                guard !responseString.starts(with: "500 Internal Server Error") else {
                    return SnodeAPIError.internalServerError
                }
                
                return NetworkError.requestFailed(error: responseString, rawData: data)
        }
    }
}

// MARK: - NetworkStatus

extension LibSession {
    public enum NetworkStatus {
        case unknown
        case connecting
        case connected
        case disconnected
        
        init(status: CONNECTION_STATUS) {
            switch status {
                case CONNECTION_STATUS_CONNECTING: self = .connecting
                case CONNECTION_STATUS_CONNECTED: self = .connected
                case CONNECTION_STATUS_DISCONNECTED: self = .disconnected
                default: self = .unknown
            }
        }
    }
}

// MARK: - LogCategory

extension LibSession {
    enum LogCategory: String {
        case quic
        case network
        case unknown
        
        init(_ namePtr: UnsafePointer<CChar>?, _ nameLen: Int) {
            switch String(pointer: namePtr, length: nameLen, encoding: .utf8).map({ LogCategory(rawValue: $0) }) {
                case .some(let cat): self = cat
                case .none: self = .unknown
            }
        }
    }
}

// MARK: - CSNode Conformance and Convenience

extension LibSession.CSNode: Hashable, CustomStringConvertible {
    public var ipString: String { "\(ip.0).\(ip.1).\(ip.2).\(ip.3)" }
    public var address: String { "\(ipString):\(quic_port)" }
    public var x25519PubkeyHex: String { String(libSessionVal: x25519_pubkey_hex) }
    public var ed25519PubkeyHex: String { String(libSessionVal: ed25519_pubkey_hex) }
    
    public var description: String { address }
    
    public func copy() -> LibSession.CSNode {
        return LibSession.CSNode(
            ip: ip,
            quic_port: quic_port,
            x25519_pubkey_hex: x25519_pubkey_hex,
            ed25519_pubkey_hex: ed25519_pubkey_hex,
            failure_count: failure_count,
            invalid: invalid
        )
    }
    
    public func hash(into hasher: inout Hasher) {
        ip.0.hash(into: &hasher)
        ip.1.hash(into: &hasher)
        ip.2.hash(into: &hasher)
        ip.3.hash(into: &hasher)
        quic_port.hash(into: &hasher)
        x25519PubkeyHex.hash(into: &hasher)
        ed25519PubkeyHex.hash(into: &hasher)
        failure_count.hash(into: &hasher)
        invalid.hash(into: &hasher)
    }
    
    public static func == (lhs: LibSession.CSNode, rhs: LibSession.CSNode) -> Bool {
        return (
            lhs.ip == rhs.ip &&
            lhs.quic_port == rhs.quic_port &&
            lhs.x25519PubkeyHex == rhs.x25519PubkeyHex &&
            lhs.ed25519PubkeyHex == rhs.ed25519PubkeyHex &&
            lhs.failure_count == rhs.failure_count &&
            lhs.invalid == rhs.invalid
        )
    }
}
