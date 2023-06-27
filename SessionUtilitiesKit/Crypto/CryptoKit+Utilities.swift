// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import CryptoKit
import Curve25519Kit

public extension Digest {
    var bytes: [UInt8] { Array(makeIterator()) }
    var data: Data { Data(bytes) }
    
    var hexString: String {
        bytes.map { String(format: "%02X", $0) }.joined()
    }
}

// MARK: - AES.GCM

public extension AES.GCM {
    static let ivSize: Int = 12
    
    struct EncryptionResult {
        public let ciphertext: Data
        public let symmetricKey: Data
        public let ephemeralPublicKey: Data
    }

    enum Error: LocalizedError {
        case keyPairGenerationFailed
        case sharedSecretGenerationFailed

        public var errorDescription: String? {
            switch self {
                case .keyPairGenerationFailed: return "Couldn't generate a key pair."
                case .sharedSecretGenerationFailed: return "Couldn't generate a shared secret."
            }
        }
    }

    /// - Note: Sync. Don't call from the main thread.
    static func generateSymmetricKey(x25519PublicKey: Data, x25519PrivateKey: Data) throws -> Data {
        #if DEBUG
        if Thread.isMainThread {
            preconditionFailure("It's illegal to call encrypt(_:forSnode:) from the main thread.")
        }
        #endif
        guard let sharedSecret: Data = try? Curve25519.generateSharedSecret(fromPublicKey: x25519PublicKey, privateKey: x25519PrivateKey) else {
            throw Error.sharedSecretGenerationFailed
        }
        let salt = "LOKI"
        
        return Data(
            HMAC<SHA256>.authenticationCode(
                for: sharedSecret,
                using: SymmetricKey(data: salt.bytes)
            )
        )
    }

    /// - Note: Sync. Don't call from the main thread.
    static func decrypt(_ nonceAndCiphertext: Data, with symmetricKey: Data) throws -> Data {
        #if DEBUG
        if Thread.isMainThread {
            preconditionFailure("It's illegal to call decrypt(_:usingAESGCMWithSymmetricKey:) from the main thread.")
        }
        #endif
        
        return try AES.GCM.open(
            try AES.GCM.SealedBox(combined: nonceAndCiphertext),
            using: SymmetricKey(data: symmetricKey)
        )
    }

    /// - Note: Sync. Don't call from the main thread.
    static func encrypt(_ plaintext: Data, with symmetricKey: Data) throws -> Data {
        #if DEBUG
        if Thread.isMainThread {
            preconditionFailure("It's illegal to call encrypt(_:usingAESGCMWithSymmetricKey:) from the main thread.")
        }
        #endif
        
        let nonceData: Data = try Randomness.generateRandomBytes(numberBytes: ivSize)
        let sealedData: AES.GCM.SealedBox = try AES.GCM.seal(
            plaintext,
            using: SymmetricKey(data: symmetricKey),
            nonce: try AES.GCM.Nonce(data: nonceData)
        )
        
        guard let cipherText: Data = sealedData.combined else {
            throw GeneralError.keyGenerationFailed
        }
        
        return cipherText
    }

    /// - Note: Sync. Don't call from the main thread.
    static func encrypt(_ plaintext: Data, for hexEncodedX25519PublicKey: String) throws -> EncryptionResult {
        #if DEBUG
        if Thread.isMainThread {
            preconditionFailure("It's illegal to call encrypt(_:forSnode:) from the main thread.")
        }
        #endif
        let x25519PublicKey = Data(hex: hexEncodedX25519PublicKey)
        let ephemeralKeyPair = Curve25519.generateKeyPair()
        let symmetricKey = try generateSymmetricKey(x25519PublicKey: x25519PublicKey, x25519PrivateKey: ephemeralKeyPair.privateKey)
        let ciphertext = try encrypt(plaintext, with: Data(symmetricKey))
        
        return EncryptionResult(ciphertext: ciphertext, symmetricKey: Data(symmetricKey), ephemeralPublicKey: ephemeralKeyPair.publicKey)
    }
}
