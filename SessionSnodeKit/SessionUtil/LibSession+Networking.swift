// Copyright © 2024 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import SessionUtil
import SessionUtilitiesKit

// MARK: - LibSession

public extension LibSession {
    private static func sendRequest(
        ed25519SecretKey: [UInt8],
        targetPubkey: String,
        targetIp: String,
        targetPort: UInt16,
        endpoint: String,
        payload: [UInt8]?,
        callback: @escaping (Bool, Bool, Int16, Data?) -> Void
    ) {
        class CWrapper {
            let callback: (Bool, Bool, Int16, Data?) -> Void
            
            public init(_ callback: @escaping (Bool, Bool, Int16, Data?) -> Void) {
                self.callback = callback
            }
        }
        
        let callbackWrapper: CWrapper = CWrapper(callback)
        let cWrapperPtr: UnsafeMutableRawPointer = Unmanaged.passRetained(callbackWrapper).toOpaque()
        let cRemoteAddress: remote_address = remote_address(
            pubkey: targetPubkey.toLibSession(),
            ip: targetIp.toLibSession(),
            port: targetPort
        )
        let cEndpoint: [CChar] = endpoint.cArray
        let cPayload: [UInt8] = (payload ?? [])
        
        network_send_request(
            ed25519SecretKey,
            cRemoteAddress,
            cEndpoint,
            cEndpoint.count,
            cPayload,
            cPayload.count,
            { success, timeout, statusCode, dataPtr, dataLen, ctx in
                let data: Data? = dataPtr.map { Data(bytes: $0, count: dataLen) }
                Unmanaged<CWrapper>.fromOpaque(ctx!).takeRetainedValue().callback(success, timeout, statusCode, data)
            },
            cWrapperPtr
        )
    }
    
    private static func sendOnionRequest(
        path: [Snode],
        ed25519SecretKey: [UInt8],
        to destination: OnionRequestAPIDestination,
        payload: [UInt8]?,
        callback: @escaping (Bool, Bool, Int16, Data?) -> Void
    ) {
        class CWrapper {
            let callback: (Bool, Bool, Int16, Data?) -> Void
            
            public init(_ callback: @escaping (Bool, Bool, Int16, Data?) -> Void) {
                self.callback = callback
            }
        }
        
        let callbackWrapper: CWrapper = CWrapper(callback)
        let cWrapperPtr: UnsafeMutableRawPointer = Unmanaged.passRetained(callbackWrapper).toOpaque()
        let cPayload: [UInt8] = (payload ?? [])
        var x25519Pubkeys: [UnsafePointer<CChar>?] = path.map { $0.x25519PublicKey.cArray }.unsafeCopy()
        var ed25519Pubkeys: [UnsafePointer<CChar>?] = path.map { $0.ed25519PublicKey.cArray }.unsafeCopy()
        let cNodes: UnsafePointer<onion_request_service_node>? = path
            .enumerated()
            .map { index, snode in
                onion_request_service_node(
                    ip: snode.ip.toLibSession(),
                    lmq_port: snode.lmqPort,
                    x25519_pubkey_hex: x25519Pubkeys[index],
                    ed25519_pubkey_hex: ed25519Pubkeys[index],
                    failure_count: 0
                )
            }
            .unsafeCopy()
        let cOnionPath: onion_request_path = onion_request_path(
            nodes: cNodes,
            nodes_count: path.count,
            failure_count: 0
        )
        
        switch destination {
            case .snode(let snode):
                let cX25519Pubkey: UnsafePointer<CChar>? = snode.x25519PublicKey.cArray.unsafeCopy()
                let cEd25519Pubkey: UnsafePointer<CChar>? = snode.ed25519PublicKey.cArray.unsafeCopy()
                
                network_send_onion_request_to_snode_destination(
                    cOnionPath,
                    ed25519SecretKey,
                    onion_request_service_node(
                        ip: snode.ip.toLibSession(),
                        lmq_port: snode.lmqPort,
                        x25519_pubkey_hex: cX25519Pubkey,
                        ed25519_pubkey_hex: cEd25519Pubkey,
                        failure_count: 0
                    ),
                    cPayload,
                    cPayload.count,
                    { success, timeout, statusCode, dataPtr, dataLen, ctx in
                        let data: Data? = dataPtr.map { Data(bytes: $0, count: dataLen) }
                        Unmanaged<CWrapper>.fromOpaque(ctx!).takeRetainedValue().callback(success, timeout, statusCode, data)
                    },
                    cWrapperPtr
                )
                
            case .server(let host, let target, let x25519PublicKey, let scheme, let port):
                let cMethod: [CChar] = "GET".cArray
                let targetScheme: String = (scheme ?? "https")
                
                network_send_onion_request_to_server_destination(
                    cOnionPath,
                    ed25519SecretKey,
                    cMethod,
                    host.cArray,
                    target.cArray,
                    targetScheme.cArray,
                    x25519PublicKey.cArray,
                    (port ?? (targetScheme == "https" ? 443 : 80)),
                    nil,
                    nil,
                    0,
                    cPayload,
                    cPayload.count,
                    { success, timeout, statusCode, dataPtr, dataLen, ctx in
                        let data: Data? = dataPtr.map { Data(bytes: $0, count: dataLen) }
                        Unmanaged<CWrapper>.fromOpaque(ctx!).takeRetainedValue().callback(success, timeout, statusCode, data)
                    },
                    cWrapperPtr
                )
        }
    }
    
