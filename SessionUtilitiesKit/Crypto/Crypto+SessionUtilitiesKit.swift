// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Sodium
import Clibsodium
import Curve25519Kit

// MARK: - Box

public extension Crypto.Size {
    static let publicKey: Crypto.Size = Crypto.Size(id: "publicKey") { $0.sign.PublicKeyBytes }
    static let secretKey: Crypto.Size = Crypto.Size(id: "secretKey") { $0.sign.SecretKeyBytes }
}

// MARK: - Sign

public extension Crypto.Action {
    static func toX25519(ed25519PublicKey: Bytes) -> Crypto.Action {
        return Crypto.Action(id: "toX25519", args: [ed25519PublicKey]) { sodium in
            sodium.sign.toX25519(ed25519PublicKey: ed25519PublicKey)
        }
    }
    
    static func toX25519(ed25519SecretKey: Bytes) -> Crypto.Action {
        return Crypto.Action(id: "toX25519", args: [ed25519SecretKey]) { sodium in
            sodium.sign.toX25519(ed25519SecretKey: ed25519SecretKey)
        }
    }
}

// MARK: - Ed25519

public extension Crypto.KeyPairType {
    static func x25519KeyPair() -> Crypto.KeyPairType {
        return Crypto.KeyPairType(id: "x25519KeyPair") {
            let keyPair: ECKeyPair = Curve25519.generateKeyPair()
            
            return KeyPair(publicKey: Array(keyPair.publicKey), secretKey: Array(keyPair.privateKey))
        }
    }
    
    static func ed25519KeyPair(
        seed: Data? = nil,
        using dependencies: Dependencies = Dependencies()
    ) -> Crypto.KeyPairType {
        return Crypto.KeyPairType(id: "ed25519KeyPair") {
            let pkSize: Int = dependencies[singleton: .crypto].size(.publicKey)
            let skSize: Int = dependencies[singleton: .crypto].size(.secretKey)
            var edPK: [UInt8] = [UInt8](repeating: 0, count: pkSize)
            var edSK: [UInt8] = [UInt8](repeating: 0, count: skSize)
            var targetSeed: [UInt8] = ((seed ?? (try? Randomness.generateRandomBytes(numberBytes: skSize)))
                .map { Array($0) })
                .defaulting(to: [])
            
            // Generate the key
            guard Sodium.lib_crypto_sign_ed25519_seed_keypair(&edPK, &edSK, &targetSeed) == 0 else {
                return nil
            }
            
            return KeyPair(publicKey: edPK, secretKey: edSK)
        }
    }
}

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
