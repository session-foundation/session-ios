// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import SessionUtil
import SessionUtilitiesKit

// MARK: - Messages

public extension Crypto.Generator {
    static func ciphertextWithSessionBlindingProtocol(
        plaintext: Data,
        recipientBlindedId: String,
        serverPublicKey: String
    ) -> Crypto.Generator<Data> {
        return Crypto.Generator(
            id: "ciphertextWithSessionBlindingProtocol",
            args: [plaintext, serverPublicKey]
        ) { dependencies in
            var cPlaintext: [UInt8] = Array(plaintext)
            var cEd25519SecretKey: [UInt8] = dependencies[cache: .general].ed25519SecretKey
            var cRecipientBlindedId: [UInt8] = Array(Data(hex: recipientBlindedId))
            var cServerPublicKey: [UInt8] = Array(Data(hex: serverPublicKey))
            var maybeCiphertext: UnsafeMutablePointer<UInt8>? = nil
            var ciphertextLen: Int = 0

            guard !cEd25519SecretKey.isEmpty else { throw MessageSenderError.noUserED25519KeyPair }
            guard
                cEd25519SecretKey.count == 64,
                cServerPublicKey.count == 32,
                session_encrypt_for_blinded_recipient(
                    &cPlaintext,
                    cPlaintext.count,
                    &cEd25519SecretKey,
                    &cServerPublicKey,
                    &cRecipientBlindedId,
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

    static func plaintextWithSessionBlindingProtocol(
        ciphertext: Data,
        senderId: String,
        recipientId: String,
        serverPublicKey: String
    ) -> Crypto.Generator<(plaintext: Data, senderSessionIdHex: String)> {
        return Crypto.Generator(
            id: "plaintextWithSessionBlindingProtocol",
            args: [ciphertext, senderId, recipientId]
        ) { dependencies in
            var cCiphertext: [UInt8] = Array(ciphertext)
            var cEd25519SecretKey: [UInt8] = dependencies[cache: .general].ed25519SecretKey
            var cSenderId: [UInt8] = Array(Data(hex: senderId))
            var cRecipientId: [UInt8] = Array(Data(hex: recipientId))
            var cServerPublicKey: [UInt8] = Array(Data(hex: serverPublicKey))
            var cSenderSessionId: [CChar] = [CChar](repeating: 0, count: 67)
            var maybePlaintext: UnsafeMutablePointer<UInt8>? = nil
            var plaintextLen: Int = 0

            guard !cEd25519SecretKey.isEmpty else { throw MessageSenderError.noUserED25519KeyPair }
            guard
                cEd25519SecretKey.count == 64,
                cServerPublicKey.count == 32,
                session_decrypt_for_blinded_recipient(
                    &cCiphertext,
                    cCiphertext.count,
                    &cEd25519SecretKey,
                    &cServerPublicKey,
                    &cSenderId,
                    &cRecipientId,
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
}
