// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtilitiesKit

import Quick
import Nimble

@testable import SessionNetworkingKit

class CryptoSOGSAPISpec: AsyncSpec {
    override class func spec() {
        // MARK: Configuration
        
        @TestState var dependencies: TestDependencies! = TestDependencies()
        @TestState var crypto: Crypto! = Crypto(using: dependencies)
        @TestState var mockGeneralCache: MockGeneralCache! = .create(using: dependencies)
        
        beforeEach {
            dependencies.set(singleton: .crypto, to: crypto)
            
            try await mockGeneralCache.defaultInitialSetup()
            dependencies.set(cache: .general, to: mockGeneralCache)
        }
        
        // MARK: - Crypto for SOGSAPI
        describe("Crypto for SOGSAPI") {
            // MARK: -- when generating a blinded15 key pair
            context("when generating a blinded15 key pair") {
                // MARK: ---- successfully generates
                it("successfully generates") {
                    let result = crypto.generate(
                        .blinded15KeyPair(
                            serverPublicKey: TestConstants.serverPublicKey,
                            ed25519SecretKey: Data(hex: TestConstants.edSecretKey).bytes
                        )
                    )
                    
                    // Note: The first 64 characters of the secretKey are consistent but the chars after that always differ
                    expect(result?.publicKey.toHexString()).to(equal(TestConstants.blind15PublicKey))
                    expect(result?.secretKey.toHexString()).to(equal(TestConstants.blind15SecretKey))
                }
                
                // MARK: ---- fails if the edKeyPair secret key length wrong
                it("fails if the ed25519SecretKey length wrong") {
                    let result = crypto.generate(
                        .blinded15KeyPair(
                            serverPublicKey: TestConstants.serverPublicKey,
                            ed25519SecretKey: Array(Data(hex: String(TestConstants.edSecretKey.prefix(4))))
                        )
                    )
                    
                    expect(result).to(beNil())
                }
            }
            
            // MARK: -- when generating a blinded25 key pair
            context("when generating a blinded25 key pair") {
                // MARK: ---- successfully generates
                it("successfully generates") {
                    let result = crypto.generate(
                        .blinded25KeyPair(
                            serverPublicKey: TestConstants.serverPublicKey,
                            ed25519SecretKey: Data(hex: TestConstants.edSecretKey).bytes
                        )
                    )
                    
                    // Note: The first 64 characters of the secretKey are consistent but the chars after that always differ
                    expect(result?.publicKey.toHexString()).to(equal(TestConstants.blind25PublicKey))
                    expect(result?.secretKey.toHexString()).to(equal(TestConstants.blind25SecretKey))
                }
                
                // MARK: ---- fails if the edKeyPair secret key length wrong
                it("fails if the ed25519SecretKey length wrong") {
                    let result = crypto.generate(
                        .blinded25KeyPair(
                            serverPublicKey: TestConstants.serverPublicKey,
                            ed25519SecretKey: Data(hex: String(TestConstants.edSecretKey.prefix(4))).bytes
                        )
                    )
                    
                    expect(result).to(beNil())
                }
            }
            
            // MARK: -- when generating a signatureBlind15
            context("when generating a signatureBlind15") {
                // MARK: ---- generates a correct signature
                it("generates a correct signature") {
                    let result = crypto.generate(
                        .signatureBlind15(
                            message: "TestMessage".bytes,
                            serverPublicKey: TestConstants.serverPublicKey,
                            ed25519SecretKey: Array(Data(hex: TestConstants.edSecretKey))
                        )
                    )
                    
                    expect(result?.toHexString())
                        .to(equal(
                            "245003f1627ebdfc6099c32597d426ef84d1b301861a5ffbbac92dde6c608334" +
                            "ceb56a022a094a9a664fae034b50eed40bd1bfb262c7e542c979eec265ae3f07"
                        ))
                }
            }
            
            // MARK: -- when generating a signatureBlind25
            context("when generating a signatureBlind25") {
                // MARK: ---- generates a correct signature
                it("generates a correct signature") {
                    let result = crypto.generate(
                        .signatureBlind25(
                            message: "TestMessage".bytes,
                            serverPublicKey: TestConstants.serverPublicKey,
                            ed25519SecretKey: Data(hex: TestConstants.edSecretKey).bytes
                        )
                    )
                    
                    expect(result?.toHexString())
                        .to(equal(
                            "9ff9b7fb7d435c7a2c0b0b2ae64963baaf394386b9f7c7f924eeac44ec0f74c7" +
                            "fe6304c73a9b3a65491f81e44b545e54631e83e9a412eaed5fd4db2e05ec830c"
                        ))
                }
            }
            
            // MARK: -- when checking if a session id matches a blinded id
            context("when checking if a session id matches a blinded id") {
                // MARK: ---- returns true when a blind15 id matches
                it("returns true when a blind15 id matches") {
                    let result = crypto.verify(
                        .sessionId(
                            "05\(TestConstants.publicKey)",
                            matchesBlindedId: "15\(TestConstants.blind15PublicKey)",
                            serverPublicKey: TestConstants.serverPublicKey
                        )
                    )
                    
                    expect(result).to(beTrue())
                }
                
                // MARK: ---- returns true when a blind25 id matches
                it("returns true when a blind25 id matches") {
                    let result = crypto.verify(
                        .sessionId(
                            "05\(TestConstants.publicKey)",
                            matchesBlindedId: "25\(TestConstants.blind25PublicKey)",
                            serverPublicKey: TestConstants.serverPublicKey
                        )
                    )
                    
                    expect(result).to(beTrue())
                }
                
                // MARK: ---- returns false if given an invalid session id
                it("returns false if given an invalid session id") {
                    let result = crypto.verify(
                        .sessionId(
                            "AB\(TestConstants.publicKey)",
                            matchesBlindedId: "15\(TestConstants.blind15PublicKey)",
                            serverPublicKey: TestConstants.serverPublicKey
                        )
                    )
                    
                    expect(result).to(beFalse())
                }
                
                // MARK: ---- returns false if given an invalid blinded id
                it("returns false if given an invalid blinded id") {
                    let result = crypto.verify(
                        .sessionId(
                            "05\(TestConstants.publicKey)",
                            matchesBlindedId: "AB\(TestConstants.blind15PublicKey)",
                            serverPublicKey: TestConstants.serverPublicKey
                        )
                    )
                    
                    expect(result).to(beFalse())
                }
            }
        }
    }
}
