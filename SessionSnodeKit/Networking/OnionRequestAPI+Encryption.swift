// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import CryptoKit
import SessionUtilitiesKit

internal extension OnionRequestAPI {
    static func encode(ciphertext: Data, json: JSON) -> AnyPublisher<Data, Error> {
        // The encoding of V2 onion requests looks like: | 4 bytes: size N of ciphertext | N bytes: ciphertext | json as utf8 |
        guard
            JSONSerialization.isValidJSONObject(json),
            let jsonAsData = try? JSONSerialization.data(withJSONObject: json, options: [ .fragmentsAllowed ])
        else {
            return Fail(error: HTTPError.invalidJSON)
                .eraseToAnyPublisher()
        }
        
        let ciphertextSize = Int32(ciphertext.count).littleEndian
        let ciphertextSizeAsData = withUnsafePointer(to: ciphertextSize) { Data(bytes: $0, count: MemoryLayout<Int32>.size) }
        
        return Just(ciphertextSizeAsData + ciphertext + jsonAsData)
            .setFailureType(to: Error.self)
            .eraseToAnyPublisher()
    }
    
    /// Encrypts `payload` for `destination` and returns the result. Use this to build the core of an onion request.
    static func encrypt(
        _ payload: Data,
        for destination: OnionRequestAPIDestination
    ) -> AnyPublisher<AES.GCM.EncryptionResult, Error> {
        switch destination {
            case .snode(let snode):
                // Need to wrap the payload for snode requests
                return encode(ciphertext: payload, json: [ "headers" : "" ])
                    .tryMap { data -> AES.GCM.EncryptionResult in
                        try AES.GCM.encrypt(data, for: snode.x25519PublicKey)
                    }
                    .eraseToAnyPublisher()
                
            case .server(_, _, let serverX25519PublicKey, _, _):
                do {
                    return Just(try AES.GCM.encrypt(payload, for: serverX25519PublicKey))
                        .setFailureType(to: Error.self)
                        .eraseToAnyPublisher()
                }
                catch {
                    return Fail(error: error)
                        .eraseToAnyPublisher()
                }
        }
    }
    
    /// Encrypts the previous encryption result (i.e. that of the hop after this one) for this hop. Use this to build the layers of an onion request.
    static func encryptHop(
        from lhs: OnionRequestAPIDestination,
        to rhs: OnionRequestAPIDestination,
        using previousEncryptionResult: AES.GCM.EncryptionResult
    ) -> AnyPublisher<AES.GCM.EncryptionResult, Error> {
        var parameters: JSON
        
        switch rhs {
            case .snode(let snode):
                let snodeED25519PublicKey = snode.ed25519PublicKey
                parameters = [ "destination" : snodeED25519PublicKey ]
                
            case .server(let host, let target, _, let scheme, let port):
                let scheme = scheme ?? "https"
                let port = port ?? (scheme == "https" ? 443 : 80)
                parameters = [ "host" : host, "target" : target, "method" : "POST", "protocol" : scheme, "port" : port ]
        }
        
        parameters["ephemeral_key"] = previousEncryptionResult.ephemeralPublicKey.toHexString()
        
        let x25519PublicKey: String = {
            switch lhs {
                case .snode(let snode): return snode.x25519PublicKey
                case .server(_, _, let serverX25519PublicKey, _, _):
                    return serverX25519PublicKey
            }
        }()
        
        return encode(ciphertext: previousEncryptionResult.ciphertext, json: parameters)
            .tryMap { data -> AES.GCM.EncryptionResult in try AES.GCM.encrypt(data, for: x25519PublicKey) }
            .eraseToAnyPublisher()
    }
}
