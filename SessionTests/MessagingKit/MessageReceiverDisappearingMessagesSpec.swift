// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Combine
import GRDB
import Quick
import Nimble
import SessionSnodeKit
import SessionUtilitiesKit
import SessionMessagingKit
import SessionUIKit

@testable import Session

class MessageReceiverDisappearingMessagesSpec: QuickSpec {
    // MARK: - Spec

    override func spec() {
        var mockStorage: Storage!
        var mockProto: SNProtoContent!
        var mockMessage: VisibleMessage!
        
        describe("a MessageReceiver") {
            
            // MARK: - Configuration
            
            beforeEach {
                mockStorage = SynchronousStorage(
                    customWriter: try! DatabaseQueue(),
                    customMigrationTargets: [
                        SNUtilitiesKit.self,
                        SNSnodeKit.self,
                        SNMessagingKit.self,
                        SNUIKit.self
                    ]
                )
                
                let proto = SNProtoContent.builder()
                let dataMessage = SNProtoDataMessage.builder()
                proto.setExpirationType(.deleteAfterRead)
                proto.setExpirationTimer(UInt32(DisappearingMessagesConfiguration.DefaultDuration.disappearAfterRead.seconds))
                proto.setLastDisappearingMessageChangeTimestamp((1234567890 - (60 * 10)) * 1000)
                dataMessage.setBody("Test")
                proto.setDataMessage(try! dataMessage.build())
                mockProto = try? proto.build()
                
                mockMessage = VisibleMessage(
                    sender: "TestId",
                    sentTimestamp: ((1234567890 - (60 * 10)) * 1000),
                    recipient: "05\(TestConstants.publicKey)",
                    text: "Test"
                )
                mockMessage.receivedTimestamp = (1234567890 * 1000)
                
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
            
            // MARK: - when receiving an outdated disappearing message config update
            context("when receiving an outdated disappearing message config update") {
                // MARK: -- does NOT update local config
                it("does NOT update local config") {
                    let config: DisappearingMessagesConfiguration = DisappearingMessagesConfiguration
                        .defaultWith("TestId")
                        .with(
                            isEnabled: false,
                            durationSeconds: 0,
                            type: .unknown,
                            lastChangeTimestampMs: (1234567890 * 1000)
                        )
                    
                    mockStorage.write { db in
                        try config.save(db)
                        
                        try MessageReceiver.handle(
                            db,
                            threadId: "TestId",
                            threadVariant: .contact,
                            message: mockMessage,
                            serverExpirationTimestamp: nil,
                            associatedWithProto: mockProto
                        )
                    }
                    
                    let updatedConfig: DisappearingMessagesConfiguration? = mockStorage.read { db in
                        try DisappearingMessagesConfiguration.fetchOne(db, id: "TestId")
                    }
                    
                    expect(updatedConfig?.isEnabled).to(beFalse())
                    expect(updatedConfig?.durationSeconds).to(equal(0))
                    expect(updatedConfig?.type).to(equal(.unknown))
                }
            }
            
            // MARK: - when receiving a newer disappearing message config update
            context("when receiving a newer disappearing message config update") {
                // MARK: -- updates the local config properly
                it("updates the local config properly") {
                    mockStorage.write { db in
                        try MessageReceiver.updateDisappearingMessagesConfigurationIfNeeded(
                            db,
                            threadId: "TestId",
                            threadVariant: .contact,
                            message: mockMessage,
                            proto: mockProto
                        )
                    }
                    
                    let updatedConfig: DisappearingMessagesConfiguration? = mockStorage.read { db in
                        try DisappearingMessagesConfiguration.fetchOne(db, id: "TestId")
                    }
                    
                    expect(updatedConfig?.isEnabled).to(beTrue())
//                    expect(updatedConfig?.durationSeconds)
//                        .to(equal(DisappearingMessagesConfiguration.DefaultDuration.disappearAfterRead.seconds))
                    expect(updatedConfig?.type).to(equal(.disappearAfterRead))
                }
            }
        }
    }
}
