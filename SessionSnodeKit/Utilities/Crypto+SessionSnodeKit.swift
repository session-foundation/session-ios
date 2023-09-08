// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Sodium
import Clibsodium
import SessionUtilitiesKit

// MARK: - Generic Hash

public extension Crypto.Action {
    static func hash(message: Bytes, key: Bytes? = nil) -> Crypto.Action {
        return Crypto.Action(id: "hash", args: [message, key]) { sodium in
            sodium.genericHash.hash(message: message, key: key)
        }
    }
}

// MARK: - Sign

public extension Crypto.Action {
    static func signature(message: Bytes, secretKey: Bytes) -> Crypto.Action {
        return Crypto.Action(id: "signature", args: [message, secretKey]) { sodium in
            sodium.sign.signature(message: message, secretKey: secretKey)
        }
    }
}

public extension Crypto.Verification {
    static func signature(message: Bytes, publicKey: Bytes, signature: Bytes) -> Crypto.Verification {
        return Crypto.Verification(id: "signature", args: [message, publicKey, signature]) { sodium in
            sodium.sign.verify(message: message, publicKey: publicKey, signature: signature)
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

public extension Crypto.Action {
    /// This method is the same as the standard AeadXChaCha20Poly1305Ietf `encrypt` method except it allows the
    /// specification of a nonce which allows for deterministic behaviour with unit testing
    static func encryptAeadXChaCha20(
        message: Bytes,
        secretKey: Bytes,
        nonce: Bytes,
        additionalData: Bytes? = nil,
        using dependencies: Dependencies
    ) -> Crypto.Action {
        return Crypto.Action(
            id: "encryptAeadXChaCha20",
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
    
    static func decryptAeadXChaCha20(
        authenticatedCipherText: Bytes,
        secretKey: Bytes,
        nonce: Bytes,
        additionalData: Bytes? = nil
    ) -> Crypto.Action {
        return Crypto.Action(
            id: "decryptAeadXChaCha20",
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

public extension Crypto.Action {
    static func legacyArgon2PWHash(passwd: Bytes, salt: Bytes) -> Crypto.Action {
        return Crypto.Action(id: "legacyArgon2PWHash", args: [passwd, salt]) { sodium in
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
    
    static func legacyArgon2SecretBoxOpen(
        authenticatedCipherText: Bytes,
        secretKey: Bytes,
        nonce: Bytes
    ) -> Crypto.Action {
        return Crypto.Action(id: "legacyArgon2SecretBoxOpen", args: [authenticatedCipherText, secretKey, nonce]) {
            $0.secretBox.open(
                authenticatedCipherText: authenticatedCipherText,
                secretKey: secretKey,
                nonce: nonce
            )
        }
    }
}
