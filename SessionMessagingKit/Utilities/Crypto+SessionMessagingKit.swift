// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Sodium
import Clibsodium
import SessionUtilitiesKit

// MARK: - Generic Hash

public extension Crypto.Action {
    static func hash(message: Bytes, outputLength: Int) -> Crypto.Action {
        return Crypto.Action(id: "hashOutputLength", args: [message, outputLength]) { sodium in
            sodium.genericHash.hash(message: message, outputLength: outputLength)
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

// MARK: - Box

public extension Crypto.Size {
    static let signature: Crypto.Size = Crypto.Size(id: "signature") { $0.sign.Bytes }
}

public extension Crypto.Action {
    static func seal(message: Bytes, recipientPublicKey: Bytes) -> Crypto.Action {
        return Crypto.Action(id: "seal", args: [message, recipientPublicKey]) { sodium in
            sodium.box.seal(message: message, recipientPublicKey: recipientPublicKey)
        }
    }
    
    static func open(anonymousCipherText: Bytes, recipientPublicKey: Bytes, recipientSecretKey: Bytes) -> Crypto.Action {
        return Crypto.Action(
            id: "open",
            args: [anonymousCipherText, recipientPublicKey, recipientSecretKey]
        ) { sodium in
            sodium.box.open(
                anonymousCipherText: anonymousCipherText,
                recipientPublicKey: recipientPublicKey,
                recipientSecretKey: recipientSecretKey
            )
        }
    }
}

// MARK: - AeadXChaCha20Poly1305Ietf

public extension Crypto.Size {
    static let aeadXChaCha20NonceBytes: Crypto.Size = Crypto.Size(id: "aeadXChaCha20NonceBytes") { sodium in
        sodium.aead.xchacha20poly1305ietf.NonceBytes
    }
}
