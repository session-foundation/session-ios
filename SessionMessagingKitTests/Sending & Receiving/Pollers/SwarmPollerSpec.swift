// Copyright © 2026 Session Technology Foundation. All rights reserved.

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

            // MARK: -- when a config message fails to merge on the notification extension import path
            context("when a config message fails to merge on the notification extension import path") {
                // MARK: ---- removes the orphan dedupe record so the config message can be reprocessed by a later poll
                it("removes the orphan dedupe record so the config message can be reprocessed by a later poll") {
                    _ = try await fixture.mockStorage.write { db in
                        SwarmPoller.processPollResponse(
                            db,
                            cat: .poller,
                            source: .pushNotification,
                            swarmPublicKey: fixture.userSessionId.hexString,
                            shouldStoreMessages: true,
                            ignoreDedupeFiles: true,
                            forceSynchronousProcessing: true,
                            sortedMessages: [(
                                namespace: .configUserGroups,
                                messages: [fixture.configMessage(hash: "TestConfigHash")],
                                lastHash: nil
                            )],
                            using: fixture.dependencies
                        )
                    }

                    /// The extension created a dedupe file for this config message when it received it, so without removing it the
                    /// message would be dropped as a duplicate on every future poll and the config change would never apply
                    await fixture.mockExtensionHelper
                        .verify {
                            try $0.removeDedupeRecord(
                                threadId: fixture.userSessionId.hexString,
                                uniqueIdentifier: "TestConfigHash"
                            )
                        }
                        .wasCalled(exactly: 1, timeout: .milliseconds(100))
                }
            }

            // MARK: -- when a config message fails to merge on the normal (non-synchronous) poll path
            context("when a config message fails to merge on the normal (non-synchronous) poll path") {
                // MARK: ---- does not remove the dedupe record
                it("does not remove the dedupe record") {
                    _ = try await fixture.mockStorage.write { db in
                        SwarmPoller.processPollResponse(
                            db,
                            cat: .poller,
                            source: .snode(fixture.snode),
                            swarmPublicKey: fixture.userSessionId.hexString,
                            shouldStoreMessages: true,
                            ignoreDedupeFiles: false,
                            forceSynchronousProcessing: false,
                            sortedMessages: [(
                                namespace: .configUserGroups,
                                messages: [fixture.configMessage(hash: "TestConfigHash")],
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

        // MARK: - a swarm poll refreshing config TTLs
        describe("a swarm poll refreshing config TTLs") {
            beforeEach {
                try await fixture.stubPollResponses()
            }

            // MARK: -- sends one extension for two polls inside the cooldown
            it("sends one extension for two polls inside the cooldown") {
                try await fixture.poll(swarm: fixture.userSessionId)
                fixture.advanceTime(by: 30 * 60)
                try await fixture.poll(swarm: fixture.userSessionId)

                expect(fixture.sentPollCount).to(equal(2))
                expect(fixture.sentExtensionCount).to(equal(1))
            }

            // MARK: -- sends another extension once the cooldown has passed
            it("sends another extension once the cooldown has passed") {
                try await fixture.poll(swarm: fixture.userSessionId)
                fixture.advanceTime(by: Network.StorageServer.ConfigTtlExtensionThrottle.cooldown - 1)
                try await fixture.poll(swarm: fixture.userSessionId)
                fixture.advanceTime(by: 1)
                try await fixture.poll(swarm: fixture.userSessionId)

                expect(fixture.sentPollCount).to(equal(3))
                expect(fixture.sentExtensionCount).to(equal(2))
            }

            // MARK: -- does not start the cooldown when the extension fails
            it("does not start the cooldown when the extension fails") {
                fixture.extensionResponseCode = 500
                try await fixture.poll(swarm: fixture.userSessionId)
                fixture.advanceTime(by: 1)
                try await fixture.poll(swarm: fixture.userSessionId)
                expect(fixture.sentExtensionCount).to(equal(2))

                /// Positive control: once one succeeds the next poll is throttled, so the retries above are retries rather
                /// than a throttle that never engages
                fixture.extensionResponseCode = 200
                try await fixture.poll(swarm: fixture.userSessionId)
                try await fixture.poll(swarm: fixture.userSessionId)
                expect(fixture.sentExtensionCount).to(equal(3))
            }

            // MARK: -- does not start the cooldown when the extension response cannot be parsed
            it("does not start the cooldown when the extension response cannot be parsed") {
                fixture.extensionResponseBody = "\"not an expire response\""
                try await fixture.poll(swarm: fixture.userSessionId)
                try await fixture.poll(swarm: fixture.userSessionId)

                expect(fixture.sentExtensionCount).to(equal(2))
            }

            // MARK: -- does not start the cooldown when the whole poll fails
            it("does not start the cooldown when the whole poll fails") {
                fixture.failWholeRequest = true
                await expect { try await fixture.poll(swarm: fixture.userSessionId) }.to(throwError())

                fixture.failWholeRequest = false
                try await fixture.poll(swarm: fixture.userSessionId)
                expect(fixture.sentExtensionCount).to(equal(2))
            }

            // MARK: -- does not hold the cooldown open when the clock moves backwards
            it("does not hold the cooldown open when the clock moves backwards") {
                try await fixture.poll(swarm: fixture.userSessionId)
                fixture.advanceTime(by: -(24 * 60 * 60))
                try await fixture.poll(swarm: fixture.userSessionId)

                expect(fixture.sentExtensionCount).to(equal(2))
            }

            // MARK: -- tracks the cooldown per swarm
            it("tracks the cooldown per swarm") {
                try await fixture.poll(swarm: fixture.groupId)
                try await fixture.poll(swarm: fixture.otherGroupId)
                try await fixture.poll(swarm: fixture.userSessionId)
                try await fixture.poll(swarm: fixture.groupId)

                expect(fixture.sentPollCount).to(equal(4))
                expect(fixture.sentExtensionCount).to(equal(3))
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
    var mockLibSessionCache: MockLibSessionCache { mock(cache: .libSession) }
    var mockNetwork: MockNetwork { mock(for: .network) }

    let groupId: SessionId = SessionId(
        .group,
        hex: "03cbd569f56fb13ea95a3f0c05c331cc24139c0090feb412069dc49fab34406ece"
    )
    let otherGroupId: SessionId = SessionId(
        .group,
        hex: "03aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    )
    let userSessionId: SessionId = SessionId(.standard, hex: TestConstants.publicKey)
    let snode: LibSession.Snode = LibSession.Snode(
        ed25519PubkeyHex: TestConstants.edPublicKey,
        ip: "1.1.1.1",
        httpsPort: 10,
        quicPort: 1,
        version: "2.11.0",
        swarmId: 1
    )

    static func create() async throws -> SwarmPollerTestFixture {
        let fixture: SwarmPollerTestFixture = SwarmPollerTestFixture()
        try await fixture.applyBaselineStubs()

        return fixture
    }

    // MARK: - Config TTL refresh

    var extensionResponseCode: Int = 200
    var extensionResponseBody: String = #"{"swarm":{},"hf":[2,11],"t":1234567890000}"#
    var failWholeRequest: Bool = false
    @ThreadSafeObject private var sentBatchBodies: [Data] = []

    var sentPollCount: Int { sentBatchBodies.count }
    var sentExtensionCount: Int {
        sentBatchBodies.filter { body in
            guard
                let json: [String: Any] = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                let requests: [[String: Any]] = json["requests"] as? [[String: Any]]
            else { return false }

            return requests.contains { ($0["method"] as? String) == Network.StorageServer.Endpoint.expire.path }
        }.count
    }

    func advanceTime(by interval: TimeInterval) {
        dependencies.dateNow = dependencies.dateNow.addingTimeInterval(interval)
    }

    func poll(swarm: SessionId) async throws {
        _ = try await Network.StorageServer.poll(
            namespaces: [.configUserProfile],
            lastHashes: [:],
            refreshingConfigHashes: ["TestConfigHash1", "TestConfigHash2"],
            updateExpiryDates: { _, _ in },
            from: snode,
            authMethod: SignedAuthenticationMethod(info: .standard(sessionId: swarm, ed25519PublicKey: [1, 2, 3])),
            using: dependencies
        )
    }

    func stubPollResponses() async throws {
        try await mockNetwork.defaultInitialSetup(using: dependencies)
        await mockNetwork.removeRequestMocks()
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
            .thenReturn { [weak self] args -> (info: ResponseInfoType, value: Data?) in
                guard let self, let body: Data = args[2] as? Data else {
                    return (MockResponseInfo.mock, nil)
                }

                self._sentBatchBodies.performUpdate { $0 + [body] }

                if self.failWholeRequest {
                    return (MockResponseInfo(requestData: .mock, code: 502, headers: [:]), nil)
                }

                let getMessagesResponse: String = #"{"code":200,"body":{"messages":[],"more":false,"hf":[2,11],"t":1234567890000}}"#
                let includesExtension: Bool = String(data: body, encoding: .utf8)?
                    .contains(#""method":"\#(Network.StorageServer.Endpoint.expire.path)""#) == true
                let subResponses: [String] = (includesExtension ?
                    [#"{"code":\#(self.extensionResponseCode),"body":\#(self.extensionResponseBody)}"#, getMessagesResponse] :
                    [getMessagesResponse]
                )

                return (MockResponseInfo.mock, "[\(subResponses.joined(separator: ","))]".data(using: .utf8))
            }
    }

    // MARK: - Convenience

    func configMessage(hash: String) -> Network.StorageServer.Message {
        return Network.StorageServer.Message(
            snode: nil,
            publicKey: userSessionId.hexString,
            namespace: .configUserGroups,
            rawMessage: Network.StorageServer.GetMessagesResponse.RawMessage(
                base64EncodedDataString: Data([1, 2, 3]).base64EncodedString(),
                expirationMs: nil,
                hash: hash,
                timestampMs: 1234567890
            )
        )!
    }

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
        try await mockExtensionHelper
            .when { try $0.createDedupeRecord(threadId: .any, uniqueIdentifier: .any) }
            .thenReturn(())
        try await mockExtensionHelper
            .when { $0.dedupeRecordExists(threadId: .any, uniqueIdentifier: .any) }
            .thenReturn(false)

        /// Force the config merge to fail (as it would when the config data can't be applied)
        try await mockLibSessionCache.defaultInitialSetup()
        try await mockLibSessionCache
            .when { try $0.handleConfigMessages(.any, swarmPublicKey: .any, messages: .any) }
            .thenThrow(TestError.mock)
    }
}

// MARK: - SignedAuthenticationMethod

/// Signs with fixed bytes so a poll can be built without stubbing crypto; nothing in these specs verifies the signature
private struct SignedAuthenticationMethod: AuthenticationMethod {
    let info: Authentication.Info

    func generateSignature(with verificationBytes: [UInt8], using dependencies: Dependencies) throws -> Authentication.Signature {
        return .standard(signature: Array(repeating: 1, count: 64))
    }
}
