// Copyright © 2026 Session Technology Foundation. All rights reserved.

import Foundation
import GRDB
import Quick
import Nimble
import SessionUtilitiesKit
import TestUtilities

@testable import SessionNetworkingKit
@testable import SessionMessagingKit

class UnsupportedMessageSpec: AsyncSpec {
    override class func spec() {
        @TestState var fixture: UnsupportedMessageTestFixture!

        beforeEach {
            fixture = try await UnsupportedMessageTestFixture.create()
        }

        // MARK: - an UnsupportedMessage
        describe("an UnsupportedMessage") {
            // MARK: -- when scanning top-level protobuf fields
            context("when scanning top-level protobuf fields") {
                // MARK: ---- returns the field numbers in order
                it("returns the field numbers in order") {
                    let content: Data = try fixture.content(body: "Test", unknownFieldNumber: 19)

                    expect(UnsupportedMessage.topLevelFieldNumbers(in: content)).to(equal([1, 15, 19]))
                }

                // MARK: ---- returns nil for a truncated length-delimited field
                it("returns nil for a truncated length-delimited field") {
                    expect(UnsupportedMessage.topLevelFieldNumbers(in: Data([0x0A, 0x05, 0x01]))).to(beNil())
                }

                // MARK: ---- treats fields up to 18 as known
                it("treats fields up to 18 as known") {
                    /// Field 18 (`msgId`) is a metadata field newer clients add alongside known types
                    let content: Data = try fixture.content(body: "Test", unknownFieldNumber: 18)

                    expect(UnsupportedMessage.containsUnknownContentType(content)).to(beFalse())
                    expect(UnsupportedMessage.containsUnknownContentType(
                        try fixture.content(body: "Test", unknownFieldNumber: 19)
                    )).to(beTrue())
                }
            }

            // MARK: -- when parsing a one-to-one message starting with a zero byte
            context("when parsing a one-to-one message starting with a zero byte") {
                // MARK: ---- returns a newer format message without decrypting
                it("returns a newer format message without decrypting") {
                    let processedMessage: ProcessedMessage = try MessageReceiver.parse(
                        data: fixture.newerFormatData,
                        origin: fixture.origin(namespace: .default),
                        using: fixture.dependencies
                    )
                    let message: UnsupportedMessage? = processedMessage.unsupportedMessage

                    expect(message?.kind).to(equal(.newerFormat))
                    expect(message?.placement).to(equal(UnsupportedMessage.Placement.none))
                    expect(message?.rawData).to(equal(fixture.newerFormatData))
                    expect(processedMessage.threadId).to(equal(fixture.userSessionId.hexString))
                    await fixture.mockCrypto
                        .verify {
                            try $0.tryGenerate(.decodedMessage(
                                encodedMessage: Data.any,
                                origin: .swarm(
                                publicKey: .any,
                                namespace: .default,
                                serverHash: .any,
                                serverTimestampMs: .any,
                                serverExpirationTimestamp: .any
                            )
                            ))
                        }
                        .wasNotCalled()
                }

                // MARK: ---- does not treat a group message as a newer format
                it("does not treat a group message as a newer format") {
                    /// Group messages are symmetrically encrypted so can legitimately start with any byte
                    try await fixture.mockCrypto
                        .when {
                            try $0.tryGenerate(.decodedMessage(
                                encodedMessage: Data.any,
                                origin: .swarm(
                                publicKey: .any,
                                namespace: .groupMessages,
                                serverHash: .any,
                                serverTimestampMs: .any,
                                serverExpirationTimestamp: .any
                            )
                            ))
                        }
                        .thenThrow(CryptoError.invalidKey)

                    expect {
                        try MessageReceiver.parse(
                            data: fixture.newerFormatData,
                            origin: fixture.origin(publicKey: fixture.groupId.hexString, namespace: .groupMessages),
                            using: fixture.dependencies
                        )
                    }.to(throwError(CryptoError.invalidKey))
                }
            }

            // MARK: -- when parsing a decrypted message
            context("when parsing a decrypted message") {
                // MARK: ---- returns an incoming unknown type for an unknown field with no known content
                it("returns an incoming unknown type for an unknown field with no known content") {
                    try await fixture.stubDecoded(content: try fixture.content(body: nil, unknownFieldNumber: 19))

                    let processedMessage: ProcessedMessage = try MessageReceiver.parse(
                        data: fixture.encryptedData,
                        origin: fixture.origin(namespace: .default),
                        using: fixture.dependencies
                    )

                    expect(processedMessage.unsupportedMessage?.kind).to(equal(.unknownType))
                    expect(processedMessage.unsupportedMessage?.placement).to(equal(.incoming))
                    expect(processedMessage.threadId).to(equal(fixture.otherSessionId.hexString))
                }

                // MARK: ---- processes known content normally even with an unknown field
                it("processes known content normally even with an unknown field") {
                    try await fixture.stubDecoded(content: try fixture.content(body: "Test", unknownFieldNumber: 19))

                    let processedMessage: ProcessedMessage = try MessageReceiver.parse(
                        data: fixture.encryptedData,
                        origin: fixture.origin(namespace: .default),
                        using: fixture.dependencies
                    )

                    expect(processedMessage.unsupportedMessage).to(beNil())
                    expect(processedMessage.messageInfo?.message).to(beAKindOf(VisibleMessage.self))
                }

                // MARK: ---- does not treat content without an unknown field as unsupported
                it("does not treat content without an unknown field as unsupported") {
                    try await fixture.stubDecoded(content: try fixture.content(body: nil, unknownFieldNumber: 18))

                    expect {
                        try MessageReceiver.parse(
                            data: fixture.encryptedData,
                            origin: fixture.origin(namespace: .default),
                            using: fixture.dependencies
                        )
                    }.to(throwError())
                }

                // MARK: ---- places a sync from our own device in its sync target as outgoing
                it("places a sync from our own device in its sync target as outgoing") {
                    try await fixture.stubDecoded(
                        content: try fixture.content(
                            body: nil,
                            syncTarget: fixture.otherSessionId.hexString,
                            unknownFieldNumber: 19
                        ),
                        sender: fixture.userSessionId
                    )

                    let processedMessage: ProcessedMessage = try MessageReceiver.parse(
                        data: fixture.encryptedData,
                        origin: fixture.origin(namespace: .default),
                        using: fixture.dependencies
                    )

                    expect(processedMessage.unsupportedMessage?.placement).to(equal(.outgoing))
                    expect(processedMessage.threadId).to(equal(fixture.otherSessionId.hexString))
                }

                // MARK: ---- retains a sync from our own device without a sync target without placing it
                it("retains a sync from our own device without a sync target without placing it") {
                    try await fixture.stubDecoded(
                        content: try fixture.content(body: nil, unknownFieldNumber: 19),
                        sender: fixture.userSessionId
                    )

                    let processedMessage: ProcessedMessage = try MessageReceiver.parse(
                        data: fixture.encryptedData,
                        origin: fixture.origin(namespace: .default),
                        using: fixture.dependencies
                    )

                    expect(processedMessage.unsupportedMessage?.placement).to(equal(UnsupportedMessage.Placement.none))
                }
            }

            // MARK: -- when handled
            context("when handled") {
                // MARK: ---- retains a newer format message without a placeholder and triggers the banner
                it("retains a newer format message without a placeholder and triggers the banner") {
                    try await fixture.handle(
                        try MessageReceiver.parse(
                            data: fixture.newerFormatData,
                            origin: fixture.origin(namespace: .default),
                            using: fixture.dependencies
                        )
                    )

                    let (records, interactionCount, bannerState) = try await fixture.mockStorage.read { db in
                        (
                            try UnsupportedMessageRecord.fetchAll(db),
                            try Interaction.fetchCount(db),
                            UnsupportedMessageBanner.state(db)
                        )
                    }
                    expect(records.map(\.kind)).to(equal([.newerFormat]))
                    expect(records.first?.data).to(equal(fixture.newerFormatData))
                    expect(records.first?.placeholderMessageId).to(beNil())
                    expect(interactionCount).to(equal(0))
                    expect(bannerState).to(equal(.general))
                }

                // MARK: ---- adds a placeholder to an existing conversation
                it("adds a placeholder to an existing conversation") {
                    try await fixture.createThread(id: fixture.otherSessionId.hexString)
                    try await fixture.stubDecoded(content: try fixture.content(body: nil, unknownFieldNumber: 19))
                    try await fixture.handle(
                        try MessageReceiver.parse(
                            data: fixture.encryptedData,
                            origin: fixture.origin(namespace: .default),
                            using: fixture.dependencies
                        )
                    )

                    let (records, interactions, bannerState) = try await fixture.mockStorage.read { db in
                        (
                            try UnsupportedMessageRecord.fetchAll(db),
                            try Interaction.fetchAll(db),
                            UnsupportedMessageBanner.state(db)
                        )
                    }
                    expect(interactions.map(\.variant)).to(equal([.standardIncomingUnsupported]))
                    expect(interactions.first?.timestampMs).to(equal(Int64(fixture.sentTimestampMs)))
                    expect(records.first?.placeholderMessageId).to(equal(interactions.first?.id))
                    expect(bannerState).to(equal(.hidden))
                }

                // MARK: ---- does not create a conversation
                it("does not create a conversation") {
                    try await fixture.stubDecoded(content: try fixture.content(body: nil, unknownFieldNumber: 19))
                    try await fixture.handle(
                        try MessageReceiver.parse(
                            data: fixture.encryptedData,
                            origin: fixture.origin(namespace: .default),
                            using: fixture.dependencies
                        )
                    )

                    let (recordCount, threadCount) = try await fixture.mockStorage.read { db in
                        (try UnsupportedMessageRecord.fetchCount(db), try SessionThread.fetchCount(db))
                    }
                    expect(recordCount).to(equal(1))
                    expect(threadCount).to(equal(0))
                }

                // MARK: ---- removes the retained data when the placeholder is deleted
                it("removes the retained data when the placeholder is deleted") {
                    try await fixture.createThread(id: fixture.otherSessionId.hexString)
                    try await fixture.stubDecoded(content: try fixture.content(body: nil, unknownFieldNumber: 19))
                    try await fixture.handle(
                        try MessageReceiver.parse(
                            data: fixture.encryptedData,
                            origin: fixture.origin(namespace: .default),
                            using: fixture.dependencies
                        )
                    )

                    try await fixture.mockStorage.write { db in
                        let interactionIds: Set<Int64> = Set(try Interaction.select(.id).asRequest(of: Int64.self).fetchAll(db))

                        try Interaction.markAsDeleted(
                            db,
                            threadId: fixture.otherSessionId.hexString,
                            threadVariant: .contact,
                            interactionIds: interactionIds,
                            options: .local,
                            using: fixture.dependencies
                        )
                    }

                    let recordCount: Int = try await fixture.mockStorage.read { db in try UnsupportedMessageRecord.fetchCount(db) }
                    expect(recordCount).to(equal(0))
                }
            }

            // MARK: -- when reprocessed
            context("when reprocessed") {
                beforeEach {
                    try await fixture.createThread(id: fixture.otherSessionId.hexString)
                    try await fixture.stubDecoded(content: try fixture.content(body: nil, unknownFieldNumber: 19))
                    try await fixture.handle(
                        try MessageReceiver.parse(
                            data: fixture.encryptedData,
                            origin: fixture.origin(namespace: .default),
                            using: fixture.dependencies
                        )
                    )
                }

                // MARK: ---- replaces the placeholder in place once the message can be processed
                it("replaces the placeholder in place once the message can be processed") {
                    /// Simulate a newer version which understands the content
                    try await fixture.stubDecoded(content: try fixture.content(body: "Test", unknownFieldNumber: 19))

                    let result: ReprocessUnsupportedMessagesJob.ReprocessResult? = try await fixture.mockStorage.write { db in
                        let recordId: Int64? = try UnsupportedMessageRecord.fetchOne(db)?.id

                        return try recordId.map {
                            try ReprocessUnsupportedMessagesJob.reprocess(
                                db,
                                recordId: $0,
                                currentVersion: "NewVersion",
                                using: fixture.dependencies
                            )
                        }
                    }

                    let (records, interactions) = try await fixture.mockStorage.read { db in
                        (try UnsupportedMessageRecord.fetchAll(db), try Interaction.fetchAll(db))
                    }
                    expect(result).to(equal(.replaced))
                    expect(records).to(beEmpty())
                    expect(interactions.map(\.variant)).to(equal([.standardIncoming]))
                    expect(interactions.first?.body).to(equal("Test"))
                    expect(interactions.first?.timestampMs).to(equal(Int64(fixture.sentTimestampMs)))
                }

                // MARK: ---- keeps the placeholder and records the attempt when still unsupported
                it("keeps the placeholder and records the attempt when still unsupported") {
                    let result: ReprocessUnsupportedMessagesJob.ReprocessResult? = try await fixture.mockStorage.write { db in
                        let recordId: Int64? = try UnsupportedMessageRecord.fetchOne(db)?.id

                        return try recordId.map {
                            try ReprocessUnsupportedMessagesJob.reprocess(
                                db,
                                recordId: $0,
                                currentVersion: "NewVersion",
                                using: fixture.dependencies
                            )
                        }
                    }

                    let (records, interactions) = try await fixture.mockStorage.read { db in
                        (try UnsupportedMessageRecord.fetchAll(db), try Interaction.fetchAll(db))
                    }
                    expect(result).to(equal(.stillUnsupported))
                    expect(records.map(\.lastAttemptVersion)).to(equal(["NewVersion"]))
                    expect(interactions.map(\.variant)).to(equal([.standardIncomingUnsupported]))
                }
            }

            // MARK: -- when enforcing limits
            context("when enforcing limits") {
                // MARK: ---- removes expired records
                it("removes expired records") {
                    let nowMs: Int64 = await fixture.dependencies.networkOffsetTimestampMs()

                    try await fixture.mockStorage.write { db in
                        var expired: UnsupportedMessageRecord = fixture.record(hash: "expired", expiresAtMs: nowMs - 1)
                        var current: UnsupportedMessageRecord = fixture.record(hash: "current", expiresAtMs: nowMs + 1000)
                        var noExpiry: UnsupportedMessageRecord = fixture.record(hash: "noExpiry", expiresAtMs: nil)
                        try expired.insert(db)
                        try current.insert(db)
                        try noExpiry.insert(db)

                        try UnsupportedMessageRecord.enforceLimits(db, using: fixture.dependencies)
                    }

                    let hashes: [String] = try await fixture.mockStorage.read { db in
                        try UnsupportedMessageRecord.fetchAll(db).map(\.hash).sorted()
                    }
                    expect(hashes).to(equal(["current", "noExpiry"]))
                }
            }
        }

        // MARK: - an UnsupportedMessageBanner
        describe("an UnsupportedMessageBanner") {
            // MARK: -- is hidden until triggered
            it("is hidden until triggered") {
                expect(UnsupportedMessageBanner.state(triggeredAtMs: nil, otherDeviceTriggeredAtMs: nil, dismissedAtMs: nil))
                    .to(equal(.hidden))
            }

            // MARK: -- uses the other device text when that was a trigger
            it("uses the other device text when that was a trigger") {
                expect(UnsupportedMessageBanner.state(triggeredAtMs: 10, otherDeviceTriggeredAtMs: 10, dismissedAtMs: nil))
                    .to(equal(.otherDevice))
                expect(UnsupportedMessageBanner.state(triggeredAtMs: 10, otherDeviceTriggeredAtMs: nil, dismissedAtMs: nil))
                    .to(equal(.general))
            }

            // MARK: -- only reappears for a trigger at least a week after dismissal
            it("only reappears for a trigger at least a week after dismissal") {
                let week: Int64 = UnsupportedMessageBanner.reappearAfterDismissalMs

                expect(UnsupportedMessageBanner.state(triggeredAtMs: 100 + week - 1, otherDeviceTriggeredAtMs: nil, dismissedAtMs: 100))
                    .to(equal(.hidden))
                expect(UnsupportedMessageBanner.state(triggeredAtMs: 100 + week, otherDeviceTriggeredAtMs: nil, dismissedAtMs: 100))
                    .to(equal(.general))
                expect(UnsupportedMessageBanner.state(triggeredAtMs: 100 + week, otherDeviceTriggeredAtMs: 50, dismissedAtMs: 100))
                    .to(equal(.general))
            }
        }
    }
}

