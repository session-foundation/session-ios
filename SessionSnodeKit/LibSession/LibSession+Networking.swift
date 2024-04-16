// Copyright © 2024 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import Combine
import SessionUtil
import SessionUtilitiesKit

// MARK: - LibSession

public extension LibSession {
    fileprivate static var networkCache: Atomic<(ed25519Pubkey: String, network: UnsafeMutablePointer<network_object>?)?> = Atomic(nil)
    
    struct ServiceNodeChanges {
        enum Change: UInt32 {
            case none = 0
            case invalidPath = 1
            case replaceSwarm = 2
            case updatePath = 3
            case updateNode = 4
        }
        
        let change: Change
        let nodes: [Snode]
        let nodeFailureCount: [UInt]
        let nodeInvalid: [Bool]
        let pathFailureCount: UInt
        let pathInvalid: Bool
        
        init(cChanges: network_service_node_changes) {
            self.change = (Change(rawValue: cChanges.type.rawValue) ?? .none)
            self.pathFailureCount = UInt(cChanges.failure_count)
            self.pathInvalid = cChanges.invalid
            
            guard cChanges.nodes_count > 0 else {
                self.nodes = []
                self.nodeInvalid = []
                self.nodeFailureCount = []
                return
            }
            
            var pendingNodes: [Snode] = []
            var pendingNodeFailureCount: [UInt] = []
            var pendingNodeInvalid: [Bool] = []
            let cNodes: UnsafePointer<network_service_node> = UnsafePointer<network_service_node>(cChanges.nodes)
            (0..<cChanges.nodes_count).forEach { index in
                pendingNodes.append(
                    Snode(
                        ip: String(libSessionVal: cNodes[index].ip),
                        lmqPort: cNodes[index].quic_port,
                        x25519PublicKey: String(libSessionVal: cNodes[index].x25519_pubkey_hex),
                        ed25519PublicKey: String(libSessionVal: cNodes[index].ed25519_pubkey_hex)
                    )
                )
                pendingNodeFailureCount.append(UInt(cNodes[index].failure_count))
                pendingNodeInvalid.append(cNodes[index].invalid)
            }
            self.nodes = pendingNodes
            self.nodeFailureCount = pendingNodeFailureCount
            self.nodeInvalid = pendingNodeInvalid
        }
    }
    
    private class CWrapper {
        let callback: (Bool, Bool, Int16, Data?, ServiceNodeChanges) -> Void
        private var pointersToDeallocate: [UnsafeRawPointer?] = []
        
        public init(_ callback: @escaping (Bool, Bool, Int16, Data?, ServiceNodeChanges) -> Void) {
            self.callback = callback
        }
        
        public func addUnsafePointerToCleanup<T>(_ pointer: UnsafePointer<T>?) {
            pointersToDeallocate.append(UnsafeRawPointer(pointer))
        }
        
        deinit {
            pointersToDeallocate.forEach { $0?.deallocate() }
        }
    }
    
    // MARK: - Internal Functions
    
    private static func getNetwork(ed25519SecretKey: [UInt8]?, canOverrideKey: Bool) throws -> UnsafeMutablePointer<network_object>? {
        guard let cEd25519SecretKey: [UInt8] = ed25519SecretKey else {
            throw SnodeAPIError.missingSecretKey
        }
        
        let ed25519Pubkey: String = String(cEd25519SecretKey.toHexString().suffix(32))
        
        // If we have an existing network and, either we can't override the key or the key matches then use
        // the existing network
        if
            let existingNetworkCache: (ed25519Pubkey: String, network: UnsafeMutablePointer<network_object>?) = networkCache.wrappedValue,
            let network: UnsafeMutablePointer<network_object> = existingNetworkCache.network,
            (
                !canOverrideKey ||
                existingNetworkCache.ed25519Pubkey == ed25519Pubkey
            )
        { return network }
        
        return try networkCache.mutate { networkCache in
            var error: [CChar] = [CChar](repeating: 0, count: 256)
            
            if let networkPtr: UnsafeMutablePointer<network_object> = networkCache?.network {
                networkCache = (ed25519Pubkey, networkPtr)
                guard network_replace_key(networkPtr, cEd25519SecretKey, &error) else {
                    SNLog("[LibQuic Error] Unable to replace network key: \(String(cString: error))")
                    throw SnodeAPIError.invalidNetwork
                }
                
                return networkPtr
            }
            
            var network: UnsafeMutablePointer<network_object>?
            
            guard network_init(&network, cEd25519SecretKey, &error) else {
                SNLog("[LibQuic Error] Unable to create network object: \(String(cString: error))")
                throw SnodeAPIError.invalidNetwork
            }
            networkCache = (ed25519Pubkey, network)
            
            return network
        }
    }
    
