// Copyright © 2024 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import CryptoKit
import CommonCrypto
import SessionUtil
import SessionNetworkingKit
import SessionUtilitiesKit

// MARK: - Encryption

public extension Crypto {
    enum AttachmentDomain: Sendable, Equatable, Hashable {
        case attachment
        case profilePicture
        
        fileprivate var libSessionValue: ATTACHMENT_DOMAIN {
            switch self {
                case .attachment: return ATTACHMENT_DOMAIN_ATTACHMENT
                case .profilePicture: return ATTACHMENT_DOMAIN_PROFILE_PIC
            }
        }
    }
}

public extension Crypto.Generator {
    private static var hmac256KeyLength: Int { 32 }
    private static var hmac256OutputLength: Int { 32 }
    private static var aesCBCIvLength: Int { 16 }
    private static var aesKeySize: Int { 32 }
    
    static func expectedEncryptedAttachmentSize(plaintext: Data) -> Crypto.Generator<Int> {
        return Crypto.Generator(
            id: "expectedEncryptedAttachmentSize",
            args: [plaintext]
        ) { dependencies in
            return session_attachment_encrypted_size(plaintext.count)
        }
    }
    
    static func encryptAttachment(
        plaintext: Data,
        domain: Crypto.AttachmentDomain
    ) -> Crypto.Generator<(ciphertext: Data, encryptionKey: Data)> {
        return Crypto.Generator(
            id: "encryptAttachment",
            args: [plaintext]
        ) { dependencies in
            guard !dependencies[cache: .general].ed25519Seed.isEmpty else {
                Log.error(.crypto, "Invalid seed.")
                throw CryptoError.encryptionFailed
            }
            
            let cPlaintext: [UInt8] = Array(plaintext)
            let encryptedSize: Int = session_attachment_encrypted_size(cPlaintext.count)
            var cEncryptionKey: [UInt8] = [UInt8](repeating: 0, count: 32)
            var cEncryptedData: [UInt8] = [UInt8](repeating: 0, count: encryptedSize)
            var cError: [CChar] = [CChar](repeating: 0, count: 256)
            
            guard
                session_attachment_encrypt(
                    dependencies[cache: .general].ed25519Seed,
                    cPlaintext,
                    cPlaintext.count,
                    domain.libSessionValue,
                    &cEncryptionKey,
                    &cEncryptedData,
                    &cError
                )
            else {
                Log.error(.crypto, "Attachment encryption failed due to error: \(String(cString: cError))")
                throw CryptoError.encryptionFailed
            }
            
            return (Data(cEncryptedData), Data(cEncryptionKey))
        }
    }
    
    @available(*, deprecated, message: "This encryption method is deprecated and will be removed in a future release.")
    static func legacyEncryptedAttachment(
        plaintext: Data
    ) -> Crypto.Generator<(ciphertext: Data, encryptionKey: Data, digest: Data)> {
        return Crypto.Generator(
            id: "legacyEncryptedAttachment",
            args: [plaintext]
        ) { dependencies in
            // Due to paddedSize, we need to divide by two.
            guard
                plaintext.count < (UInt.max / 2),
                var iv: [UInt8] = dependencies[singleton: .crypto].generate(.randomBytes(aesCBCIvLength)),
                var encryptionKey: [UInt8] = dependencies[singleton: .crypto].generate(.randomBytes(aesKeySize)),
                var hmacKey: [UInt8] = dependencies[singleton: .crypto].generate(.randomBytes(hmac256KeyLength))
            else { throw AttachmentError.legacyEncryptionFailed }

            // The concatenated key for storage
            var outKey: Data = Data()
            outKey.append(Data(encryptionKey))
            outKey.append(Data(hmacKey))

            // Apply any padding
            let desiredSize: Int = max(541, min(Int(Network.maxFileSize), Int(floor(pow(1.05, ceil(log(Double(plaintext.count)) / log(1.05)))))))
            var paddedAttachmentData: [UInt8] = Array(plaintext)
            if desiredSize > plaintext.count {
                paddedAttachmentData.append(contentsOf: [UInt8](repeating: 0, count: desiredSize - plaintext.count))
            }
            
            var numBytesEncrypted: size_t = 0
            var bufferData: [UInt8] = Array(Data(count: paddedAttachmentData.count + kCCBlockSizeAES128))
            let cryptStatus: CCCryptorStatus = CCCrypt(
                CCOperation(kCCEncrypt),
                CCAlgorithm(kCCAlgorithmAES128),
                CCOptions(kCCOptionPKCS7Padding),
                &encryptionKey, encryptionKey.count,
                &iv,
                &paddedAttachmentData, paddedAttachmentData.count,
                &bufferData, bufferData.count,
                &numBytesEncrypted
            )

            guard
                cryptStatus == kCCSuccess,
                bufferData.count >= numBytesEncrypted
            else { throw AttachmentError.legacyEncryptionFailed }
            
            let ciphertext: [UInt8] = Array(bufferData[0..<numBytesEncrypted])
            var encryptedPaddedData: [UInt8] = (iv + ciphertext)

            // compute hmac of: iv || encrypted data
            guard
                encryptedPaddedData.count < (UInt.max / 2),
                hmacKey.count < (UInt.max / 2)
            else { throw AttachmentError.legacyEncryptionFailed }
            
            var hmacDataBuffer: [UInt8] = Array(Data(count: Int(CC_SHA256_DIGEST_LENGTH)))
            CCHmac(
                CCHmacAlgorithm(kCCHmacAlgSHA256),
                &hmacKey,
                hmacKey.count,
                &encryptedPaddedData,
                encryptedPaddedData.count,
                &hmacDataBuffer
            )
            let hmac: [UInt8] = Array(hmacDataBuffer[0..<hmac256OutputLength])
            encryptedPaddedData.append(contentsOf: hmac)

            // compute digest of: iv || encrypted data || hmac
            guard encryptedPaddedData.count < UInt32.max else {
                throw AttachmentError.legacyEncryptionFailed
            }
            
            var digest: [UInt8] = Array(Data(count: Int(CC_SHA256_DIGEST_LENGTH)))
            CC_SHA256(&encryptedPaddedData, UInt32(encryptedPaddedData.count), &digest)
            
            return (Data(encryptedPaddedData), outKey, Data(digest))
        }
    }

