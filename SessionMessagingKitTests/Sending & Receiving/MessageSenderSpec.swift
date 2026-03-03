// Copyright © 2026 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit

import Quick
import Nimble

@testable import SessionMessagingKit
@testable import SessionNetworkingKit

class MessageSenderSpec: AsyncSpec {
    override class func spec() {
        // MARK: Configuration
        
        @TestState var dependencies: TestDependencies! = TestDependencies()
        @TestState var mockStorage: Storage! = SynchronousStorage(
            customWriter: try! DatabaseQueue(),
            using: dependencies
        )
        @TestState var mockCrypto: MockCrypto! = .create(using: dependencies)
        @TestState var mockGeneralCache: MockGeneralCache! = .create(using: dependencies)
        @TestState var mockNetwork: MockNetwork! = .create(using: dependencies)
        
        beforeEach {
            dependencies.set(cache: .general, to: mockGeneralCache)
            try await mockGeneralCache.defaultInitialSetup()
            
            dependencies.set(singleton: .storage, to: mockStorage)
            try await mockStorage.perform(migrations: SNMessagingKit.migrations)
            try await mockStorage.write { db in
                try Identity(variant: .ed25519PublicKey, data: Data(hex: TestConstants.edPublicKey)).insert(db)
                try Identity(variant: .ed25519SecretKey, data: Data(hex: TestConstants.edSecretKey)).insert(db)
            }
            
            dependencies.set(singleton: .crypto, to: mockCrypto)
            try await mockCrypto
                .when { $0.generate(.signature(message: .any, ed25519SecretKey: .any)) }
                .thenReturn(Authentication.Signature.standard(signature: "TestSignature".bytes))
            try await mockCrypto
                .when { $0.generate(.randomBytes(24)) }
                .thenReturn(Array(Data(base64Encoded: "pbTUizreT0sqJ2R2LloseQDyVL2RYztD")!))
            try await mockCrypto
                .when { $0.generate(.ed25519KeyPair(seed: Array<UInt8>.any)) }
                .thenReturn(
                    KeyPair(
                        publicKey: Array(Data(hex: TestConstants.edPublicKey)),
                        secretKey: Array(Data(hex: TestConstants.edSecretKey))
                    )
                )
            
            dependencies.set(singleton: .network, to: mockNetwork)
            try await mockNetwork.defaultInitialSetup(using: dependencies)
        }
        
        // MARK: - a MessageSender
        describe("a MessageSender") {
            // MARK: -- when sending to a contact
            context("when sending to a contact") {
                beforeEach {
                    try await mockCrypto
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
                    try await mockCrypto
                        .when { $0.generate(.signature(message: .any, ed25519SecretKey: .any)) }
                        .thenReturn(Authentication.Signature.standard(signature: []))
                    try await mockNetwork
                        .when {
                            try await $0.send(
                                endpoint: MockEndpoint.any,
                                destination: .any,
                                body: .any,
                                category: .any,
                                requestTimeout: .any,
                                overallTimeout: .any
                            )
                        }
                        .thenReturn(MockNetwork.response(
                            data: try! JSONEncoder(using: dependencies).encode(
                                Network.StorageServer.SendMessagesResponse(
                                    hash: "TestHash",
                                    swarm: [:],
                                    hardFork: [2, 11],
                                    timeOffset: 0
                                )
                            )
                        ))
                }
                
                // MARK: ---- calls the network correctly
                it("calls the network correctly") {
                    await expect {
                        try await MessageSender.send(
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
                    
                    await mockNetwork
                        .verify {
                            try await $0.send(
                                endpoint: MockEndpoint.any,
                                destination: .any,
                                body: .any,
                                category: .any,
                                requestTimeout: .any,
                                overallTimeout: .any
                            )
                        }
                        .wasCalled(exactly: 1, timeout: .milliseconds(100))
                }
            }
            
            // MARK: -- when preparing to send to a contact
            context("when preparing to send to a contact") {
                beforeEach {
                    try await mockCrypto
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
                    try await mockCrypto
                        .when { $0.generate(.signature(message: .any, ed25519SecretKey: .any)) }
                        .thenReturn(Authentication.Signature.standard(signature: []))
                }
                
                // MARK: ---- can encrypt correctly
                it("can encrypt correctly") {
                    var message: Message = VisibleMessage(
                        text: "TestMessage"
                    )
                    
                    let preparedRequest: Network.PreparedRequest<MessageSender.SendResponse>? = try require {
                        try MessageSender.preparedSend(
                            message: &message,
                            to: .contact(publicKey: "05\(TestConstants.publicKey)"),
                            namespace: .default,
                            interactionId: nil,
                            attachments: nil,
                            authMethod: Authentication.standard(
                                sessionId: SessionId(.standard, hex: TestConstants.publicKey),
                                ed25519PublicKey: Array(Data(hex: TestConstants.edPublicKey)),
                                ed25519SecretKey: Array(Data(hex: TestConstants.edSecretKey))
                            ),
                            using: dependencies
                        )
                    }.toNot(throwError())
                    
                    expect(preparedRequest).toNot(beNil())
                }
            }
        }
    }
}
