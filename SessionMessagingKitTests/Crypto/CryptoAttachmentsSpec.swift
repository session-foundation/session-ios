// Copyright © 2026 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtilitiesKit
import TestUtilities

import Quick
import Nimble

@testable import SessionMessagingKit

/// Content encrypted the legacy way stays on the file server indefinitely, so both legacy formats have
/// to keep decrypting long after nothing writes them. The legacy vectors here were produced externally
/// rather than by a round trip, so they still describe the wire format now that the encrypting half is
/// gone.
class CryptoAttachmentsSpec: AsyncSpec {
    override class func spec() {
        @TestState var dependencies: TestDependencies! = TestDependencies()
        @TestState var crypto: Crypto! = Crypto(using: dependencies)
        @TestState var mockGeneralCache: MockGeneralCache! = .create(using: dependencies)
        
        beforeEach {
            dependencies.set(singleton: .crypto, to: crypto)
            dependencies.set(cache: .general, to: mockGeneralCache)
            try await mockGeneralCache.defaultInitialSetup()
        }
        
        /// 32-byte AES key ‖ 32-byte HMAC key
        let legacyAttachmentKey: Data = Data(
            hex: String(repeating: "11", count: 32) + String(repeating: "22", count: 32)
        )
        /// IV ‖ AES-256-CBC(PKCS7) ‖ HMAC-SHA256(IV ‖ ciphertext), over a 541-byte zero-padded plaintext
        let legacyAttachmentCiphertext: Data = Data(hex: [
            "333333333333333333333333333333330ee1ed4f89c70232caed52b8765365ff",
            "e904557d3c61038c97bdb5bee3189fc6f53aac97422dc92d8693c0a72b3aa362",
            "01d1bd3a6dd6164a09154ae87aa95888066a80449e211fc64a69c04b0f9ddce0",
            "2f144fbea3a731ded616d0436b2fd6ec908f89ebf85d15bad69bdaa66827f0b3",
            "484b7425d383f7136e3c911881731c043863f49f5ada6f85f8fa456efd08a2db",
            "8c7b510cb04a225035db36e21660f5274939dc09639ffd30cc36ac9fc8776761",
            "5a93ab017c028a8bdf2dd7ef48c245b846c7cd4942866d77b056a2a59924d426",
            "4d1e1d23b8c5ed598f23ada8a905c5579383581203db2c5f60c434551992162f",
            "b9f36105a91515c5472105c64f3c111a16c745bbca3e810460319b3124c430ca",
            "3d87f4fd9400502cd62d7e782ee5eebf4656f4acd84a9ae964e0f40804dea71d",
            "675eb620a2659094b52a3bdf9b36c8ac66ffcbbb129749e5394eabf4b8708249",
            "12cf7966797621b0ca073baf66d500d5589649b89d5298855471178c724907d2",
            "5e5812ea7cbf4d9fdf19319eeba03b491cf2857a388ef861ea11e83876d43751",
            "fbbc80aaf205e5d937e9dcc046f9aaf3ee56b6a627a5a474e1ac5cde5a12e52a",
            "fd23fcdadeb591aa06f374bd84edf8a5d61151df711ed8fbded86f0b23c28ef4",
            "414b99d422c4bf95f30f1f18b274c42d9e61a48f63a754d100c7bf64fc88f469",
            "407560f167919c9d5f10d5a343dff87e753ab281e57073fce95481d2b8c4da0e",
            "5f0d13c67d802c1733c232e3d520f38a4f9d5a43c6ce60843288322b883d7d24",
            "796efd75c676cb02a5b6148ea737534d"
        ].joined())
        let legacyAttachmentDigest: Data = Data(
            hex: "ee65e6417b452d017a4d8e2ce984883c1f7dc8d920d7551f0e2d2af7606bd9a9"
        )
        let legacyAttachmentPlaintext: Data = "legacy attachment payload".data(using: .utf8)!
        
        /// nonce ‖ AES-GCM ciphertext ‖ tag
        let legacyDisplayPictureKey: Data = Data(hex: String(repeating: "44", count: 32))
        let legacyDisplayPictureCiphertext: Data = Data(
            hex: "5555555555555555555555554478a06908c0ab29f4a320e4eb849d7b895486cb" +
                 "6f84114414cc1ae0a9b6c0226544ba88d842ee49bc6de829c8c1"
        )
        let legacyDisplayPicturePlaintext: Data = "legacy display picture payload".data(using: .utf8)!
        
        // MARK: - Attachment Crypto
        describe("Attachment Crypto") {
            // MARK: -- when decrypting legacy attachments
            context("when decrypting legacy attachments") {
                // MARK: ---- strips the sender's padding using the unpadded size
                it("strips the sender's padding using the unpadded size") {
                    let result: Data = try crypto.tryGenerate(
                        .legacyDecryptAttachment(
                            ciphertext: legacyAttachmentCiphertext,
                            key: legacyAttachmentKey,
                            digest: legacyAttachmentDigest,
                            unpaddedSize: UInt(legacyAttachmentPlaintext.count)
                        )
                    )
                    
                    expect(result).to(equal(legacyAttachmentPlaintext))
                }
                
                // MARK: ---- keeps the padding when no unpadded size is known
                it("keeps the padding when no unpadded size is known") {
                    /// Clients from before the size was on the pointer sent `0`, and the padding is
                    /// indistinguishable from content at that point, so it has to be kept
                    let result: Data = try crypto.tryGenerate(
                        .legacyDecryptAttachment(
                            ciphertext: legacyAttachmentCiphertext,
                            key: legacyAttachmentKey,
                            digest: legacyAttachmentDigest,
                            unpaddedSize: 0
                        )
                    )
                    
                    expect(result.count).to(equal(541))
                    expect(result.prefix(legacyAttachmentPlaintext.count)).to(equal(legacyAttachmentPlaintext))
                }
                
                // MARK: ---- fails on a tampered ciphertext
                it("fails on a tampered ciphertext") {
                    var tampered: Data = legacyAttachmentCiphertext
                    tampered[20] = tampered[20] &+ 1
                    
                    expect {
                        try crypto.tryGenerate(
                            .legacyDecryptAttachment(
                                ciphertext: tampered,
                                key: legacyAttachmentKey,
                                digest: legacyAttachmentDigest,
                                unpaddedSize: UInt(legacyAttachmentPlaintext.count)
                            )
                        )
                    }.to(throwError(AttachmentError.legacyDecryptionFailed))
                }
                
                // MARK: ---- fails on a mismatched digest
                it("fails on a mismatched digest") {
                    expect {
                        try crypto.tryGenerate(
                            .legacyDecryptAttachment(
                                ciphertext: legacyAttachmentCiphertext,
                                key: legacyAttachmentKey,
                                digest: Data(hex: String(repeating: "00", count: 32)),
                                unpaddedSize: UInt(legacyAttachmentPlaintext.count)
                            )
                        )
                    }.to(throwError(AttachmentError.legacyDecryptionFailed))
                }
            }
            
            // MARK: -- when decrypting legacy display pictures
            context("when decrypting legacy display pictures") {
                // MARK: ---- returns the original data
                it("returns the original data") {
                    let result: Data = try crypto.tryGenerate(
                        .legacyDecryptedDisplayPicture(
                            data: legacyDisplayPictureCiphertext,
                            key: legacyDisplayPictureKey
                        )
                    )
                    
                    expect(result).to(equal(legacyDisplayPicturePlaintext))
                }
                
                // MARK: ---- fails with the wrong key
                it("fails with the wrong key") {
                    expect {
                        try crypto.tryGenerate(
                            .legacyDecryptedDisplayPicture(
                                data: legacyDisplayPictureCiphertext,
                                key: Data(hex: String(repeating: "45", count: 32))
                            )
                        )
                    }.to(throwError(CryptoError.failedToGenerateOutput))
                }
            }
            
            // MARK: -- when choosing a decryption format
            context("when choosing a decryption format") {
                // MARK: ---- picks legacy for a key and digest with no stream fragment
                it("picks legacy for a key and digest with no stream fragment") {
                    expect(
                        try AttachmentDownloadJob.decryptionFormat(
                            encryptionKey: legacyAttachmentKey,
                            digest: legacyAttachmentDigest,
                            wantsStreamDecryption: false
                        )
                    ).to(equal(.legacy(key: legacyAttachmentKey, digest: legacyAttachmentDigest)))
                }
                
                // MARK: ---- picks stream when the url says so, with or without a digest
                it("picks stream when the url says so, with or without a digest") {
                    let key: Data = Data(hex: String(repeating: "66", count: 32))
                    
                    expect(
                        try AttachmentDownloadJob.decryptionFormat(
                            encryptionKey: key,
                            digest: nil,
                            wantsStreamDecryption: true
                        )
                    ).to(equal(.stream(key: key)))
                    
                    /// A digest is meaningless for this format, but older senders left an empty one on
                    /// the pointer so it must not change the decision
                    expect(
                        try AttachmentDownloadJob.decryptionFormat(
                            encryptionKey: key,
                            digest: Data(),
                            wantsStreamDecryption: true
                        )
                    ).to(equal(.stream(key: key)))
                }
                
                // MARK: ---- picks plaintext when there is no key
                it("picks plaintext when there is no key") {
                    expect(
                        try AttachmentDownloadJob.decryptionFormat(
                            encryptionKey: nil,
                            digest: nil,
                            wantsStreamDecryption: false
                        )
                    ).to(equal(.plaintext))
                    
                    /// Community attachments come through with an empty key rather than a missing one
                    expect(
                        try AttachmentDownloadJob.decryptionFormat(
                            encryptionKey: Data(),
                            digest: nil,
                            wantsStreamDecryption: false
                        )
                    ).to(equal(.plaintext))
                }
                
                // MARK: ---- throws for a key it cannot pair with a format
                it("throws for a key it cannot pair with a format") {
                    /// This is what a url whose stream fragment we failed to recognise looks like, and
                    /// storing it as plaintext would save the ciphertext and report success
                    expect {
                        try AttachmentDownloadJob.decryptionFormat(
                            encryptionKey: Data(hex: String(repeating: "66", count: 32)),
                            digest: nil,
                            wantsStreamDecryption: false
                        )
                    }.to(throwError(AttachmentDownloadJob.AttachmentDownloadError.unknownEncryptionFormat))
                }
            }
            
            // MARK: -- when using stream encryption
            context("when using stream encryption") {
                // MARK: ---- round trips an attachment
                it("round trips an attachment") {
                    let plaintext: Data = "stream attachment payload".data(using: .utf8)!
                    let encrypted = try crypto.tryGenerate(
                        .encryptAttachment(plaintext: plaintext, domain: .attachment)
                    )
                    
                    expect(encrypted.ciphertext.first).to(equal(0x53))     /// the 'S' identifier
                    expect(encrypted.encryptionKey.count).to(equal(32))
                    expect(encrypted.ciphertext.count).to(equal(
                        try crypto.tryGenerate(.expectedEncryptedAttachmentSize(plaintextSize: plaintext.count))
                    ))
                    
                    let decrypted: Data = try crypto.tryGenerate(
                        .decryptAttachment(ciphertext: encrypted.ciphertext, key: encrypted.encryptionKey)
                    )
                    
                    expect(decrypted).to(equal(plaintext))
                }
                
                // MARK: ---- gives an attachment and a display picture unrelated keys
                it("gives an attachment and a display picture unrelated keys") {
                    /// The domain is the blake2b key, so identical bytes from one sender must not
                    /// produce related ciphertext across the two uses
                    let plaintext: Data = "the same bytes, two domains".data(using: .utf8)!
                    let asAttachment = try crypto.tryGenerate(
                        .encryptAttachment(plaintext: plaintext, domain: .attachment)
                    )
                    let asDisplayPicture = try crypto.tryGenerate(
                        .encryptAttachment(plaintext: plaintext, domain: .profilePicture)
                    )
                    
                    expect(asAttachment.encryptionKey).toNot(equal(asDisplayPicture.encryptionKey))
                    expect(asAttachment.ciphertext).toNot(equal(asDisplayPicture.ciphertext))
                    
                    expect {
                        try crypto.tryGenerate(
                            .decryptAttachment(
                                ciphertext: asAttachment.ciphertext,
                                key: asDisplayPicture.encryptionKey
                            )
                        )
                    }.to(throwError(CryptoError.decryptionFailed))
                }
                
                // MARK: ---- produces the same ciphertext for the same content
                it("produces the same ciphertext for the same content") {
                    /// Deduplication on the file server depends on this, and it is the reason display
                    /// pictures can be re-uploaded without changing their URL
                    let plaintext: Data = "repeatable".data(using: .utf8)!
                    let first = try crypto.tryGenerate(
                        .encryptAttachment(plaintext: plaintext, domain: .profilePicture)
                    )
                    let second = try crypto.tryGenerate(
                        .encryptAttachment(plaintext: plaintext, domain: .profilePicture)
                    )
                    
                    expect(first.ciphertext).to(equal(second.ciphertext))
                    expect(first.encryptionKey).to(equal(second.encryptionKey))
                }
            }
        }
    }
}
