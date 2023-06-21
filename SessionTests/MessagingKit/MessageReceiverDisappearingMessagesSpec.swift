// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Combine
import GRDB
import Quick
import Nimble

@testable import Session

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
                        SNSnodeKit.migrations(),
                        SNMessagingKit.migrations(),
                        SNUIKit.migrations()
                    ]
                )
                
                let timestampMs: UInt64 = UInt64(Date().timeIntervalSince1970) - 10 * 60 * 1000 // 10 minutes ago
                
                let proto = SNProtoContent.builder()
                let dataMessage = SNProtoDataMessage.builder()
                proto.setExpirationType(.deleteAfterSend)
                proto.setExpirationTimer(UInt32(DisappearingMessagesConfiguration.DefaultDuration.disappearAfterSend.seconds))
                proto.setLastDisappearingMessageChangeTimestamp(timestampMs)
                dataMessage.setBody("Test")
                proto.setDataMessage(try! dataMessage.build())
                mockProto = try? proto.build()
                
                mockMessage = VisibleMessage(
                    sender: "TestId",
                    sentTimestamp: timestampMs,
                    recipient: getUserHexEncodedPublicKey(),
                    text: "Test"
                )
                mockMessage.receivedTimestamp = UInt64(Date().timeIntervalSince1970)
                
                mockStorage.write { db in
                    try SessionThread.fetchOrCreate(
                        db,
                        id: "TestId",
                        variant: .contact,
                        shouldBeVisible: true
                    )
                }
            }
            
            afterEach {
                mockStorage = nil
                mockProto = nil
            }
            
            // MARK: - Basic Tests
            
            context("Receive a newer disappearing message config update") {
                it("Update local config properly") {
                    mockStorage.write { db in
                        do {
                            try MessageReceiver.handle(
                                db,
                                threadId: "TestId",
                                threadVariant: .contact,
                                message: mockMessage,
                                serverExpirationTimestamp: nil,
                                associatedWithProto: mockProto
                            )
                        } catch {
                            print(error)
                        }
                        
                    }
                    
                    let updatedConfig: DisappearingMessagesConfiguration? = mockStorage.read { db in
                        try DisappearingMessagesConfiguration.fetchOne(db, id: "TestId")
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
            }
            
            context("Receive a outdated disappearing message config update") {
                it("Do NOT update local config") {
                    let config: DisappearingMessagesConfiguration = DisappearingMessagesConfiguration
                        .defaultWith("TestId")
                        .with(
                            isEnabled: false,
                            durationSeconds: 0,
                            type: .unknown,
                            lastChangeTimestampMs: Int64(Date().timeIntervalSince1970)
                        )
                    
                    mockStorage.write { db in
                        try config.save(db)
                    }
                    
                    mockStorage.write { db in
                        do {
                            try MessageReceiver.handle(
                                db,
                                threadId: "TestId",
                                threadVariant: .contact,
                                message: mockMessage,
                                serverExpirationTimestamp: nil,
                                associatedWithProto: mockProto
                            )
                        } catch {
                            print(error)
                        }
                        
                    }
                    
                    let updatedConfig: DisappearingMessagesConfiguration? = mockStorage.read { db in
                        try DisappearingMessagesConfiguration.fetchOne(db, id: "TestId")
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
}
