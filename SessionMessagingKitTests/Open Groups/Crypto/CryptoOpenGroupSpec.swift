// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtilitiesKit

import Quick
import Nimble

@testable import SessionMessagingKit

class CryptoOpenGroupSpec: QuickSpec {
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
        
        // MARK: - Crypto for Open Group
        describe("Crypto for Open Group") {
            // MARK: -- when decrypting with the session blinding protocol
            context("when decrypting with the session blinding protocol") {
                // MARK: ---- can decrypt a blind15 message correctly
                it("can decrypt a blind15 message correctly") {
                    let result = try? crypto.tryGenerate(
                        .plaintextWithSessionBlindingProtocol(
                            ciphertext: Data(
                                base64Encoded: "AMuM6E07xyYzN1/gP64v9TelMjkylHsFZznTzE7rDIykIHBHKbdkLnXo4Q1iVWdD" +
                                "ct9F9YqIsRsqmdLl1t6nfQtWoiUSkjBChvg3J61f7rpS3/A+"
                            )!,
                            senderId: "15\(TestConstants.blind15PublicKey)",
                            recipientId: "15\(TestConstants.blind15PublicKey)",
                            serverPublicKey: TestConstants.serverPublicKey
                        )
                    )
                    
                    expect(String(data: (result?.plaintext ?? Data()), encoding: .utf8)).to(equal("TestMessage"))
                    expect(result?.senderSessionIdHex).to(equal("05\(TestConstants.publicKey)"))
                }
                
                // MARK: ---- can decrypt a blind25 message correctly
                it("can decrypt a blind25 message correctly") {
                    let result = try? crypto.tryGenerate(
                        .plaintextWithSessionBlindingProtocol(
                            ciphertext: Data(
                                base64Encoded: "ALLcu/jtQsel6HewKdRCsRYXrQl7r60Oz2SX/DKmjCRo4mO2yqMx2+oGwm39n6+p" +
                                "6dK1n+UWPnm4qGRiN6BvZ+xwNsBruPgyW1EV9i8AcEO0P/1X"
                            )!,
                            senderId: "25\(TestConstants.blind25PublicKey)",
                            recipientId: "25\(TestConstants.blind25PublicKey)",
                            serverPublicKey: TestConstants.serverPublicKey
                        )
                    )
                    
                    expect(String(data: (result?.plaintext ?? Data()), encoding: .utf8)).to(equal("TestMessage"))
                    expect(result?.senderSessionIdHex).to(equal("05\(TestConstants.publicKey)"))
                }
                
                // MARK: ---- throws an error if there is no ed25519 keyPair
                it("throws an error if there is no ed25519 keyPair") {
                    mockGeneralCache.when { $0.ed25519SecretKey }.thenReturn([])
                    
                    expect {
                        try crypto.tryGenerate(
                            .plaintextWithSessionBlindingProtocol(
                                ciphertext: Data(
                                    base64Encoded: "SRP0eBUWh4ez6ppWjUs5/Wph5fhnPRgB5zsWWnTz+FBAw/YI3oS2pDpIfyetMTbU" +
                                    "sFMhE5G4PbRtQFey1hsxLl221Qivc3ayaX2Mm/X89Dl8e45BC+Lb/KU9EdesxIK4pVgYXs9XrMtX3v8" +
                                    "dt0eBaXneOBfr7qB8pHwwMZjtkOu1ED07T9nszgbWabBphUfWXe2U9K3PTRisSCI="
                                )!,
                                senderId: "25\(TestConstants.blind25PublicKey)",
                                recipientId: "25\(TestConstants.blind25PublicKey)",
                                serverPublicKey: TestConstants.serverPublicKey
                            )
                        )
                    }
                    .to(throwError(CryptoError.missingUserSecretKey))
                }
                
                // MARK: ---- throws an error if the data is too short
                it("throws an error if the data is too short") {
                    expect {
                        try crypto.tryGenerate(
                            .plaintextWithSessionBlindingProtocol(
                                ciphertext: Data([1, 2, 3]),
                                senderId: "15\(TestConstants.blind15PublicKey)",
                                recipientId: "15\(TestConstants.blind15PublicKey)",
                                serverPublicKey: TestConstants.serverPublicKey
                            )
                        )
                    }
                    .to(throwError(MessageError.decodingFailed))
                }
                
                // MARK: ---- throws an error if the data version is not 0
                it("throws an error if the data version is not 0") {
                    expect {
                        try crypto.tryGenerate(
                            .plaintextWithSessionBlindingProtocol(
                                ciphertext: (
                                    Data([1]) +
                                    "TestMessage".data(using: .utf8)! +
                                    Data(base64Encoded: "pbTUizreT0sqJ2R2LloseQDyVL2RYztD")!
                                ),
                                senderId: "15\(TestConstants.blind15PublicKey)",
                                recipientId: "15\(TestConstants.blind15PublicKey)",
                                serverPublicKey: TestConstants.serverPublicKey
                            )
                        )
                    }
                    .to(throwError(MessageError.decodingFailed))
                }
                
                // MARK: ---- throws an error if it cannot decrypt the data
                it("throws an error if it cannot decrypt the data") {
                    expect {
                        try crypto.tryGenerate(
                            .plaintextWithSessionBlindingProtocol(
                                ciphertext: "RandomData".data(using: .utf8)!,
                                senderId: "25\(TestConstants.blind25PublicKey)",
                                recipientId: "25\(TestConstants.blind25PublicKey)",
                                serverPublicKey: TestConstants.serverPublicKey
                            )
                        )
                    }
                    .to(throwError(MessageError.decodingFailed))
                }
                
                // MARK: ---- throws an error if the inner bytes are too short
                it("throws an error if the inner bytes are too short") {
                    expect {
                        try crypto.tryGenerate(
                            .plaintextWithSessionBlindingProtocol(
                                ciphertext: (
                                    Data([0]) +
                                    "TestMessage".data(using: .utf8)! +
                                    Data(base64Encoded: "pbTUizreT0sqJ2R2LloseQDyVL2RYztD")!
                                ),
                                senderId: "15\(TestConstants.blind15PublicKey)",
                                recipientId: "15\(TestConstants.blind15PublicKey)",
                                serverPublicKey: TestConstants.serverPublicKey
                            )
                        )
                    }
                    .to(throwError(MessageError.decodingFailed))
                }
            }
        }
    }
}
