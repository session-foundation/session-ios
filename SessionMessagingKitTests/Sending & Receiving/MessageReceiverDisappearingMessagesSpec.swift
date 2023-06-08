// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Sodium
import GRDB
import SessionUtilitiesKit

import Quick
import Nimble

@testable import SessionMessagingKit

class MessageReceiverDisappearingMessagesSpec: QuickSpec {
    // MARK: - Spec

    override func spec() {
        var mockStorage: Storage!
        var mockProto: SNProtoContent!
        var mockMessage: VisibleMessage!
        
        describe("a MessageReceiver") {
            beforeEach {
                mockStorage = Storage(
                    customWriter: try! DatabaseQueue(),
                    customMigrations: [
                        SNUtilitiesKit.migrations(),
                        SNMessagingKit.migrations(),
                    ]
                )
                
                let timestampMs: UInt64 = UInt64(Date().timeIntervalSince1970) - 10 * 60 * 1000 // 10 minutes ago
                
                let proto = SNProtoContent.builder()
                proto.setExpirationType(.deleteAfterSend)
                proto.setExpirationTimer(UInt32(DisappearingMessagesConfiguration.DefaultDuration.disappearAfterSend.seconds))
                proto.setLastDisappearingMessageChangeTimestamp(timestampMs)
                mockProto = try? proto.build()
                
                mockMessage = VisibleMessage(
                    sender: "TestId",
                    sentTimestamp: timestampMs,
                    text: "Test"
                )
            }
            
            afterEach {
                mockStorage = nil
                mockProto = nil
            }
            
            // MARK: - Basic Tests
            
            it("Handle disappearing messages config update properly") {
                let updatedConfig: DisappearingMessagesConfiguration? = mockStorage.write { db in
                    try MessageReceiver.handle(
                        db,
                        threadId: "TestId",
                        threadVariant: .contact,
                        message: mockMessage,
                        serverExpirationTimestamp: nil,
                        associatedWithProto: mockProto
                    )
                    
                    return try? DisappearingMessagesConfiguration.fetchOne(db, id: "TestId")
                }
                
                expect(updatedConfig?.isEnabled)
                    .toEventually(
                        beTrue(),
                        timeout: .milliseconds(100)
                    )
                expect(updatedConfig?.durationSeconds)
                    .toEventually(
                        equal(DisappearingMessagesConfiguration.DefaultDuration.disappearAfterSend.seconds),
                        timeout: .milliseconds(100)
                    )
                expect(updatedConfig?.type)
                    .toEventually(
                        equal(.disappearAfterSend),
                        timeout: .milliseconds(100)
                    )
            }
            
            it("Do NOT handle outdated disappearing messages config update") {
                let config: DisappearingMessagesConfiguration = DisappearingMessagesConfiguration
                    .defaultWith("TestId")
                    .with(
                        isEnabled: false,
                        durationSeconds: 0,
                        type: .unknown,
                        lastChangeTimestampMs: Int64(Date().timeIntervalSince1970)
                    )
                
                let updatedConfig: DisappearingMessagesConfiguration? = mockStorage.write { db in
                    try config.save(db)
                    
                    try MessageReceiver.handle(
                        db,
                        threadId: "TestId",
                        threadVariant: .contact,
                        message: mockMessage,
                        serverExpirationTimestamp: nil,
                        associatedWithProto: mockProto
                    )
                    
                    return try? DisappearingMessagesConfiguration.fetchOne(db, id: "TestId")
                }
                
                expect(updatedConfig?.isEnabled)
                    .toEventually(
                        beFalse(),
                        timeout: .milliseconds(100)
                    )
                expect(updatedConfig?.durationSeconds)
                    .toEventually(
                        equal(0),
                        timeout: .milliseconds(100)
                    )
                expect(updatedConfig?.type)
                    .toEventually(
                        equal(.unknown),
                        timeout: .milliseconds(100)
                    )
            }
        }
    }
}
