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
        @TestState var mockStorage: Storage! = try! Storage.createForTesting(using: dependencies)
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

            // MARK: -- when recording pro stats for a sent message
            context("when recording pro stats for a sent message") {
                @TestState var interactionId: Int64!
                
                beforeEach {
                    try await mockStorage.write { db in
                        try SessionThread.upsert(
                            db,
                            id: "TestThread",
                            variant: .contact,
                            values: SessionThread.TargetValues(shouldBeVisible: .setTo(true)),
                            using: dependencies
                        )
                        interactionId = try Interaction(
                            serverHash: nil,
                            messageUuid: nil,
                            threadId: "TestThread",
                            authorId: "05\(TestConstants.publicKey)",
                            variant: .standardOutgoing,
                            body: "Test",
                            timestampMs: 1234567890,
                            receivedAtTimestampMs: 1234567890,
                            wasRead: true,
                            hasMention: false,
                            expiresInSeconds: nil,
                            expiresStartedAtMs: nil,
                            linkPreviewUrl: nil,
                            openGroupServerMessageId: nil,
                            openGroupWhisper: false,
                            openGroupWhisperMods: false,
                            openGroupWhisperTo: nil,
                            state: .sending,
                            recipientReadTimestampMs: nil,
                            mostRecentFailureText: nil,
                            proMessageFeatures: .none,
                            proProfileFeatures: .none
                        ).inserted(db).id
                    }
                }
                
                // MARK: ---- emits the counters under the key the pro settings screen observes
                it("emits the counters into the bucket the pro settings screen reads") {
                    var emittedKeys: [ObservableKey] = []
                    
                    try await mockStorage.write { db in
                        try MessageSender.handleSuccessfulMessageSend(
                            db,
                            threadId: "TestThread",
                            message: VisibleMessage(
                                text: "Test",
                                proMessageFeatures: .largerCharacterLimit,
                                proProfileFeatures: .proBadge
                            ),
                            to: .contact(publicKey: "05\(TestConstants.publicKey)"),
                            interactionId: interactionId,
                            using: dependencies
                        )
                        emittedKeys = db.currentEvents().map { $0.key }
                    }
                    
                    /// `EventChangeset` buckets events by the generic half of the key, so this is what decides whether
                    /// `SessionProSettingsViewModel` finds them: reading the `setting` bucket returns nothing when the
                    /// writes went in under `keyValue`, and the numbers on screen silently stop moving.
                    ///
                    /// **Note:** Asserted on the generic rather than on key equality, because `ObservableKey` is
                    /// `RawRepresentable` and so compares by name alone - `setting` and `keyValue` for the same counter
                    /// are equal, which is precisely why the mismatch is invisible at the subscription
                    let counterGenerics: [GenericObservableKey] = emittedKeys
                        .filter {
                            $0.rawValue == KeyValueStore.IntKey.proBadgesSentCounter.rawValue ||
                            $0.rawValue == KeyValueStore.IntKey.longerMessagesSentCounter.rawValue
                        }
                        .map { $0.generic }
                    
                    expect(counterGenerics).to(haveCount(2))
                    expect(Set(counterGenerics)).to(equal([.keyValue]))
                }
                
                // MARK: ---- increments each counter once
                it("increments each counter once") {
                    try await mockStorage.write { db in
                        try MessageSender.handleSuccessfulMessageSend(
                            db,
                            threadId: "TestThread",
                            message: VisibleMessage(
                                text: "Test",
                                proMessageFeatures: .largerCharacterLimit,
                                proProfileFeatures: .proBadge
                            ),
                            to: .contact(publicKey: "05\(TestConstants.publicKey)"),
                            interactionId: interactionId,
                            using: dependencies
                        )
                    }
                    
                    let badges: Int = try await mockStorage.read { db in (db[.proBadgesSentCounter] ?? 0) }
                    let longer: Int = try await mockStorage.read { db in (db[.longerMessagesSentCounter] ?? 0) }
                    
                    expect(badges).to(equal(1))
                    expect(longer).to(equal(1))
                }
                
                // MARK: ---- does not count again for a message already delivered
                it("does not count again for a message already delivered") {
                    /// `sent` is not terminal - `handleFailedMessageSend` moves a delivered message to `failedToSync`
                    /// when its sync leg fails, and `syncing` is a delivered message whose sync leg is still running. A
                    /// second successful pass from any of them is the same message arriving again, not a new one
                    let deliveredStates: [Interaction.State] = [.sent, .syncing, .failedToSync]
                    
                    for state in deliveredStates {
                        try await mockStorage.write { db in
                            _ = try Interaction
                                .filter(id: interactionId)
                                .updateAll(db, Interaction.Columns.state.set(to: state))
                            db[.proBadgesSentCounter] = 0
                            db[.longerMessagesSentCounter] = 0
                        }
                        
                        try await mockStorage.write { db in
                            try MessageSender.handleSuccessfulMessageSend(
                                db,
                                threadId: "TestThread",
                                message: VisibleMessage(
                                    text: "Test",
                                    proMessageFeatures: .largerCharacterLimit,
                                    proProfileFeatures: .proBadge
                                ),
                                to: .contact(publicKey: "05\(TestConstants.publicKey)"),
                                interactionId: interactionId,
                                using: dependencies
                            )
                        }
                        
                        let badges: Int = try await mockStorage.read { db in (db[.proBadgesSentCounter] ?? 0) }
                        let longer: Int = try await mockStorage.read { db in (db[.longerMessagesSentCounter] ?? 0) }
                        let stateAfter: Interaction.State? = try await mockStorage.read { db in
                            try Interaction.filter(id: interactionId).fetchOne(db)?.state
                        }
                        
                        /// Paired with the absences below so a fixture which never reached the counting code fails loudly
                        /// rather than passing quietly - the handler marks the interaction `sent`, so this is what
                        /// distinguishes "correctly did not count" from "never ran"
                        expect(stateAfter).to(equal(.sent), description: "handler did not run for \(state)")
                        expect(badges).to(equal(0), description: "counted again from \(state)")
                        expect(longer).to(equal(0), description: "counted again from \(state)")
                    }
                }
                
                // MARK: ---- counts a message which had previously failed outright
                it("counts a message which had previously failed outright") {
                    /// `failed` never reached a recipient, so the send which follows it is the first delivery and must count
                    try await mockStorage.write { db in
                        _ = try Interaction
                            .filter(id: interactionId)
                            .updateAll(db, Interaction.Columns.state.set(to: Interaction.State.failed))
                    }
                    
                    try await mockStorage.write { db in
                        try MessageSender.handleSuccessfulMessageSend(
                            db,
                            threadId: "TestThread",
                            message: VisibleMessage(
                                text: "Test",
                                proMessageFeatures: .largerCharacterLimit,
                                proProfileFeatures: .proBadge
                            ),
                            to: .contact(publicKey: "05\(TestConstants.publicKey)"),
                            interactionId: interactionId,
                            using: dependencies
                        )
                    }
                    
                    let badges: Int = try await mockStorage.read { db in (db[.proBadgesSentCounter] ?? 0) }
                    
                    expect(badges).to(equal(1))
                }
                
                // MARK: ---- only counts the message once when it is sent again
                it("only counts the message once when it is sent again") {
                    /// The same interaction reaching a successful send twice - a resend, or a job retry after the send
                    /// actually landed - must contribute one badge and one longer message, not two
                    for _ in 0..<2 {
                        try await mockStorage.write { db in
                            try MessageSender.handleSuccessfulMessageSend(
                                db,
                                threadId: "TestThread",
                                message: VisibleMessage(
                                    text: "Test",
                                    proMessageFeatures: .largerCharacterLimit,
                                    proProfileFeatures: .proBadge
                                ),
                                to: .contact(publicKey: "05\(TestConstants.publicKey)"),
                                interactionId: interactionId,
                                using: dependencies
                            )
                        }
                    }
                    
                    let badges: Int = try await mockStorage.read { db in (db[.proBadgesSentCounter] ?? 0) }
                    let longer: Int = try await mockStorage.read { db in (db[.longerMessagesSentCounter] ?? 0) }
                    
                    expect(badges).to(equal(1))
                    expect(longer).to(equal(1))
                }
                
                // MARK: ---- does not count a message which used no pro features
                it("does not count a message which used no pro features") {
                    try await mockStorage.write { db in
                        try MessageSender.handleSuccessfulMessageSend(
                            db,
                            threadId: "TestThread",
                            message: VisibleMessage(text: "Test"),
                            to: .contact(publicKey: "05\(TestConstants.publicKey)"),
                            interactionId: interactionId,
                            using: dependencies
                        )
                    }
                    
                    let badges: Int = try await mockStorage.read { db in (db[.proBadgesSentCounter] ?? 0) }
                    let longer: Int = try await mockStorage.read { db in (db[.longerMessagesSentCounter] ?? 0) }
                    let stateAfter: Interaction.State? = try await mockStorage.read { db in
                        try Interaction.filter(id: interactionId).fetchOne(db)?.state
                    }
                    
                    /// Paired with the absences so a fixture which never reached the counting code fails loudly
                    expect(stateAfter).to(equal(.sent))
                    expect(badges).to(equal(0))
                    expect(longer).to(equal(0))
                }
            }
        }
    }
}
