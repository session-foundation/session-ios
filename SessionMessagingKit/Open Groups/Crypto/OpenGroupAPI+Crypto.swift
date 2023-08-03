// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import CryptoKit
import Sodium
import Clibsodium
import Curve25519Kit
import SessionUtilitiesKit

// MARK: - Nonce

internal extension OpenGroupAPI {
    class NonceGenerator16Byte: NonceGenerator {
        public var NonceBytes: Int { 16 }
    }
    
    class NonceGenerator24Byte: NonceGenerator {
        public var NonceBytes: Int { 24 }
    }
}

public extension Crypto.Size {
    static let nonce16: Crypto.Size = Crypto.Size(id: "nonce16") { OpenGroupAPI.NonceGenerator16Byte().NonceBytes }
    static let nonce24: Crypto.Size = Crypto.Size(id: "nonce24") { OpenGroupAPI.NonceGenerator24Byte().NonceBytes }
}

public extension Crypto.Action {
    static func generateNonce16() -> Crypto.Action {
        return Crypto.Action(id: "generateNonce16") { OpenGroupAPI.NonceGenerator16Byte().nonce() }
    }
    
    static func generateNonce24() -> Crypto.Action {
        return Crypto.Action(id: "generateNonce24") { OpenGroupAPI.NonceGenerator24Byte().nonce() }
    }
}

// MARK: - AeadXChaCha20Poly1305Ietf

public extension Crypto.Size {
    static let aeadXChaCha20KeyBytes: Crypto.Size = Crypto.Size(id: "aeadXChaCha20KeyBytes") {
        Sodium().aead.xchacha20poly1305ietf.KeyBytes
    }
    static let aeadXChaCha20ABytes: Crypto.Size = Crypto.Size(id: "aeadXChaCha20ABytes") {
        Sodium().aead.xchacha20poly1305ietf.ABytes
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
            guard secretKey.count == dependencies.crypto.size(.aeadXChaCha20KeyBytes) else { return nil }

            var authenticatedCipherText = Bytes(
                repeating: 0,
                count: message.count + dependencies.crypto.size(.aeadXChaCha20ABytes)
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
        ) {
            return Sodium().aead.xchacha20poly1305ietf.decrypt(
                authenticatedCipherText: authenticatedCipherText,
                secretKey: secretKey,
                nonce: nonce,
                additionalData: additionalData
            )
        }
    }
}

// MARK: - Blinding

/// These extenion methods are used to generate a sign "blinded" messages
///
/// According to the Swift engineers the only situation when `UnsafeRawBufferPointer.baseAddress` is nil is when it's an
/// empty collection; as such our guard cases wihch return `-1` when unwrapping this value should never be hit and we can ignore
/// them as possible results.
///
/// For more information see:
/// https://forums.swift.org/t/when-is-unsafemutablebufferpointer-baseaddress-nil/32136/5
/// https://github.com/apple/swift-evolution/blob/master/proposals/0055-optional-unsafe-pointers.md#unsafebufferpointer
public extension Crypto.Action {
    private static let scalarLength: Int = Int(crypto_core_ed25519_scalarbytes())   // 32
    private static let noClampLength: Int = Int(Sodium.lib_crypto_scalarmult_ed25519_bytes())  // 32
    private static let scalarMultLength: Int = Int(crypto_scalarmult_bytes())       // 32
    fileprivate static let publicKeyLength: Int = Int(crypto_scalarmult_bytes())        // 32
    fileprivate static let secretKeyLength: Int = Int(crypto_sign_secretkeybytes())     // 64
    