    @available(*, deprecated, message: "This encryption method is deprecated and will be removed in a future release.")
    static func legacyEncryptedDisplayPicture(
        data: Data,
        key: Data
    ) -> Crypto.Generator<Data> {
        return Crypto.Generator(
            id: "legacyEncryptedDisplayPicture",
            args: [data, key]
        ) { dependencies in
            // The key structure is: nonce || ciphertext || authTag
            guard
                key.count == DisplayPictureManager.encryptionKeySize,
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
}

// MARK: - Decryption

public extension Crypto.Generator {
    static func decryptAttachment(
        ciphertext: Data,
        key: Data
    ) -> Crypto.Generator<Data> {
        return Crypto.Generator(
            id: "decryptAttachment",
            args: [ciphertext, key]
        ) { dependencies in
            let cCiphertext: [UInt8] = Array(ciphertext)
            let expectedDecryptedSize: Int = session_attachment_decrypted_max_size(cCiphertext.count)
            let cDecryptionKey: [UInt8] = Array(key)
            var cDecryptedData: [UInt8] = [UInt8](repeating: 0, count: expectedDecryptedSize)
            var cDecryptedSize: Int = 0
            var cError: [CChar] = [CChar](repeating: 0, count: 256)
            
            guard
                session_attachment_decrypt(
                    cCiphertext,
                    cCiphertext.count,
                    cDecryptionKey,
                    &cDecryptedData,
                    &cDecryptedSize,
                    &cError
                )
            else {
                Log.error(.crypto, "Attachment decryption failed due to error: \(String(cString: cError))")
                throw CryptoError.decryptionFailed
            }
            
            return Data(cDecryptedData)
        }
    }
    
    static func legacyDecryptAttachment(
        ciphertext: Data,
        key: Data,
        digest: Data,
        unpaddedSize: UInt
    ) -> Crypto.Generator<Data> {
        return Crypto.Generator(
            id: "legacyDecryptAttachment",
            args: [ciphertext, key, digest, unpaddedSize]
        ) {
            guard ciphertext.count >= aesCBCIvLength + hmac256OutputLength else {
                throw AttachmentError.legacyDecryptionFailed
            }
            
            // key: 32 byte AES key || 32 byte Hmac-SHA256 key.
            var encryptionKey: [UInt8] = Array(key[0..<aesKeySize])
            var hmacKey: [UInt8] = Array(key[aesKeySize...])
            
            // ciphertext: IV || Ciphertext || truncated MAC(IV||Ciphertext)
            var iv: [UInt8] = Array(ciphertext[0..<aesCBCIvLength])
            var encryptedAttachment: [UInt8] = Array(ciphertext[aesCBCIvLength..<ciphertext.count - hmac256OutputLength])
            let hmac: [UInt8] = Array(ciphertext[(ciphertext.count - hmac256OutputLength)...])
            
            // Verify hmac of: iv || encrypted data
            var dataToAuth: [UInt8] = (iv + encryptedAttachment)
            var hmacDataBuffer: [UInt8] = Array(Data(count: Int(CC_SHA256_DIGEST_LENGTH)))
            CCHmac(
                CCHmacAlgorithm(kCCHmacAlgSHA256),
                &hmacKey,
                hmacKey.count,
                &dataToAuth,
                dataToAuth.count,
                &hmacDataBuffer
            )
            let generatedHmac: [UInt8] = Array(hmacDataBuffer[0..<hmac256OutputLength])
            let isHmacEqual: Bool = {
                guard hmac.count == generatedHmac.count else { return false }
                
                var isEqual: UInt8 = 0
                (0..<hmac.count).forEach { index in
                    // Rather than returning as soon as we find a discrepency, we compare the rest of
                    // the byte stream to maintain a constant time comparison
                    isEqual |= hmac[index] ^ generatedHmac[index]
                }
                
                return (isEqual == 0)
            }()
            
            guard isHmacEqual else { throw AttachmentError.legacyDecryptionFailed }
            
            // Verify digest of: iv || encrypted data || hmac
            dataToAuth += generatedHmac
            var generatedDigest: [UInt8] = Array(Data(count: Int(CC_SHA256_DIGEST_LENGTH)))
            CC_SHA256(&dataToAuth, UInt32(dataToAuth.count), &generatedDigest)
            let isDigestEqual: Bool = {
                guard digest.count == generatedDigest.count else { return false }
                
                var isEqual: UInt8 = 0
                (0..<digest.count).forEach { index in
                    // Rather than returning as soon as we find a discrepency, we compare the rest of
                    // the byte stream to maintain a constant time comparison
                    isEqual |= digest[index] ^ generatedDigest[index]
                }
                
                return (isEqual == 0)
            }()
            
            guard isDigestEqual else { throw AttachmentError.legacyDecryptionFailed }
            
            var numBytesDecrypted: size_t = 0
            var bufferData: [UInt8] = Array(Data(count: ciphertext.count + kCCBlockSizeAES128))
            let cryptStatus: CCCryptorStatus = CCCrypt(
                CCOperation(kCCDecrypt),
                CCAlgorithm(kCCAlgorithmAES128),
                CCOptions(kCCOptionPKCS7Padding),
                &encryptionKey, encryptionKey.count,
                &iv,
                &encryptedAttachment, encryptedAttachment.count,
                &bufferData, bufferData.count,
                &numBytesDecrypted
            )
            
            guard
                cryptStatus == kCCSuccess,
                bufferData.count >= numBytesDecrypted
            else { throw AttachmentError.legacyDecryptionFailed }
            
            let paddedPlaintext: [UInt8] = Array(bufferData[0..<numBytesDecrypted])
            
            // Legacy iOS clients didn't set the unpaddedSize on attachments.
            // So an unpaddedSize of 0 could mean one of two things:
            // [case 1] receiving a legacy attachment from before padding was introduced
            // [case 2] receiving a modern attachment of length 0 that just has some null padding (e.g. an empty group sync)
            guard unpaddedSize > 0 else {
                guard paddedPlaintext.contains(where: { $0 != 0x00 }) else {
                    // [case 2] The bytes were all 0's. We assume it was all padding and the actual
                    // attachment data was indeed empty. The downside here would be if a legacy client
                    // was intentionally sending an attachment consisting of just 0's. This seems unlikely,
                    // and would only affect iOS clients from before commit:
                    //
                    //      6eeb78157a044e632adc3daf6254aceacd53e335
                    //      Author: Michael Kirk <michael.code@endoftheworl.de>
                    //      Date:   Thu Oct 26 15:08:25 2017 -0700
                    //
                    //      Include size in attachment pointer
                    return Data()
                }
                
                // [case 1] There was something besides 0 in our data, assume it wasn't padding.
                return Data(paddedPlaintext)
            }
            
            guard unpaddedSize <= paddedPlaintext.count else {
                throw AttachmentError.legacyDecryptionFailed
            }
            
            // If the `paddedPlaintext` is the same length as the `unpaddedSize` then just return it
            guard unpaddedSize != paddedPlaintext.count else { return Data(paddedPlaintext) }
            
            return Data(paddedPlaintext[0..<Int(unpaddedSize)])
        }
    }
    
    static func legacyDecryptedDisplayPicture(
        data: Data,
        key: Data
    ) -> Crypto.Generator<Data> {
        return Crypto.Generator(
            id: "legacyDecryptedDisplayPicture",
            args: [data, key]
        ) { dependencies in
            guard key.count == DisplayPictureManager.encryptionKeySize else {
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
