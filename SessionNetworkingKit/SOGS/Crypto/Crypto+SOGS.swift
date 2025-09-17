// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import SessionUtil
import SessionUtilitiesKit

public extension Crypto.Generator {
    /// Constructs a "blinded" key pair (`ka, kA`) based on an open group server `publicKey` and an ed25519 `keyPair`
    static func blinded15KeyPair(
        serverPublicKey: String,
        ed25519SecretKey: [UInt8]
    ) -> Crypto.Generator<KeyPair> {
        return Crypto.Generator(
            id: "blinded15KeyPair",
            args: [serverPublicKey, ed25519SecretKey]
        ) {
            var cEd25519SecretKey: [UInt8] = Array(ed25519SecretKey)
            var cServerPublicKey: [UInt8] = Array(Data(hex: serverPublicKey))
            var cBlindedPubkey: [UInt8] = [UInt8](repeating: 0, count: 32)
            var cBlindedSeckey: [UInt8] = [UInt8](repeating: 0, count: 32)
            
            guard
                cEd25519SecretKey.count == 64,
                cServerPublicKey.count == 32,
                session_blind15_key_pair(
                    &cEd25519SecretKey,
                    &cServerPublicKey,
                    &cBlindedPubkey,
                    &cBlindedSeckey
                )
            else { throw CryptoError.keyGenerationFailed }
            
            return KeyPair(publicKey: cBlindedPubkey, secretKey: cBlindedSeckey)
        }
    }
    
    /// Constructs a "blinded" key pair (`ka, kA`) based on an open group server `publicKey` and an ed25519 `keyPair`
    static func blinded25KeyPair(
        serverPublicKey: String,
        ed25519SecretKey: [UInt8]
    ) -> Crypto.Generator<KeyPair> {
        return Crypto.Generator(
            id: "blinded25KeyPair",
            args: [serverPublicKey, ed25519SecretKey]
        ) {
            var cEd25519SecretKey: [UInt8] = Array(ed25519SecretKey)
            var cServerPublicKey: [UInt8] = Array(Data(hex: serverPublicKey))
            var cBlindedPubkey: [UInt8] = [UInt8](repeating: 0, count: 32)
            var cBlindedSeckey: [UInt8] = [UInt8](repeating: 0, count: 32)
            
            guard
                cEd25519SecretKey.count == 64,
                cServerPublicKey.count == 32,
                session_blind25_key_pair(
                    &cEd25519SecretKey,
                    &cServerPublicKey,
                    &cBlindedPubkey,
                    &cBlindedSeckey
                )
            else { throw CryptoError.keyGenerationFailed }
            
            return KeyPair(publicKey: cBlindedPubkey, secretKey: cBlindedSeckey)
        }
    }
    
    static func signatureBlind15(
        message: [UInt8],
        serverPublicKey: String,
        ed25519SecretKey: [UInt8]
    ) -> Crypto.Generator<[UInt8]> {
        return Crypto.Generator(
            id: "signatureBlind15",
            args: [message, serverPublicKey, ed25519SecretKey]
        ) {
            var cEd25519SecretKey: [UInt8] = ed25519SecretKey
            var cServerPublicKey: [UInt8] = Array(Data(hex: serverPublicKey))
            var cMessage: [UInt8] = message
            var cSignature: [UInt8] = [UInt8](repeating: 0, count: 64)

            guard
                cEd25519SecretKey.count == 64,
                cServerPublicKey.count == 32,
                session_blind15_sign(
                    &cEd25519SecretKey,
                    &cServerPublicKey,
                    &cMessage,
                    cMessage.count,
                    &cSignature
                )
            else { throw CryptoError.signatureGenerationFailed }

            return cSignature
        }
    }
    
    static func signatureBlind25(
        message: [UInt8],
        serverPublicKey: String,
        ed25519SecretKey: [UInt8]
    ) -> Crypto.Generator<[UInt8]> {
        return Crypto.Generator(
            id: "signatureBlind25",
            args: [message, serverPublicKey, ed25519SecretKey]
        ) {
            var cEd25519SecretKey: [UInt8] = ed25519SecretKey
            var cServerPublicKey: [UInt8] = Array(Data(hex: serverPublicKey))
            var cMessage: [UInt8] = message
            var cSignature: [UInt8] = [UInt8](repeating: 0, count: 64)

            guard
                cEd25519SecretKey.count == 64,
                cServerPublicKey.count == 32,
                session_blind25_sign(
                    &cEd25519SecretKey,
                    &cServerPublicKey,
                    &cMessage,
                    cMessage.count,
                    &cSignature
                )
            else { throw CryptoError.signatureGenerationFailed }

            return cSignature
        }
    }
}

public extension Crypto.Verification {
    /// This method should be used to check if a users standard sessionId matches a blinded one
    static func sessionId(
        _ standardSessionId: String,
        matchesBlindedId blindedSessionId: String,
        serverPublicKey: String
    ) -> Crypto.Verification {
        return Crypto.Verification(
            id: "sessionId",
            args: [standardSessionId, blindedSessionId, serverPublicKey]
        ) {
            guard
                var cStandardSessionId: [CChar] = standardSessionId.cString(using: .utf8),
                var cBlindedSessionId: [CChar] = blindedSessionId.cString(using: .utf8),
                var cServerPublicKey: [CChar] = serverPublicKey.cString(using: .utf8)
            else { return false }
            
            return session_id_matches_blinded_id(
                &cStandardSessionId,
                &cBlindedSessionId,
                &cServerPublicKey
            )
        }
    }
}
