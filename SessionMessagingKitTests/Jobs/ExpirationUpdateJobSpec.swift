// Copyright © 2026 Session Technology Foundation. All rights reserved.

import Foundation
import GRDB
import TestUtilities

import Quick
import Nimble

@testable import SessionNetworkingKit
@testable import SessionMessagingKit
@testable import SessionUtilitiesKit

class ExpirationUpdateJobSpec: AsyncSpec {
    override class func spec() {
        // MARK: Configuration

        @TestState var dependencies: TestDependencies! = TestDependencies { dependencies in
            dependencies.dateNow = Date(timeIntervalSince1970: 1234567890)
            dependencies.forceSynchronous = true
        }
        @TestState var mockStorage: Storage! = try! Storage.createForTesting(using: dependencies)
        @TestState var mockNetwork: MockNetwork! = .create(using: dependencies)
        @TestState var mockCrypto: MockCrypto! = .create(using: dependencies)
        @TestState var mockGeneralCache: MockGeneralCache! = .create(using: dependencies)
        @TestState var mockJobRunner: MockJobRunner! = .create(using: dependencies)

        /// The expiry the node reports for a message whose expiry it left alone, in milliseconds
        let unchangedExpiryMs: UInt64 = 1234567950000

        /// A message on a 60 second disappearing timer whose countdown has not started
        let expiresInSeconds: TimeInterval = 60

        beforeEach {
            dependencies.set(singleton: .storage, to: mockStorage)
            dependencies.set(singleton: .network, to: mockNetwork)
            dependencies.set(singleton: .crypto, to: mockCrypto)
            dependencies.set(cache: .general, to: mockGeneralCache)
            dependencies.set(singleton: .jobRunner, to: mockJobRunner)

            try await mockGeneralCache
                .when { $0.sessionId }
                .thenReturn(SessionId(.standard, hex: TestConstants.publicKey))
            try await mockGeneralCache
                .when { $0.ed25519Seed }
                .thenReturn(Array(Data(hex: TestConstants.edKeySeed)))
            try await mockJobRunner
                .when { await $0.jobsMatching(filters: .any) }
                .thenReturn([:])

            try await mockStorage.perform(migrations: SNMessagingKit.migrations)
            try await mockStorage.write { db in
                try SessionThread.upsert(
                    db,
                    id: "05\(TestConstants.publicKey)",
                    variant: .contact,
                    values: SessionThread.TargetValues(
                        creationDateTimestamp: .setTo(1234567890),
                        shouldBeVisible: .setTo(false)
                    ),
                    using: dependencies
                )
                _ = try Interaction(
                    serverHash: "H1",
                    threadId: "05\(TestConstants.publicKey)",
                    threadVariant: .contact,
                    authorId: "05\(TestConstants.publicKey)",
                    variant: .standardOutgoing,
                    body: "Test",
                    timestampMs: 1234567890000,
                    expiresInSeconds: expiresInSeconds,
                    expiresStartedAtMs: nil,
                    using: dependencies
                ).inserted(db)
            }

            try await mockCrypto
                .when { $0.generate(.ed25519KeyPair(seed: Array<UInt8>.any)) }
                .thenReturn(
                    KeyPair(
                        publicKey: Array(Data(hex: TestConstants.edPublicKey)),
                        secretKey: Array(Data(hex: TestConstants.edSecretKey))
                    )
                )
            try await mockCrypto
                .when { try $0.tryGenerate(.signature(message: .any, ed25519SecretKey: .any)) }
                .thenReturn(Authentication.Signature.standard(signature: Array("TestSignature".data(using: .utf8)!)))
            try await mockCrypto
                .when { $0.verify(.signature(message: .any, publicKey: .any, signature: .any)) }
                .thenReturn(true)
            try await mockJobRunner
                .when { $0.add(.any, job: .any, initialDependencies: .any) }
                .thenReturn(.mock)

            /// A node that left `H1` alone because a `shorten` asked for a later expiry than it already had - the only case in
            /// which a node includes `unchanged` at all
            try await mockNetwork.defaultInitialSetup(using: dependencies)
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
                .thenReturn(
                    MockNetwork.response(
                        data: [
                            "{\"swarm\":{\"\(TestConstants.edPublicKey)\":{\"updated\":[],",
                            "\"unchanged\":{\"H1\":\(unchangedExpiryMs)},\"expiry\":1234567999000,",
                            "\"signature\":\"\(Data("TestSignature".utf8).base64EncodedString())\"}},",
                            "\"hf\":[2,11],\"t\":0}"
                        ].joined().data(using: .utf8)!
                    )
                )
        }

        // MARK: - an ExpirationUpdateJob
        describe("an ExpirationUpdateJob") {
            // MARK: -- asks the swarm to shorten the expiry only
            it("asks the swarm to shorten the expiry only") {
                /// Without `shorten` the node sets the expiry literally, which can extend a message that should only ever get
                /// sooner, and never reports `unchanged`
                _ = try await ExpirationUpdateJob.run(
                    Job(
                        variant: .expirationUpdate,
                        threadId: "05\(TestConstants.publicKey)",
                        details: ExpirationUpdateJob.Details(serverHashes: ["H1"], expirationTimestampMs: 1234567999000)
                    )!,
                    using: dependencies
                )

                let info = await mockNetwork.verify {
                    try await $0.send(
                        endpoint: MockEndpoint.any,
                        destination: .any,
                        body: .any,
                        category: .any,
                        requestTimeout: .any,
                        overallTimeout: .any
                    )
                }.wasCalled(exactly: 1)
                let body: String? = info?.matchingCalls.first?.parameterSummary

                /// Premise: the captured call is the `expire` request for this message
                expect(body).to(contain("H1"))
                expect(body).to(contain("expiry"))
                expect(body).to(contain("\"shorten\":true"))
            }

            // MARK: -- starts the timer from the expiry the swarm left unchanged
            it("starts the timer from the expiry the swarm left unchanged") {
                /// A message the node would not shorten already expires at the reported time, so its countdown started that
                /// long before - the job works that start time back out and applies it
                _ = try await ExpirationUpdateJob.run(
                    Job(
                        variant: .expirationUpdate,
                        threadId: "05\(TestConstants.publicKey)",
                        details: ExpirationUpdateJob.Details(serverHashes: ["H1"], expirationTimestampMs: 1234567999000)
                    )!,
                    using: dependencies
                )

                let startedAtMs: Double? = try await mockStorage.read { db in
                    try Interaction
                        .filter(Interaction.Columns.serverHash == "H1")
                        .select(.expiresStartedAtMs)
                        .asRequest(of: Double.self)
                        .fetchOne(db)
                }

                expect(startedAtMs).to(equal(Double(unchangedExpiryMs) - (expiresInSeconds * 1000)))
            }
        }
    }
}
