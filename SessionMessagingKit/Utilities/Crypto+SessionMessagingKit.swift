// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Sodium
import Clibsodium
import Curve25519Kit
import SessionUtilitiesKit

// MARK: - Generic Hash

public extension Crypto.Action {
    static func hash(message: Bytes, key: Bytes?) -> Crypto.Action {
        return Crypto.Action(id: "hash", args: [message, key]) {
            Sodium().genericHash.hash(message: message, key: key)
        }
    }
    
    static func hash(message: Bytes, outputLength: Int) -> Crypto.Action {
        return Crypto.Action(id: "hashOutputLength", args: [message, outputLength]) {
            Sodium().genericHash.hash(message: message, outputLength: outputLength)
        }
    }
    
    static func hashSaltPersonal(
        message: Bytes,
        outputLength: Int,
        key: Bytes? = nil,
        salt: Bytes,
        personal: Bytes
    ) -> Crypto.Action {
        return Crypto.Action(
            id: "hashSaltPersonal",
            args: [message, outputLength, key, salt, personal]
        ) {
            var output: [UInt8] = [UInt8](repeating: 0, count: outputLength)

            let result = crypto_generichash_blake2b_salt_personal(
                &output,
                outputLength,
                message,
                UInt64(message.count),
                key,
                (key?.count ?? 0),
                salt,
                personal
            )

            guard result == 0 else { return nil }

            return output
        }
    }
}

// MARK: - Sign

public extension Crypto.Action {
    static func toX25519(ed25519PublicKey: Bytes) -> Crypto.Action {
        return Crypto.Action(id: "toX25519", args: [ed25519PublicKey]) {
            Sodium().sign.toX25519(ed25519PublicKey: ed25519PublicKey)
        }
    }
    
    static func toX25519(ed25519SecretKey: Bytes) -> Crypto.Action {
        return Crypto.Action(id: "toX25519", args: [ed25519SecretKey]) {
            Sodium().sign.toX25519(ed25519SecretKey: ed25519SecretKey)
        }
    }
    
    static func signature(message: Bytes, secretKey: Bytes) -> Crypto.Action {
        return Crypto.Action(id: "signature", args: [message, secretKey]) {
            Sodium().sign.signature(message: message, secretKey: secretKey)
        }
    }
}

public extension Crypto.Verification {
    static func signature(message: Bytes, publicKey: Bytes, signature: Bytes) -> Crypto.Verification {
        return Crypto.Verification(id: "signature", args: [message, publicKey, signature]) {
            Sodium().sign.verify(message: message, publicKey: publicKey, signature: signature)
        }
    }
}

// MARK: - Box

public extension Crypto.Size {
    static let signature: Crypto.Size = Crypto.Size(id: "signature") { Sodium().sign.Bytes }
    static let publicKey: Crypto.Size = Crypto.Size(id: "publicKey") { Sodium().sign.PublicKeyBytes }
}

public extension Crypto.Action {
    static func seal(message: Bytes, recipientPublicKey: Bytes) -> Crypto.Action {
        return Crypto.Action(id: "seal", args: [message, recipientPublicKey]) {
            Sodium().box.seal(message: message, recipientPublicKey: recipientPublicKey)
        }
    }
    
    static func open(anonymousCipherText: Bytes, recipientPublicKey: Bytes, recipientSecretKey: Bytes) -> Crypto.Action {
        return Crypto.Action(
            id: "open",
            args: [anonymousCipherText, recipientPublicKey, recipientSecretKey]
        ) {
            Sodium().box.open(
                anonymousCipherText: anonymousCipherText,
                recipientPublicKey: recipientPublicKey,
                recipientSecretKey: recipientSecretKey
            )
        }
    }
}

// MARK: - Ed25519

public extension Crypto.Action {
    static func signEd25519(data: Bytes, keyPair: KeyPair) -> Crypto.Action {
        return Crypto.Action(id: "signEd25519", args: [data, keyPair]) {
            let ecKeyPair: ECKeyPair = try ECKeyPair(
                publicKeyData: Data(keyPair.publicKey),
                privateKeyData: Data(keyPair.secretKey)
            )
            
            return try Ed25519.sign(Data(data), with: ecKeyPair).bytes
        }
    }
}

public extension Crypto.Verification {
    static func signatureEd25519(_ signature: Data, publicKey: Data, data: Data) -> Crypto.Verification {
        return Crypto.Verification(id: "signatureEd25519", args: [signature, publicKey, data]) {
            return ((try? Ed25519.verifySignature(signature, publicKey: publicKey, data: data)) == true)
        }
    }
}

public extension Crypto.KeyPairType {
    static func x25519KeyPair() -> Crypto.KeyPairType {
        return Crypto.KeyPairType(id: "x25519KeyPair") {
            let keyPair: ECKeyPair = Curve25519.generateKeyPair()
            
            return KeyPair(publicKey: Array(keyPair.publicKey), secretKey: Array(keyPair.privateKey))
        }
    }
}
