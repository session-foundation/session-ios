// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation

import Quick
import Nimble

@testable import SessionNetworkingKit

class SOGSEndpointSpec: QuickSpec {
    override class func spec() {
        // MARK: - a SOGSEndpoint
        describe("a SOGSEndpoint") {
            // MARK: -- provides the correct batch request variant
            it("provides the correct batch request variant") {
                expect(Network.SOGS.Endpoint.batchRequestVariant).to(equal(.sogs))
            }
            
            // MARK: -- excludes the correct headers from batch sub request
            it("excludes the correct headers from batch sub request") {
                expect(Network.SOGS.Endpoint.excludedSubRequestHeaders).to(equal([
                    HTTPHeader.sogsPubKey,
                    HTTPHeader.sogsTimestamp,
                    HTTPHeader.sogsNonce,
                    HTTPHeader.sogsSignature
                ]))
            }
            
            // MARK: -- generates the path value correctly
            it("generates the path value correctly") {
                // Utility
                
                expect(Network.SOGS.Endpoint.onion.path).to(equal("oxen/v4/lsrpc"))
                expect(Network.SOGS.Endpoint.batch.path).to(equal("batch"))
                expect(Network.SOGS.Endpoint.sequence.path).to(equal("sequence"))
                expect(Network.SOGS.Endpoint.capabilities.path).to(equal("capabilities"))
                
                // Rooms
                
                expect(Network.SOGS.Endpoint.rooms.path).to(equal("rooms"))
                expect(Network.SOGS.Endpoint.room("test").path).to(equal("room/test"))
                expect(Network.SOGS.Endpoint.roomPollInfo("test", 123).path).to(equal("room/test/pollInfo/123"))
                
                // Messages
                
                expect(Network.SOGS.Endpoint.roomMessage("test").path).to(equal("room/test/message"))
                expect(Network.SOGS.Endpoint.roomMessageIndividual("test", id: 123).path).to(equal("room/test/message/123"))
                expect(Network.SOGS.Endpoint.roomMessagesRecent("test").path).to(equal("room/test/messages/recent"))
                expect(Network.SOGS.Endpoint.roomMessagesBefore("test", id: 123).path).to(equal("room/test/messages/before/123"))
                expect(Network.SOGS.Endpoint.roomMessagesSince("test", seqNo: 123).path)
                    .to(equal("room/test/messages/since/123"))
                expect(Network.SOGS.Endpoint.roomDeleteMessages("test", sessionId: "testId").path)
                    .to(equal("room/test/all/testId"))
                
                // Pinning
                
                expect(Network.SOGS.Endpoint.roomPinMessage("test", id: 123).path).to(equal("room/test/pin/123"))
                expect(Network.SOGS.Endpoint.roomUnpinMessage("test", id: 123).path).to(equal("room/test/unpin/123"))
                expect(Network.SOGS.Endpoint.roomUnpinAll("test").path).to(equal("room/test/unpin/all"))
                
                // Files
                
                expect(Network.SOGS.Endpoint.roomFile("test").path).to(equal("room/test/file"))
                expect(Network.SOGS.Endpoint.roomFileIndividual("test", "123").path).to(equal("room/test/file/123"))
                
                // Inbox/Outbox (Message Requests)
                
                expect(Network.SOGS.Endpoint.inbox.path).to(equal("inbox"))
                expect(Network.SOGS.Endpoint.inboxSince(id: 123).path).to(equal("inbox/since/123"))
                expect(Network.SOGS.Endpoint.inboxFor(sessionId: "test").path).to(equal("inbox/test"))
                
                expect(Network.SOGS.Endpoint.outbox.path).to(equal("outbox"))
                expect(Network.SOGS.Endpoint.outboxSince(id: 123).path).to(equal("outbox/since/123"))
                
                // Users
                
                expect(Network.SOGS.Endpoint.userBan("test").path).to(equal("user/test/ban"))
                expect(Network.SOGS.Endpoint.userUnban("test").path).to(equal("user/test/unban"))
                expect(Network.SOGS.Endpoint.userModerator("test").path).to(equal("user/test/moderator"))
            }
        }
    }
}
