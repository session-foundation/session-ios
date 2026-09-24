// Copyright © 2026 Session Technology Foundation. All rights reserved.

import Foundation
import GRDB
import Quick
import Nimble
import SessionUtil
import TestUtilities

@testable import SessionUtilitiesKit
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

        // MARK: - a SwarmPoller whose swarm's cursor is reset during a poll
        ///
        /// A reset asks the next poll of the swarm to fetch from the beginning - on promotion to admin, and on removal from a
        /// group. A poll already in flight finishes afterwards and would store the newest hash it received as the cursor,
        /// undoing the reset so the history is never fetched. Driven through a real group poll, with the reset performed by
        /// the production reset functions at the moment named in each case
        describe("a SwarmPoller whose swarm's cursor is reset during a poll") {
            // MARK: -- when nothing resets the cursor
            context("when nothing resets the cursor") {
                // MARK: ---- stores the newest hash it received as the cursor
                it("stores the newest hash it received as the cursor") {
                    try await fixture.stubCursorPoll(hashes: ["H1", "H2"], resetWhileRetrieving: nil)

                    _ = try await require { try await fixture.groupPoller.poll(forceSynchronousProcessing: false) }
                        .toNot(throwError())

                    await expect { try await fixture.cursor() }.to(equal("H2"))
                }
            }

            // MARK: -- when the cursor is reset while the retrieve is in flight
            context("when the cursor is reset while the retrieve is in flight") {
                // MARK: ---- leaves the cursor reset
                it("leaves the cursor reset") {
                    /// The promotion reset, which keeps the records and marks them invalid
                    try await fixture.storeCursor("H0")
                    try await fixture.stubCursorPoll(hashes: ["H1", "H2"]) { db in
                        try SnodeReceivedMessageInfo.invalidateCursor(
                            db,
                            swarmPublicKey: fixture.groupId.hexString,
                            namespace: .configGroupInfo,
                            using: fixture.dependencies
                        )
                    }

                    _ = try await require { try await fixture.groupPoller.poll(forceSynchronousProcessing: false) }
                        .toNot(throwError())

                    /// Premise: the reset ran, during the retrieve
                    expect(fixture.resetRan).to(beTrue())
                    await expect { try await fixture.cursor() }.to(beNil())
                }
            }

            // MARK: -- when the cursor was already empty and is reset while the retrieve is in flight
            context("when the cursor was already empty and is reset while the retrieve is in flight") {
                // MARK: ---- leaves the cursor reset
                it("leaves the cursor reset") {
                    /// The cursor reads the same before and after this reset, so a check comparing cursor values passes it and
                    /// the poll stores its hash
                    try await fixture.stubCursorPoll(hashes: ["H1", "H2"]) { db in
                        try SnodeReceivedMessageInfo.deleteCursor(
                            db,
                            swarmPublicKey: fixture.groupId.hexString,
                            using: fixture.dependencies
                        )
                    }

                    _ = try await require { try await fixture.groupPoller.poll(forceSynchronousProcessing: false) }
                        .toNot(throwError())

                    expect(fixture.resetRan).to(beTrue())
                    await expect { try await fixture.cursor() }.to(beNil())
                }
            }

            // MARK: -- when the cursor is reset inside the poll's own write, after its cursor check and before it stores a hash
            context("when the cursor is reset inside the poll's own write, after its cursor check and before it stores a hash") {
                // MARK: ---- leaves the cursor reset
                it("leaves the cursor reset") {
                    /// The last point a reset can land before the poll's cursor write: inside the same write transaction, after
                    /// the poll's check that its cursors still match what it sent, and before it stores a hash. The check at
                    /// the start of the write passes here - the cursor is still `H0` - so only a check made at the write
                    /// itself can see the reset.
                    ///
                    /// The promotion reset on the messages namespace, from the message decode that precedes the cursor write.
                    /// The decode reports the message as outdated, which is one of the outcomes that still stores its hash
                    try await fixture.storeCursor("H0", namespace: .groupMessages)
                    try await fixture.stubCursorPoll(namespace: .groupMessages, hashes: ["H1", "H2"], resetWhileRetrieving: nil)
                    try await fixture.resetInsideTheWriteBeforeFirstCursorWrite { db in
                        try SnodeReceivedMessageInfo.invalidateCursor(
                            db,
                            swarmPublicKey: fixture.groupId.hexString,
                            namespace: .groupMessages,
                            using: fixture.dependencies
                        )
                    }

                    _ = try await require {
                        try await fixture.groupPoller(namespace: .groupMessages).poll(forceSynchronousProcessing: false)
                    }.toNot(throwError())

                    expect(fixture.resetRan).to(beTrue())
                    await expect { try await fixture.cursor(namespace: .groupMessages) }.to(beNil())
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
    var mockLibSessionCache: MockLibSessionCache { mock(cache: .libSession) }
    var mockNetwork: MockNetwork { mock(for: .network) }

    let groupId: SessionId = SessionId(
        .group,
        hex: "03cbd569f56fb13ea95a3f0c05c331cc24139c0090feb412069dc49fab34406ece"
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

    // MARK: - Cursor resets

    var resetRan: Bool { lock.withLock { _resetRan } }
    private var _resetRan: Bool = false
    private let lock: NSLock = NSLock()

    /// A group poll of `groupId`'s info config namespace alone
    ///
    /// A config namespace because its messages are stored without decrypting them, so the cursor write happens for a stub
    /// payload. Not storing messages, so no jobs are queued - the cursor write comes before that decision and does not
    /// depend on it. `groupPoller(namespace:)` polls one other namespace the same way
    lazy var groupPoller: GroupPoller = groupPoller(namespace: .configGroupInfo)

    func groupPoller(namespace: Network.StorageServer.Namespace) -> GroupPoller {
        return GroupPoller(
            pollerName: "TestGroupPoller",
            destination: .swarm(groupId.hexString),
            swarmDrainStrategy: .limitedReuse(count: 6),
            namespaces: [namespace],
            failureCount: 0,
            numConsecutiveEmptyPolls: 0,
            shouldStoreMessages: false,
            logStartAndStopCalls: false,
            customAuthMethod: Authentication.groupAdmin(
                groupSessionId: groupId,
                ed25519SecretKey: Array(Data(hex: TestConstants.edSecretKey))
            ),
            key: nil,
            using: dependencies
        )
    }

    /// The cursor the next poll of `groupId`'s `namespace` would send
    func cursor(namespace: Network.StorageServer.Namespace = .configGroupInfo) async throws -> String? {
        return try await mockStorage.read { [snode, groupId, dependencies] db in
            try SnodeReceivedMessageInfo.fetchLastNotExpired(
                db,
                for: snode,
                namespace: namespace,
                swarmPublicKey: groupId.hexString,
                using: dependencies
            )?.hash
        }
    }

    func storeCursor(_ hash: String, namespace: Network.StorageServer.Namespace = .configGroupInfo) async throws {
        try await mockStorage.write { [snode, groupId] db in
            _ = SnodeReceivedMessageInfo(
                snode: snode,
                swarmPublicKey: groupId.hexString,
                namespace: namespace,
                hash: hash,
                expirationDateMs: 9999999999999
            ).storeUpdatedLastHash(db)
        }
    }

    /// Stub a poll whose retrieve returns `hashes`, running `resetWhileRetrieving` in its own write transaction while the
    /// retrieve is in flight - after the poll has read its cursor, before it has the response
    func stubCursorPoll(
        namespace: Network.StorageServer.Namespace = .configGroupInfo,
        hashes: [String],
        resetWhileRetrieving: ((ObservingDatabase) throws -> Void)?
    ) async throws {
        try await mockNetwork.defaultInitialSetup(using: dependencies)
        try await mockNetwork
            .when { try await $0.getSwarm(for: .any, ignoreStrikeCount: .any) }
            .thenReturn([snode])
        try await mockGeneralCache.when { $0.userExists }.thenReturn(true)
        try await mockLibSessionCache.when { $0.activeHashes(for: .any) }.thenReturn([])
        try await mockCrypto
            .when { try $0.tryGenerate(.signature(message: .any, ed25519SecretKey: .any)) }
            .thenReturn(Authentication.Signature.standard(signature: Array("TestSignature".data(using: .utf8)!)))

        let items: String = hashes
            .map { hash in
                [
                    "{\"data\":\"\(Data([1, 2, 3]).base64EncodedString())\",\"expiration\":9999999999999,",
                    "\"hash\":\"\(hash)\",\"timestamp\":1234567890}"
                ].joined()
            }
            .joined(separator: ",")
        /// The storage server's batch shape, `{"results": […]}` - not the bare array SOGS returns, which the batch decoder
        /// takes a different branch for
        let response: (ResponseInfoType, Data?) = MockNetwork.response(
            data: [
                "{\"results\":[{\"code\":200,\"headers\":{},\"body\":{\"messages\":[\(items)],",
                "\"more\":false,\"hf\":[2,11],\"t\":0}}]}"
            ].joined().data(using: .utf8)!
        )

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
            .thenReturn { [weak self, mockStorage, dependencies] _ in
                if let reset = resetWhileRetrieving {
                    /// Synchronously and in its own transaction: the poll holds none while its retrieve is out
                    try? mockStorage.syncState.testDbWriter?.write { db in
                        try reset(ObservingDatabase.create(db, using: dependencies))
                    }
                    self?.lock.withLock { self?._resetRan = true }
                }

                return response
            }
    }

    /// Run `reset` inside the poll's own write transaction, from the decode of the first message in the messages namespace -
    /// which comes after the poll's check that its cursors are unchanged, and before it stores that message's hash
    func resetInsideTheWriteBeforeFirstCursorWrite(_ reset: @escaping (ObservingDatabase) throws -> Void) async throws {
        var decodes: Int = 0

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
            .then { [weak self, mockStorage, dependencies] _ in
                decodes += 1
                guard decodes == 1 else { return }

                /// Re-entrant because this runs inside the poll's write, on the writer's queue
                try? mockStorage.syncState.testDbWriter?.unsafeReentrantWrite { db in
                    try reset(ObservingDatabase.create(db, using: dependencies))
                }
                self?.lock.withLock { self?._resetRan = true }
            }
            .thenThrow(MessageError.outdatedMessage)
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
