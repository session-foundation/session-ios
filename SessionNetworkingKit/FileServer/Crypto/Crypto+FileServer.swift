// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import SessionUtil
import SessionUtilitiesKit

// MARK: - Version Blinded ID

public extension Crypto.Generator {
    static func versionBlinded07KeyPair(
        ed25519SecretKey: [UInt8]
    ) -> Crypto.Generator<KeyPair> {
        return Crypto.Generator(
            id: "versionBlinded07KeyPair",
            args: [ed25519SecretKey]
        ) {
            var cEd25519SecretKey: [UInt8] = Array(ed25519SecretKey)
            var cBlindedPubkey: [UInt8] = [UInt8](repeating: 0, count: 32)
            var cBlindedSeckey: [UInt8] = [UInt8](repeating: 0, count: 64)
            
            guard
                cEd25519SecretKey.count == 64,
                session_blind_version_key_pair(
                    &cEd25519SecretKey,
                    &cBlindedPubkey,
                    &cBlindedSeckey
                )
            else { throw CryptoError.keyGenerationFailed }
            
            return KeyPair(publicKey: cBlindedPubkey, secretKey: cBlindedSeckey)
        }
    }
    
    static func signatureVersionBlind07(
        timestamp: UInt64,
        method: String,
        path: String,
        body: String?,
        ed25519SecretKey: [UInt8]
    ) -> Crypto.Generator<[UInt8]> {
        return Crypto.Generator(
            id: "signatureVersionBlind07",
            args: [timestamp, method, path, body, ed25519SecretKey]
        ) {
            var cEd25519SecretKey: [UInt8] = Array(ed25519SecretKey)
            guard
                cEd25519SecretKey.count == 64,
                var cMethod: [CChar] = method.cString(using: .utf8),
                var cPath: [CChar] = path.cString(using: .utf8)
            else {
                throw CryptoError.signatureGenerationFailed
            }

            var cSignature: [UInt8] = [UInt8](repeating: 0, count: 64)
            
            if let body: String = body {
                var cBody: [UInt8] = Array(body.bytes)
                guard session_blind_version_sign_request(
                    &cEd25519SecretKey,
                    timestamp,
                    &cMethod,
                    &cPath,
                    &cBody,
                    cBody.count,
                    &cSignature
                ) else {
                    throw CryptoError.signatureGenerationFailed
                }
            } else {
                guard session_blind_version_sign_request(
                    &cEd25519SecretKey,
                    timestamp,
                    &cMethod,
                    &cPath,
                    nil,
                    0,
                    &cSignature
                )
                else {
                    throw CryptoError.signatureGenerationFailed
                }
            }
            
            return cSignature
        }
    }
}
