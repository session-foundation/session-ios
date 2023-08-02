// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Sodium
import SessionUtilitiesKit

import Quick
import Nimble

@testable import SessionMessagingKit

class CryptoSMKSpec: QuickSpec {
    // MARK: - Spec

    override func spec() {
        var crypto: Crypto!
        var mockCrypto: MockCrypto!
        var dependencies: Dependencies!
        
        beforeEach {
            crypto = Crypto()
            mockCrypto = MockCrypto()
            dependencies = Dependencies(crypto: crypto)
        }
        
        describe("Crypto for SessionMessagingKit") {
            
            // MARK: - when extending Sign
            context("when extending Sign") {
                // MARK: -- can convert an ed25519 public key into an x25519 public key
                it("can convert an ed25519 public key into an x25519 public key") {
                    let result = try? crypto.perform(.toX25519(ed25519PublicKey: TestConstants.edPublicKey.bytes))
                    
                    expect(result?.toHexString())
                        .to(equal("95ffb559d4e804e9b414a5178454c426f616b4a61089b217b41165dbb7c9fe2d"))
                }
                
                // MARK: -- can convert an ed25519 private key into an x25519 private key
                it("can convert an ed25519 private key into an x25519 private key") {
                    let result = try? crypto.perform(.toX25519(ed25519SecretKey: TestConstants.edSecretKey.bytes))
                    
                    expect(result?.toHexString())
                        .to(equal("c83f9a1479b103c275d2db2d6c199fdc6f589b29b742f6405e01cc5a9a1d135d"))
                }
            }
            
            // MARK: - when extending Sodium
            context("when extending Sodium") {
                // MARK: -- and generating a blinding factor
                context("and generating a blinding factor") {
                    // MARK: --- successfully generates a blinding factor
                    it("successfully generates a blinding factor") {
                        let result = try? crypto.perform(
                            .generateBlindingFactor(
                                serverPublicKey: TestConstants.serverPublicKey,
                                using: dependencies
                            )
                        )
                        
                        expect(result?.toHexString())
                            .to(equal("84e3eb75028a9b73fec031b7448e322a68ca6485fad81ab1bead56f759ebeb0f"))
                    }
                    
                    // MARK: --- fails if the serverPublicKey is not a hex string
                    it("fails if the serverPublicKey is not a hex string") {
                        let result = try? crypto.perform(
                            .generateBlindingFactor(
                                serverPublicKey: "Test",
                                using: dependencies
                            )
                        )
                        
                        expect(result).to(beNil())
                    }
                    
                    // MARK: --- fails if it cannot hash the serverPublicKey bytes
                    it("fails if it cannot hash the serverPublicKey bytes") {
                        dependencies = Dependencies(crypto: mockCrypto)
                        mockCrypto
                            .when { try $0.perform(.hash(message: anyArray(), outputLength: any())) }
                            .thenReturn(nil)
                        
                        let result = try? crypto.perform(
                            .generateBlindingFactor(
                                serverPublicKey: TestConstants.serverPublicKey,
                                using: dependencies
                            )
                        )
                        
                        expect(result).to(beNil())
                    }
                }
                
                // MARK: -- and generating a blinded key pair
                context("and generating a blinded key pair") {
                    // MARK: --- successfully generates a blinded key pair
                    it("successfully generates a blinded key pair") {
                        let result = crypto.generate(
                            .blindedKeyPair(
                                serverPublicKey: TestConstants.serverPublicKey,
                                edKeyPair: KeyPair(
                                    publicKey: Data(hex: TestConstants.edPublicKey).bytes,
                                    secretKey: Data(hex: TestConstants.edSecretKey).bytes
                                ),
                                using: dependencies
                            )
                        )
                        
                        // Note: The first 64 characters of the secretKey are consistent but the chars after that always differ
                        expect(result?.publicKey.toHexString()).to(equal(TestConstants.blindedPublicKey))
                        expect(String(result?.secretKey.toHexString().prefix(64) ?? ""))
                            .to(equal("16663322d6b684e1c9dcc02b9e8642c3affd3bc431a9ea9e63dbbac88ce7a305"))
                    }
                    
                    // MARK: --- fails if the edKeyPair public key length wrong
                    it("fails if the edKeyPair public key length wrong") {
                        let result = crypto.generate(
                            .blindedKeyPair(
                                serverPublicKey: TestConstants.serverPublicKey,
                                edKeyPair: KeyPair(
                                    publicKey: Data(hex: String(TestConstants.edPublicKey.prefix(4))).bytes,
                                    secretKey: Data(hex: TestConstants.edSecretKey).bytes
                                ),
                                using: dependencies
                            )
                        )
                        
                        expect(result).to(beNil())
                    }
                    
                    // MARK: --- fails if the edKeyPair secret key length wrong
                    it("fails if the edKeyPair secret key length wrong") {
                        let result = crypto.generate(
                            .blindedKeyPair(
                                serverPublicKey: TestConstants.serverPublicKey,
                                edKeyPair: KeyPair(
                                    publicKey: Data(hex: TestConstants.edPublicKey).bytes,
                                    secretKey: Data(hex: String(TestConstants.edSecretKey.prefix(4))).bytes
                                ),
                                using: dependencies
                            )
                        )
                        
                        expect(result).to(beNil())
                    }
                    
                    // MARK: --- fails if it cannot generate a blinding factor
                    it("fails if it cannot generate a blinding factor") {
                        let result = crypto.generate(
                            .blindedKeyPair(
                                serverPublicKey: "Test",
                                edKeyPair: KeyPair(
                                    publicKey: Data(hex: TestConstants.edPublicKey).bytes,
                                    secretKey: Data(hex: TestConstants.edSecretKey).bytes
                                ),
                                using: dependencies
                            )
                        )
                        
                        expect(result).to(beNil())
                    }
                }
                
                // MARK: -- and generating a sogsSignature
                context("and generating a sogsSignature") {
                    // MARK: --- generates a correct signature
                    it("generates a correct signature") {
                        let result = try? crypto.perform(
                            .sogsSignature(
                                message: "TestMessage".bytes,
                                secretKey: Data(hex: TestConstants.edSecretKey).bytes,
                                blindedSecretKey: Data(hex: "44d82cc15c0a5056825cae7520b6b52d000a23eb0c5ed94c4be2d9dc41d2d409").bytes,
                                blindedPublicKey: Data(hex: "0bb7815abb6ba5142865895f3e5286c0527ba4d31dbb75c53ce95e91ffe025a2").bytes
                            )
                        )
                        
                        expect(result?.toHexString())
                            .to(equal(
                                "dcc086abdd2a740d9260b008fb37e12aa0ff47bd2bd9e177bbbec37fd46705a9" +
                                "072ce747bda66c788c3775cdd7ad60ad15a478e0886779aad5d795fd7bf8350d"
                            ))
                    }
                }
                
                // MARK: -- and combining keys
                context("and combining keys") {
                    // MARK: --- generates a correct combined key
                    it("generates a correct combined key") {
                        let result = try? crypto.perform(
                            .combineKeys(
                                lhsKeyBytes: Data(hex: TestConstants.edSecretKey).bytes,
                                rhsKeyBytes: Data(hex: TestConstants.edPublicKey).bytes
                            )
                        )
                        
                        expect(result?.toHexString())
                            .to(equal("1159b5d0fcfba21228eb2121a0f59712fa8276fc6e5547ff519685a40b9819e6"))
                    }
                }
                
                // MARK: -- and creating a shared blinded encryption key
                context("and creating a shared blinded encryption key") {
                    // MARK: --- generates a correct combined key
                    it("generates a correct combined key") {
                        let result = try? crypto.perform(
                            .sharedBlindedEncryptionKey(
                                secretKey: Data(hex: TestConstants.edSecretKey).bytes,
                                otherBlindedPublicKey: Data(hex: TestConstants.blindedPublicKey).bytes,
                                fromBlindedPublicKey: Data(hex: TestConstants.publicKey).bytes,
                                toBlindedPublicKey: Data(hex: TestConstants.blindedPublicKey).bytes,
                                using: dependencies
                            )
                        )
                        
                        expect(result?.toHexString())
                            .to(equal("388ee09e4c356b91f1cce5cc0aa0cf59e8e8cade69af61685d09c2d2731bc99e"))
                    }
                    
                    // MARK: --- fails if the scalar multiplication fails
                    it("fails if the scalar multiplication fails") {
                        let result = try? crypto.perform(
                            .sharedBlindedEncryptionKey(
                                secretKey: Data(hex: TestConstants.edSecretKey).bytes,
                                otherBlindedPublicKey: Data(hex: TestConstants.publicKey).bytes,
                                fromBlindedPublicKey: Data(hex: TestConstants.edPublicKey).bytes,
                                toBlindedPublicKey: Data(hex: TestConstants.publicKey).bytes,
                                using: dependencies
                            )
                        )
                        
                        expect(result?.toHexString()).to(beNil())
                    }
                }
                
                // MARK: -- and checking if a session id matches a blinded id
                context("and checking if a session id matches a blinded id") {
                    // MARK: --- returns true when they match
                    it("returns true when they match") {
                        let result = crypto.verify(
                            .sessionId(
                                "05\(TestConstants.publicKey)",
                                matchesBlindedId: "15\(TestConstants.blindedPublicKey)",
                                serverPublicKey: TestConstants.serverPublicKey,
                                using: dependencies
                            )
                        )
                        
                        expect(result).to(beTrue())
                    }
                    
                    // MARK: --- returns false if given an invalid session id
                    it("returns false if given an invalid session id") {
                        let result = crypto.verify(
                            .sessionId(
                                "AB\(TestConstants.publicKey)",
                                matchesBlindedId: "15\(TestConstants.blindedPublicKey)",
                                serverPublicKey: TestConstants.serverPublicKey,
                                using: dependencies
                            )
                        )
                        
                        expect(result).to(beFalse())
                    }
                    
                    // MARK: --- returns false if given an invalid blinded id
                    it("returns false if given an invalid blinded id") {
                        let result = crypto.verify(
                            .sessionId(
                                "05\(TestConstants.publicKey)",
                                matchesBlindedId: "AB\(TestConstants.blindedPublicKey)",
                                serverPublicKey: TestConstants.serverPublicKey,
                                using: dependencies
                            )
                        )
                        
                        expect(result).to(beFalse())
                    }
                    
                    // MARK: --- returns false if it fails to generate the blinding factor
                    it("returns false if it fails to generate the blinding factor") {
                        let result = crypto.verify(
                            .sessionId(
                                "05\(TestConstants.publicKey)",
                                matchesBlindedId: "15\(TestConstants.blindedPublicKey)",
                                serverPublicKey: "Test",
                                using: dependencies
                            )
                        )
                        
                        expect(result).to(beFalse())
                    }
                }
            }
            
            // MARK: - when extending GenericHash
            describe("when extending GenericHash") {
                // MARK: -- and generating a hash with salt and personal values
                context("and generating a hash with salt and personal values") {
                    // MARK: --- generates a hash correctly
                    it("generates a hash correctly") {
                        let result = try? crypto.perform(
                            .hashSaltPersonal(
                                message: "TestMessage".bytes,
                                outputLength: 32,
                                key: "Key".bytes,
                                salt: "Salt".bytes,
                                personal: "Personal".bytes
                            )
                        )
                        
                        expect(result).toNot(beNil())
                        expect(result?.count).to(equal(32))
                    }
                    
                    // MARK: --- generates a hash correctly with no key
                    it("generates a hash correctly with no key") {
                        let result = try? crypto.perform(
                            .hashSaltPersonal(
                                message: "TestMessage".bytes,
                                outputLength: 32,
                                key: nil,
                                salt: "Salt".bytes,
                                personal: "Personal".bytes
                            )
                        )
                        
                        expect(result).toNot(beNil())
                        expect(result?.count).to(equal(32))
                    }
                    
                    // MARK: --- fails if given invalid options
                    it("fails if given invalid options") {
                        let result = try? crypto.perform(
                            .hashSaltPersonal(
                                message: "TestMessage".bytes,
                                outputLength: 65,   // Max of 64
                                key: "Key".bytes,
                                salt: "Salt".bytes,
                                personal: "Personal".bytes
                            )
                        )
                        
                        expect(result).to(beNil())
                    }
                }
            }
            
            // MARK: - when extending AeadXChaCha20Poly1305Ietf
            context("when extending AeadXChaCha20Poly1305Ietf") {
                // MARK: -- when encrypting
                context("when encrypting") {
                    // MARK: --- encrypts correctly
                    it("encrypts correctly") {
                        let result = try? crypto.perform(
                            .encryptAeadXChaCha20(
                                message: "TestMessage".bytes,
                                secretKey: Data(hex: TestConstants.publicKey).bytes,
                                nonce: "TestNonce".bytes,
                                additionalData: nil,
                                using: Dependencies()
                            )
                        )
                        
                        expect(result).toNot(beNil())
                        expect(result?.count).to(equal(27))
                    }
                    
                    // MARK: --- encrypts correctly with additional data
                    it("encrypts correctly with additional data") {
                        let result = try? crypto.perform(
                            .encryptAeadXChaCha20(
                                message: "TestMessage".bytes,
                                secretKey: Data(hex: TestConstants.publicKey).bytes,
                                nonce: "TestNonce".bytes,
                                additionalData: "TestData".bytes,
                                using: Dependencies()
                            )
                        )
                        
                        expect(result).toNot(beNil())
                        expect(result?.count).to(equal(27))
                    }
                    
                    // MARK: --- fails if given an invalid key
                    it("fails if given an invalid key") {
                        let result = try? crypto.perform(
                            .encryptAeadXChaCha20(
                                message: "TestMessage".bytes,
                                secretKey: "TestKey".bytes,
                                nonce: "TestNonce".bytes,
                                additionalData: "TestData".bytes,
                                using: Dependencies()
                            )
                        )
                        
                        expect(result).to(beNil())
                    }
                }
            }
        }
    }
}
