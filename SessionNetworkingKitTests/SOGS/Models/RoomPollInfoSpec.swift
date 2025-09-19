// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation

import Quick
import Nimble

@testable import SessionNetworkingKit

class RoomPollInfoSpec: QuickSpec {
    override class func spec() {
        // MARK: - a RoomPollInfo
        describe("a RoomPollInfo") {
            // MARK: -- when initializing with a room
            context("when initializing with a room") {
                // MARK: ---- copies all the relevant values across
                it("copies all the relevant values across") {
                    let room: Network.SOGS.Room = Network.SOGS.Room(
                        token: "testToken",
                        name: "testName",
                        roomDescription: nil,
                        infoUpdates: 123,
                        messageSequence: 0,
                        created: 0,
                        activeUsers: 234,
                        activeUsersCutoff: 0,
                        imageId: nil,
                        pinnedMessages: nil,
                        admin: true,
                        globalAdmin: true,
                        admins: [],
                        hiddenAdmins: nil,
                        moderator: true,
                        globalModerator: true,
                        moderators: [],
                        hiddenModerators: nil,
                        read: true,
                        defaultRead: true,
                        defaultAccessible: true,
                        write: true,
                        defaultWrite: true,
                        upload: true,
                        defaultUpload: true
                    )
                    let roomPollInfo: Network.SOGS.RoomPollInfo = Network.SOGS.RoomPollInfo(room: room)
                    
                    expect(roomPollInfo.token).to(equal(room.token))
                    expect(roomPollInfo.activeUsers).to(equal(room.activeUsers))
                    expect(roomPollInfo.admin).to(equal(room.admin))
                    expect(roomPollInfo.globalAdmin).to(equal(room.globalAdmin))
                    expect(roomPollInfo.moderator).to(equal(room.moderator))
                    expect(roomPollInfo.globalModerator).to(equal(room.globalModerator))
                    expect(roomPollInfo.read).to(equal(room.read))
                    expect(roomPollInfo.defaultRead).to(equal(room.defaultRead))
                    expect(roomPollInfo.defaultAccessible).to(equal(room.defaultAccessible))
                    expect(roomPollInfo.write).to(equal(room.write))
                    expect(roomPollInfo.defaultWrite).to(equal(room.defaultWrite))
                    expect(roomPollInfo.upload).to(equal(room.upload))
                    expect(roomPollInfo.defaultUpload).to(equal(room.defaultUpload))
                    expect(roomPollInfo.details).to(equal(room))
                }
            }
            
            // MARK: -- when decoding
            context("when decoding") {
                // MARK: ---- defaults admin and moderator values to false if omitted
                it("defaults admin and moderator values to false if omitted") {
                    let roomPollInfoJson: String = """
                    {
                        "token": "testToken",
                        "active_users": 0,
                        
                        "read": true,
                        "default_read": true,
                        "default_accessible": true,
                        "write": true,
                        "default_write": true,
                        "upload": true,
                        "default_upload": true,
                    
                        "details": null
                    }
                    """
                    let roomData: Data = roomPollInfoJson.data(using: .utf8)!
                    let result: Network.SOGS.RoomPollInfo = try! JSONDecoder().decode(Network.SOGS.RoomPollInfo.self, from: roomData)
                    
                    expect(result.admin).to(beFalse())
                    expect(result.globalAdmin).to(beFalse())
                    expect(result.moderator).to(beFalse())
                    expect(result.globalModerator).to(beFalse())
                }
                
                // MARK: ---- sets the admin and moderator values when provided
                it("sets the admin and moderator values when provided") {
                    let roomPollInfoJson: String = """
                    {
                        "token": "testToken",
                        "active_users": 0,
                    
                        "admin": true,
                        "global_admin": true,
                    
                        "moderator": true,
                        "global_moderator": true,
                        
                        "read": true,
                        "default_read": true,
                        "default_accessible": true,
                        "write": true,
                        "default_write": true,
                        "upload": true,
                        "default_upload": true,
                    
                        "details": null
                    }
                    """
                    let roomData: Data = roomPollInfoJson.data(using: .utf8)!
                    let result: Network.SOGS.RoomPollInfo = try! JSONDecoder().decode(Network.SOGS.RoomPollInfo.self, from: roomData)
                    
                    expect(result.admin).to(beTrue())
                    expect(result.globalAdmin).to(beTrue())
                    expect(result.moderator).to(beTrue())
                    expect(result.globalModerator).to(beTrue())
                }
            }
        }
    }
}