// MARK: - Convenience

private extension ProcessedMessage {
    var messageInfo: MessageReceiveJob.Details.MessageInfo? {
        guard case .standard(_, _, let messageInfo, _) = self else { return nil }

        return messageInfo
    }

    var unsupportedMessage: UnsupportedMessage? { messageInfo?.message as? UnsupportedMessage }
}

// MARK: - Fixture

private class UnsupportedMessageTestFixture: FixtureBase {
    var mockStorage: Storage {
        mock(for: .storage) { dependencies in
            try! Storage.createForTesting(using: dependencies)
        }
    }
    var mockCrypto: MockCrypto { mock(for: .crypto) }
    var mockGeneralCache: MockGeneralCache { mock(cache: .general) }
    var mockLibSessionCache: MockLibSessionCache { mock(cache: .libSession) }

    let userSessionId: SessionId = SessionId(.standard, hex: TestConstants.publicKey)
    let otherSessionId: SessionId = SessionId(
        .standard,
        hex: "05aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    )
    let groupId: SessionId = SessionId(
        .group,
        hex: "03cbd569f56fb13ea95a3f0c05c331cc24139c0090feb412069dc49fab34406ece"
    )
    let sentTimestampMs: UInt64 = 1234567890000

    /// Synthetic data matching the v2 frame layout (`0x00 0x02`, key indicator, ephemeral key, ML-KEM ciphertext, payload)
    let newerFormatData: Data = Data([0x00, 0x02] + Array(repeating: 0, count: 1534))

    /// Stand-in ciphertext, the decrypted result is stubbed so its content doesn't matter
    let encryptedData: Data = Data([0x0A, 0x01, 0x01])

    static func create() async throws -> UnsupportedMessageTestFixture {
        let fixture: UnsupportedMessageTestFixture = UnsupportedMessageTestFixture()
        try await fixture.applyBaselineStubs()

        return fixture
    }

    private func applyBaselineStubs() async throws {
        try await mockStorage.perform(migrations: SNMessagingKit.migrations)
        try await mockGeneralCache.when { $0.sessionId }.thenReturn(userSessionId)
        try await mockLibSessionCache.defaultInitialSetup()
    }

    // MARK: - Convenience

    func origin(
        publicKey: String? = nil,
        namespace: Network.StorageServer.Namespace
    ) -> Message.Origin {
        return .swarm(
            publicKey: (publicKey ?? userSessionId.hexString),
            namespace: namespace,
            serverHash: "TestHash",
            serverTimestampMs: Int64(sentTimestampMs + 100),
            serverExpirationTimestamp: (TimeInterval(sentTimestampMs) / 1000) + (14 * 24 * 60 * 60)
        )
    }

    /// A serialized `Content` with a signature timestamp, optionally a `DataMessage`, and an extra varint field
    func content(body: String?, syncTarget: String? = nil, unknownFieldNumber: Int) throws -> Data {
        let contentBuilder: SNProtoContent.SNProtoContentBuilder = SNProtoContent.builder()
        contentBuilder.setSigTimestamp(sentTimestampMs)

        if body != nil || syncTarget != nil {
            let dataMessageBuilder: SNProtoDataMessage.SNProtoDataMessageBuilder = SNProtoDataMessage.builder()
            body.map { dataMessageBuilder.setBody($0) }
            syncTarget.map { dataMessageBuilder.setSyncTarget($0) }
            contentBuilder.setDataMessage(try dataMessageBuilder.build())
        }

        var result: Data = try contentBuilder.build().serializedData()
        result.append(contentsOf: varint(UInt64(unknownFieldNumber << 3)))
        result.append(0x01)

        return result
    }

    func stubDecoded(content: Data, sender: SessionId? = nil) async throws {
        try await mockCrypto
            .when {
                try $0.tryGenerate(.decodedMessage(
                    encodedMessage: Data.any,
                    origin: .swarm(
                        publicKey: .any,
                        namespace: .default,
                        serverHash: .any,
                        serverTimestampMs: .any,
                        serverExpirationTimestamp: .any
                    )
                ))
            }
            .thenReturn(
                DecodedMessage(
                    content: content,
                    sender: (sender ?? otherSessionId),
                    decodedPro: nil,
                    decodedEnvelope: nil,
                    sentTimestampMs: sentTimestampMs
                )
            )
    }

    func createThread(id: String) async throws {
        try await mockStorage.write { [dependencies] db in
            try SessionThread.upsert(
                db,
                id: id,
                variant: .contact,
                values: SessionThread.TargetValues(shouldBeVisible: .setTo(true)),
                using: dependencies
            )
        }
    }

    func handle(_ processedMessage: ProcessedMessage) async throws {
        guard case .standard(let threadId, let threadVariant, let messageInfo, _) = processedMessage else { return }

        try await mockStorage.write { [dependencies, userSessionId] db in
            _ = try MessageReceiver.handle(
                db,
                threadId: threadId,
                threadVariant: threadVariant,
                message: messageInfo.message,
                decodedMessage: messageInfo.decodedMessage,
                serverExpirationTimestamp: messageInfo.serverExpirationTimestamp,
                suppressNotifications: true,
                currentUserSessionIds: [userSessionId.hexString],
                using: dependencies
            )
        }
    }

    func record(hash: String, expiresAtMs: Int64?) -> UnsupportedMessageRecord {
        return UnsupportedMessageRecord(
            kind: .newerFormat,
            swarmPublicKey: userSessionId.hexString,
            namespace: Network.StorageServer.Namespace.default.rawValue,
            hash: hash,
            serverTimestampMs: Int64(sentTimestampMs),
            serverExpiryMs: nil,
            data: newerFormatData,
            placeholderMessageId: nil,
            expiresAtMs: expiresAtMs,
            receivedAtMs: Int64(sentTimestampMs),
            lastAttemptVersion: "Test"
        )
    }

    private func varint(_ value: UInt64) -> [UInt8] {
        var value: UInt64 = value
        var result: [UInt8] = []

        repeat {
            var byte: UInt8 = UInt8(value & 0x7F)
            value >>= 7

            if value != 0 { byte |= 0x80 }

            result.append(byte)
        } while value != 0

        return result
    }
}
