// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtil
import SessionUtilitiesKit

import Quick
import Nimble

@testable import SessionSnodeKit
@testable import SessionMessagingKit

class LibSessionSpec: QuickSpec {
    override class func spec() {
        // MARK: Configuration
        
        @TestState var dependencies: TestDependencies! = TestDependencies { dependencies in
            dependencies.dateNow = Date(timeIntervalSince1970: 1234567890)
            dependencies.forceSynchronous = true
        }
        @TestState(cache: .general, in: dependencies) var mockGeneralCache: MockGeneralCache! = MockGeneralCache(
            initialSetup: { cache in
                cache.when { $0.sessionId }.thenReturn(SessionId(.standard, hex: TestConstants.publicKey))
            }
        )
        @TestState(singleton: .storage, in: dependencies) var mockStorage: Storage! = SynchronousStorage(
            customWriter: try! DatabaseQueue(),
            migrationTargets: [
                SNUtilitiesKit.self,
                SNMessagingKit.self
            ],
            using: dependencies,
            initialData: { db in
                try Identity(variant: .x25519PublicKey, data: Data(hex: TestConstants.publicKey)).insert(db)
                try Identity(variant: .x25519PrivateKey, data: Data(hex: TestConstants.privateKey)).insert(db)
                try Identity(variant: .ed25519PublicKey, data: Data(hex: TestConstants.edPublicKey)).insert(db)
                try Identity(variant: .ed25519SecretKey, data: Data(hex: TestConstants.edSecretKey)).insert(db)
            }
        )
        @TestState(singleton: .crypto, in: dependencies) var mockCrypto: MockCrypto! = MockCrypto(
            initialSetup: { crypto in
                crypto
                    .when { $0.generate(.ed25519KeyPair()) }
                    .thenReturn(
                        KeyPair(
                            publicKey: Array(Data(hex: "cbd569f56fb13ea95a3f0c05c331cc24139c0090feb412069dc49fab34406ece")),
                            secretKey: Array(Data(
                                hex: "0123456789abcdef0123456789abcdeffedcba9876543210fedcba9876543210" +
                                "cbd569f56fb13ea95a3f0c05c331cc24139c0090feb412069dc49fab34406ece"
                            ))
                        )
                    )
                crypto
                    .when { $0.generate(.ed25519KeyPair(seed: .any)) }
                    .thenReturn(
                        KeyPair(
                            publicKey: Array(Data(hex: "cbd569f56fb13ea95a3f0c05c331cc24139c0090feb412069dc49fab34406ece")),
                            secretKey: Array(Data(
                                hex: "0123456789abcdef0123456789abcdeffedcba9876543210fedcba9876543210" +
                                "cbd569f56fb13ea95a3f0c05c331cc24139c0090feb412069dc49fab34406ece"
                            ))
                        )
                    )
                crypto
                    .when { try $0.tryGenerate(.signature(message: .any, ed25519SecretKey: .any)) }
                    .thenReturn(
                        Authentication.Signature.standard(signature: Array("TestSignature".data(using: .utf8)!))
                    )
            }
        )
        @TestState var createGroupOutput: LibSession.CreatedGroupInfo! = {
            mockStorage.write { db in
                 try LibSession.createGroup(
                    db,
                    name: "TestGroup",
                    description: nil,
                    displayPictureUrl: nil,
                    displayPictureFilename: nil,
                    displayPictureEncryptionKey: nil,
                    members: [],
                    using: dependencies
                 )
            }
        }()
        @TestState(cache: .libSession, in: dependencies) var mockLibSessionCache: MockLibSessionCache! = MockLibSessionCache(
            initialSetup: { cache in
                var conf: UnsafeMutablePointer<config_object>!
                var secretKey: [UInt8] = Array(Data(hex: TestConstants.edSecretKey))
                _ = user_groups_init(&conf, &secretKey, nil, 0, nil)
                
                cache.when { $0.setConfig(for: .any, sessionId: .any, to: .any) }.thenReturn(())
                cache.when { $0.config(for: .userGroups, sessionId: .any) }
                    .thenReturn(.userGroups(conf))
                cache.when { $0.config(for: .groupInfo, sessionId: .any) }
                    .thenReturn(createGroupOutput.groupState[.groupInfo])
                cache.when { $0.config(for: .groupMembers, sessionId: .any) }
                    .thenReturn(createGroupOutput.groupState[.groupMembers])
                cache.when { $0.config(for: .groupKeys, sessionId: .any) }
                    .thenReturn(createGroupOutput.groupState[.groupKeys])
                cache.when { $0.configNeedsDump(.any) }.thenReturn(false)
                cache
                    .when { try $0.createDump(config: .any, for: .any, sessionId: .any, timestampMs: .any) }
                    .thenReturn(nil)
                cache
                    .when { try $0.performAndPushChange(.any, for: .any, sessionId: .any, change: { _ in }) }
                    .then { args, untrackedArgs in
                        let callback: ((LibSession.Config?) throws -> Void)? = (untrackedArgs[test: 1] as? (LibSession.Config?) throws -> Void)
                        
                        switch args[test: 0] as? ConfigDump.Variant {
                            case .userGroups: try? callback?(.userGroups(conf))
                            case .groupInfo: try? callback?(createGroupOutput.groupState[.groupInfo])
                            case .groupMembers: try? callback?(createGroupOutput.groupState[.groupMembers])
                            case .groupKeys: try? callback?(createGroupOutput.groupState[.groupKeys])
                            default: break
                        }
                    }
                    .thenReturn(())
            }
        )
        @TestState var userGroupsConfig: LibSession.Config!
        
        // MARK: - LibSession
        describe("LibSession") {
            // MARK: -- when parsing a community url
            context("when parsing a community url") {
                // MARK: ---- handles the example urls correctly
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
                        .map { LibSession.parseCommunity(url: $0) }
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

                // MARK: ---- handles the r prefix if present
                it("handles the r prefix if present") {
                    let info = LibSession.parseCommunity(
                        url: [
                            "https://sessionopengroup.co/r/main?",
                            "public_key=658d29b91892a2389505596b135e76a53db6e11d613a51dbd3d0816adffb231c"
                        ].joined()
                    )
                    
                    expect(info?.room).to(equal("main"))
                    expect(info?.server).to(equal("https://sessionopengroup.co"))
                    expect(info?.publicKey).to(equal("658d29b91892a2389505596b135e76a53db6e11d613a51dbd3d0816adffb231c"))
                }

                // MARK: ---- fails if no scheme is provided
                it("fails if no scheme is provided") {
                    let info = LibSession.parseCommunity(
                        url: [
                            "sessionopengroup.co/r/main?",
                            "public_key=658d29b91892a2389505596b135e76a53db6e11d613a51dbd3d0816adffb231c"
                        ].joined()
                    )
                    
                    expect(info?.room).to(beNil())
                    expect(info?.server).to(beNil())
                    expect(info?.publicKey).to(beNil())
                }
                
                // MARK: ---- fails if there is no room
                it("fails if there is no room") {
                    let info = LibSession.parseCommunity(
                        url: [
                            "https://sessionopengroup.co?",
                            "public_key=658d29b91892a2389505596b135e76a53db6e11d613a51dbd3d0816adffb231c"
                        ].joined()
                    )
                    
                    expect(info?.room).to(beNil())
                    expect(info?.server).to(beNil())
                    expect(info?.publicKey).to(beNil())
                }
                
                // MARK: ---- fails if there is no public key parameter
                it("fails if there is no public key parameter") {
                    let info = LibSession.parseCommunity(
                        url: "https://sessionopengroup.co/r/main"
                    )
                    
                    expect(info?.room).to(beNil())
                    expect(info?.server).to(beNil())
                    expect(info?.publicKey).to(beNil())
                }
                
                // MARK: ---- fails if the public key parameter is not 64 characters
                it("fails if the public key parameter is not 64 characters") {
                    let info = LibSession.parseCommunity(
                        url: [
                            "https://sessionopengroup.co/r/main?",
                            "public_key=658d29b91892a2389505596b135e76a53db6e11d613a51dbd3d0816adffb231"
                        ].joined()
                    )
                    
                    expect(info?.room).to(beNil())
                    expect(info?.server).to(beNil())
                    expect(info?.publicKey).to(beNil())
                }
                
                // MARK: ---- fails if the public key parameter is not a hex string
                it("fails if the public key parameter is not a hex string") {
                    let info = LibSession.parseCommunity(
                        url: [
                            "https://sessionopengroup.co/r/main?",
                            "public_key=!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
                        ].joined()
                    )
                    
                    expect(info?.room).to(beNil())
                    expect(info?.server).to(beNil())
                    expect(info?.publicKey).to(beNil())
                }
                
                // MARK: ---- maintains the same TLS
                it("maintains the same TLS") {
                    let server1 = LibSession.parseCommunity(
                        url: [
                            "http://sessionopengroup.co/r/main?",
                            "public_key=658d29b91892a2389505596b135e76a53db6e11d613a51dbd3d0816adffb231c"
                        ].joined()
                    )?.server
                    let server2 = LibSession.parseCommunity(
                        url: [
                            "https://sessionopengroup.co/r/main?",
                            "public_key=658d29b91892a2389505596b135e76a53db6e11d613a51dbd3d0816adffb231c"
                        ].joined()
                    )?.server
                    
                    expect(server1).to(equal("http://sessionopengroup.co"))
                    expect(server2).to(equal("https://sessionopengroup.co"))
                }
                
                // MARK: ---- maintains the same port
                it("maintains the same port") {
                    let server1 = LibSession.parseCommunity(
                        url: [
                            "https://sessionopengroup.co/r/main?",
                            "public_key=658d29b91892a2389505596b135e76a53db6e11d613a51dbd3d0816adffb231c"
                        ].joined()
                    )?.server
                    let server2 = LibSession.parseCommunity(
                        url: [
                            "https://sessionopengroup.co:1234/r/main?",
                            "public_key=658d29b91892a2389505596b135e76a53db6e11d613a51dbd3d0816adffb231c"
                        ].joined()
                    )?.server
                    
                    expect(server1).to(equal("https://sessionopengroup.co"))
                    expect(server2).to(equal("https://sessionopengroup.co:1234"))
                }
            }
            
            // MARK: -- when generating a url
            context("when generating a url") {
                // MARK: ---- generates the url correctly
                it("generates the url correctly") {
                    expect(LibSession.communityUrlFor(server: "server", roomToken: "room", publicKey: "f8fec9b701000000ffffffff0400008000000000000000000000000000000000"))
                        .to(equal("server/room?public_key=f8fec9b701000000ffffffff0400008000000000000000000000000000000000"))
                }
                
                // MARK: ---- maintains the casing provided
                it("maintains the casing provided") {
                    expect(LibSession.communityUrlFor(server: "SeRVer", roomToken: "RoOM", publicKey: "f8fec9b701000000ffffffff0400008000000000000000000000000000000000"))
                        .to(equal("SeRVer/RoOM?public_key=f8fec9b701000000ffffffff0400008000000000000000000000000000000000"))
                }
                
                // MARK: ---- returns null when given a null value
                it("returns null when given a null value") {
                    expect(LibSession.communityUrlFor(server: nil, roomToken: "RoOM", publicKey: "f8fec9b701000000ffffffff0400008000000000000000000000000000000000"))
                        .to(beNil())
                }
            }
            
            // MARK: -- when creating a group
            context("when creating a group") {
                beforeEach {
                    var userGroupsConf: UnsafeMutablePointer<config_object>!
                    var secretKey: [UInt8] = Array(Data(hex: TestConstants.edSecretKey))
                    _ = user_groups_init(&userGroupsConf, &secretKey, nil, 0, nil)
                    userGroupsConfig = .userGroups(userGroupsConf)
                    
                    mockLibSessionCache
                        .when { $0.config(for: .userGroups, sessionId: .any) }
                        .thenReturn(userGroupsConfig)
                }
                
                // MARK: ---- throws when there is no user ed25519 keyPair
                it("throws when there is no user ed25519 keyPair") {
                    var resultError: Error? = nil
                    
                    mockStorage.write { db in
                        try Identity.filter(id: .ed25519PublicKey).deleteAll(db)
                        try Identity.filter(id: .ed25519SecretKey).deleteAll(db)
                        
                        do {
                            _ = try LibSession.createGroup(
                                db,
                                name: "Testname",
                                description: nil,
                                displayPictureUrl: nil,
                                displayPictureFilename: nil,
                                displayPictureEncryptionKey: nil,
                                members: [],
                                using: dependencies
                            )
                        }
                        catch { resultError = error }
                    }
                    
                    expect(resultError).to(matchError(MessageSenderError.noKeyPair))
                }
                
                // MARK: ---- throws when it fails to generate a new identity ed25519 keyPair
                it("throws when it fails to generate a new identity ed25519 keyPair") {
                    var resultError: Error? = nil
                    
                    mockCrypto.when { $0.generate(.ed25519KeyPair()) }.thenReturn(nil)
                    
                    mockStorage.write { db in
                        do {
                            _ = try LibSession.createGroup(
                                db,
                                name: "Testname",
                                description: nil,
                                displayPictureUrl: nil,
                                displayPictureFilename: nil,
                                displayPictureEncryptionKey: nil,
                                members: [],
                                using: dependencies
                            )
                        }
                        catch { resultError = error }
                    }
                    
                    expect(resultError).to(matchError(MessageSenderError.noKeyPair))
                }
                
                // MARK: ---- throws when given an invalid member id
                it("throws when given an invalid member id") {
                    var resultError: Error? = nil
                    
                    mockStorage.write { db in
                        do {
                            _ = try LibSession.createGroup(
                                db,
                                name: "Testname",
                                description: nil,
                                displayPictureUrl: nil,
                                displayPictureFilename: nil,
                                displayPictureEncryptionKey: nil,
                                members: [(
                                    id: "123456",
                                    profile: Profile(
                                        id: "123456",
                                        name: ""
                                    )
                                )],
                                using: dependencies
                            )
                        }
                        catch { resultError = error }
                    }
                    
                    expect(resultError)
                        .to(matchError(LibSessionError.libSessionError("Invalid session ID: expected 66 hex digits starting with 05; got 123456")))
                }
                
                // MARK: ---- returns the correct identity keyPair
                it("returns the correct identity keyPair") {
                    createGroupOutput = mockStorage.write { db in
                        try LibSession.createGroup(
                            db,
                            name: "Testname",
                            description: nil,
                            displayPictureUrl: nil,
                            displayPictureFilename: nil,
                            displayPictureEncryptionKey: nil,
                            members: [],
                            using: dependencies
                        )
                    }
                    
                    expect(createGroupOutput.identityKeyPair.publicKey.toHexString())
                        .to(equal("cbd569f56fb13ea95a3f0c05c331cc24139c0090feb412069dc49fab34406ece"))
                    expect(createGroupOutput.identityKeyPair.secretKey.toHexString())
                        .to(equal(
                            "0123456789abcdef0123456789abcdeffedcba9876543210fedcba9876543210" +
                            "cbd569f56fb13ea95a3f0c05c331cc24139c0090feb412069dc49fab34406ece"
                        ))
                }
                
                // MARK: ---- returns a closed group with the correct data set
                it("returns a closed group with the correct data set") {
                    createGroupOutput = mockStorage.write { db in
                        try LibSession.createGroup(
                            db,
                            name: "Testname",
                            description: nil,
                            displayPictureUrl: "TestUrl",
                            displayPictureFilename: "TestFilename",
                            displayPictureEncryptionKey: Data([1, 2, 3]),
                            members: [],
                            using: dependencies
                        )
                    }
                    
                    expect(createGroupOutput.group.threadId)
                        .to(equal("03cbd569f56fb13ea95a3f0c05c331cc24139c0090feb412069dc49fab34406ece"))
                    expect(createGroupOutput.group.groupIdentityPrivateKey?.toHexString())
                        .to(equal(
                            "0123456789abcdef0123456789abcdeffedcba9876543210fedcba9876543210" +
                            "cbd569f56fb13ea95a3f0c05c331cc24139c0090feb412069dc49fab34406ece"
                        ))
                    expect(createGroupOutput.group.name).to(equal("Testname"))
                    expect(createGroupOutput.group.displayPictureUrl).to(equal("TestUrl"))
                    expect(createGroupOutput.group.displayPictureFilename).to(equal("TestFilename"))
                    expect(createGroupOutput.group.displayPictureEncryptionKey).to(equal(Data([1, 2, 3])))
                    expect(createGroupOutput.group.formationTimestamp).to(equal(1234567890))
                    expect(createGroupOutput.group.invited).to(beFalse())
                }
                
                // MARK: ---- returns the members setup correctly
                it("returns the members setup correctly") {
                    createGroupOutput = mockStorage.write { db in
                        try LibSession.createGroup(
                            db,
                            name: "Testname",
                            description: nil,
                            displayPictureUrl: nil,
                            displayPictureFilename: nil,
                            displayPictureEncryptionKey: nil,
                            members: [(
                                id: "051111111111111111111111111111111111111111111111111111111111111111",
                                profile: Profile(
                                    id: "051111111111111111111111111111111111111111111111111111111111111111",
                                    name: "TestName",
                                    profilePictureUrl: "testUrl",
                                    profileEncryptionKey: Data([1, 2, 3])
                                )
                            )],
                            using: dependencies
                        )
                    }
                    
                    expect(createGroupOutput.members.count).to(equal(2))
                    expect(createGroupOutput.members.map { $0.groupId })
                        .to(equal([
                            "03cbd569f56fb13ea95a3f0c05c331cc24139c0090feb412069dc49fab34406ece",
                            "03cbd569f56fb13ea95a3f0c05c331cc24139c0090feb412069dc49fab34406ece",
                        ]))
                    expect(createGroupOutput.members.map { $0.profileId }.asSet())
                        .to(equal([
                            "051111111111111111111111111111111111111111111111111111111111111111",
                            "05\(TestConstants.publicKey)"
                        ]))
                    expect(createGroupOutput.members.map { $0.role }.asSet())
                        .to(equal([
                            .standard,
                            .admin
                        ]))
                    expect(createGroupOutput.members.map { $0.isHidden }.asSet())
                        .to(equal([
                            false,
                            false
                        ]))
                }
                
                // MARK: ---- adds the current user as an admin when not provided
                it("adds the current user as an admin when not provided") {
                    createGroupOutput = mockStorage.write { db in
                        try LibSession.createGroup(
                            db,
                            name: "Testname",
                            description: nil,
                            displayPictureUrl: nil,
                            displayPictureFilename: nil,
                            displayPictureEncryptionKey: nil,
                            members: [(
                                id: "051111111111111111111111111111111111111111111111111111111111111111",
                                profile: Profile(
                                    id: "051111111111111111111111111111111111111111111111111111111111111111",
                                    name: "TestName"
                                )
                            )],
                            using: dependencies
                        )
                    }
                    
                    expect(createGroupOutput.members.map { $0.groupId })
                        .to(contain("03cbd569f56fb13ea95a3f0c05c331cc24139c0090feb412069dc49fab34406ece"))
                    expect(createGroupOutput.members.map { $0.profileId })
                        .to(contain("05\(TestConstants.publicKey)"))
                    expect(createGroupOutput.members.map { $0.role }).to(contain(.admin))
                }
                
                // MARK: ---- handles members without profile data correctly
                it("handles members without profile data correctly") {
                    createGroupOutput = mockStorage.write { db in
                        try LibSession.createGroup(
                            db,
                            name: "Testname",
                            description: nil,
                            displayPictureUrl: nil,
                            displayPictureFilename: nil,
                            displayPictureEncryptionKey: nil,
                            members: [(
                                id: "051111111111111111111111111111111111111111111111111111111111111111",
                                profile: nil
                            )],
                            using: dependencies
                        )
                    }
                    
                    expect(createGroupOutput.members.count).to(equal(2))
                    expect(createGroupOutput.members.map { $0.groupId })
                        .to(contain("03cbd569f56fb13ea95a3f0c05c331cc24139c0090feb412069dc49fab34406ece"))
                    expect(createGroupOutput.members.map { $0.profileId })
                        .to(contain("051111111111111111111111111111111111111111111111111111111111111111"))
                    expect(createGroupOutput.members.map { $0.role }).to(contain(.standard))
                }
                
                // MARK: ---- stores the config states in the cache correctly
                it("stores the config states in the cache correctly") {
                    createGroupOutput = mockStorage.write { db in
                        try LibSession.createGroup(
                            db,
                            name: "Testname",
                            description: nil,
                            displayPictureUrl: nil,
                            displayPictureFilename: nil,
                            displayPictureEncryptionKey: nil,
                            members: [(
                                id: "051111111111111111111111111111111111111111111111111111111111111111",
                                profile: nil
                            )],
                            using: dependencies
                        )
                    }
                    
                    expect(mockLibSessionCache).to(call(.exactly(times: 3)) {
                        $0.setConfig(for: .any, sessionId: .any, to: .any)
                    })
                    expect(mockLibSessionCache)
                        .to(call(matchingParameters: .atLeast(2)) {
                            $0.setConfig(
                                for: .groupInfo,
                                sessionId: SessionId(
                                    .group,
                                    hex: "cbd569f56fb13ea95a3f0c05c331cc24139c0090feb412069dc49fab34406ece"
                                ),
                                to: .any
                            )
                        })
                    expect(mockLibSessionCache)
                        .to(call(matchingParameters: .atLeast(2)) {
                            $0.setConfig(
                                for: .groupMembers,
                                sessionId: SessionId(
                                    .group,
                                    hex: "cbd569f56fb13ea95a3f0c05c331cc24139c0090feb412069dc49fab34406ece"
                                ),
                                to: .any
                            )
                        })
                    expect(mockLibSessionCache)
                        .to(call(matchingParameters: .atLeast(2)) {
                            $0.setConfig(
                                for: .groupKeys,
                                sessionId: SessionId(
                                    .group,
                                    hex: "cbd569f56fb13ea95a3f0c05c331cc24139c0090feb412069dc49fab34406ece"
                                ),
                                to: .any
                            )
                        })
                }
            }
            
            // MARK: -- when saving a created a group
            context("when saving a created a group") {
                beforeEach {
                    mockLibSessionCache.when { $0.configNeedsDump(.any) }.thenReturn(true)
                    mockLibSessionCache
                        .when { try $0.createDump(config: .any, for: .any, sessionId: .any, timestampMs: .any) }
                        .then { args in
                            mockStorage.write { db in
                                try ConfigDump(
                                    variant: args[1] as! ConfigDump.Variant,
                                    sessionId: (args[2] as! SessionId).hexString,
                                    data: Data([1, 2, 3]),
                                    timestampMs: args[3] as! Int64
                                ).upsert(db)
                            }
                        }
                        .thenReturn(nil)
                }
                
                // MARK: ---- saves config dumps for the stored configs
                it("saves config dumps for the stored configs") {
                    mockStorage.write { db in
                        createGroupOutput = try LibSession.createGroup(
                            db,
                            name: "Testname",
                            description: nil,
                            displayPictureUrl: nil,
                            displayPictureFilename: nil,
                            displayPictureEncryptionKey: nil,
                            members: [(
                                id: "051111111111111111111111111111111111111111111111111111111111111111",
                                profile: nil
                            )],
                            using: dependencies
                        )
                        
                        try LibSession.saveCreatedGroup(
                            db,
                            group: createGroupOutput.group,
                            groupState: createGroupOutput.groupState,
                            using: dependencies
                        )
                    }
                    
                    let result: [ConfigDump]? = mockStorage.read { db in
                        try ConfigDump.fetchAll(db)
                    }
                    
                    expect(result?.map { $0.variant }.asSet())
                        .to(contain([.groupInfo, .groupKeys, .groupMembers]))
                    expect(result?.map { $0.sessionId }.asSet())
                        .to(contain([
                            SessionId(
                                .group,
                                hex: "cbd569f56fb13ea95a3f0c05c331cc24139c0090feb412069dc49fab34406ece"
                            )
                        ]))
                    expect(result?.map { $0.timestampMs }.asSet()).to(contain([1234567890000]))
                }
                
                // MARK: ---- adds the group to the user groups config
                it("adds the group to the user groups config") {
                    mockStorage.write { db in
                        createGroupOutput = try LibSession.createGroup(
                            db,
                            name: "Testname",
                            description: nil,
                            displayPictureUrl: nil,
                            displayPictureFilename: nil,
                            displayPictureEncryptionKey: nil,
                            members: [(
                                id: "051111111111111111111111111111111111111111111111111111111111111111",
                                profile: nil
                            )],
                            using: dependencies
                        )
                        
                        try LibSession.saveCreatedGroup(
                            db,
                            group: createGroupOutput.group,
                            groupState: createGroupOutput.groupState,
                            using: dependencies
                        )
                    }
                    
                    expect(mockLibSessionCache)
                        .to(call(.exactly(times: 1), matchingParameters: .all) {
                            try $0.performAndPushChange(
                                .any,
                                for: .userGroups,
                                sessionId: SessionId(.standard, hex: TestConstants.publicKey),
                                change: { _ in }
                            )
                        })
                }
            }
        }
    }
}

// MARK: - Convenience

private extension LibSession.Config {
    var conf: UnsafeMutablePointer<config_object>? {
        switch self {
            case .userProfile(let conf), .contacts(let conf),
                .convoInfoVolatile(let conf), .userGroups(let conf),
                .groupInfo(let conf), .groupMembers(let conf):
                return conf
            default: return nil
        }
    }
}