    private static func sendRequest(
        ed25519SecretKey: [UInt8]?,
        snode: Snode,
        endpoint: String,
        payloadBytes: [UInt8]?
    ) -> AnyPublisher<(ResponseInfoType, Data?), Error> {
        return Deferred {
            Future { resolver in
                guard let ed25519SecretKey: [UInt8] = ed25519SecretKey else {
                    return resolver(Result.failure(SnodeAPIError.missingSecretKey))
                }
                
                LibSession.sendRequest(
                    ed25519SecretKey: ed25519SecretKey,
                    targetPubkey: snode.ed25519PublicKey,
                    targetIp: snode.ip,
                    targetPort: snode.lmqPort,
                    endpoint: endpoint,//.rawValue,
                    payload: payloadBytes,
                    callback: { success, timeout, statusCode, data in
                        switch SnodeAPIError(success: success, timeout: timeout, statusCode: statusCode, data: data) {
                            case .some(let error): resolver(Result.failure(error))
                            case .none: resolver(Result.success((HTTP.ResponseInfo(code: Int(statusCode), headers: [:]), data)))
                        }
                    }
                )
            }
        }.eraseToAnyPublisher()
    }
    
    static func sendRequest(
        ed25519SecretKey: [UInt8]?,
        snode: Snode,
        endpoint: String
    ) -> AnyPublisher<(ResponseInfoType, Data?), Error> {
        return sendRequest(ed25519SecretKey: ed25519SecretKey, snode: snode, endpoint: endpoint, payloadBytes: nil)
    }
    
    static func sendRequest<T: Encodable>(
        ed25519SecretKey: [UInt8]?,
        snode: Snode,
        endpoint: String,
        payload: T
    ) -> AnyPublisher<(ResponseInfoType, Data?), Error> {
        let payloadBytes: [UInt8]
        
        switch payload {
            case let data as Data: payloadBytes = Array(data)
            case let bytes as [UInt8]: payloadBytes = bytes
            default:
                guard let encodedPayload: Data = try? JSONEncoder().encode(payload) else {
                    return Fail(error: SnodeAPIError.invalidPayload).eraseToAnyPublisher()
                }
                
                payloadBytes = Array(encodedPayload)
        }
        
        return sendRequest(ed25519SecretKey: ed25519SecretKey, snode: snode, endpoint: endpoint, payloadBytes: payloadBytes)
    }
    
    static func sendOnionRequest<T: Encodable>(
        path: [Snode],
        ed25519SecretKey: [UInt8]?,
        to destination: OnionRequestAPIDestination,
        payload: T
    ) -> AnyPublisher<(ResponseInfoType, Data?), Error> {
        let payloadBytes: [UInt8]
        switch payload {
            case let data as Data: payloadBytes = Array(data)
            case let bytes as [UInt8]: payloadBytes = bytes
            default:
                guard let encodedPayload: Data = try? JSONEncoder().encode(payload) else {
                    return Fail(error: SnodeAPIError.invalidPayload).eraseToAnyPublisher()
                }
                
                payloadBytes = Array(encodedPayload)
        }
        
        return Deferred {
            Future { resolver in
                guard let ed25519SecretKey: [UInt8] = ed25519SecretKey else {
                    return resolver(Result.failure(SnodeAPIError.missingSecretKey))
                }
                
                LibSession.sendOnionRequest(
                    path: path,
                    ed25519SecretKey: ed25519SecretKey,
                    to: destination,
                    payload: payloadBytes,
                    callback: { success, timeout, statusCode, data in
                        switch SnodeAPIError(success: success, timeout: timeout, statusCode: statusCode, data: data) {
                            case .some(let error): resolver(Result.failure(error))
                            case .none: resolver(Result.success((HTTP.ResponseInfo(code: Int(statusCode), headers: [:]), data)))
                        }
                    }
                )
            }
        }.eraseToAnyPublisher()
    }
}
