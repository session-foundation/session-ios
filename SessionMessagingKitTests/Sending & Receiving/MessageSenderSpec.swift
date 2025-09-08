// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionNetworkingKit
import SessionUtilitiesKit

import Quick
import Nimble

@testable import SessionMessagingKit

class MessageSenderSpec: AsyncSpec {
    override class func spec() {
        // MARK: Configuration
        
        @TestState var dependencies: TestDependencies! = TestDependencies()
        @TestState(singleton: .storage, in: dependencies) var mockStorage: Storage! = SynchronousStorage(
            customWriter: try! DatabaseQueue(),
            using: dependencies
        )
        @TestState(singleton: .crypto, in: dependencies) var mockCrypto: MockCrypto! = .create()
        @TestState var mockGeneralCache: MockGeneralCache! = MockGeneralCache()
        
        beforeEach {
            /// The compiler kept crashing when doing this via `@TestState` so need to do it here instead
            mockGeneralCache.defaultInitialSetup()
            dependencies.set(cache: .general, to: mockGeneralCache)
            
            try await mockStorage.perform(migrations: SNMessagingKit.migrations)
            try await mockStorage.writeAsync { db in
                try Identity(variant: .ed25519PublicKey, data: Data(hex: TestConstants.edPublicKey)).insert(db)
                try Identity(variant: .ed25519SecretKey, data: Data(hex: TestConstants.edSecretKey)).insert(db)
            }
            
            try await mockCrypto
                .when { $0.generate(.signature(message: .any, ed25519SecretKey: .any)) }
                .thenReturn(Authentication.Signature.standard(signature: "TestSignature".bytes))
            try await mockCrypto
                .when { $0.generate(.randomBytes(24)) }
                .thenReturn(Array(Data(base64Encoded: "pbTUizreT0sqJ2R2LloseQDyVL2RYztD")!))
            try await mockCrypto
                .when { $0.generate(.ed25519KeyPair(seed: .any)) }
                .thenReturn(
                    KeyPair(
                        publicKey: Array(Data(hex: TestConstants.edPublicKey)),
                        secretKey: Array(Data(hex: TestConstants.edSecretKey))
                    )
                )
        }
        
        // MARK: - a MessageSender
        describe("a MessageSender") {
            // MARK: -- when preparing to send to a contact
            context("when preparing to send to a contact") {
                @TestState var preparedRequest: Network.PreparedRequest<Message>?
                
                beforeEach {
                    try await mockCrypto
                        .when {
                            $0.generate(.ciphertextWithSessionProtocol(plaintext: .any, destination: .any))
                        }
                        .thenReturn(Data([1, 2, 3]))
                    try await mockCrypto
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