    /// 64-byte blake2b hash then reduce to get the blinding factor
    static func generateBlindingFactor(
        serverPublicKey: String,
        using dependencies: Dependencies
    ) -> Crypto.Action {
        return Crypto.Action(
            id: "generateBlindingFactor",
            args: [serverPublicKey]
        ) {
            /// k = salt.crypto_core_ed25519_scalar_reduce(blake2b(server_pk, digest_size=64).digest())
            let serverPubKeyData: Data = Data(hex: serverPublicKey)
            
            guard
                !serverPubKeyData.isEmpty,
                let serverPublicKeyHashBytes: Bytes = try? dependencies.crypto.perform(
                    .hash(message: [UInt8](serverPubKeyData), outputLength: 64)
                )
            else { return nil }
            
            /// Reduce the server public key into an ed25519 scalar (`k`)
            let kPtr: UnsafeMutablePointer<UInt8> = UnsafeMutablePointer<UInt8>.allocate(capacity: Crypto.Action.scalarLength)
            
            _ = serverPublicKeyHashBytes.withUnsafeBytes { (serverPublicKeyHashPtr: UnsafeRawBufferPointer) -> Int32 in
                guard let serverPublicKeyHashBaseAddress: UnsafePointer<UInt8> = serverPublicKeyHashPtr.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                    return -1   // Impossible case (refer to comments at top of extension)
                }
                
                Sodium.lib_crypto_core_ed25519_scalar_reduce(kPtr, serverPublicKeyHashBaseAddress)
                return 0
            }
            
            return Data(bytes: kPtr, count: Crypto.Action.scalarLength).bytes
        }
    }
    
    /// Calculate k*a.  To get 'a' (the Ed25519 private key scalar) we call the sodium function to
    /// convert to an *x* secret key, which seems wrong--but isn't because converted keys use the
    /// same secret scalar secret (and so this is just the most convenient way to get 'a' out of
    /// a sodium Ed25519 secret key)
    fileprivate static func generatePrivateKeyScalar(secretKey: Bytes) -> Bytes {
        /// a = s.to_curve25519_private_key().encode()
        let aPtr: UnsafeMutablePointer<UInt8> = UnsafeMutablePointer<UInt8>.allocate(capacity: Crypto.Action.scalarMultLength)
        
        /// Looks like the `crypto_sign_ed25519_sk_to_curve25519` function can't actually fail so no need to verify the result
        /// See: https://github.com/jedisct1/libsodium/blob/master/src/libsodium/crypto_sign/ed25519/ref10/keypair.c#L70
        _ = secretKey.withUnsafeBytes { (secretKeyPtr: UnsafeRawBufferPointer) -> Int32 in
            guard let secretKeyBaseAddress: UnsafePointer<UInt8> = secretKeyPtr.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return -1   // Impossible case (refer to comments at top of extension)
            }
            
            return crypto_sign_ed25519_sk_to_curve25519(aPtr, secretKeyBaseAddress)
        }
        
        return Data(bytes: aPtr, count: Crypto.Action.scalarMultLength).bytes
    }
    
    /// Constructs an Ed25519 signature from a root Ed25519 key and a blinded scalar/pubkey pair, with one tweak to the
    /// construction: we add kA into the hashed value that yields r so that we have domain separation for different blinded
    /// pubkeys (this doesn't affect verification at all)
    static func sogsSignature(
        message: Bytes,
        secretKey: Bytes,
        blindedSecretKey ka: Bytes,
        blindedPublicKey kA: Bytes
    ) -> Crypto.Action {
        return Crypto.Action(
            id: "sogsSignature",
            args: [message, secretKey, ka, kA]
        ) {
            /// H_rh = sha512(s.encode()).digest()[32:]
            let H_rh: Bytes = Bytes(SHA512.hash(data: secretKey).suffix(32))
            
            /// r = salt.crypto_core_ed25519_scalar_reduce(sha512_multipart(H_rh, kA, message_parts))
            let combinedHashBytes: Bytes = SHA512.hash(data: H_rh + kA + message).bytes
            let rPtr: UnsafeMutablePointer<UInt8> = UnsafeMutablePointer<UInt8>.allocate(capacity: Crypto.Action.scalarLength)
            
            _ = combinedHashBytes.withUnsafeBytes { (combinedHashPtr: UnsafeRawBufferPointer) -> Int32 in
                guard let combinedHashBaseAddress: UnsafePointer<UInt8> = combinedHashPtr.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                    return -1   // Impossible case (refer to comments at top of extension)
                }
                
                Sodium.lib_crypto_core_ed25519_scalar_reduce(rPtr, combinedHashBaseAddress)
                return 0
            }
            
            /// sig_R = salt.crypto_scalarmult_ed25519_base_noclamp(r)
            let sig_RPtr: UnsafeMutablePointer<UInt8> = UnsafeMutablePointer<UInt8>.allocate(capacity: Crypto.Action.noClampLength)
            guard crypto_scalarmult_ed25519_base_noclamp(sig_RPtr, rPtr) == 0 else { return nil }
            
            /// HRAM = salt.crypto_core_ed25519_scalar_reduce(sha512_multipart(sig_R, kA, message_parts))
            let sig_RBytes: Bytes = Data(bytes: sig_RPtr, count: Crypto.Action.noClampLength).bytes
            let HRAMHashBytes: Bytes = SHA512.hash(data: sig_RBytes + kA + message).bytes
            let HRAMPtr: UnsafeMutablePointer<UInt8> = UnsafeMutablePointer<UInt8>.allocate(capacity: Crypto.Action.scalarLength)
            
            _ = HRAMHashBytes.withUnsafeBytes { (HRAMHashPtr: UnsafeRawBufferPointer) -> Int32 in
                guard let HRAMHashBaseAddress: UnsafePointer<UInt8> = HRAMHashPtr.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                    return -1   // Impossible case (refer to comments at top of extension)
                }
                
                Sodium.lib_crypto_core_ed25519_scalar_reduce(HRAMPtr, HRAMHashBaseAddress)
                return 0
            }
            
            /// sig_s = salt.crypto_core_ed25519_scalar_add(r, salt.crypto_core_ed25519_scalar_mul(HRAM, ka))
            let sig_sMulPtr: UnsafeMutablePointer<UInt8> = UnsafeMutablePointer<UInt8>.allocate(capacity: Crypto.Action.scalarLength)
            let sig_sPtr: UnsafeMutablePointer<UInt8> = UnsafeMutablePointer<UInt8>.allocate(capacity: Crypto.Action.scalarLength)
            
            _ = ka.withUnsafeBytes { (kaPtr: UnsafeRawBufferPointer) -> Int32 in
                guard let kaBaseAddress: UnsafePointer<UInt8> = kaPtr.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                    return -1   // Impossible case (refer to comments at top of extension)
                }
                
                Sodium.lib_crypto_core_ed25519_scalar_mul(sig_sMulPtr, HRAMPtr, kaBaseAddress)
                Sodium.lib_crypto_core_ed25519_scalar_add(sig_sPtr, rPtr, sig_sMulPtr)
                return 0
            }
            
            /// full_sig = sig_R + sig_s
            return (Data(bytes: sig_RPtr, count: Crypto.Action.noClampLength).bytes + Data(bytes: sig_sPtr, count: Crypto.Action.scalarLength).bytes)
        }
    }
    
    /// Combines two keys (`kA`)
    static func combineKeys(
        lhsKeyBytes: Bytes,
        rhsKeyBytes: Bytes
    ) -> Crypto.Action {
        return Crypto.Action(
            id: "combineKeys",
            args: [lhsKeyBytes, rhsKeyBytes]
        ) {
            let combinedPtr: UnsafeMutablePointer<UInt8> = UnsafeMutablePointer<UInt8>.allocate(capacity: Crypto.Action.noClampLength)
            
            let result = rhsKeyBytes.withUnsafeBytes { (rhsKeyBytesPtr: UnsafeRawBufferPointer) -> Int32 in
                return lhsKeyBytes.withUnsafeBytes { (lhsKeyBytesPtr: UnsafeRawBufferPointer) -> Int32 in
                    guard let lhsKeyBytesBaseAddress: UnsafePointer<UInt8> = lhsKeyBytesPtr.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                        return -1   // Impossible case (refer to comments at top of extension)
                    }
                    guard let rhsKeyBytesBaseAddress: UnsafePointer<UInt8> = rhsKeyBytesPtr.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                        return -1   // Impossible case (refer to comments at top of extension)
                    }
                    
                    return Sodium.lib_crypto_scalarmult_ed25519_noclamp(combinedPtr, lhsKeyBytesBaseAddress, rhsKeyBytesBaseAddress)
                }
            }
            
            /// Ensure the above worked
            guard result == 0 else { return nil }
            
            return Data(bytes: combinedPtr, count: Crypto.Action.noClampLength).bytes
        }
    }
    
    /// Calculate a shared secret for a message from A to B:
    ///
    /// BLAKE2b(a kB || kA || kB)
    ///
    /// The receiver can calulate the same value via:
    ///
    /// BLAKE2b(b kA || kA || kB)
    static func sharedBlindedEncryptionKey(
        secretKey: Bytes,
        otherBlindedPublicKey: Bytes,
        fromBlindedPublicKey kA: Bytes,
        toBlindedPublicKey kB: Bytes,
        using dependencies: Dependencies
    ) -> Crypto.Action {
        return Crypto.Action(
            id: "sharedBlindedEncryptionKey",
            args: [secretKey, otherBlindedPublicKey, kA, kB]
        ) {
            let aBytes: Bytes = generatePrivateKeyScalar(secretKey: secretKey)
            let combinedKeyBytes: Bytes = try dependencies.crypto.perform(
                .combineKeys(lhsKeyBytes: aBytes, rhsKeyBytes: otherBlindedPublicKey)
            )
            
            return try dependencies.crypto.perform(
                .hash(message: (combinedKeyBytes + kA + kB), outputLength: 32)
            )
        }
    }
}

