// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionNetworkingKit
import SessionUtilitiesKit
import TestUtilities

import Quick
import Nimble

@testable import SessionMessagingKit

class MessageDeduplicationSpec: AsyncSpec {
    override class func spec() {
        // MARK: Configuration
        
        @TestState var dependencies: TestDependencies! = TestDependencies()
        
        @TestState var mockStorage: Storage! = SynchronousStorage(
            customWriter: try! DatabaseQueue(),
            using: dependencies
        )
        @TestState var mockExtensionHelper: MockExtensionHelper! = .create(using: dependencies)
        @TestState var mockMessage: Message! = {
            let result: ReadReceipt = ReadReceipt(timestamps: [1])
            result.sentTimestampMs = 12345678901234
            
            return result
        }()
        
        beforeEach {
            try await mockStorage.perform(migrations: SNMessagingKit.migrations)
            dependencies.set(singleton: .storage, to: mockStorage)
            
            try await mockExtensionHelper.when { $0.deleteCache() }.thenReturn(())
            try await mockExtensionHelper
                .when { $0.dedupeRecordExists(threadId: .any, uniqueIdentifier: .any) }
                .thenReturn(false)
            try await mockExtensionHelper
                .when { try $0.createDedupeRecord(threadId: .any, uniqueIdentifier: .any) }
                .thenReturn(())
            try await mockExtensionHelper
                .when { try $0.removeDedupeRecord(threadId: .any, uniqueIdentifier: .any) }
                .thenReturn(())
            try await mockExtensionHelper
                .when { try $0.upsertLastClearedRecord(threadId: .any) }
                .thenReturn(())
            dependencies.set(singleton: .extensionHelper, to: mockExtensionHelper)
        }
        
        // MARK: - MessageDeduplication - Inserting
        describe("MessageDeduplication") {
            // MARK: -- when inserting
            context("when inserting") {
                // MARK: ---- inserts a record correctly
                it("inserts a record correctly") {
                    mockStorage.write { db in
                        expect {
                            try MessageDeduplication.insert(
                                db,
                                threadId: "testThreadId",
                                threadVariant: .contact,
                                uniqueIdentifier: "testId",
                                message: nil,
                                serverExpirationTimestamp: 1234567890,
                                ignoreDedupeFiles: false,
                                using: dependencies
                            )
                        }.toNot(throwError())
                    }
                    
                    let expectedTimestamp: Int64 = (1234567890 + ((Network.StorageServer.Message.serverClockToleranceMs * 2) / 1000))
                    let records: [MessageDeduplication]? = mockStorage
                        .read { db in try MessageDeduplication.fetchAll(db) }
                    expect(records?.count).to(equal(1))
                    expect(records?.first?.threadId).to(equal("testThreadId"))
                    expect(records?.first?.uniqueIdentifier).to(equal("testId"))
                    expect(records?.first?.expirationTimestampSeconds).to(equal(expectedTimestamp))
                    expect(records?.first?.shouldDeleteWhenDeletingThread).to(beFalse())
                    await mockExtensionHelper
                        .verify { try $0.createDedupeRecord(threadId: "testThreadId", uniqueIdentifier: "testId") }
                        .wasCalled(exactly: 1)
                }
                
                // MARK: ---- checks that it is not a duplicate record
                it("checks that it is not a duplicate record") {
                    mockStorage.write { db in
                        expect {
                            try MessageDeduplication.insert(
                                db,
                                threadId: "testThreadId",
                                threadVariant: .contact,
                                uniqueIdentifier: "testId",
                                message: nil,
                                serverExpirationTimestamp: 1234567890,
                                ignoreDedupeFiles: false,
                                using: dependencies
                            )
                        }.toNot(throwError())
                    }
                    
                    await mockExtensionHelper
                        .verify { $0.dedupeRecordExists(threadId: "testThreadId", uniqueIdentifier: "testId") }
                        .wasCalled(exactly: 1)
                }
                
                // MARK: ---- creates a legacy record if needed
                it("creates a legacy record if needed") {
                    mockStorage.write { db in
                        expect {
                            try MessageDeduplication.insert(
                                db,
                                threadId: "testThreadId",
                                threadVariant: .contact,
                                uniqueIdentifier: "testId",
                                legacyIdentifier: "testLegacyId",
                                message: mockMessage,
                                serverExpirationTimestamp: 1234567890,
                                ignoreDedupeFiles: false,
                                using: dependencies
                            )
                        }.toNot(throwError())
                    }
                    
                    await mockExtensionHelper
                        .verify { $0.dedupeRecordExists(threadId: "testThreadId", uniqueIdentifier: "testLegacyId") }
                        .wasCalled(exactly: 1)
                }
                
                // MARK: ---- sets the shouldDeleteWhenDeletingThread flag correctly
                it("sets the shouldDeleteWhenDeletingThread flag correctly") {
                    mockStorage.write { db in
                        expect {
                            try MessageDeduplication.insert(
                                db,
                                threadId: "testThreadId",
                                threadVariant: .contact,
                                uniqueIdentifier: "testId1",
                                message: mockMessage,
                                serverExpirationTimestamp: 1234567890,
                                ignoreDedupeFiles: false,
                                using: dependencies
                            )
                            try MessageDeduplication.insert(
                                db,
                                threadId: "testThreadId",
                                threadVariant: .community,
                                uniqueIdentifier: "testId2",
                                message: mockMessage,
                                serverExpirationTimestamp: 1234567890,
                                ignoreDedupeFiles: false,
                                using: dependencies
                            )
                            try MessageDeduplication.insert(
                                db,
                                threadId: "testThreadId",
                                threadVariant: .legacyGroup,
                                uniqueIdentifier: "testId3",
                                message: mockMessage,
                                serverExpirationTimestamp: 1234567890,
                                ignoreDedupeFiles: false,
                                using: dependencies
                            )
                            try MessageDeduplication.insert(
                                db,
                                threadId: "testThreadId",
                                threadVariant: .group,
                                uniqueIdentifier: "testId4",
                                message: GroupUpdateInviteMessage(
                                    inviteeSessionIdHexString: "TestId",
                                    groupSessionId: SessionId(.group, hex: TestConstants.publicKey),
                                    groupName: "TestGroup",
                                    memberAuthData: Data([1, 2, 3]),
                                    profile: nil,
                                    adminSignature: .standard(signature: "TestSignature".bytes)
                                ),
                                serverExpirationTimestamp: 1234567890,
                                ignoreDedupeFiles: false,
                                using: dependencies
                            )
                            try MessageDeduplication.insert(
                                db,
                                threadId: "testThreadId",
                                threadVariant: .group,
                                uniqueIdentifier: "testId5",
                                message: GroupUpdatePromoteMessage(
                                    groupIdentitySeed: Data([1, 2, 3]),
                                    groupName: "TestGroup",
                                    sentTimestampMs: 1234567890000
                                ),
                                serverExpirationTimestamp: 1234567890,
                                ignoreDedupeFiles: false,
                                using: dependencies
                            )
                            try MessageDeduplication.insert(
                                db,
                                threadId: "testThreadId",
                                threadVariant: .group,
                                uniqueIdentifier: "testId6",
                                message: GroupUpdateMemberLeftMessage(),
                                serverExpirationTimestamp: 1234567890,
                                ignoreDedupeFiles: false,
                                using: dependencies
                            )
                            try MessageDeduplication.insert(
                                db,
                                threadId: "testThreadId",
                                threadVariant: .group,
                                uniqueIdentifier: "testId7",
                                message: GroupUpdateInviteResponseMessage(
                                    isApproved: true,
                                    profile: nil,
                                    sentTimestampMs: 1234567800000
                                ),
                                serverExpirationTimestamp: 1234567890,
                                ignoreDedupeFiles: false,
                                using: dependencies
                            )
                            try MessageDeduplication.insert(
                                db,
                                threadId: "testThreadId",
                                threadVariant: .group,
                                uniqueIdentifier: "testId8",
                                message: mockMessage,
                                serverExpirationTimestamp: 1234567890,
                                ignoreDedupeFiles: false,
                                using: dependencies
                            )
                            try MessageDeduplication.insert(
                                db,
                                threadId: "testThreadId",
                                threadVariant: nil,
                                uniqueIdentifier: "testId9",
                                message: mockMessage,
                                serverExpirationTimestamp: 1234567890,
                                ignoreDedupeFiles: false,
                                using: dependencies
                            )
                            try MessageDeduplication.insert(
                                db,
                                threadId: "testThreadId",
                                threadVariant: nil,
                                uniqueIdentifier: "testId10",
                                message: nil,
                                serverExpirationTimestamp: 1234567890,
                                ignoreDedupeFiles: false,
                                using: dependencies
                            )
                        }.toNot(throwError())
                    }
                    
                    let records: [String: MessageDeduplication] = mockStorage
                        .read { db in try MessageDeduplication.fetchAll(db) }
                        .defaulting(to: [])
                        .reduce(into: [:]) { result, next in result[next.uniqueIdentifier] = next }
                    expect(records["testId1"]?.shouldDeleteWhenDeletingThread).to(beFalse())
                    expect(records["testId2"]?.shouldDeleteWhenDeletingThread).to(beTrue())
                    expect(records["testId3"]?.shouldDeleteWhenDeletingThread).to(beTrue())
                    expect(records["testId4"]?.shouldDeleteWhenDeletingThread).to(beFalse())
                    expect(records["testId5"]?.shouldDeleteWhenDeletingThread).to(beFalse())
                    expect(records["testId6"]?.shouldDeleteWhenDeletingThread).to(beFalse())
                    expect(records["testId7"]?.shouldDeleteWhenDeletingThread).to(beFalse())
                    expect(records["testId8"]?.shouldDeleteWhenDeletingThread).to(beTrue())
                    expect(records["testId9"]?.shouldDeleteWhenDeletingThread).to(beFalse())
                    expect(records["testId10"]?.shouldDeleteWhenDeletingThread).to(beFalse())
                }
                
                // MARK: ---- does nothing if no uniqueIdentifier is provided
                it("does nothing if no uniqueIdentifier is provided") {
                    mockStorage.write { db in
                        expect {
                            try MessageDeduplication.insert(
                                db,
                                threadId: "testThreadId",
                                threadVariant: .contact,
                                uniqueIdentifier: nil,
                                legacyIdentifier: "testLegacyId",
                                message: mockMessage,
                                serverExpirationTimestamp: 1234567890,
                                ignoreDedupeFiles: false,
                                using: dependencies
                            )
                        }.toNot(throwError())
                    }
                    
                    let records: [MessageDeduplication]? = mockStorage
                        .read { db in try MessageDeduplication.fetchAll(db) }
                    expect(records).to(beEmpty())
                }
                
                // MARK: ---- creates a record from a ProcessedMessage
                it("creates a record from a ProcessedMessage") {
                    mockStorage.write { db in
                        expect {
                            try MessageDeduplication.insert(
                                db,
                                processedMessage: .standard(
                                    threadId: "testThreadId",
                                    threadVariant: .contact,
                                    proto: try! SNProtoContent.builder().build(),
                                    messageInfo: MessageReceiveJob.Details.MessageInfo(
                                        message: mockMessage,
                                        variant: .readReceipt,
                                        threadVariant: .contact,
                                        serverExpirationTimestamp: nil,
                                        proto: try! SNProtoContent.builder().build()
                                    ),
                                    uniqueIdentifier: "testId"
                                ),
                                ignoreDedupeFiles: false,
                                using: dependencies
                            )
                        }.toNot(throwError())
                    }
                    await mockExtensionHelper
                        .verify { try $0.createDedupeRecord(threadId: "testThreadId", uniqueIdentifier: "testId") }
                        .wasCalled(exactly: 1)
                    await mockExtensionHelper
                        .verify {
                            try $0.createDedupeRecord(
                                threadId: "testThreadId",
                                uniqueIdentifier: "LegacyRecord-1-12345678901234"
                            )
                        }
                        .wasCalled(exactly: 1)
                }
                
                // MARK: ---- does not create records for config ProcessedMessages
                it("does not create records for config ProcessedMessages") {
                    mockStorage.write { db in
                        expect {
                            try MessageDeduplication.insert(
                                db,
                                processedMessage: .config(
                                    publicKey: "testThreadId",
                                    namespace: .configContacts,
                                    serverHash: "1234",
                                    serverTimestampMs: 1234567890,
                                    data: Data([1, 2, 3]),
                                    uniqueIdentifier: "testId"
                                ),
                                ignoreDedupeFiles: false,
                                using: dependencies
                            )
                        }.toNot(throwError())
                    }
                    
                    let records: [MessageDeduplication]? = mockStorage
                        .read { db in try MessageDeduplication.fetchAll(db) }
                    expect(records).to(beEmpty())
                    await mockExtensionHelper
                        .verify { try $0.createDedupeRecord(threadId: "testThreadId", uniqueIdentifier: "testId") }
                        .wasNotCalled()
                }
                
                // MARK: ---- throws if the message is a duplicate
                it("throws if the message is a duplicate") {
                    try await mockExtensionHelper
                        .when { $0.dedupeRecordExists(threadId: .any, uniqueIdentifier: .any) }
                        .thenReturn(true)
                    
                    mockStorage.write { db in
                        expect {
                            try MessageDeduplication.insert(
                                db,
                                threadId: "testThreadId",
                                threadVariant: .contact,
                                uniqueIdentifier: "testId",
                                legacyIdentifier: "testLegacyId",
                                message: mockMessage,
                                serverExpirationTimestamp: 1234567890,
                                ignoreDedupeFiles: false,
                                using: dependencies
                            )
                        }.to(throwError(MessageReceiverError.duplicateMessage))
                    }
                }
                
                // MARK: ---- throws if the message is a legacy duplicate
                it("throws if the message is a legacy duplicate") {
                    try await mockExtensionHelper
                        .when {
                            $0.dedupeRecordExists(
                                threadId: "testThreadId",
                                uniqueIdentifier: "testId"
                            )
                        }
                        .thenReturn(false)
                    try await mockExtensionHelper
                        .when {
                            $0.dedupeRecordExists(
                                threadId: "testThreadId",
                                uniqueIdentifier: "testLegacyId"
                            )
                        }
                        .thenReturn(true)
                    
                    mockStorage.write { db in
                        expect {
                            try MessageDeduplication.insert(
                                db,
                                threadId: "testThreadId",
                                threadVariant: .contact,
                                uniqueIdentifier: "testId",
                                legacyIdentifier: "testLegacyId",
                                message: mockMessage,
                                serverExpirationTimestamp: 1234567890,
                                ignoreDedupeFiles: false,
                                using: dependencies
                            )
                        }.to(throwError(MessageReceiverError.duplicateMessage))
                    }
                }
                
                // MARK: ---- throws if it fails to create the dedupe file
                it("throws if it fails to create the dedupe file") {
                    try await mockExtensionHelper
                        .when { try $0.createDedupeRecord(threadId: .any, uniqueIdentifier: .any) }
                        .thenThrow(TestError.mock)
                    
                    mockStorage.write { db in
                        expect {
                            try MessageDeduplication.insert(
                                db,
                                threadId: "testThreadId",
                                threadVariant: .contact,
                                uniqueIdentifier: "testId",
                                legacyIdentifier: "testLegacyId",
                                message: mockMessage,
                                serverExpirationTimestamp: 1234567890,
                                ignoreDedupeFiles: false,
                                using: dependencies
                            )
                        }.to(throwError(TestError.mock))
                    }
                }
                
                // MARK: ---- throws if it fails to create the legacy dedupe file
                it("throws if it fails to create the legacy dedupe file") {
                    try await mockExtensionHelper
                        .when {
                            try $0.createDedupeRecord(
                                threadId: "testThreadId",
                                uniqueIdentifier: "testLegacyId"
                            )
                        }
                        .thenThrow(TestError.mock)
                    
                    mockStorage.write { db in
                        expect {
                            try MessageDeduplication.insert(
                                db,
                                threadId: "testThreadId",
                                threadVariant: .contact,
                                uniqueIdentifier: "testId",
                                legacyIdentifier: "testLegacyId",
                                message: mockMessage,
                                serverExpirationTimestamp: 1234567890,
                                ignoreDedupeFiles: false,
                                using: dependencies
                            )
                        }.to(throwError(TestError.mock))
                    }
                }
            }
            
            // MARK: -- when inserting a call message
            context("when inserting a call message") {
                // MARK: ---- inserts a preOffer record correctly
                it("inserts a preOffer record correctly") {
                    mockStorage.write { db in
                        expect {
                            try MessageDeduplication.insertCallDedupeRecordsIfNeeded(
                                db,
                                threadId: "testThreadId",
                                callMessage: CallMessage(
                                    uuid: "12345",
                                    kind: .preOffer,
                                    sdps: [],
                                    sentTimestampMs: 1234567890
                                ),
                                expirationTimestampSeconds: 1234567891,
                                shouldDeleteWhenDeletingThread: false,
                                using: dependencies
                            )
                        }.toNot(throwError())
                    }
                    
                    let records: [MessageDeduplication]? = mockStorage
                        .read { db in try MessageDeduplication.fetchAll(db) }
                    expect(records?.count).to(equal(1))
                    expect(records?.first?.threadId).to(equal("testThreadId"))
                    expect(records?.first?.uniqueIdentifier).to(equal("12345-preOffer"))
                    expect(records?.first?.expirationTimestampSeconds).to(equal(1234567891))
                    expect(records?.first?.shouldDeleteWhenDeletingThread).to(beFalse())
                    await mockExtensionHelper
                        .verify {
                            try $0.createDedupeRecord(threadId: "testThreadId", uniqueIdentifier: "12345-preOffer")
                        }
                        .wasCalled(exactly: 1)
                }
                
                // MARK: ---- inserts a generic record correctly
                it("inserts a generic record correctly") {
                    mockStorage.write { db in
                        expect {
                            try MessageDeduplication.insertCallDedupeRecordsIfNeeded(
                                db,
                                threadId: "testThreadId",
                                callMessage: CallMessage(
                                    uuid: "12345",
                                    kind: .endCall,
                                    sdps: [],
                                    sentTimestampMs: 1234567890
                                ),
                                expirationTimestampSeconds: 1234567891,
                                shouldDeleteWhenDeletingThread: false,
                                using: dependencies
                            )
                        }.toNot(throwError())
                    }
                    
                    let records: [MessageDeduplication]? = mockStorage
                        .read { db in try MessageDeduplication.fetchAll(db) }
                    expect(records?.count).to(equal(1))
                    expect(records?.first?.threadId).to(equal("testThreadId"))
                    expect(records?.first?.uniqueIdentifier).to(equal("12345"))
                    expect(records?.first?.expirationTimestampSeconds).to(equal(1234567891))
                    expect(records?.first?.shouldDeleteWhenDeletingThread).to(beFalse())
                    await mockExtensionHelper
                        .verify {
                            try $0.createDedupeRecord(threadId: "testThreadId", uniqueIdentifier: "12345")
                        }
                        .wasCalled(exactly: 1)
                }
                
                // MARK: ---- does nothing if no call message is provided
                it("does nothing if no call message is provided") {
                    mockStorage.write { db in
                        expect {
                            try MessageDeduplication.insertCallDedupeRecordsIfNeeded(
                                db,
                                threadId: "testThreadId",
                                callMessage: nil,
                                expirationTimestampSeconds: 1234567891,
                                shouldDeleteWhenDeletingThread: false,
                                using: dependencies
                            )
                        }.toNot(throwError())
                    }
                    
                    let records: [MessageDeduplication]? = mockStorage
                        .read { db in try MessageDeduplication.fetchAll(db) }
                    expect(records?.count).to(equal(0))
                    await mockExtensionHelper
                        .verify { try $0.createDedupeRecord(threadId: .any, uniqueIdentifier: .any) }
                        .wasNotCalled()
                }
            }
        }
            
        // MARK: - MessageDeduplication - Deleting
        describe("MessageDeduplication") {
            // MARK: -- when deleting a dedupe record
            context("when deleting a dedupe record") {
                // MARK: ---- deletes the record successfully
                it("deletes the record successfully") {
                    mockStorage.write { db in
                        try MessageDeduplication(
                            threadId: "testThreadId",
                            uniqueIdentifier: "testId",
                            expirationTimestampSeconds: nil,
                            shouldDeleteWhenDeletingThread: true
                        ).insert(db)
                    }
                    
                    mockStorage.write { db in
                        expect {
                            try MessageDeduplication.deleteIfNeeded(
                                db,
                                threadIds: ["testThreadId"],
                                using: dependencies
                            )
                        }.toNot(throwError())
                    }
                    
                    await expect(mockStorage
                        .read { db in try MessageDeduplication.fetchAll(db) })
                        .toEventually(beEmpty())
                    await mockExtensionHelper
                        .verify {
                            try $0.removeDedupeRecord(threadId: "testThreadId", uniqueIdentifier: "testId")
                        }
                        .wasCalled(exactly: 1)
                }
                
                // MARK: ---- upserts the last cleared record
                it("upserts the last cleared record") {
                    mockStorage.write { db in
                        try MessageDeduplication(
                            threadId: "testThreadId",
                            uniqueIdentifier: "testId",
                            expirationTimestampSeconds: nil,
                            shouldDeleteWhenDeletingThread: true
                        ).insert(db)
                    }
                    
                    mockStorage.write { db in
                        expect {
                            try MessageDeduplication.deleteIfNeeded(
                                db,
                                threadIds: ["testThreadId"],
                                using: dependencies
                            )
                        }.toNot(throwError())
                    }
                    
                    await expect(mockStorage
                        .read { db in try MessageDeduplication.fetchAll(db) })
                        .toEventually(beEmpty())
                    await mockExtensionHelper
                        .verify { try $0.upsertLastClearedRecord(threadId: "testThreadId") }
                        .wasCalled(exactly: 1)
                }
                
                // MARK: ---- deletes multiple records
                it("deletes multiple records") {
                    mockStorage.write { db in
                        try MessageDeduplication(
                            threadId: "testThreadId",
                            uniqueIdentifier: "testId",
                            expirationTimestampSeconds: nil,
                            shouldDeleteWhenDeletingThread: true
                        ).insert(db)
                        try MessageDeduplication(
                            threadId: "testThreadId",
                            uniqueIdentifier: "testId2",
                            expirationTimestampSeconds: nil,
                            shouldDeleteWhenDeletingThread: true
                        ).insert(db)
                    }
                    
                    mockStorage.write { db in
                        expect {
                            try MessageDeduplication.deleteIfNeeded(
                                db,
                                threadIds: ["testThreadId"],
                                using: dependencies
                            )
                        }.toNot(throwError())
                    }
                    
                    await expect(mockStorage
                        .read { db in try MessageDeduplication.fetchAll(db) })
                        .toEventually(beEmpty())
                    await mockExtensionHelper
                        .verify { try $0.removeDedupeRecord(threadId: "testThreadId", uniqueIdentifier: "testId") }
                        .wasCalled(exactly: 1)
                    await mockExtensionHelper
                        .verify { try $0.removeDedupeRecord(threadId: "testThreadId", uniqueIdentifier: "testId2") }
                        .wasCalled(exactly: 1)
                }
                
                // MARK: ---- leaves unrelated records
                it("leaves unrelated records") {
                    mockStorage.write { db in
                        try MessageDeduplication(
                            threadId: "testThreadId",
                            uniqueIdentifier: "testId",
                            expirationTimestampSeconds: nil,
                            shouldDeleteWhenDeletingThread: true
                        ).insert(db)
                        try MessageDeduplication(
                            threadId: "testThreadId2",
                            uniqueIdentifier: "testId2",
                            expirationTimestampSeconds: nil,
                            shouldDeleteWhenDeletingThread: true
                        ).insert(db)
                    }
                    
                    mockStorage.write { db in
                        expect {
                            try MessageDeduplication.deleteIfNeeded(
                                db,
                                threadIds: ["testThreadId"],
                                using: dependencies
                            )
                        }.toNot(throwError())
                    }
                    
                    let records: [MessageDeduplication]? = await expect(mockStorage
                        .read { db in try MessageDeduplication.fetchAll(db) })
                        .toEventually(haveCount(1))
                        .retrieveValue()
                    expect((records?.map { $0.threadId }).map { Set($0) }).to(equal(["testThreadId2"]))
                    expect((records?.map { $0.uniqueIdentifier }).map { Set($0) })
                        .to(equal(["testId2"]))
                    await mockExtensionHelper
                        .verify {
                            try $0.removeDedupeRecord(threadId: "testThreadId", uniqueIdentifier: "testId")
                        }
                        .wasCalled(exactly: 1)
                }
                
                // MARK: ---- leaves records which should not be deleted alongside the thread
                it("leaves records which should not be deleted alongside the thread") {
                    mockStorage.write { db in
                        try MessageDeduplication(
                            threadId: "testThreadId",
                            uniqueIdentifier: "testId",
                            expirationTimestampSeconds: nil,
                            shouldDeleteWhenDeletingThread: false
                        ).insert(db)
                    }
                    
                    mockStorage.write { db in
                        expect {
                            try MessageDeduplication.deleteIfNeeded(
                                db,
                                threadIds: ["testThreadId"],
                                using: dependencies
                            )
                        }.toNot(throwError())
                    }
                    
                    let records: [MessageDeduplication]? = mockStorage
                        .read { db in try MessageDeduplication.fetchAll(db) }
                    expect((records?.map { $0.threadId }).map { Set($0) }).to(equal(["testThreadId"]))
                    expect((records?.map { $0.uniqueIdentifier }).map { Set($0) })
                        .to(equal(["testId"]))
                    await mockExtensionHelper
                        .verify { try $0.removeDedupeRecord(threadId: .any, uniqueIdentifier: .any) }
                        .wasNotCalled()
                }
                
                // MARK: ---- resets the expiration timestamp when failing to delete the file
                it("resets the expiration timestamp when failing to delete the file") {
                    mockStorage.write { db in
                        try MessageDeduplication(
                            threadId: "testThreadId",
                            uniqueIdentifier: "testId",
                            expirationTimestampSeconds: 1234567890,
                            shouldDeleteWhenDeletingThread: true
                        ).insert(db)
                    }
                    try await mockExtensionHelper
                        .when { try $0.removeDedupeRecord(threadId: .any, uniqueIdentifier: .any) }
                        .thenThrow(TestError.mock)
                    
                    mockStorage.write { db in
                        expect {
                            try MessageDeduplication.deleteIfNeeded(
                                db,
                                threadIds: ["testThreadId"],
                                using: dependencies
                            )
                        }.toNot(throwError())
                    }
                    
                    let records: [MessageDeduplication]? = await expect(mockStorage
                        .read { db in try MessageDeduplication.fetchAll(db) })
                        .toEventually(haveCount(1))
                        .retrieveValue()
                    expect((records?.map { $0.threadId }).map { Set($0) }).to(equal(["testThreadId"]))
                    expect((records?.map { $0.uniqueIdentifier }).map { Set($0) })
                        .to(equal(["testId"]))
                    expect((records?.map { $0.expirationTimestampSeconds }).map { Set($0) })
                        .to(equal([0]))
                    await mockExtensionHelper
                        .verify {
                            try $0.removeDedupeRecord(threadId: "testThreadId", uniqueIdentifier: "testId")
                        }
                        .wasCalled(exactly: 1)
                }
            }
        }
        
        // MARK: - MessageDeduplication - Creating
        describe("MessageDeduplication") {
            // MARK: -- when creating a dedupe file
            context("when creating a dedupe file") {
                // MARK: ---- creates the file successfully
                it("creates the file successfully") {
                    expect {
                        try MessageDeduplication.createDedupeFile(
                            threadId: "testThreadId",
                            uniqueIdentifier: "testId",
                            using: dependencies
                        )
                    }.toNot(throwError())
                    await mockExtensionHelper
                        .verify { try $0.createDedupeRecord(threadId: "testThreadId", uniqueIdentifier: "testId") }
                        .wasCalled(exactly: 1)
                }
                
                // MARK: ---- creates both the main file and a legacy file when needed
                it("creates both the main file and a legacy file when needed") {
                    expect {
                        try MessageDeduplication.createDedupeFile(
                            threadId: "testThreadId",
                            uniqueIdentifier: "testId",
                            legacyIdentifier: "testLegacyId",
                            using: dependencies
                        )
                    }.toNot(throwError())
                    await mockExtensionHelper
                        .verify { try $0.createDedupeRecord(threadId: "testThreadId", uniqueIdentifier: "testId") }
                        .wasCalled(exactly: 1)
                    await mockExtensionHelper
                        .verify {
                            try $0.createDedupeRecord(
                                threadId: "testThreadId",
                                uniqueIdentifier: "testLegacyId"
                            )
                        }
                        .wasCalled(exactly: 1)
                }
                
                // MARK: ---- creates a file from a ProcessedMessage
                it("creates a file from a ProcessedMessage") {
                    expect {
                        try MessageDeduplication.createDedupeFile(
                            .standard(
                                threadId: "testThreadId",
                                threadVariant: .contact,
                                proto: try! SNProtoContent.builder().build(),
                                messageInfo: MessageReceiveJob.Details.MessageInfo(
                                    message: Message(),
                                    variant: .visibleMessage,
                                    threadVariant: .contact,
                                    serverExpirationTimestamp: nil,
                                    proto: try! SNProtoContent.builder().build()
                                ),
                                uniqueIdentifier: "testId"
                            ),
                            using: dependencies
                        )
                    }.toNot(throwError())
                    await mockExtensionHelper
                        .verify { try $0.createDedupeRecord(threadId: "testThreadId", uniqueIdentifier: "testId") }
                        .wasCalled(exactly: 1)
                }
                
                // MARK: ---- throws when it fails to create the file
                it("throws when it fails to create the file") {
                    try await mockExtensionHelper
                        .when { try $0.createDedupeRecord(threadId: .any, uniqueIdentifier: .any) }
                        .thenThrow(TestError.mock)
                    
                    expect {
                        try MessageDeduplication.createDedupeFile(
                            threadId: "testThreadId",
                            uniqueIdentifier: "testId",
                            using: dependencies
                        )
                    }.to(throwError(TestError.mock))
                }
                
                // MARK: ---- throws when it fails to create the legacy file
                it("throws when it fails to create the legacy file") {
                    try await mockExtensionHelper
                        .when {
                            try $0.createDedupeRecord(
                                threadId: "testThreadId",
                                uniqueIdentifier: "testId"
                            )
                        }
                        .thenReturn(())
                    try await mockExtensionHelper
                        .when {
                            try $0.createDedupeRecord(
                                threadId: "testThreadId",
                                uniqueIdentifier: "testLegacyId"
                            )
                        }
                        .thenThrow(TestError.mock)
                    
                    expect {
                        try MessageDeduplication.createDedupeFile(
                            threadId: "testThreadId",
                            uniqueIdentifier: "testId",
                            legacyIdentifier: "testLegacyId",
                            using: dependencies
                        )
                    }.to(throwError(TestError.mock))
                    await mockExtensionHelper
                        .verify { try $0.createDedupeRecord(threadId: "testThreadId", uniqueIdentifier: "testId") }
                        .wasCalled(exactly: 1)
                    await mockExtensionHelper
                        .verify {
                            try $0.createDedupeRecord(
                                threadId: "testThreadId",
                                uniqueIdentifier: "testLegacyId"
                            )
                        }
                        .wasCalled(exactly: 1)
                }
            }
            
            // MARK: -- when creating a call message dedupe file
            context("when creating a call message dedupe file") {
                // MARK: ---- creates a preOffer file correctly
                it("creates a preOffer file correctly") {
                    expect {
                        try MessageDeduplication.createCallDedupeFilesIfNeeded(
                            threadId: "testThreadId",
                            callMessage: CallMessage(
                                uuid: "12345",
                                kind: .preOffer,
                                sdps: [],
                                sentTimestampMs: 1234567890
                            ),
                            using: dependencies
                        )
                    }.toNot(throwError())
                    
                    await mockExtensionHelper
                        .verify {
                            try $0.createDedupeRecord(threadId: "testThreadId", uniqueIdentifier: "12345-preOffer")
                        }
                        .wasCalled(exactly: 1)
                }
                
                // MARK: ---- creates a generic file correctly
                it("creates a generic file correctly") {
                    expect {
                        try MessageDeduplication.createCallDedupeFilesIfNeeded(
                            threadId: "testThreadId",
                            callMessage: CallMessage(
                                uuid: "12345",
                                kind: .endCall,
                                sdps: [],
                                sentTimestampMs: 1234567890
                            ),
                            using: dependencies
                        )
                    }.toNot(throwError())
                    
                    await mockExtensionHelper
                        .verify { try $0.createDedupeRecord(threadId: "testThreadId", uniqueIdentifier: "12345") }
                        .wasCalled(exactly: 1)
                }
                
                // MARK: ---- creates a files for the correct call message kinds
                it("creates a files for the correct call message kinds") {
                    var resultIdentifiers: [String] = []
                    var resultKinds: [CallMessage.Kind] = []
                    
                    for kind in CallMessage.Kind.allCases {
                        try await mockExtensionHelper
                            .when { try $0.createDedupeRecord(threadId: .any, uniqueIdentifier: .any) }
                            .then { args in
                                guard let identifier: String = args[test: 1] as? String else { return }
                                
                                resultIdentifiers.append(identifier)
                                resultKinds.append(kind)
                            }
                            .thenReturn(())
                        
                        expect {
                            try MessageDeduplication.createCallDedupeFilesIfNeeded(
                                threadId: "testThreadId",
                                callMessage: CallMessage(
                                    uuid: "12345",
                                    kind: kind,
                                    sdps: [],
                                    sentTimestampMs: 1234567890
                                ),
                                using: dependencies
                            )
                        }.toNot(throwError())
                    }
                    
                    expect(resultIdentifiers).to(equal(["12345-preOffer", "12345"]))
                    expect(resultKinds).to(equal([.preOffer, .endCall]))
                }
                
                // MARK: ---- creates files for the correct call message states
                it("creates files for the correct call message states") {
                    var resultIdentifiers: [String] = []
                    var resultStates: [CallMessage.MessageInfo.State] = []
                    
                    for state in CallMessage.MessageInfo.State.allCases {
                        let message: CallMessage = CallMessage(
                            uuid: "12345",
                            kind: .answer,
                            sdps: [],
                            sentTimestampMs: 1234567890
                        )
                        message.state = state
                        try await mockExtensionHelper
                            .when { try $0.createDedupeRecord(threadId: .any, uniqueIdentifier: .any) }
                            .then { args in
                                guard let identifier: String = args[test: 1] as? String else { return }
                                
                                resultIdentifiers.append(identifier)
                                resultStates.append(state)
                            }
                            .thenReturn(())
                        
                        expect {
                            try MessageDeduplication.createCallDedupeFilesIfNeeded(
                                threadId: "testThreadId",
                                callMessage: message,
                                using: dependencies
                            )
                        }.toNot(throwError())
                    }
                    
                    expect(resultIdentifiers).to(equal(["12345", "12345", "12345"]))
                    expect(resultStates).to(equal([.missed, .permissionDenied, .permissionDeniedMicrophone]))
                }
                
                // MARK: ---- does nothing if no call message is provided
                it("does nothing if no call message is provided") {
                    expect {
                        try MessageDeduplication.createCallDedupeFilesIfNeeded(
                            threadId: "testThreadId",
                            callMessage: nil,
                            using: dependencies
                        )
                    }.toNot(throwError())
                    
                    await mockExtensionHelper
                        .verify { try $0.createDedupeRecord(threadId: .any, uniqueIdentifier: .any) }
                        .wasNotCalled()
                }
            }
        }
        
        // MARK: - MessageDeduplication - Ensuring
        describe("MessageDeduplication") {
            // MARK: -- when ensuring a message is not a duplicate
            context("when ensuring a message is not a duplicate") {
                // MARK: ---- does not throw when not a duplicate
                it("does not throw when not a duplicate") {
                    expect {
                        try MessageDeduplication.ensureMessageIsNotADuplicate(
                            threadId: "testThreadId",
                            uniqueIdentifier: "testId",
                            using: dependencies
                        )
                    }.toNot(throwError())
                }
                
                // MARK: ---- when ensuring a message is not a legacy duplicate
                it("does not throw when not a legacy duplicate") {
                    expect {
                        try MessageDeduplication.ensureMessageIsNotADuplicate(
                            threadId: "testThreadId",
                            uniqueIdentifier: "testId",
                            legacyIdentifier: "testLegacyId",
                            using: dependencies
                        )
                    }.toNot(throwError())
                }
                
                // MARK: ---- does not throw when given a non duplicate ProcessedMessage
                it("does not throw when given a non duplicate ProcessedMessage") {
                    expect {
                        try MessageDeduplication.ensureMessageIsNotADuplicate(
                            .standard(
                                threadId: "testThreadId",
                                threadVariant: .contact,
                                proto: try! SNProtoContent.builder().build(),
                                messageInfo: MessageReceiveJob.Details.MessageInfo(
                                    message: Message(),
                                    variant: .visibleMessage,
                                    threadVariant: .contact,
                                    serverExpirationTimestamp: nil,
                                    proto: try! SNProtoContent.builder().build()
                                ),
                                uniqueIdentifier: "testId"
                            ),
                            using: dependencies
                        )
                    }.toNot(throwError())
                }
                
                // MARK: ---- throws when the message is a duplicate
                it("throws when the message is a duplicate") {
                    try await mockExtensionHelper
                        .when { $0.dedupeRecordExists(threadId: .any, uniqueIdentifier: .any) }
                        .thenReturn(true)
                    
                    expect {
                        try MessageDeduplication.ensureMessageIsNotADuplicate(
                            threadId: "testThreadId",
                            uniqueIdentifier: "testId",
                            using: dependencies
                        )
                    }.to(throwError(MessageReceiverError.duplicateMessage))
                }
                
                // MARK: ---- throws when the message is a legacy duplicate
                it("throws when the message is a legacy duplicate") {
                    try await mockExtensionHelper
                        .when {
                            $0.dedupeRecordExists(
                                threadId: "testThreadId",
                                uniqueIdentifier: "testId"
                            )
                        }
                        .thenReturn(false)
                    try await mockExtensionHelper
                        .when {
                            $0.dedupeRecordExists(
                                threadId: "testThreadId",
                                uniqueIdentifier: "testLegacyId"
                            )
                        }
                        .thenReturn(true)
                    
                    expect {
                        try MessageDeduplication.ensureMessageIsNotADuplicate(
                            threadId: "testThreadId",
                            uniqueIdentifier: "testId",
                            legacyIdentifier: "testLegacyId",
                            using: dependencies
                        )
                    }.to(throwError(MessageReceiverError.duplicateMessage))
                    await mockExtensionHelper
                        .verify { $0.dedupeRecordExists(threadId: "testThreadId", uniqueIdentifier: "testId") }
                        .wasCalled(exactly: 1)
                    await mockExtensionHelper
                        .verify { $0.dedupeRecordExists(threadId: "testThreadId", uniqueIdentifier: "testLegacyId") }
                        .wasCalled(exactly: 1)
                }
            }
            
            // MARK: -- when ensuring a call message is not a duplicate
            context("when ensuring a call message is not a duplicate") {
                // MARK: ---- does not throw when not a duplicate
                it("does not throw when not a duplicate") {
                    expect {
                        try MessageDeduplication.ensureCallMessageIsNotADuplicate(
                            threadId: "testThreadId",
                            callMessage: CallMessage(
                                uuid: "12345",
                                kind: .preOffer,
                                sdps: [],
                                sentTimestampMs: nil
                            ),
                            using: dependencies
                        )
                    }.toNot(throwError())
                }
                
                // MARK: ---- does nothing if no call message is provided
                it("does nothing if no call message is provided") {
                    expect {
                        try MessageDeduplication.ensureCallMessageIsNotADuplicate(
                            threadId: "testThreadId",
                            callMessage: nil,
                            using: dependencies
                        )
                    }.toNot(throwError())
                }
                
                // MARK: ---- throws when the call message is a duplicate
                it("throws when the call message is a duplicate") {
                    try await mockExtensionHelper
                        .when { $0.dedupeRecordExists(threadId: .any, uniqueIdentifier: .any) }
                        .thenReturn(true)
                    
                    expect {
                        try MessageDeduplication.ensureCallMessageIsNotADuplicate(
                            threadId: "testThreadId",
                            callMessage: CallMessage(
                                uuid: "12345",
                                kind: .preOffer,
                                sdps: [],
                                sentTimestampMs: nil
                            ),
                            using: dependencies
                        )
                    }.to(throwError(MessageReceiverError.duplicatedCall))
                }
            }
        }
    }
}

// MARK: - Convenience

extension CallMessage.Kind: @retroactive CaseIterable {
    public static var allCases: [CallMessage.Kind] = {
        var result: [CallMessage.Kind] = []
        switch CallMessage.Kind.preOffer {
            case .preOffer: result.append(.preOffer); fallthrough
            case .offer: result.append(.offer); fallthrough
            case .answer: result.append(.answer); fallthrough
            case .provisionalAnswer: result.append(.provisionalAnswer); fallthrough
            case .iceCandidates: result.append(.iceCandidates(sdpMLineIndexes: [], sdpMids: [])); fallthrough
            case .endCall: result.append(.endCall)
        }
        
        return result
    }()
}
