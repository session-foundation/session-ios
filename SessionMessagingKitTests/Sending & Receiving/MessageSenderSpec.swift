// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionNetworkingKit
import SessionUtilitiesKit

import Quick
import Nimble

@testable import SessionMessagingKit

class MessageSenderSpec: QuickSpec {
    override class func spec() {
        // MARK: Configuration
        
        @TestState var dependencies: TestDependencies! = TestDependencies()
        @TestState(singleton: .storage, in: dependencies) var mockStorage: Storage! = SynchronousStorage(
            customWriter: try! DatabaseQueue(),
            migrations: SNMessagingKit.migrations,
            using: dependencies,
            initialData: { db in
                try Identity(variant: .ed25519PublicKey, data: Data(hex: TestConstants.edPublicKey)).insert(db)
                try Identity(variant: .ed25519SecretKey, data: Data(hex: TestConstants.edSecretKey)).insert(db)
            }
        )
        @TestState(singleton: .crypto, in: dependencies) var mockCrypto: MockCrypto! = MockCrypto(
            initialSetup: { crypto in
                crypto
                    .when { $0.generate(.signature(message: .any, ed25519SecretKey: .any)) }
                    .thenReturn(Authentication.Signature.standard(signature: "TestSignature".bytes))
                crypto
                    .when { $0.generate(.randomBytes(24)) }
                    .thenReturn(Array(Data(base64Encoded: "pbTUizreT0sqJ2R2LloseQDyVL2RYztD")!))
                crypto
                    .when { $0.generate(.ed25519KeyPair(seed: Array<UInt8>.any)) }
                    .thenReturn(
                        KeyPair(
                            publicKey: Array(Data(hex: TestConstants.edPublicKey)),
                            secretKey: Array(Data(hex: TestConstants.edSecretKey))
                        )
                    )
            }
        )
        @TestState(cache: .general, in: dependencies) var mockGeneralCache: MockGeneralCache! = MockGeneralCache(
            initialSetup: { cache in
                cache.when { $0.sessionId }.thenReturn(SessionId(.standard, hex: TestConstants.publicKey))
                cache.when { $0.ed25519SecretKey }.thenReturn(Array(Data(hex: TestConstants.edSecretKey)))
                cache
                    .when { $0.ed25519Seed }
                    .thenReturn(Array(Array(Data(hex: TestConstants.edSecretKey)).prefix(upTo: 32)))
            }
        )
        
        // MARK: - a MessageSender
        describe("a MessageSender") {
            // MARK: -- when preparing to send to a contact
            context("when preparing to send to a contact") {
                @TestState var preparedRequest: Network.PreparedRequest<Message>?
                
                beforeEach {
                    mockCrypto
                        .when {
                            try $0.generate(
                                .encodedMessage(
                                    plaintext: Array<UInt8>.any,
                                    proMessageFeatures: .any,
                                    proProfileFeatures: .any,
                                    destination: .any,
                                    sentTimestampMs: .any
                                )
                            )
                        }
                        .thenReturn(Data([1, 2, 3]))
                    mockCrypto
                        .when { $0.generate(.signature(message: .any, ed25519SecretKey: .any)) }
                        .thenReturn(Authentication.Signature.standard(signature: []))
                }
                
                // MARK: ---- can encrypt correctly
                it("can encrypt correctly") {
                    expect {
                        preparedRequest = try MessageSender.preparedSend(
                            message: VisibleMessage(
                                text: "TestMessage"
                            ),
                            to: .contact(publicKey: "05\(TestConstants.publicKey)"),
                            namespace: .default,
                            interactionId: nil,
                            attachments: nil,
                            authMethod: Authentication.standard(
                                sessionId: SessionId(.standard, hex: TestConstants.publicKey),
                                ed25519PublicKey: Array(Data(hex: TestConstants.edPublicKey)),
                                ed25519SecretKey: Array(Data(hex: TestConstants.edSecretKey))
                            ),
                            onEvent: nil,
                            using: dependencies
                        )
                    }.toNot(throwError())
                    
                    expect(preparedRequest).toNot(beNil())
                }
            }
        }
    }
}
