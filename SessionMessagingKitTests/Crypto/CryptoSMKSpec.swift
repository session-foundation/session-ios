// Copyright © 2026 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtilitiesKit
import TestUtilities

import Quick
import Nimble

@testable import SessionMessagingKit

class CryptoSMKSpec: AsyncSpec {
    override class func spec() {
        // MARK: Configuration

        @TestState var dependencies: TestDependencies! = TestDependencies()
        @TestState var crypto: Crypto! = Crypto(using: dependencies)
        @TestState var mockGeneralCache: MockGeneralCache! = .create(using: dependencies)
        
        beforeEach {
            dependencies.set(singleton: .crypto, to: crypto)
            
            dependencies.set(cache: .general, to: mockGeneralCache)
            try await mockGeneralCache.defaultInitialSetup()
        }
        
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
                    expect(result?.count).to(equal(397))
                }

                // MARK: ---- throws an error if there is no ed25519 keyPair
                it("throws an error if there is no ed25519 keyPair") {
                    try await mockGeneralCache.when { $0.ed25519SecretKey }.thenReturn([])

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
                @TestState var encodedMessage: Data! = Data(
                    base64Encoded: "CAESvwEKABIAGrYBCAYSACjQiOyP9yM4AUKmAfjX/WXVFs+QE5Eh54Esw9/N" +
                    "lYza3k8MOvcRAI7y8k0JzLsm/KpXxKP7Zx7+5YyII9sCRXzFK2U4/X9SSMN088YEr/5wKoDfL5q" +
                    "PQbN70aa59WS8YE+yWcniQO0KXfAzr6Acn40fsa9BMr9tnQLfvxY8vD7qBz9iEOV9jTxPzxUoD+" +
                    "JelIbsv2qlkOl9vs166NC/Y772NZmUAR5u1ewL4SYEWkqX5R4gAA=="
                )
                
                // MARK: ---- successfully decrypts a message
                it("successfully decrypts a message") {
                    try require {
                        result = try crypto.tryGenerate(
                            .decodedMessage(
                                encodedMessage: encodedMessage,
                                origin: .swarm(
                                    publicKey: "05\(TestConstants.publicKey)",
                                    namespace: .default,
                                    serverHash: "12345",
                                    serverTimestampMs: 1234567890,
                                    serverExpirationTimestamp: 1234567890
                                )
                            )
                        )
                    }.toNot(throwError())
                    
                    let proto: SNProtoContent! = try require { try result!.decodeProtoContent() }
                        .toNot(throwError())
                    expect(proto.dataMessage?.body).to(equal("TestMessage"))
                    expect(result!.sender.hexString)
                        .to(equal("0588672ccb97f40bb57238989226cf429b575ba355443f47bc76c5ab144a96c65b"))
                }

                // MARK: ---- throws an error if there is no ed25519 keyPair
                it("throws an error if there is no ed25519 keyPair") {
                    try await mockGeneralCache.when { $0.ed25519SecretKey }.thenReturn([])

                    expect {
                        result = try crypto.tryGenerate(
                            .decodedMessage(
                                encodedMessage: encodedMessage,
                                origin: .swarm(
                                    publicKey: "05\(TestConstants.publicKey)",
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
                                    publicKey: "05\(TestConstants.publicKey)",
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

            // MARK: -- when deriving the Session Pro Apple account token
            describe("when deriving the Session Pro Apple account token") {
                // MARK: ---- derives a deterministic UUID from a known master public key
                it("derives a deterministic UUID from a known master public key") {
                    let publicKey: [UInt8] = Array(0..<32).map { UInt8($0) }

                    expect(try UUID(sessionProMasterPublicKey: publicKey).uuidString)
                        .to(equal("00010203-0405-4607-8809-0A0B0C0D0E0F"))
                }

                // MARK: ---- overwrites only the version and variant bits
                it("overwrites only the version and variant bits") {
                    let publicKey: [UInt8] = [
                        0xff, 0xee, 0xdd, 0xcc, 0xbb, 0xaa, 0x99, 0x88,
                        0x77, 0x66, 0x55, 0x44, 0x33, 0x22, 0x11, 0x00,
                        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
                    ]

                    /// The 6th byte's high nibble becomes `4` (version) and the 8th byte's top two bits become
                    /// `10` (variant → `b`), every other bit of the first 16 bytes is preserved verbatim
                    expect(try UUID(sessionProMasterPublicKey: publicKey).uuidString)
                        .to(equal("FFEEDDCC-BBAA-4988-B766-554433221100"))
                }

                // MARK: ---- uses only the first 16 bytes of the master public key
                it("uses only the first 16 bytes of the master public key") {
                    let first16: [UInt8] = Array(0..<16).map { UInt8($0) }
                    let differentTail: [UInt8] = first16 + Array(repeating: 0xAB, count: 16)

                    expect(try UUID(sessionProMasterPublicKey: differentTail))
                        .to(equal(try UUID(sessionProMasterPublicKey: first16 + Array(repeating: 0, count: 16))))
                }

                // MARK: ---- throws if the public key is too short
                it("throws if the public key is too short") {
                    expect { try UUID(sessionProMasterPublicKey: Array(0..<15).map { UInt8($0) }) }
                        .to(throwError(CryptoError.invalidPublicKey))
                }

                // MARK: ---- produces a valid version 4 UUID via the crypto generator
                it("produces a valid version 4 UUID via the crypto generator") {
                    let result: UUID? = crypto.generate(.sessionProAppleAccountToken())
                    try require(result).toNot(beNil())

                    let chars: [Character] = Array(result!.uuidString)

                    /// 15th character (start of the 3rd group) is the version and must be `4`
                    expect(chars[14]).to(equal(Character("4")))

                    /// 20th character (start of the 4th group) is the variant and must be one of `8`, `9`, `a`, `b`
                    expect([Character("8"), Character("9"), Character("A"), Character("B")])
                        .to(contain(chars[19]))

                    /// The derivation is deterministic for a given identity seed
                    expect(crypto.generate(.sessionProAppleAccountToken())).to(equal(result))
                }
            }
        }
    }
}
