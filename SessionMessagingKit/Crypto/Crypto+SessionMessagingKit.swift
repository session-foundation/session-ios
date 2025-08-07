// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import CryptoKit
import SessionSnodeKit
import SessionUtil
import SessionUtilitiesKit

// MARK: - Encryption

public extension Crypto.Generator {
    static func ciphertextWithSessionProtocol(
        plaintext: Data,
        destination: Message.Destination
    ) -> Crypto.Generator<Data> {
        return Crypto.Generator(
            id: "ciphertextWithSessionProtocol",
            args: [plaintext, destination]
        ) { dependencies in
            let destinationX25519PublicKey: Data = try {
                switch destination {
                    case .contact(let publicKey): return Data(SessionId(.standard, hex: publicKey).publicKey)
                    case .syncMessage: return Data(dependencies[cache: .general].sessionId.publicKey)
                    case .closedGroup: throw MessageSenderError.deprecatedLegacyGroup
                    default: throw MessageSenderError.signingFailed
                }
            }()

            var cPlaintext: [UInt8] = Array(plaintext)
            var cEd25519SecretKey: [UInt8] = dependencies[cache: .general].ed25519SecretKey
            var cDestinationPubKey: [UInt8] = Array(destinationX25519PublicKey)
            var maybeCiphertext: UnsafeMutablePointer<UInt8>? = nil
            var ciphertextLen: Int = 0

            guard !cEd25519SecretKey.isEmpty else { throw MessageSenderError.noUserED25519KeyPair }
            guard
                cEd25519SecretKey.count == 64,
                cDestinationPubKey.count == 32,
                session_encrypt_for_recipient_deterministic(
                    &cPlaintext,
                    cPlaintext.count,
                    &cEd25519SecretKey,
                    &cDestinationPubKey,
                    &maybeCiphertext,
                    &ciphertextLen
                ),
                ciphertextLen > 0,
                let ciphertext: Data = maybeCiphertext.map({ Data(bytes: $0, count: ciphertextLen) })
            else { throw MessageSenderError.encryptionFailed }

            free(UnsafeMutableRawPointer(mutating: maybeCiphertext))

            return ciphertext
        }
    }

    static func ciphertextWithMultiEncrypt(
        messages: [Data],
        toRecipients recipients: [SessionId],
        ed25519PrivateKey: [UInt8],
        domain: LibSession.Crypto.Domain
    ) -> Crypto.Generator<Data> {
        return Crypto.Generator(
            id: "ciphertextWithMultiEncrypt",
            args: [messages, recipients, ed25519PrivateKey, domain]
        ) {
            var outLen: Int = 0
            return try messages.map { Array($0) }.withUnsafeUInt8CArray { cMessages in
                try recipients.map { Array($0.publicKey) }.withUnsafeUInt8CArray { cRecipients in
                    var messageSizes: [Int] = messages.map { $0.count }
                    var secretKey: [UInt8] = ed25519PrivateKey
                    var cDomain: [CChar] = try domain.cString(using: .utf8) ?? {
                        throw LibSessionError.invalidCConversion
                    }()
                    
                    let cEncryptedDataPtr: UnsafeMutablePointer<UInt8>? = session_encrypt_for_multiple_simple_ed25519(
                        &outLen,
                        cMessages.baseAddress,
                        &messageSizes,
                        messages.count,
                        cRecipients.baseAddress,
                        recipients.count,
                        &secretKey,
                        &cDomain,
                        nil,
                        0
                    )

                    let encryptedData: Data? = cEncryptedDataPtr.map { Data(bytes: $0, count: outLen) }
                    free(UnsafeMutableRawPointer(mutating: cEncryptedDataPtr))

                    return try encryptedData ?? { throw MessageSenderError.encryptionFailed }()
                }
            }
        }
    }
    
    static func ciphertextWithXChaCha20(plaintext: Data, encKey: [UInt8]) -> Crypto.Generator<Data> {
        return Crypto.Generator(
            id: "ciphertextWithXChaCha20",
            args: [plaintext, encKey]
        ) {
            var cPlaintext: [UInt8] = Array(plaintext)
            var cEncKey: [UInt8] = encKey
            var maybeCiphertext: UnsafeMutablePointer<UInt8>? = nil
            var ciphertextLen: Int = 0

            guard
                cEncKey.count == 32,
                session_encrypt_xchacha20(
                    &cPlaintext,
                    cPlaintext.count,
                    &cEncKey,
                    &maybeCiphertext,
                    &ciphertextLen
                ),
                ciphertextLen > 0,
                let ciphertext: Data = maybeCiphertext.map({ Data(bytes: $0, count: ciphertextLen) })
            else { throw MessageSenderError.encryptionFailed }

            free(UnsafeMutableRawPointer(mutating: maybeCiphertext))

            return ciphertext
        }
    }
}

