// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation

import Quick
import Nimble

@testable import SessionUtilitiesKit

class GeneralCacheSpec: QuickSpec {
    override class func spec() {
        // MARK: Configuration
        
        @TestState var dependencies: TestDependencies! = TestDependencies()
        @TestState(singleton: .crypto, in: dependencies) var mockCrypto: MockCrypto! = MockCrypto(
            initialSetup: { crypto in
                crypto
                    .when { $0.generate(.ed25519KeyPair(seed: .any)) }
                    .thenReturn(
                        KeyPair(
                            publicKey: Array(Data(hex: TestConstants.edPublicKey)),
                            secretKey: Array(Data(hex: TestConstants.edSecretKey))
                        )
                    )
                crypto
                    .when { $0.generate(.x25519(ed25519Pubkey: .any)) }
                    .thenReturn(Array(Data(hex: TestConstants.publicKey)))
            }
        )
        
        // MARK: - a General Cache
        describe("a General Cache") {
            // MARK: -- starts with an invalid state
            it("starts with an invalid state") {
                let cache: General.Cache = General.Cache(using: dependencies)
                
                expect(cache.userExists).to(beFalse())
                expect(cache.sessionId).to(equal(.invalid))
                expect(cache.ed25519SecretKey).to(beEmpty())
            }
            
            // MARK: -- correctly indicates whether the user exists
            it("correctly indicates whether the user exists") {
                let cache: General.Cache = General.Cache(using: dependencies)
                cache.setSecretKey(ed25519SecretKey: Array(Data(hex: TestConstants.edSecretKey)))

                expect(cache.userExists).to(beTrue())
            }
            
            // MARK: -- generates the correct sessionId
            it("generates the correct sessionId") {
                let cache: General.Cache = General.Cache(using: dependencies)
                cache.setSecretKey(ed25519SecretKey: Array(Data(hex: TestConstants.edSecretKey)))
                
                expect(cache.sessionId).to(equal(SessionId(.standard, hex: TestConstants.publicKey)))
            }
            
            // MARK: -- remains invalid when given a seckey that is too short
            it("remains invalid when given a seckey that is too short") {
                mockCrypto.when { $0.generate(.ed25519KeyPair(seed: .any)) }.thenReturn(nil)
                let cache: General.Cache = General.Cache(using: dependencies)
                cache.setSecretKey(ed25519SecretKey: [1, 2, 3])
                
                expect(cache.userExists).to(beFalse())
                expect(cache.sessionId).to(equal(.invalid))
                expect(cache.ed25519SecretKey).to(beEmpty())
            }
            
            // MARK: -- remains invalid when ed key pair generation fails
            it("remains invalid when ed key pair generation fails") {
                mockCrypto.when { $0.generate(.ed25519KeyPair(seed: .any)) }.thenReturn(nil)
                let cache: General.Cache = General.Cache(using: dependencies)
                cache.setSecretKey(ed25519SecretKey: Array(Data(hex: TestConstants.edSecretKey)))
                
                expect(cache.userExists).to(beFalse())
                expect(cache.sessionId).to(equal(.invalid))
                expect(cache.ed25519SecretKey).to(beEmpty())
            }
            
            // MARK: -- remains invalid when x25519 pubkey generation fails
            it("remains invalid when x25519 pubkey generation fails") {
                mockCrypto.when { $0.generate(.x25519(ed25519Pubkey: .any)) }.thenReturn(nil)
                let cache: General.Cache = General.Cache(using: dependencies)
                cache.setSecretKey(ed25519SecretKey: Array(Data(hex: TestConstants.edSecretKey)))
                
                expect(cache.userExists).to(beFalse())
                expect(cache.sessionId).to(equal(.invalid))
                expect(cache.ed25519SecretKey).to(beEmpty())
            }
            
            // MARK: -- changes back to an invalid state if updated with an invalid value
            it("changes back to an invalid state if updated with an invalid value") {
                let cache: General.Cache = General.Cache(using: dependencies)
                cache.setSecretKey(ed25519SecretKey: Array(Data(hex: TestConstants.edSecretKey)))
                expect(cache.userExists).to(beTrue())
                
                cache.setSecretKey(ed25519SecretKey: [])
                expect(cache.userExists).to(beFalse())
                expect(cache.sessionId).to(equal(.invalid))
                expect(cache.ed25519SecretKey).to(beEmpty())
            }
        }
    }
}