    private static func toCIp(ip: String) throws -> (UInt8, UInt8, UInt8, UInt8) {
        let result: [UInt8] = ip.split(separator: ".").compactMap { UInt8($0) }
        
        guard result.count == 4 else { throw SnodeAPIError.invalidIP }
        
        return (result[0], result[1], result[2], result[3])
    }
    
    private static func cSwarm(for swarmPublicKey: String?) -> (ptr: UnsafePointer<network_service_node>?, count: Int) {
        guard let swarm: Set<Snode> = swarmPublicKey.map({ SnodeAPI.swarmCache.wrappedValue[$0] }) else { return (nil, 0) }
        
        let cSwarm: UnsafePointer<network_service_node>? = swarm
            .enumerated()
            .map { index, snode in
                network_service_node(
                    ip: snode.ip.toLibSession(),
                    quic_port: snode.lmqPort,
                    x25519_pubkey_hex: snode.x25519PublicKey.toLibSession(),
                    ed25519_pubkey_hex: snode.ed25519PublicKey.toLibSession(),
                    failure_count: UInt8(SnodeAPI.snodeFailureCount.wrappedValue[snode] ?? 0),
                    invalid: false
                )
            }
            .unsafeCopy()
        
        return (cSwarm, swarm.count)
    }
    
    private static func processError(
        _ success: Bool,
        _ timeout: Bool,
        _ statusCode: Int16,
        _ data: Data?,
        _ changes: ServiceNodeChanges,
        _ swarmPublicKey: String?,
        using dependencies: Dependencies
    ) -> Error? {
        /// Process the `ServiceNodeChanges` before handling the error to ensure we have updated out snode cache correctly
        switch changes.change {
            case .none, .invalidPath: break
                
            case .updatePath, .updateNode:
                /// Update the failure count or drop any nodes flagged as invalid
                zip(changes.nodes, changes.nodeFailureCount, changes.nodeInvalid).forEach { snode, failureCount, invalid in
                    guard invalid else {
                        /// If the snode wasn't marked as invalid and it's failure count hasn't changed then do nothing
                        guard failureCount != (SnodeAPI.snodeFailureCount.wrappedValue[snode] ?? 0) else { return }
                        
                        SNLog("Couldn't reach snode at: \(snode); setting failure count to \(failureCount).")
                        SnodeAPI.snodeFailureCount.mutate { $0[snode] = failureCount }
                        return
                    }
                    
                    SNLog("Failure threshold reached for: \(snode); dropping it.")
                    if let publicKey: String = swarmPublicKey {
                        SnodeAPI.dropSnodeFromSwarmIfNeeded(snode, publicKey: publicKey)
                    }
                    SnodeAPI.dropSnodeFromSnodePool(snode)
                    SnodeAPI.snodeFailureCount.mutate { $0.removeValue(forKey: snode) }
                    SNLog("Snode pool count: \(SnodeAPI.snodePool.wrappedValue.count).")
                }
                
                /// There should never be a case where `pathInvalid` when the change is `updateNode` but including this just to be safe
                guard changes.change != .updateNode else { break }
                
                /// Update the path failure count or drop the path if invalid
                switch changes.pathInvalid {
                    case false: OnionRequestAPI.pathFailureCount.mutate { $0[changes.nodes] = changes.pathFailureCount }
                    case true:
                        LibSession.removePath(path: changes.nodes)
                        OnionRequestAPI.dropGuardSnode(changes.nodes.first)
                        OnionRequestAPI.drop(changes.nodes)
                }
                
            case .replaceSwarm:
                switch swarmPublicKey {
                    case .none: SNLog("Tried to replace the swarm without an associated public key.")
                    case .some(let publicKey): SnodeAPI.setSwarm(to: changes.nodes.asSet(), for: publicKey)
                }
        }
        
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
            case (500, _), (502, _), (503, _): return SnodeAPIError.unreachable
            case (_, .none): return NetworkError.unknown
            case (_, .some(let responseString)): return NetworkError.requestFailed(error: responseString, rawData: data)
        }
    }
    
    // MARK: - Public Interface
    
    static func addPath(path: [Snode]) {
        guard let ed25519SecretKey: [UInt8] = Identity.fetchUserEd25519KeyPair()?.secretKey else {
            SNLog("[LibSession] Unable to add path to network due to missing secret key.")
            return
        }
        
        let network: UnsafeMutablePointer<network_object>?
        let cNodes: UnsafePointer<network_service_node>?
        
        do {
            network = try getNetwork(ed25519SecretKey: ed25519SecretKey, canOverrideKey: true)
            cNodes = try path
                .enumerated()
                .map { index, snode in
                    network_service_node(
                        ip: try toCIp(ip: snode.ip),
                        quic_port: snode.lmqPort,
                        x25519_pubkey_hex: snode.x25519PublicKey.toLibSession(),
                        ed25519_pubkey_hex: snode.ed25519PublicKey.toLibSession(),
                        failure_count: UInt8(SnodeAPI.snodeFailureCount.wrappedValue[snode] ?? 0),
                        invalid: false
                    )
                }
                .unsafeCopy()
        }
        catch { return }
        
        let cOnionPath: onion_request_path = onion_request_path(
            nodes: cNodes,
            nodes_count: path.count,
            failure_count: UInt8(OnionRequestAPI.pathFailureCount.wrappedValue[path] ?? 0)
        )
        var error: [CChar] = [CChar](repeating: 0, count: 256)
        if !network_add_path(network, cOnionPath, &error) {
            SNLog("[LibSession] Failed to add path due to error: \(String(cString: error)).")
        }
        cNodes?.deallocate()
    }
    
    static func removePath(path: [Snode]) {
        guard let ed25519SecretKey: [UInt8] = Identity.fetchUserEd25519KeyPair()?.secretKey else {
            return SNLog("[LibSession] Unable to add path to network due to missing secret key.")
        }
        guard let snode: Snode = path.first else { return SNLog("[LibSession] Unable to remove empty path.") }
        
        let network: UnsafeMutablePointer<network_object>?
        let cNodeIp: (UInt8, UInt8, UInt8, UInt8)
        
        do {
            network = try getNetwork(ed25519SecretKey: ed25519SecretKey, canOverrideKey: true)
            cNodeIp = try toCIp(ip: snode.ip)
        }
        catch { return }
        
        let cNode: network_service_node = network_service_node(
            ip: cNodeIp,
            quic_port: snode.lmqPort,
            x25519_pubkey_hex: snode.x25519PublicKey.toLibSession(),
            ed25519_pubkey_hex: snode.ed25519PublicKey.toLibSession(),
            failure_count: UInt8(SnodeAPI.snodeFailureCount.wrappedValue[snode] ?? 0),
            invalid: false
        )
        var error: [CChar] = [CChar](repeating: 0, count: 256)
        if !network_remove_path(network, cNode, &error) {
            SNLog("[LibSession] Failed to remove path due to error: \(String(cString: error)).")
        }
    }
    
    static func addNetworkLogger(ed25519SecretKey: [UInt8]?) {
        network_add_logger(try? getNetwork(ed25519SecretKey: ed25519SecretKey, canOverrideKey: true), { logPtr, msgLen in
            guard let log: String = String(pointer: logPtr, length: msgLen, encoding: .utf8) else {
                print("[quic:info] Null log")
                return
            }
            
            print(log.trimmingCharacters(in: .whitespacesAndNewlines))
        })
    }
    
    static func sendDirectRequest<T: Encodable>(
        endpoint: any EndpointType,
        body: T?,
        snode: Snode,
        swarmPublicKey: String?,
        ed25519SecretKey: [UInt8]?,
        canOverrideKey: Bool = true,
        using dependencies: Dependencies
    ) -> AnyPublisher<(ResponseInfoType, Data?), Error> {
        return Deferred {
            Future<(ResponseInfoType, Data?), Error> { resolver in
                let network: UnsafeMutablePointer<network_object>?
                let cSnodeIp: (UInt8, UInt8, UInt8, UInt8)
                
                do {
                    network = try getNetwork(ed25519SecretKey: ed25519SecretKey, canOverrideKey: canOverrideKey)
                    cSnodeIp = try toCIp(ip: snode.ip)
                }
                catch { return resolver(Result.failure(error)) }
                
                // Prepare the parameters
                let cPayloadBytes: [UInt8]
                
                switch body {
                    case .none: cPayloadBytes = []
                    case let data as Data: cPayloadBytes = Array(data)
                    case let bytes as [UInt8]: cPayloadBytes = bytes
                    default:
                        guard let encodedBody: Data = try? JSONEncoder().encode(body) else {
                            return resolver(Result.failure(SnodeAPIError.invalidPayload))
                        }
                        
                        cPayloadBytes = Array(encodedBody)
                }
                let cTarget: network_service_node = network_service_node(
                    ip: cSnodeIp,
                    quic_port: snode.lmqPort,
                    x25519_pubkey_hex: snode.x25519PublicKey.toLibSession(),
                    ed25519_pubkey_hex: snode.ed25519PublicKey.toLibSession(),
                    failure_count: UInt8(SnodeAPI.snodeFailureCount.wrappedValue[snode] ?? 0),
                    invalid: false
                )
                let cSwarmInfo: (ptr: UnsafePointer<network_service_node>?, count: Int) = cSwarm(for: swarmPublicKey)
                let callbackWrapper: CWrapper = CWrapper { success, timeout, statusCode, data, changes in
                    switch processError(success, timeout, statusCode, data, changes, swarmPublicKey, using: dependencies) {
                        case .some(let error): resolver(Result.failure(error))
                        case .none: resolver(Result.success((Network.ResponseInfo(code: Int(statusCode), headers: [:]), data)))
                    }
                }
                callbackWrapper.addUnsafePointerToCleanup(cSwarmInfo.ptr)
                let cWrapperPtr: UnsafeMutableRawPointer = Unmanaged.passRetained(callbackWrapper).toOpaque()
                
                // Trigger the request
                network_send_request(
                    network,
                    cTarget,
                    endpoint.path.cArray.nullTerminated(),
                    cPayloadBytes,
                    cPayloadBytes.count,
                    cSwarmInfo.ptr,
                    cSwarmInfo.count,
                    { success, timeout, statusCode, dataPtr, dataLen, cChanges, ctx in
                        let data: Data? = dataPtr.map { Data(bytes: $0, count: dataLen) }
                        let changes: ServiceNodeChanges = ServiceNodeChanges(cChanges: cChanges)
                        Unmanaged<CWrapper>.fromOpaque(ctx!).takeRetainedValue()
                            .callback(success, timeout, statusCode, data, changes)
                    },
                    cWrapperPtr
                )
            }
        }.eraseToAnyPublisher()
    }
    
    static func sendOnionRequest<T: Encodable>(
        to destination: OnionRequestAPIDestination,
        body: T?,
        swarmPublicKey: String?,
        ed25519SecretKey: [UInt8]?,
        using dependencies: Dependencies
    ) -> AnyPublisher<(ResponseInfoType, Data?), Error> {
        return Deferred {
            Future<(ResponseInfoType, Data?), Error> { resolver in
                let network: UnsafeMutablePointer<network_object>?
                
                do { network = try getNetwork(ed25519SecretKey: ed25519SecretKey, canOverrideKey: true) }
                catch { return resolver(Result.failure(error)) }
                
                // Prepare the parameters
                let cPayloadBytes: [UInt8]
                
                switch body {
                    case .none: cPayloadBytes = []
                    case let data as Data: cPayloadBytes = Array(data)
                    case let bytes as [UInt8]: cPayloadBytes = bytes
                    default:
                        guard let encodedBody: Data = try? JSONEncoder().encode(body) else {
                            return resolver(Result.failure(SnodeAPIError.invalidPayload))
                        }
                        
                        cPayloadBytes = Array(encodedBody)
                }
                let cSwarmInfo: (ptr: UnsafePointer<network_service_node>?, count: Int) = cSwarm(for: swarmPublicKey)
                let callbackWrapper: CWrapper = CWrapper { success, timeout, statusCode, data, changes in
                    switch processError(success, timeout, statusCode, data, changes, swarmPublicKey, using: dependencies) {
                        case .some(let error): resolver(Result.failure(error))
                        case .none: resolver(Result.success((Network.ResponseInfo(code: Int(statusCode), headers: [:]), data)))
                    }
                }
                callbackWrapper.addUnsafePointerToCleanup(cSwarmInfo.ptr)
                let cWrapperPtr: UnsafeMutableRawPointer = Unmanaged.passRetained(callbackWrapper).toOpaque()
                
                // Trigger the request
                switch destination {
                    case .snode(let snode):
                        let cSnodeIp: (UInt8, UInt8, UInt8, UInt8)
                        
                        do { cSnodeIp = try toCIp(ip: snode.ip) }
                        catch { return resolver(Result.failure(error)) }
                        
                        network_send_onion_request_to_snode_destination(
                            network,
                            onion_request_service_node_destination(
                                ip: cSnodeIp,
                                quic_port: snode.lmqPort,
                                x25519_pubkey_hex: snode.x25519PublicKey.toLibSession(),
                                ed25519_pubkey_hex: snode.ed25519PublicKey.toLibSession(),
                                failure_count: UInt8(SnodeAPI.snodeFailureCount.wrappedValue[snode] ?? 0),
                                invalid: false,
                                swarm: cSwarmInfo.ptr,
                                swarm_count: cSwarmInfo.count
                            ),
                            cPayloadBytes,
                            cPayloadBytes.count,
                            { success, timeout, statusCode, dataPtr, dataLen, cChanges, ctx in
                                let data: Data? = dataPtr.map { Data(bytes: $0, count: dataLen) }
                                let changes: ServiceNodeChanges = ServiceNodeChanges(cChanges: cChanges)
                                Unmanaged<CWrapper>.fromOpaque(ctx!).takeRetainedValue()
                                    .callback(success, timeout, statusCode, data, changes)
                            },
                            cWrapperPtr
                        )
                        
                    case .server(let method, let scheme, let host, let endpoint, let port, let headers, let queryParams, let x25519PublicKey):
                        let targetScheme: String = (scheme ?? "https")
                        let headerInfo: [(key: String, value: String)]? = headers?.map { ($0.key, $0.value) }
                        let queryInfo: [(key: String, value: String)]? = queryParams?.map { ($0.key, $0.value) }
                        var cHeaderKeys: [UnsafePointer<CChar>?] = (headerInfo ?? [])
                            .map { $0.key.cArray.nullTerminated() }
                            .unsafeCopy()
                        var cHeaderValues: [UnsafePointer<CChar>?] = (headerInfo ?? [])
                            .map { $0.value.cArray.nullTerminated() }
                            .unsafeCopy()
                        var cQueryParamKeys: [UnsafePointer<CChar>?] = (queryInfo ?? [])
                            .map { $0.key.cArray.nullTerminated() }
                            .unsafeCopy()
                        var cQueryParamValues: [UnsafePointer<CChar>?] = (queryInfo ?? [])
                            .map { $0.value.cArray.nullTerminated() }
                            .unsafeCopy()
                        
                        // Add a cleanup callback to deallocate the header arrays
                        cHeaderKeys.forEach { callbackWrapper.addUnsafePointerToCleanup($0) }
                        cHeaderValues.forEach { callbackWrapper.addUnsafePointerToCleanup($0) }
                        cQueryParamKeys.forEach { callbackWrapper.addUnsafePointerToCleanup($0) }
                        cQueryParamValues.forEach { callbackWrapper.addUnsafePointerToCleanup($0) }

                        network_send_onion_request_to_server_destination(
                            network,
                            (method ?? "GET").cArray.nullTerminated(),
                            targetScheme.cArray.nullTerminated(),
                            host.cArray.nullTerminated(),
                            endpoint.path.cArray.nullTerminated(),
                            (port ?? (targetScheme == "https" ? 443 : 80)),
                            x25519PublicKey.cArray,
                            &cQueryParamKeys,
                            &cQueryParamValues,
                            cQueryParamKeys.count,
                            &cHeaderKeys,
                            &cHeaderValues,
                            cHeaderKeys.count,
                            cPayloadBytes,
                            cPayloadBytes.count,
                            { success, timeout, statusCode, dataPtr, dataLen, cChanges, ctx in
                                let data: Data? = dataPtr.map { Data(bytes: $0, count: dataLen) }
                                let changes: ServiceNodeChanges = ServiceNodeChanges(cChanges: cChanges)
                                Unmanaged<CWrapper>.fromOpaque(ctx!).takeRetainedValue()
                                    .callback(success, timeout, statusCode, data, changes)
                            },
                            cWrapperPtr
                        )
                }
            }
        }.eraseToAnyPublisher()
    }
}
