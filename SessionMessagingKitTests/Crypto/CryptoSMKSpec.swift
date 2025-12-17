// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtilitiesKit

import Quick
import Nimble

@testable import SessionMessagingKit

class CryptoSMKSpec: QuickSpec {
    override class func spec() {
        // MARK: Configuration

        @TestState var dependencies: TestDependencies! = TestDependencies()
        @TestState(singleton: .crypto, in: dependencies) var crypto: Crypto! = Crypto(using: dependencies)
        @TestState(cache: .general, in: dependencies) var mockGeneralCache: MockGeneralCache! = MockGeneralCache(
            initialSetup: { cache in
                cache.when { $0.sessionId }.thenReturn(SessionId(.standard, hex: TestConstants.publicKey))
                cache.when { $0.ed25519SecretKey }.thenReturn(Array(Data(hex: TestConstants.edSecretKey)))
            }
        )

        // MARK: - Crypto for SessionMessagingKit
        describe("Crypto for SessionMessagingKit") {
            // MARK: -- can convert an ed25519 public key into an x25519 public key
            it("can convert an ed25519 public key into an x25519 public key") {
                let result = crypto.generate(.x25519(ed25519Pubkey: Array(Data(hex: TestConstants.edPublicKey))))

                expect(result?.toHexString())
                    .to(equal("88672ccb97f40bb57238989226cf429b575ba355443f47bc76c5ab144a96c65b"))
            }

            // MARK: -- can convert an ed25519 private key into an x25519 private key
            it("can convert an ed25519 private key into an x25519 private key") {
                let result = crypto.generate(.x25519(ed25519Seckey: Array(Data(hex: TestConstants.edSecretKey))))

                expect(result?.toHexString())
                    .to(equal("30d796c1ddb4dc455fd998a98aa275c247494a9a7bde9c1fee86ae45cd585241"))
            }

            // MARK: -- when generating a hash
            describe("when generating a hash") {
                // MARK: ------ generates a hash correctly
                it("generates a hash correctly") {
                    let result = crypto.generate(.hash(message: "TestMessage".bytes, key: "Key".bytes, length: 32))
                    expect(result).toNot(beNil())
                    expect(result?.count).to(equal(32))
                    expect(result?.toHexString())
                        .to(equal("4bb38525401d48349990f8e018aeeb3c68f9469babf4de9d3f08d960c7ae2721"))
                }

                // MARK: ------ generates a hash correctly with no key
                it("generates a hash correctly with no key") {
                    let result = crypto.generate(.hash(message: "TestMessage".bytes, key: nil, length: 32))
                    expect(result).toNot(beNil())
                    expect(result?.count).to(equal(32))
                    expect(result?.toHexString())
                        .to(equal("2a48a12262e4548afb97fe2b04a912a02297d451169ee7ef2d01a28ea20286ab"))
                }

                // MARK: ------ fails if given invalid options
                it("fails if given invalid options") {
                    // Max length 64
                    expect(crypto.generate(.hash(message: "TestMessage".bytes, key: nil, length: 65))).to(beNil())
                }
            }

            // MARK: -- when encoding messages
            context("when encoding messages") {
                @TestState var result: Data?
                
                // MARK: ---- can encrypt correctly
                it("can encrypt correctly") {
                    result = try? crypto.tryGenerate(
                        .encodedMessage(
                            plaintext: "TestMessage".data(using: .utf8)!,
                            proMessageFeatures: .none,
                            proProfileFeatures: .none,
                            destination: .contact(publicKey: "05\(TestConstants.publicKey)"),
                            sentTimestampMs: 1234567890
                        )
                    )

                    // Note: A Nonce is used for this so we can't compare the exact value when not mocked
                    expect(result).toNot(beNil())
                    expect(result?.count).to(equal(155))
                }

                // MARK: ---- throws an error if there is no ed25519 keyPair
                it("throws an error if there is no ed25519 keyPair") {
                    mockGeneralCache.when { $0.ed25519SecretKey }.thenReturn([])

                    expect {
                        result = try crypto.tryGenerate(
                            .encodedMessage(
                                plaintext: "TestMessage".data(using: .utf8)!,
                                proMessageFeatures: .none,
                                proProfileFeatures: .none,
                                destination: .contact(publicKey: "05\(TestConstants.publicKey)"),
                                sentTimestampMs: 1234567890
                            )
                        )
                    }
                    .to(throwError(CryptoError.missingUserSecretKey))
                }
            }

            // MARK: -- when decrypting with the session protocol
            context("when decrypting with the session protocol") {
                @TestState var result: DecodedMessage?
                
                // MARK: ---- successfully decrypts a message
                it("successfully decrypts a message") {
                    result = try? crypto.generate(
                        .decodedMessage(
                            encodedMessage: Data(
                                base64Encoded: "SRP0eBUWh4ez6ppWjUs5/Wph5fhnPRgB5zsWWnTz+FBAw/YI3oS2pDpIfyetMTbU" +
                                "sFMhE5G4PbRtQFey1hsxLl221Qivc3ayaX2Mm/X89Dl8e45BC+Lb/KU9EdesxIK4pVgYXs9XrMtX3v8" +
                                "dt0eBaXneOBfr7qB8pHwwMZjtkOu1ED07T9nszgbWabBphUfWXe2U9K3PTRisSCI="
                            )!,
                            origin: .swarm(
                                publicKey: TestConstants.publicKey,
                                namespace: .default,
                                serverHash: "12345",
                                serverTimestampMs: 1234567890,
                                serverExpirationTimestamp: 1234567890
                            )
                        )
                    )
                    
                    expect(String(data: (result?.content ?? Data()), encoding: .utf8)).to(equal("TestMessage"))
                    expect(result?.sender.hexString)
                        .to(equal("0588672ccb97f40bb57238989226cf429b575ba355443f47bc76c5ab144a96c65b"))
                }

                // MARK: ---- throws an error if there is no ed25519 keyPair
                it("throws an error if there is no ed25519 keyPair") {
                    mockGeneralCache.when { $0.ed25519SecretKey }.thenReturn([])

                    expect {
                        result = try crypto.tryGenerate(
                            .decodedMessage(
                                encodedMessage: Data(
                                    base64Encoded: "SRP0eBUWh4ez6ppWjUs5/Wph5fhnPRgB5zsWWnTz+FBAw/YI3oS2pDpIfyetMTbU" +
                                    "sFMhE5G4PbRtQFey1hsxLl221Qivc3ayaX2Mm/X89Dl8e45BC+Lb/KU9EdesxIK4pVgYXs9XrMtX3v8" +
                                    "dt0eBaXneOBfr7qB8pHwwMZjtkOu1ED07T9nszgbWabBphUfWXe2U9K3PTRisSCI="
                                )!,
                                origin: .swarm(
                                    publicKey: TestConstants.publicKey,
                                    namespace: .default,
                                    serverHash: "12345",
                                    serverTimestampMs: 1234567890,
                                    serverExpirationTimestamp: 1234567890
                                )
                            )
                        )
                    }
                    .to(throwError(CryptoError.missingUserSecretKey))
                }

                // MARK: ---- throws an error if the ciphertext is too short
                it("throws an error if the ciphertext is too short") {
                    expect {
                        result = try crypto.tryGenerate(
                            .decodedMessage(
                                encodedMessage: Data([1, 2, 3]),
                                origin: .swarm(
                                    publicKey: TestConstants.publicKey,
                                    namespace: .default,
                                    serverHash: "12345",
                                    serverTimestampMs: 1234567890,
                                    serverExpirationTimestamp: 1234567890
                                )
                            )
                        )
                    }
                    .to(throwError(MessageError.decodingFailed))
                }
            }
        }
    }
}
