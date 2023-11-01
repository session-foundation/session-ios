// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Sodium
import Clibsodium
import SessionUtilitiesKit

// MARK: - Generic Hash

public extension Crypto.Generator {
    static func hash(message: Bytes, key: Bytes? = nil) -> Crypto.Generator<[UInt8]> {
        return Crypto.Generator(id: "hash", args: [message, key]) { sodium in
            sodium.genericHash.hash(message: message, key: key)
        }
    }
}

// MARK: - AeadXChaCha20Poly1305Ietf

public extension Crypto.Size {
    static let aeadXChaCha20KeyBytes: Crypto.Size = Crypto.Size(id: "aeadXChaCha20KeyBytes") { sodium in
        sodium.aead.xchacha20poly1305ietf.KeyBytes
    }
    static let aeadXChaCha20ABytes: Crypto.Size = Crypto.Size(id: "aeadXChaCha20ABytes") { sodium in
        sodium.aead.xchacha20poly1305ietf.ABytes
    }
}

public extension Crypto.Generator {
    /// This method is the same as the standard AeadXChaCha20Poly1305Ietf `encrypt` method except it allows the
    /// specification of a nonce which allows for deterministic behaviour with unit testing
    static func encryptedBytesAeadXChaCha20(
        message: Bytes,
        secretKey: Bytes,
        nonce: Bytes,
        additionalData: Bytes? = nil,
        using dependencies: Dependencies
    ) -> Crypto.Generator<[UInt8]> {
        return Crypto.Generator(
            id: "encryptedBytesAeadXChaCha20",
            args: [message, secretKey, nonce, additionalData]
        ) {
            guard secretKey.count == dependencies[singleton: .crypto].size(.aeadXChaCha20KeyBytes) else { return nil }

            var authenticatedCipherText = Bytes(
                repeating: 0,
                count: message.count + dependencies[singleton: .crypto].size(.aeadXChaCha20ABytes)
            )
            var authenticatedCipherTextLen: UInt64 = 0

            let result = crypto_aead_xchacha20poly1305_ietf_encrypt(
                &authenticatedCipherText, &authenticatedCipherTextLen,
                message, UInt64(message.count),
                additionalData, UInt64(additionalData?.count ?? 0),
                nil, nonce, secretKey
            )
            
            guard result == 0 else { return nil }

            return authenticatedCipherText
        }
    }
    
    static func decryptedBytesAeadXChaCha20(
        authenticatedCipherText: Bytes,
        secretKey: Bytes,
        nonce: Bytes,
        additionalData: Bytes? = nil
    ) -> Crypto.Generator<[UInt8]> {
        return Crypto.Generator(
            id: "decryptedBytesAeadXChaCha20",
            args: [authenticatedCipherText, secretKey, nonce, additionalData]
        ) { sodium in
            sodium.aead.xchacha20poly1305ietf.decrypt(
                authenticatedCipherText: authenticatedCipherText,
                secretKey: secretKey,
                nonce: nonce,
                additionalData: additionalData
            )
        }
    }
}

// MARK: - Legacy Argon2-based encryption

public extension Crypto.Size {
    static let legacyArgon2PWHashSaltBytes: Crypto.Size = Crypto.Size(id: "legacyArgon2PWHashSaltBytes") {
        $0.pwHash.SaltBytes
    }
    static let legacyArgon2SecretBoxNonceBytes: Crypto.Size = Crypto.Size(id: "legacyArgon2SecretBoxNonceBytes") {
        $0.secretBox.NonceBytes
    }
}

public extension Crypto.Generator {
    static func legacyArgon2PWHash(passwd: Bytes, salt: Bytes) -> Crypto.Generator<[UInt8]> {
        return Crypto.Generator(id: "legacyArgon2PWHash", args: [passwd, salt]) { sodium in
            sodium.pwHash.hash(
                outputLength: sodium.secretBox.KeyBytes,
                passwd: passwd,
                salt: salt,
                opsLimit: sodium.pwHash.OpsLimitModerate,
                memLimit: sodium.pwHash.MemLimitModerate,
                alg: .Argon2ID13
            )
        }
    }
    
    static func legacyArgon2SecretBoxOpenedBytes(
        authenticatedCipherText: Bytes,
        secretKey: Bytes,
        nonce: Bytes
    ) -> Crypto.Generator<[UInt8]> {
        return Crypto.Generator(id: "legacyArgon2SecretBoxOpenedBytes", args: [authenticatedCipherText, secretKey, nonce]) {
            $0.secretBox.open(
                authenticatedCipherText: authenticatedCipherText,
                secretKey: secretKey,
                nonce: nonce
            )
        }
    }
}
