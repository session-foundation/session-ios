// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import CryptoKit
import Sodium
import Clibsodium
import SessionUtilitiesKit

// MARK: - Generic Hash

public extension Crypto.Generator {
    static func hash(message: Bytes, outputLength: Int) -> Crypto.Generator<[UInt8]> {
        return Crypto.Generator(id: "hashOutputLength", args: [message, outputLength]) { sodium in
            sodium.genericHash.hash(message: message, outputLength: outputLength)
        }
    }
    
    static func hashSaltPersonal(
        message: Bytes,
        outputLength: Int,
        key: Bytes? = nil,
        salt: Bytes,
        personal: Bytes
    ) -> Crypto.Generator<[UInt8]> {
        return Crypto.Generator(
            id: "hashSaltPersonal",
            args: [message, outputLength, key, salt, personal]
        ) {
            var output: [UInt8] = [UInt8](repeating: 0, count: outputLength)

            let result = crypto_generichash_blake2b_salt_personal(
                &output,
                outputLength,
                message,
                UInt64(message.count),
                key,
                (key?.count ?? 0),
                salt,
                personal
            )

            guard result == 0 else { throw CryptoError.failedToGenerateOutput }

            return output
        }
    }
}

// MARK: - Box

public extension Crypto.Size {
    static let signature: Crypto.Size = Crypto.Size(id: "signature") { $0.sign.Bytes }
}

public extension Crypto.Generator {
    static func sealedBytes(message: Bytes, recipientPublicKey: Bytes) -> Crypto.Generator<[UInt8]> {
        return Crypto.Generator(id: "sealedBytes", args: [message, recipientPublicKey]) { sodium in
            sodium.box.seal(message: message, recipientPublicKey: recipientPublicKey)
        }
    }
    
    static func openedBytes(anonymousCipherText: Bytes, recipientPublicKey: Bytes, recipientSecretKey: Bytes) -> Crypto.Generator<[UInt8]> {
        return Crypto.Generator(
            id: "openedBytes",
            args: [anonymousCipherText, recipientPublicKey, recipientSecretKey]
        ) { sodium in
            sodium.box.open(
                anonymousCipherText: anonymousCipherText,
                recipientPublicKey: recipientPublicKey,
                recipientSecretKey: recipientSecretKey
            )
        }
    }
}

// MARK: - AeadXChaCha20Poly1305Ietf

public extension Crypto.Size {
    static let aeadXChaCha20NonceBytes: Crypto.Size = Crypto.Size(id: "aeadXChaCha20NonceBytes") { sodium in
        sodium.aead.xchacha20poly1305ietf.NonceBytes
    }
}

// MARK: - DisplayPicture

public extension Crypto.Generator {
    static func encryptedDataDisplayPicture(
        data: Data,
        key: Data,
        using dependencies: Dependencies
    ) -> Crypto.Generator<Data> {
        return Crypto.Generator(id: "encryptedDataDisplayPicture", args: [data, key]) {
            // The key structure is: nonce || ciphertext || authTag
            guard
                key.count == DisplayPictureManager.aes256KeyByteLength,
                let nonceData: Data = dependencies[singleton: .crypto]
                    .generate(.randomBytes(numberBytes: DisplayPictureManager.nonceLength)),
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
        key: Data,
        using dependencies: Dependencies
    ) -> Crypto.Generator<Data> {
        return Crypto.Generator(id: "decryptedDataDisplayPicture", args: [data, key]) {
            guard key.count == DisplayPictureManager.aes256KeyByteLength else { throw CryptoError.failedToGenerateOutput }
            
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
