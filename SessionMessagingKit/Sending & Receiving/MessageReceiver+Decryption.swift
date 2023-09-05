// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import Sodium
import SessionUtilitiesKit

extension MessageReceiver {
    internal static func decryptWithSessionProtocol(
        ciphertext: Data,
        using x25519KeyPair: KeyPair,
        using dependencies: Dependencies = Dependencies()
    ) throws -> (plaintext: Data, senderX25519PublicKey: String) {
        let recipientX25519PrivateKey: Bytes = x25519KeyPair.secretKey
        let recipientX25519PublicKey: Bytes = x25519KeyPair.publicKey
        let signatureSize: Int = dependencies.crypto.size(.signature)
        let ed25519PublicKeySize: Int = dependencies.crypto.size(.publicKey)
        
        // 1. ) Decrypt the message
        guard
            let plaintextWithMetadata = try? dependencies.crypto.perform(
                .open(
                    anonymousCipherText: Bytes(ciphertext),
                    recipientPublicKey: Box.PublicKey(Bytes(recipientX25519PublicKey)),
                    recipientSecretKey: Bytes(recipientX25519PrivateKey)
                )
            ),
            plaintextWithMetadata.count > (signatureSize + ed25519PublicKeySize)
        else {
            throw MessageReceiverError.decryptionFailed
        }
        
        // 2. ) Get the message parts
        let signature = Bytes(plaintextWithMetadata[plaintextWithMetadata.count - signatureSize ..< plaintextWithMetadata.count])
        let senderED25519PublicKey = Bytes(plaintextWithMetadata[plaintextWithMetadata.count - (signatureSize + ed25519PublicKeySize) ..< plaintextWithMetadata.count - signatureSize])
        let plaintext = Bytes(plaintextWithMetadata[0..<plaintextWithMetadata.count - (signatureSize + ed25519PublicKeySize)])
        
        // 3. ) Verify the signature
        let verificationData = plaintext + senderED25519PublicKey + recipientX25519PublicKey
        
        guard
            dependencies.crypto.verify(
                .signature(message: verificationData, publicKey: senderED25519PublicKey, signature: signature)
            )
        else { throw MessageReceiverError.invalidSignature }
        
        // 4. ) Get the sender's X25519 public key
        guard
            let senderX25519PublicKey = try? dependencies.crypto.perform(
                .toX25519(ed25519PublicKey: senderED25519PublicKey)
            )
        else { throw MessageReceiverError.decryptionFailed }
        
        return (Data(plaintext), SessionId(.standard, publicKey: senderX25519PublicKey).hexString)
    }
    
    internal static func decryptWithSessionBlindingProtocol(
        data: Data,
        isOutgoing: Bool,
        otherBlindedPublicKey: String,
        with openGroupPublicKey: String,
        userEd25519KeyPair: KeyPair,
        using dependencies: Dependencies = Dependencies()
    ) throws -> (plaintext: Data, senderX25519PublicKey: String) {
        /// Ensure the data is at least long enough to have the required components
        guard
            data.count > (dependencies.crypto.size(.nonce24) + 2),
            let blindedKeyPair = dependencies.crypto.generate(
                .blindedKeyPair(serverPublicKey: openGroupPublicKey, edKeyPair: userEd25519KeyPair, using: dependencies)
            )
        else { throw MessageReceiverError.decryptionFailed }

        /// Step one: calculate the shared encryption key, receiving from A to B
        let otherKeyBytes: Bytes = Data(hex: otherBlindedPublicKey.removingIdPrefixIfNeeded()).bytes
        let kA: Bytes = (isOutgoing ? blindedKeyPair.publicKey : otherKeyBytes)
        guard
            let dec_key: Bytes = try? dependencies.crypto.perform(
                .sharedBlindedEncryptionKey(
                    secretKey: userEd25519KeyPair.secretKey,
                    otherBlindedPublicKey: otherKeyBytes,
                    fromBlindedPublicKey: kA,
                    toBlindedPublicKey: (isOutgoing ? otherKeyBytes : blindedKeyPair.publicKey),
                    using: dependencies
                )
            )
        else { throw MessageReceiverError.decryptionFailed }
        
        /// v, ct, nc = data[0], data[1:-24], data[-24:]
        let version: UInt8 = data.bytes[0]
        let ciphertext: Bytes = Bytes(data.bytes[1..<(data.count - dependencies.crypto.size(.nonce24))])
        let nonce: Bytes = Bytes(data.bytes[(data.count - dependencies.crypto.size(.nonce24))..<data.count])

        /// Make sure our encryption version is okay
        guard version == 0 else { throw MessageReceiverError.decryptionFailed }

        /// Decrypt
        guard
            let innerBytes: Bytes = try? dependencies.crypto.perform(
                .decryptAeadXChaCha20(
                    authenticatedCipherText: ciphertext,
                    secretKey: dec_key,
                    nonce: nonce
                )
            )
        else { throw MessageReceiverError.decryptionFailed }
        
        /// Ensure the length is correct
        guard innerBytes.count > dependencies.crypto.size(.publicKey) else { throw MessageReceiverError.decryptionFailed }

        /// Split up: the last 32 bytes are the sender's *unblinded* ed25519 key
        let plaintext: Bytes = Bytes(innerBytes[
            0...(innerBytes.count - 1 - dependencies.crypto.size(.publicKey))
        ])
        let sender_edpk: Bytes = Bytes(innerBytes[
            (innerBytes.count - dependencies.crypto.size(.publicKey))...(innerBytes.count - 1)
        ])
        
        /// Verify that the inner sender_edpk (A) yields the same outer kA we got with the message
        guard
            let blindingFactor: Bytes = try? dependencies.crypto.perform(
                .generateBlindingFactor(serverPublicKey: openGroupPublicKey, using: dependencies)
            ),
            let sharedSecret: Bytes = try? dependencies.crypto.perform(
                .combineKeys(lhsKeyBytes: blindingFactor, rhsKeyBytes: sender_edpk)
            ),
            kA == sharedSecret
        else { throw MessageReceiverError.invalidSignature }
        
        /// Get the sender's X25519 public key
        guard
            let senderSessionIdBytes: Bytes = try? dependencies.crypto.perform(
                .toX25519(ed25519PublicKey: sender_edpk)
            )
        else { throw MessageReceiverError.decryptionFailed }
        
        return (Data(plaintext), SessionId(.standard, publicKey: senderSessionIdBytes).hexString)
    }
}
