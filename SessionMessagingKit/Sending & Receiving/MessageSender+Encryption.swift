// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import Sodium
import SessionUtilitiesKit

extension MessageSender {
    internal static func encryptWithSessionProtocol(
        _ db: Database,
        plaintext: Data,
        for recipientHexEncodedX25519PublicKey: String,
        using dependencies: Dependencies
    ) throws -> Data {
        guard let userEd25519KeyPair: KeyPair = Identity.fetchUserEd25519KeyPair(db) else {
            throw MessageSenderError.noUserED25519KeyPair
        }
        
        let recipientX25519PublicKey: Data = Data(SessionId(.standard, hex: recipientHexEncodedX25519PublicKey).publicKey)
        
        let verificationData = plaintext + Data(userEd25519KeyPair.publicKey) + recipientX25519PublicKey
        guard
            let signature: Authentication.Signature = dependencies[singleton: .crypto].generate(
                .signature(message: Bytes(verificationData), secretKey: userEd25519KeyPair.secretKey)
            ),
            case .standard(let signatureBytes) = signature
        else { throw MessageSenderError.signingFailed }
        
        let plaintextWithMetadata = plaintext + Data(userEd25519KeyPair.publicKey) + Data(signatureBytes)
        guard
            let ciphertext = dependencies[singleton: .crypto].generate(
                .sealedBytes(
                    message: Bytes(plaintextWithMetadata),
                    recipientPublicKey: Bytes(recipientX25519PublicKey)
                )
            )
        else { throw MessageSenderError.encryptionFailed }
        
        return Data(ciphertext)
    }
    
    internal static func encryptWithSessionBlindingProtocol(
        _ db: Database,
        plaintext: Data,
        for recipientBlindedId: String,
        openGroupPublicKey: String,
        using dependencies: Dependencies
    ) throws -> Data {
        guard
            let recipientSessionId: SessionId = try? SessionId(from: recipientBlindedId),
            (recipientSessionId.prefix == .blinded15 || recipientSessionId.prefix == .blinded25)
        else { throw MessageSenderError.signingFailed }
        guard let userEd25519KeyPair: KeyPair = Identity.fetchUserEd25519KeyPair(db) else {
            throw MessageSenderError.noUserED25519KeyPair
        }
        guard
            let blindedKeyPair = dependencies[singleton: .crypto].generate(
                .blindedKeyPair(serverPublicKey: openGroupPublicKey, edKeyPair: userEd25519KeyPair, using: dependencies)
            )
        else { throw MessageSenderError.signingFailed }
        
        /// Step one: calculate the shared encryption key, sending from A to B
        guard
            let enc_key: Bytes = dependencies[singleton: .crypto].generate(
                .sharedBlindedEncryptionKey(
                    secretKey: userEd25519KeyPair.secretKey,
                    otherBlindedPublicKey: recipientSessionId.publicKey,
                    fromBlindedPublicKey: blindedKeyPair.publicKey,
                    toBlindedPublicKey: recipientSessionId.publicKey,
                    using: dependencies
                )
            ),
            let nonce: Bytes = dependencies[singleton: .crypto].generate(.nonce24())
        else { throw MessageSenderError.signingFailed }
        
        /// Inner data: msg || A   (i.e. the sender's ed25519 master pubkey, *not* kA blinded pubkey)
        let innerBytes: Bytes = (plaintext.bytes + userEd25519KeyPair.publicKey)
        
        /// Encrypt using xchacha20-poly1305
        guard
            let ciphertext = dependencies[singleton: .crypto].generate(
                .encryptedBytesAeadXChaCha20(message: innerBytes, secretKey: enc_key, nonce: nonce, using: dependencies)
            )
        else { throw MessageSenderError.encryptionFailed }
        
        /// data = b'\x00' + ciphertext + nonce
        return Data(Bytes(arrayLiteral: 0) + ciphertext + nonce)
    }
}
