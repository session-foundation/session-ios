// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import SessionUtil
import SessionUtilitiesKit

// MARK: - ONS Response

internal extension Crypto.Generator {
    static func sessionId(
        name: String,
        response: SnodeAPI.ONSResolveResponse
    ) -> Crypto.Generator<String> {
        return Crypto.Generator(
            id: "sessionId_for_ONS_response",
            args: [name, response]
        ) {
            guard var cName: [CChar] = name.lowercased().cString(using: .utf8) else {
                throw SnodeAPIError.onsDecryptionFailed
            }
            
            // Name must be in lowercase
            var cCiphertext: [UInt8] = Array(Data(hex: response.result.encryptedValue))
            var cSessionId: [CChar] = [CChar](repeating: 0, count: 67)
            
            // Need to switch on `result.nonce` and explciitly pass `nil` because passing an optional
            // to a C function doesn't seem to work correctly
            switch response.result.nonce {
                case .none:
                    guard
                        session_decrypt_ons_response(
                            &cName,
                            &cCiphertext,
                            cCiphertext.count,
                            nil,
                            &cSessionId
                        )
                    else { throw SnodeAPIError.onsDecryptionFailed }
                    
                case .some(let nonce):
                    var cNonce: [UInt8] = Array(Data(hex: nonce))
                    
                    guard
                        cNonce.count == 24,
                        session_decrypt_ons_response(
                            &cName,
                            &cCiphertext,
                            cCiphertext.count,
                            &cNonce,
                            &cSessionId
                        )
                    else { throw SnodeAPIError.onsDecryptionFailed }
            }
            
            return String(cString: cSessionId)
        }
    }
}

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
