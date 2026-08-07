// Copyright © 2026 Session Technology Foundation. All rights reserved.

import Foundation
import UIKit
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

        // MARK: - a SwarmPoller deciding whether local state is level with the swarm
        ///
        /// Config recovery will not re-store anything until this is established, so getting it wrong in either direction
        /// breaks the feature silently: too strict and recovery never runs, too loose and a device can re-store over state
        /// it hasn't seen yet.
        ///
        /// Deliberately driven through the **real poll path** rather than by calling the recovery cache directly - supplying
        /// the precondition in test setup is exactly what would hide the defect these two cover.
        describe("a SwarmPoller deciding whether local state is level with the swarm") {
            // MARK: -- when every namespace answered with no messages
            context("when every namespace answered with no messages") {
                // MARK: ---- V22 treats the local state as level with the swarm
                it("V22 treats the local state as level with the swarm") {
                    try await fixture.stubPoll(namespacesAnswer: .allSucceededEmpty)

                    /// Not `try?` - if the poll fails, the flag would be unset for the wrong reason and this test would be
                    /// asserting nothing
                    _ = try await require { try await fixture.poller.poll(forceSynchronousProcessing: false) }
                        .toNot(throwError())

                    await expect { await fixture.recoveryStore.localStateIsLevelWithSwarm(swarmPublicKey: fixture.userSwarm) }
                        .to(beTrue())
                }
            }

            // MARK: -- when every namespace failed
            context("when every namespace failed") {
                // MARK: ---- V22a does not treat the local state as level with the swarm
                it("V22a does not treat the local state as level with the swarm") {
                    /// A failed retrieve is dropped from the response entirely, so this arrives with the same message count
                    /// as a swarm that genuinely holds nothing. It tells us nothing about swarm state, and treating it as
                    /// "level" would let recovery run on the strength of a total failure
                    try await fixture.stubPoll(namespacesAnswer: .allFailed)

                    /// Not `try?` - a poll that threw would leave the flag unset too, so swallowing the error would make
                    /// this assertion meaningless
                    _ = try await require { try await fixture.poller.poll(forceSynchronousProcessing: false) }
                        .toNot(throwError())

                    await expect { await fixture.recoveryStore.localStateIsLevelWithSwarm(swarmPublicKey: fixture.userSwarm) }
                        .to(beFalse())
                }
            }

            // MARK: -- when a failed poll is followed by a clean one
            context("when a failed poll is followed by a clean one") {
                // MARK: ---- V22e treats the local state as level, because a failed poll lost no information
                it("V22e treats the local state as level, because a failed poll lost no information") {
                    /// The narrowing that keeps the incomplete-merge stickiness honest: a failed fetch must **not** withdraw
                    /// the swarm for the session. Nothing was consumed - the read cursor never moved - so a later successful
                    /// poll is free to establish that we're level.
                    ///
                    /// Only an incomplete *merge* is sticky, and only because that one advances the cursor past a message it
                    /// then fails to take in. Without this test, widening the stickiness to "any not-level verdict" would pass
                    /// every other vector while disabling recovery for a session over a single network blip
                    try await fixture.stubPoll(namespacesAnswer: .allFailed)
                    _ = try await require { try await fixture.poller.poll(forceSynchronousProcessing: false) }
                        .toNot(throwError())

                    await expect { await fixture.recoveryStore.localStateIsLevelWithSwarm(swarmPublicKey: fixture.userSwarm) }
                        .to(beFalse())

                    try await fixture.stubPoll(namespacesAnswer: .allSucceededEmpty)
                    _ = try await require { try await fixture.poller.poll(forceSynchronousProcessing: false) }
                        .toNot(throwError())

                    await expect { await fixture.recoveryStore.localStateIsLevelWithSwarm(swarmPublicKey: fixture.userSwarm) }
                        .to(beTrue())
                }
            }

            // MARK: -- when recovery has work and it fails
            context("when recovery has work and it fails") {
                // MARK: ---- V13f completes the poll normally regardless
                it("V13f completes the poll normally regardless") {
                    /// Recovery is a best-effort repair that RIDES ON the poll, so it must never be able to fail the thing it
                    /// depends on - a recovery step that stops polling removes its own precondition and takes everything else
                    /// polling does with it (messages, merges, the failure counter).
                    ///
                    /// On iOS the escape route is closed by the type system rather than by a catch: `recoverIfNeeded` and
                    /// `applyKeysVerdictIfNeeded` are `async` **without** `throws`, so the call sites below compile without
                    /// `try` and the compiler guarantees nothing propagates. `configRecoveryData` is likewise non-throwing in
                    /// the protocol, so not even a mock can throw from the inspection. This asserts the observable half:
                    /// recovery genuinely running and failing leaves the poll intact
                    try await fixture.stubPoll(namespacesAnswer: .allSucceededEmpty)
                    try await fixture.mockAppContext
                        .when { $0.reportedApplicationState }
                        .thenReturn(UIApplication.State.active)
                    try await fixture.mockLibSessionCache
                        .when { $0.configRecoveryData(swarmPublicKey: .any, missingHashes: .any) }
                        .thenReturn(
                            LibSession.ConfigRecoveryInspection(
                                data: [
                                    LibSession.ConfigRecoveryData(
                                        variant: .userProfile,
                                        missingHashes: ["H2"],
                                        allHashes: ["H2"],
                                        data: [Data([1, 2, 3])],
                                        seqNo: 1,
                                        obsoleteHashes: []
                                    )
                                ]
                            )
                        )

                    /// Give recovery something to do, and a swarm it believes it is level with
                    await fixture.recoveryStore.markLocalStateLevelWithSwarm(swarmPublicKey: fixture.userSwarm)


                    /// The poll itself must still succeed - the store inside recovery will not, since the stubbed response
                    /// shape belongs to the retrieve
                    _ = try await require { try await fixture.poller.poll(forceSynchronousProcessing: false) }
                        .toNot(throwError())

                    /// And the hash stays retryable rather than being spent on a round that never reached the swarm
                    await expect { await fixture.recoveryStore.hashesEligibleForRecovery(["H2"], now: fixture.dependencies.dateNow) }
                        .to(equal(["H2"]))
                }
            }

            // MARK: -- when only some namespaces answered
            context("when only some namespaces answered") {
                // MARK: ---- V22b does not treat the local state as level with the swarm
                it("V22b does not treat the local state as level with the swarm") {
                    /// A partial answer leaves us ignorant about the namespaces which didn't reply, so it can't establish
                    /// that we're up to date either
                    try await fixture.stubPoll(namespacesAnswer: .firstConfigNamespaceFailed)

                    /// Not `try?` - a poll that threw would leave the flag unset too, so swallowing the error would make
                    /// this assertion meaningless
                    _ = try await require { try await fixture.poller.poll(forceSynchronousProcessing: false) }
                        .toNot(throwError())

                    await expect { await fixture.recoveryStore.localStateIsLevelWithSwarm(swarmPublicKey: fixture.userSwarm) }
                        .to(beFalse())
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
    var mockNetwork: MockNetwork { mock(for: .network) }
    var mockAppContext: MockAppContext { mock(for: .appContext) }
    var mockLibSessionCache: MockLibSessionCache { mock(cache: .libSession) }

    let groupId: SessionId = SessionId(
        .group,
        hex: "03cbd569f56fb13ea95a3f0c05c331cc24139c0090feb412069dc49fab34406ece"
    )
    var userSwarm: String { SessionId(.standard, hex: TestConstants.publicKey).hexString }

    /// A real cache rather than a mock, since these tests are about the value it ends up holding
    ///
    /// **Registered eagerly in `applyBaselineStubs`, deliberately.** This was previously a `lazy var` whose initialiser
    /// registered it as a side effect, which meant whether the fixture was correctly wired depended on *where the first
    /// property access happened* - a test that read it midway through repaired itself for the rest of its body, and one that
    /// only read it at the end silently asserted against a different instance than the poller had mutated
    let recoveryStore: ConfigRecovery.Store = ConfigRecovery.Store()

    lazy var poller: CurrentUserPoller = CurrentUserPoller(
        pollerName: "TestPoller",
        destination: .swarm(userSwarm),
        swarmDrainStrategy: .limitedReuse(count: 6),
        namespaces: CurrentUserPoller.namespaces,
        shouldStoreMessages: true,
        logStartAndStopCalls: false,
        key: nil,
        using: dependencies
    )

    enum NamespacesAnswer {
        /// Every namespace replied, and none of them had anything for us
        case allSucceededEmpty

        /// Every retrieve errored - which arrives with the same message count as `allSucceededEmpty`
        case allFailed

        /// One config namespace errored while the rest replied
        case firstConfigNamespaceFailed
    }

    static func create() async throws -> SwarmPollerTestFixture {
        let fixture: SwarmPollerTestFixture = SwarmPollerTestFixture()
        try await fixture.applyBaselineStubs()

        return fixture
    }

    // MARK: - Convenience

    /// Stub everything a real `poll()` needs, with the retrieve sub-responses shaped by `namespacesAnswer`
    ///
    /// No config hashes are held, so no `expire` sub-request is built - these tests are about the "is our state level with
    /// the swarm" decision, which is made from the retrieve responses alone
    func stubPoll(namespacesAnswer: NamespacesAnswer) async throws {

        /// First, so the `send` stub below replaces the throwing default
        try await mockNetwork.defaultInitialSetup(using: dependencies)

        try await mockAppContext.when { $0.reportedApplicationState }.thenReturn(UIApplication.State.background)
        try await mockGeneralCache.when { $0.userExists }.thenReturn(true)
        try await mockGeneralCache.when { $0.ed25519Seed }.thenReturn(Array(Data(hex: TestConstants.edKeySeed)))
        try await mockLibSessionCache.when { $0.activeHashesByVariant(for: .any) }.thenReturn([:])
        try await mockLibSessionCache.when { $0.recoverableKeysHashes(for: .any) }.thenReturn([])
        try await mockLibSessionCache.when { $0.activeHashes(for: .any) }.thenReturn([])
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
            .thenReturn(
                Authentication.Signature.standard(signature: Array("TestSignature".data(using: .utf8)!))
            )

        let namespaces: [Network.StorageServer.Namespace] = CurrentUserPoller.namespaces
        let emptyRetrieve: Data = [
            "{\"code\":200,\"headers\":{},\"body\":",
            "{\"messages\":[],\"more\":false,\"hf\":[2,11],\"t\":0}}"
        ].joined().data(using: .utf8)!
        /// A sub-response the poll can't extract a body from, which is how a failed retrieve arrives
        let failedRetrieve: Data = "{\"code\":500,\"headers\":{}}".data(using: .utf8)!
        let bodies: [Data] = namespaces.enumerated().map { index, namespace in
            switch namespacesAnswer {
                case .allSucceededEmpty: return emptyRetrieve
                case .allFailed: return failedRetrieve
                case .firstConfigNamespaceFailed:
                    return (namespace.isConfigNamespace && index == 1 ? failedRetrieve : emptyRetrieve)
            }
        }

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
                /// The **storage server** shape (`{"results": […]}`), not the bare array SOGS returns - these tests drive a
                /// swarm poll, and `decodingResponses` takes a different branch for each, so the bare form would exercise a
                /// branch this path never reaches
                MockNetwork.storageServerBatchResponseData(
                    with: zip(namespaces, bodies).map { namespace, body in
                        (endpoint: Network.StorageServer.Endpoint.getMessages, data: body)
                    }
                )
            )
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
        dependencies.set(singleton: .configRecovery, to: recoveryStore)

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