// MARK: - Decryption

public extension Crypto.Generator {
    static func plaintextWithSessionProtocol(
        ciphertext: Data
    ) -> Crypto.Generator<(plaintext: Data, senderSessionIdHex: String)> {
        return Crypto.Generator(
            id: "plaintextWithSessionProtocol",
            args: [ciphertext]
        ) { dependencies in
            var cCiphertext: [UInt8] = Array(ciphertext)
            var cEd25519SecretKey: [UInt8] = dependencies[cache: .general].ed25519SecretKey
            var cSenderSessionId: [CChar] = [CChar](repeating: 0, count: 67)
            var maybePlaintext: UnsafeMutablePointer<UInt8>? = nil
            var plaintextLen: Int = 0

            guard !cEd25519SecretKey.isEmpty else { throw MessageSenderError.noUserED25519KeyPair }
            guard
                cEd25519SecretKey.count == 64,
                session_decrypt_incoming(
                    &cCiphertext,
                    cCiphertext.count,
                    &cEd25519SecretKey,
                    &cSenderSessionId,
                    &maybePlaintext,
                    &plaintextLen
                ),
                plaintextLen > 0,
                let plaintext: Data = maybePlaintext.map({ Data(bytes: $0, count: plaintextLen) })
            else { throw MessageReceiverError.decryptionFailed }

            free(UnsafeMutableRawPointer(mutating: maybePlaintext))

            return (plaintext, String(cString: cSenderSessionId))
        }
    }

    static func plaintextWithPushNotificationPayload(
        payload: Data,
        encKey: Data
    ) -> Crypto.Generator<Data> {
        return Crypto.Generator(
            id: "plaintextWithPushNotificationPayload",
            args: [payload, encKey]
        ) {
            var cPayload: [UInt8] = Array(payload)
            var cEncKey: [UInt8] = Array(encKey)
            var maybePlaintext: UnsafeMutablePointer<UInt8>? = nil
            var plaintextLen: Int = 0

            guard
                cEncKey.count == 32,
                session_decrypt_push_notification(
                    &cPayload,
                    cPayload.count,
                    &cEncKey,
                    &maybePlaintext,
                    &plaintextLen
                ),
                plaintextLen > 0,
                let plaintext: Data = maybePlaintext.map({ Data(bytes: $0, count: plaintextLen) })
            else { throw MessageReceiverError.decryptionFailed }

            free(UnsafeMutableRawPointer(mutating: maybePlaintext))

            return plaintext
        }
    }

    static func plaintextWithMultiEncrypt(
        ciphertext: Data,
        senderSessionId: SessionId,
        ed25519PrivateKey: [UInt8],
        domain: LibSession.Crypto.Domain
    ) -> Crypto.Generator<Data> {
        return Crypto.Generator(
            id: "plaintextWithMultiEncrypt",
            args: [ciphertext, senderSessionId, ed25519PrivateKey, domain]
        ) {
            guard ed25519PrivateKey.count == 64 else { throw CryptoError.missingUserSecretKey }
            
            var outLen: Int = 0
            var cEncryptedData: [UInt8] = Array(ciphertext)
            var cEd25519PrivateKey: [UInt8] = ed25519PrivateKey
            var cSenderPubkey: [UInt8] = senderSessionId.publicKey
            var cDomain: [CChar] = try domain.cString(using: .utf8) ?? { throw LibSessionError.invalidCConversion }()
            let cDecryptedDataPtr: UnsafeMutablePointer<UInt8>? = session_decrypt_for_multiple_simple_ed25519(
                &outLen,
                &cEncryptedData,
                cEncryptedData.count,
                &cEd25519PrivateKey,
                &cSenderPubkey,
                &cDomain
            )

            let decryptedData: Data? = cDecryptedDataPtr.map { Data(bytes: $0, count: outLen) }
            free(UnsafeMutableRawPointer(mutating: cDecryptedDataPtr))

            return try decryptedData ?? { throw MessageReceiverError.decryptionFailed }()
        }
    }
    
