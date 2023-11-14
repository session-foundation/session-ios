// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Sodium
import Clibsodium
import Curve25519Kit

// MARK: - Randomness

public extension Crypto.Generator {
    static func uuid() -> Crypto.Generator<UUID> {
        return Crypto.Generator(id: "uuid") { UUID() }
    }
    
    /// Returns `size` bytes of random data generated using the default secure random number generator. See
    /// [SecRandomCopyBytes](https://developer.apple.com/documentation/security/1399291-secrandomcopybytes) for more information.
    static func randomBytes(numberBytes: Int) -> Crypto.Generator<Data> {
        return Crypto.Generator(id: "randomBytes", args: [numberBytes]) {
            var randomBytes: Data = Data(count: numberBytes)
            let result = randomBytes.withUnsafeMutableBytes {
                SecRandomCopyBytes(kSecRandomDefault, numberBytes, $0.baseAddress!)
            }
            
            guard result == errSecSuccess, randomBytes.count == numberBytes else {
                SNLog(.warn, "Problem generating random bytes")
                throw GeneralError.randomGenerationFailed
            }
            
            return randomBytes
        }
    }
}

// MARK: - Box

public extension Crypto.Size {
    static let publicKey: Crypto.Size = Crypto.Size(id: "publicKey") { $0.sign.PublicKeyBytes }
    static let secretKey: Crypto.Size = Crypto.Size(id: "secretKey") { $0.sign.SecretKeyBytes }
}

// MARK: - Sign

public extension Crypto.Generator {
    static func x25519(ed25519PublicKey: Bytes) -> Crypto.Generator<[UInt8]> {
        return Crypto.Generator(id: "x25519Ed25519PublicKey", args: [ed25519PublicKey]) { sodium in
            sodium.sign.toX25519(ed25519PublicKey: ed25519PublicKey)
        }
    }
    
    static func x25519(ed25519SecretKey: Bytes) -> Crypto.Generator<[UInt8]> {
        return Crypto.Generator(id: "x25519Ed25519SecretKey", args: [ed25519SecretKey]) { sodium in
            sodium.sign.toX25519(ed25519SecretKey: ed25519SecretKey)
        }
    }
    
    static func signature(message: Bytes, secretKey: Bytes) -> Crypto.Generator<Authentication.Signature> {
        return Crypto.Generator(id: "signature", args: [message, secretKey]) { sodium in
            sodium.sign.signature(message: message, secretKey: secretKey).map { .standard(signature: $0) }
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

// MARK: - Ed25519

public extension Crypto.Generator {
    static func x25519KeyPair() -> Crypto.Generator<KeyPair> {
        return Crypto.Generator<KeyPair>(id: "x25519KeyPair") { () -> KeyPair in
            let keyPair: ECKeyPair = Curve25519.generateKeyPair()
            
            return KeyPair(publicKey: Array(keyPair.publicKey), secretKey: Array(keyPair.privateKey))
        }
    }
    
    static func ed25519KeyPair(
        seed: Data? = nil,
        using dependencies: Dependencies = Dependencies()
    ) -> Crypto.Generator<KeyPair> {
        return Crypto.Generator<KeyPair>(id: "ed25519KeyPair") {
            let pkSize: Int = dependencies[singleton: .crypto].size(.publicKey)
            let skSize: Int = dependencies[singleton: .crypto].size(.secretKey)
            var edPK: [UInt8] = [UInt8](repeating: 0, count: pkSize)
            var edSK: [UInt8] = [UInt8](repeating: 0, count: skSize)
            var targetSeed: [UInt8] = ((seed ?? dependencies[singleton: .crypto]
                .generate(.randomBytes(numberBytes: skSize)))
                .map { Array($0) })
                .defaulting(to: [])
            
            // Generate the key
            guard Sodium.lib_crypto_sign_ed25519_seed_keypair(&edPK, &edSK, &targetSeed) == 0 else {
                return nil
            }
            
            return KeyPair(publicKey: edPK, secretKey: edSK)
        }
    }
    
    static func signatureEd25519(data: Bytes, keyPair: KeyPair) -> Crypto.Generator<[UInt8]> {
        return Crypto.Generator(id: "signatureEd25519", args: [data, keyPair]) {
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