public extension Crypto.KeyPairType {
    /// Constructs a "blinded" key pair (`ka, kA`) based on an open group server `publicKey` and an ed25519 `keyPair`
    static func blindedKeyPair(
        serverPublicKey: String,
        edKeyPair: KeyPair,
        using dependencies: Dependencies
    ) -> Crypto.KeyPairType {
        return Crypto.KeyPairType(
            id: "blindedKeyPair",
            args: [serverPublicKey, edKeyPair]
        ) {
            guard
                edKeyPair.publicKey.count == Crypto.Action.publicKeyLength,
                edKeyPair.secretKey.count == Crypto.Action.secretKeyLength,
                let kBytes: Bytes = try? dependencies.crypto.perform(
                    .generateBlindingFactor(serverPublicKey: serverPublicKey, using: dependencies)
                )
            else { return nil }
            
            let aBytes: Bytes = Crypto.Action.generatePrivateKeyScalar(secretKey: edKeyPair.secretKey)
            
            /// Generate the blinded key pair `ka`, `kA`
            let kaPtr: UnsafeMutablePointer<UInt8> = UnsafeMutablePointer<UInt8>.allocate(capacity: Crypto.Action.secretKeyLength)
            let kAPtr: UnsafeMutablePointer<UInt8> = UnsafeMutablePointer<UInt8>.allocate(capacity: Crypto.Action.publicKeyLength)
            
            _ = aBytes.withUnsafeBytes { (aPtr: UnsafeRawBufferPointer) -> Int32 in
                return kBytes.withUnsafeBytes { (kPtr: UnsafeRawBufferPointer) -> Int32 in
                    guard let kBaseAddress: UnsafePointer<UInt8> = kPtr.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                        return -1   // Impossible case (refer to comments at top of extension)
                    }
                    guard let aBaseAddress: UnsafePointer<UInt8> = aPtr.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                        return -1   // Impossible case (refer to comments at top of extension)
                    }
                    
                    Sodium.lib_crypto_core_ed25519_scalar_mul(kaPtr, kBaseAddress, aBaseAddress)
                    return 0
                }
            }
            