    static func messageServerHash(
        swarmPubkey: String,
        namespace: SnodeAPI.Namespace,
        data: Data
    ) -> Crypto.Generator<String> {
        return Crypto.Generator(
            id: "messageServerHash",
            args: [swarmPubkey, namespace, data]
        ) {
            let cSwarmPubkey: [CChar] = try swarmPubkey.cString(using: .utf8) ?? { throw LibSessionError.invalidCConversion }()
            let cData: [CChar] = try data.base64EncodedString().cString(using: .utf8) ?? { throw LibSessionError.invalidCConversion }()
            var cHash: [CChar] = [CChar](repeating: 0, count: 65)
            
            guard session_compute_message_hash(cSwarmPubkey, Int16(namespace.rawValue), cData, &cHash) else {
                throw MessageReceiverError.decryptionFailed
            }
            
            return String(cString: cHash)
        }
    }
    
    static func plaintextWithXChaCha20(ciphertext: Data, encKey: [UInt8]) -> Crypto.Generator<Data> {
        return Crypto.Generator(
            id: "plaintextWithXChaCha20",
            args: [ciphertext, encKey]
        ) {
            var cCiphertext: [UInt8] = Array(ciphertext)
            var cEncKey: [UInt8] = encKey
            var maybePlaintext: UnsafeMutablePointer<UInt8>? = nil
            var plaintextLen: Int = 0

            guard
                cEncKey.count == 32,
                session_decrypt_xchacha20(
                    &cCiphertext,
                    cCiphertext.count,
                    &cEncKey,
                    &maybePlaintext,
                    &plaintextLen
                ),
                plaintextLen > 0,
                let plaintext: Data = maybePlaintext.map({ Data(bytes: $0, count: plaintextLen) })
            else { throw MessageReceiverError.decryptionFailed }

            free(UnsafeMutableRawPointer(mutating: maybePlaintext))

            return plaintext
        }
    }
}

// MARK: - DisplayPicture

public extension Crypto.Generator {
    static func encryptedDataDisplayPicture(
        data: Data,
        key: Data
    ) -> Crypto.Generator<Data> {
        return Crypto.Generator(
            id: "encryptedDataDisplayPicture",
            args: [data, key]
        ) { dependencies in
            // The key structure is: nonce || ciphertext || authTag
            guard
                key.count == DisplayPictureManager.aes256KeyByteLength,
                let nonceData: Data = dependencies[singleton: .crypto]
                    .generate(.randomBytes(DisplayPictureManager.nonceLength)),
                let nonce: AES.GCM.Nonce = try? AES.GCM.Nonce(data: nonceData),
                let sealedData: AES.GCM.SealedBox = try? AES.GCM.seal(
                    data,
                    using: SymmetricKey(data: key),
                    nonce: nonce
                ),
                let encryptedContent: Data = sealedData.combined
            else { throw CryptoError.failedToGenerateOutput }

            return encryptedContent
        }
    }

    static func decryptedDataDisplayPicture(
        data: Data,
        key: Data
    ) -> Crypto.Generator<Data> {
        return Crypto.Generator(
            id: "decryptedDataDisplayPicture",
            args: [data, key]
        ) { dependencies in
            guard key.count == DisplayPictureManager.aes256KeyByteLength else {
                throw CryptoError.failedToGenerateOutput
            }

            // The key structure is: nonce || ciphertext || authTag
            let cipherTextLength: Int = (data.count - (DisplayPictureManager.nonceLength + DisplayPictureManager.tagLength))

            guard
                cipherTextLength > 0,
                let sealedData: AES.GCM.SealedBox = try? AES.GCM.SealedBox(
                    nonce: AES.GCM.Nonce(data: data.subdata(in: 0..<DisplayPictureManager.nonceLength)),
                    ciphertext: data.subdata(in: DisplayPictureManager.nonceLength..<(DisplayPictureManager.nonceLength + cipherTextLength)),
                    tag: data.subdata(in: (data.count - DisplayPictureManager.tagLength)..<data.count)
                ),
                let decryptedData: Data = try? AES.GCM.open(sealedData, using: SymmetricKey(data: key))
            else { throw CryptoError.failedToGenerateOutput }

            return decryptedData
        }
    }
}
