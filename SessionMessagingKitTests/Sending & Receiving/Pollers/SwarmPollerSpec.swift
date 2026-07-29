// Copyright © 2026 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import Quick
import Nimble
import SessionUtil
import SessionUtilitiesKit
import TestUtilities

@testable import SessionNetworkingKit
@testable import SessionMessagingKit

class SwarmPollerSpec: AsyncSpec {
    override class func spec() {
        @TestState var fixture: SwarmPollerTestFixture!

        beforeEach {
            fixture = try await SwarmPollerTestFixture.create()
        }

        // MARK: - a SwarmPoller processing a poll response
        describe("a SwarmPoller processing a poll response") {
            // MARK: -- when a message fails to process on the notification extension import path
            context("when a message fails to process on the notification extension import path") {
                // MARK: ---- removes the orphan dedupe record so the message can be reprocessed by a later poll
                it("removes the orphan dedupe record so the message can be reprocessed by a later poll") {
                    _ = try await fixture.mockStorage.write { db in
                        SwarmPoller.processPollResponse(
                            db,
                            cat: .poller,
                            source: .pushNotification,
                            swarmPublicKey: fixture.groupId.hexString,
                            shouldStoreMessages: true,
                            ignoreDedupeFiles: true,
                            forceSynchronousProcessing: true,
                            sortedMessages: [(
                                namespace: .groupMessages,
                                messages: [fixture.message(hash: "TestHash")],
                                lastHash: nil
                            )],
                            using: fixture.dependencies
                        )
                    }

                    await fixture.mockExtensionHelper
                        .verify {
                            try $0.removeDedupeRecord(
                                threadId: fixture.groupId.hexString,
                                uniqueIdentifier: "TestHash"
                            )
                        }
                        .wasCalled(exactly: 1, timeout: .milliseconds(100))
                }
            }

            // MARK: -- when a message fails to process on the normal (non-synchronous) poll path
            context("when a message fails to process on the normal (non-synchronous) poll path") {
                // MARK: ---- does not remove the dedupe record
                it("does not remove the dedupe record") {
                    _ = try await fixture.mockStorage.write { db in
                        SwarmPoller.processPollResponse(
                            db,
                            cat: .poller,
                            source: .pushNotification,
                            swarmPublicKey: fixture.groupId.hexString,
                            shouldStoreMessages: true,
                            ignoreDedupeFiles: false,
                            forceSynchronousProcessing: false,
                            sortedMessages: [(
                                namespace: .groupMessages,
                                messages: [fixture.message(hash: "TestHash")],
                                lastHash: nil
                            )],
                            using: fixture.dependencies
                        )
                    }

                    await fixture.mockExtensionHelper
                        .verify { try $0.removeDedupeRecord(threadId: .any, uniqueIdentifier: .any) }
                        .wasNotCalled(timeout: .milliseconds(100))
                }
            }
        }
    }
}

// MARK: - SwarmPollerTestFixture

private class SwarmPollerTestFixture: FixtureBase {
    var mockStorage: Storage {
        mock(for: .storage) { dependencies in
            try! Storage.createForTesting(using: dependencies)
        }
    }
    var mockCrypto: MockCrypto { mock(for: .crypto) }
    var mockExtensionHelper: MockExtensionHelper { mock(for: .extensionHelper) }
    var mockGeneralCache: MockGeneralCache { mock(cache: .general) }

    let groupId: SessionId = SessionId(
        .group,
        hex: "03cbd569f56fb13ea95a3f0c05c331cc24139c0090feb412069dc49fab34406ece"
    )

    static func create() async throws -> SwarmPollerTestFixture {
        let fixture: SwarmPollerTestFixture = SwarmPollerTestFixture()
        try await fixture.applyBaselineStubs()

        return fixture
    }

    // MARK: - Convenience

    func message(hash: String) -> Network.StorageServer.Message {
        return Network.StorageServer.Message(
            snode: nil,
            publicKey: groupId.hexString,
            namespace: .groupMessages,
            rawMessage: Network.StorageServer.GetMessagesResponse.RawMessage(
                base64EncodedDataString: Data([1, 2, 3]).base64EncodedString(),
                expirationMs: nil,
                hash: hash,
                timestampMs: 1234567890
            )
        )!
    }

    // MARK: - Setup

    private func applyBaselineStubs() async throws {
        try await mockStorage.perform(migrations: SNMessagingKit.migrations)
        try await mockStorage.write { db in
            try Identity(variant: .x25519PublicKey, data: Data(hex: TestConstants.publicKey)).insert(db)
            try Identity(variant: .ed25519SecretKey, data: Data(hex: TestConstants.edSecretKey)).insert(db)
        }

        try await mockGeneralCache
            .when { $0.sessionId }
            .thenReturn(SessionId(.standard, hex: TestConstants.publicKey))
        try await mockGeneralCache
            .when { $0.ed25519SecretKey }
            .thenReturn(Array(Data(hex: TestConstants.edSecretKey)))

        /// Force message parsing to fail (as it would when the group keys haven't synced into the main app yet)
        try await mockCrypto
            .when {
                try $0.tryGenerate(
                    .decodedMessage(
                        encodedMessage: Data.any,
                        origin: .swarm(
                            publicKey: .any,
                            namespace: .groupMessages,
                            serverHash: .any,
                            serverTimestampMs: .any,
                            serverExpirationTimestamp: .any
                        )
                    )
                )
            }
            .thenThrow(CryptoError.invalidKey)

        try await mockExtensionHelper
            .when { try $0.removeDedupeRecord(threadId: .any, uniqueIdentifier: .any) }
            .thenReturn(())
    }
}
