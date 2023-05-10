// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation

import Foundation
import Sodium
import SessionUtil
import SessionUtilitiesKit
import SessionMessagingKit

import Quick
import Nimble

class SessionUtilSpec: QuickSpec {
    // MARK: - Spec
    
    override func spec() {
        describe("SessionUtil") {
            // MARK: - Parsing URLs
            
            context("when parsing a community url") {
                it("handles the example urls correctly") {
                    let validUrls: [String] = [
                        [
                            "https://sessionopengroup.co/r/main?",
                            "public_key=658d29b91892a2389505596b135e76a53db6e11d613a51dbd3d0816adffb231c"
                        ],
                        [
                            "https://sessionopengroup.co/main?",
                            "public_key=658d29b91892a2389505596b135e76a53db6e11d613a51dbd3d0816adffb231c"
                        ],
                        [
                            "http://sessionopengroup.co/r/main?",
                            "public_key=658d29b91892a2389505596b135e76a53db6e11d613a51dbd3d0816adffb231c"
                        ],
                        [
                            "http://sessionopengroup.co/main?",
                            "public_key=658d29b91892a2389505596b135e76a53db6e11d613a51dbd3d0816adffb231c"
                        ],
                        [
                            "https://143.198.213.225:443/r/main?",
                            "public_key=658d29b91892a2389505596b135e76a53db6e11d613a51dbd3d0816adffb231c"
                        ],
                        [
                            "https://143.198.213.225:443/main?",
                            "public_key=658d29b91892a2389505596b135e76a53db6e11d613a51dbd3d0816adffb231c"
                        ],
                        [
                            "http://143.198.213.255:80/main?",
                            "public_key=658d29b91892a2389505596b135e76a53db6e11d613a51dbd3d0816adffb231c"
                        ],
                        [
                            "http://143.198.213.255:80/r/main?",
                            "public_key=658d29b91892a2389505596b135e76a53db6e11d613a51dbd3d0816adffb231c"
                        ]
                    ].map { $0.joined() }
                    let processedValues: [(room: String, server: String, publicKey: String)] = validUrls
                        .map { SessionUtil.parseCommunity(url: $0) }
                        .compactMap { $0 }
                    let processedRooms: [String] = processedValues.map { $0.room }
                    let processedServers: [String] = processedValues.map { $0.server }
                    let processedPublicKeys: [String] = processedValues.map { $0.publicKey }
                    let expectedRooms: [String] = [String](repeating: "main", count: 8)
                    let expectedServers: [String] = [
                        "https://sessionopengroup.co",
                        "https://sessionopengroup.co",
                        "http://sessionopengroup.co",
                        "http://sessionopengroup.co",
                        "https://143.198.213.225",
                        "https://143.198.213.225",
                        "http://143.198.213.255",
                        "http://143.198.213.255"
                    ]
                    let expectedPublicKeys: [String] = [String](
                        repeating: "658d29b91892a2389505596b135e76a53db6e11d613a51dbd3d0816adffb231c",
                        count: 8
                    )
                    
                    expect(processedValues.count).to(equal(validUrls.count))
                    expect(processedRooms).to(equal(expectedRooms))
                    expect(processedServers).to(equal(expectedServers))
                    expect(processedPublicKeys).to(equal(expectedPublicKeys))
                }
                
                it("handles the r prefix if present") {
                    let info = SessionUtil.parseCommunity(
                        url: [
                            "https://sessionopengroup.co/r/main?",
                            "public_key=658d29b91892a2389505596b135e76a53db6e11d613a51dbd3d0816adffb231c"
                        ].joined()
                    )
                    
                    expect(info?.room).to(equal("main"))
                    expect(info?.server).to(equal("https://sessionopengroup.co"))
                    expect(info?.publicKey).to(equal("658d29b91892a2389505596b135e76a53db6e11d613a51dbd3d0816adffb231c"))
                }
                
                it("fails if no scheme is provided") {
                    let info = SessionUtil.parseCommunity(
                        url: [
                            "sessionopengroup.co/r/main?",
                            "public_key=658d29b91892a2389505596b135e76a53db6e11d613a51dbd3d0816adffb231c"
                        ].joined()
                    )
                    
                    expect(info?.room).to(beNil())
                    expect(info?.server).to(beNil())
                    expect(info?.publicKey).to(beNil())
                }
                
                it("fails if there is no room") {
                    let info = SessionUtil.parseCommunity(
                        url: [
                            "https://sessionopengroup.co?",
                            "public_key=658d29b91892a2389505596b135e76a53db6e11d613a51dbd3d0816adffb231c"
                        ].joined()
                    )
                    
                    expect(info?.room).to(beNil())
                    expect(info?.server).to(beNil())
                    expect(info?.publicKey).to(beNil())
                }
                
                it("fails if there is no public key parameter") {
                    let info = SessionUtil.parseCommunity(
                        url: "https://sessionopengroup.co/r/main"
                    )
                    
                    expect(info?.room).to(beNil())
                    expect(info?.server).to(beNil())
                    expect(info?.publicKey).to(beNil())
                }
                
                it("fails if the public key parameter is not 64 characters") {
                    let info = SessionUtil.parseCommunity(
                        url: [
                            "https://sessionopengroup.co/r/main?",
                            "public_key=658d29b91892a2389505596b135e76a53db6e11d613a51dbd3d0816adffb231"
                        ].joined()
                    )
                    
                    expect(info?.room).to(beNil())
                    expect(info?.server).to(beNil())
                    expect(info?.publicKey).to(beNil())
                }
                
                it("fails if the public key parameter is not a hex string") {
                    let info = SessionUtil.parseCommunity(
                        url: [
                            "https://sessionopengroup.co/r/main?",
                            "public_key=!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
                        ].joined()
                    )
                    
                    expect(info?.room).to(beNil())
                    expect(info?.server).to(beNil())
                    expect(info?.publicKey).to(beNil())
                }
                
                it("maintains the same TLS") {
                    let server1 = SessionUtil.parseCommunity(
                        url: [
                            "http://sessionopengroup.co/r/main?",
                            "public_key=658d29b91892a2389505596b135e76a53db6e11d613a51dbd3d0816adffb231c"
                        ].joined()
                    )?.server
                    let server2 = SessionUtil.parseCommunity(
                        url: [
                            "https://sessionopengroup.co/r/main?",
                            "public_key=658d29b91892a2389505596b135e76a53db6e11d613a51dbd3d0816adffb231c"
                        ].joined()
                    )?.server
                    
                    expect(server1).to(equal("http://sessionopengroup.co"))
                    expect(server2).to(equal("https://sessionopengroup.co"))
                }
                
                it("maintains the same port") {
                    let server1 = SessionUtil.parseCommunity(
                        url: [
                            "https://sessionopengroup.co/r/main?",
                            "public_key=658d29b91892a2389505596b135e76a53db6e11d613a51dbd3d0816adffb231c"
                        ].joined()
                    )?.server
                    let server2 = SessionUtil.parseCommunity(
                        url: [
                            "https://sessionopengroup.co:1234/r/main?",
                            "public_key=658d29b91892a2389505596b135e76a53db6e11d613a51dbd3d0816adffb231c"
                        ].joined()
                    )?.server
                    
                    expect(server1).to(equal("https://sessionopengroup.co"))
                    expect(server2).to(equal("https://sessionopengroup.co:1234"))
                }
            }
            
            // MARK: - Generating URLs
            
            context("when generating a url") {
                it("generates the url correctly") {
                    expect(SessionUtil.communityUrlFor(server: "server", roomToken: "room", publicKey: "f8fec9b701000000ffffffff0400008000000000000000000000000000000000"))
                        .to(equal("server/room?public_key=f8fec9b701000000ffffffff0400008000000000000000000000000000000000"))
                }
                
                it("maintains the casing provided") {
                    expect(SessionUtil.communityUrlFor(server: "SeRVer", roomToken: "RoOM", publicKey: "f8fec9b701000000ffffffff0400008000000000000000000000000000000000"))
                        .to(equal("SeRVer/RoOM?public_key=f8fec9b701000000ffffffff0400008000000000000000000000000000000000"))
                }
            }
        }
    }
}
