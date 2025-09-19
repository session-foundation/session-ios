// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation

import Quick
import Nimble

@testable import SessionNetworkingKit

class RoomSpec: QuickSpec {
    override class func spec() {
        // MARK: - a Room
        describe("a Room") {
            // MARK: -- when decoding
            context("when decoding") {
                // MARK: ---- defaults admin and moderator values to false if omitted
                it("defaults admin and moderator values to false if omitted") {
                    let roomJson: String = """
                    {
                        "token": "testToken",
                        "name": "testName",
                        "description": "testDescription",
                        "info_updates": 0,
                        "message_sequence": 0,
                        "created": 1,
                                
                        "active_users": 0,
                        "active_users_cutoff": 0,
                        "image_id": 0,
                        "pinned_messages": [],
                                
                        "admins": [],
                        "hidden_admins": [],
                                
                        "moderators": [],
                        "hidden_moderators": [],
                                
                        "read": true,
                        "default_read": true,
                        "default_accessible": true,
                        "write": true,
                        "default_write": true,
                        "upload": true,
                        "default_upload": true
                    }
                    """
                    let roomData: Data = roomJson.data(using: .utf8)!
                    let result: Network.SOGS.Room = try! JSONDecoder().decode(Network.SOGS.Room.self, from: roomData)
                    
                    expect(result.admin).to(beFalse())
                    expect(result.globalAdmin).to(beFalse())
                    expect(result.moderator).to(beFalse())
                    expect(result.globalModerator).to(beFalse())
                }
                
                // MARK: ---- sets the admin and moderator values when provided
                it("sets the admin and moderator values when provided") {
                    let roomJson: String = """
                    {
                        "token": "testToken",
                        "name": "testName",
                        "description": "testDescription",
                        "info_updates": 0,
                        "message_sequence": 0,
                        "created": 1,
                                
                        "active_users": 0,
                        "active_users_cutoff": 0,
                        "image_id": 0,
                        "pinned_messages": [],
                        
                        "admin": true,
                        "global_admin": true,
                        "admins": [],
                        "hidden_admins": [],
                        
                        "moderator": true,
                        "global_moderator": true,
                        "moderators": [],
                        "hidden_moderators": [],
                                
                        "read": true,
                        "default_read": true,
                        "default_accessible": true,
                        "write": true,
                        "default_write": true,
                        "upload": true,
                        "default_upload": true
                    }
                    """
                    let roomData: Data = roomJson.data(using: .utf8)!
                    let result: Network.SOGS.Room = try! JSONDecoder().decode(Network.SOGS.Room.self, from: roomData)
                    
                    expect(result.admin).to(beTrue())
                    expect(result.globalAdmin).to(beTrue())
                    expect(result.moderator).to(beTrue())
                    expect(result.globalModerator).to(beTrue())
                }
            }
        }
    }
}