            guard crypto_scalarmult_ed25519_base_noclamp(kAPtr, kaPtr) == 0 else { return nil }
            
            return KeyPair(
                publicKey: Data(bytes: kAPtr, count: Crypto.Action.publicKeyLength).bytes,
                secretKey: Data(bytes: kaPtr, count: Crypto.Action.secretKeyLength).bytes
            )
        }
    }
}

public extension Crypto.Verification {
    /// This method should be used to check if a users standard sessionId matches a blinded one
    static func sessionId(
        _ standardSessionId: String,
        matchesBlindedId blindedSessionId: String,
        serverPublicKey: String,
        using dependencies: Dependencies
    ) -> Crypto.Verification {
        return Crypto.Verification(
            id: "sessionId",
            args: [standardSessionId, blindedSessionId, serverPublicKey]
        ) {
            // Only support generating blinded keys for standard session ids
            guard
                let sessionId: SessionId = SessionId(from: standardSessionId),
                sessionId.prefix == .standard,
                let blindedId: SessionId = SessionId(from: blindedSessionId),
                (
                    blindedId.prefix == .blinded15 ||
                    blindedId.prefix == .blinded25
                ),
                let kBytes: Bytes = try? dependencies.crypto.perform(
                    .generateBlindingFactor(serverPublicKey: serverPublicKey, using: dependencies)
                )
            else { return false }
            
            /// From the session id (ignoring 05 prefix) we have two possible ed25519 pubkeys; the first is the positive (which is what
            /// Signal's XEd25519 conversion always uses)
            ///
            /// Note: The below method is code we have exposed from the `curve25519_verify` method within the Curve25519 library
            /// rather than custom code we have written
            guard let xEd25519Key: Data = try? Ed25519.publicKey(from: Data(hex: sessionId.publicKey)) else { return false }
            
            /// Blind the positive public key
            guard
                let pk1: Bytes = try? dependencies.crypto.perform(
                    .combineKeys(lhsKeyBytes: kBytes, rhsKeyBytes: xEd25519Key.bytes)
                )
            else { return false }
            
            /// For the negative, what we're going to get out of the above is simply the negative of pk1, so flip the sign bit to get pk2
            ///     pk2 = pk1[0:31] + bytes([pk1[31] ^ 0b1000_0000])
            let pk2: Bytes = (pk1[0..<31] + [(pk1[31] ^ 0b1000_0000)])
            
            return (
                SessionId(.blinded15, publicKey: pk1).publicKey == blindedId.publicKey ||
                SessionId(.blinded15, publicKey: pk2).publicKey == blindedId.publicKey
            )
        }
    }
}
