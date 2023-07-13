// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import Sodium
import SessionSnodeKit
import SessionUtilitiesKit

import Quick
import Nimble

@testable import SessionMessagingKit

// MARK: - OpenGroupManagerSpec

class OpenGroupManagerSpec: QuickSpec {
    class TestCapabilitiesAndRoomApi: TestOnionRequestAPI {
        static let capabilitiesData: OpenGroupAPI.Capabilities = OpenGroupAPI.Capabilities(capabilities: [.sogs], missing: nil)
        static let roomData: OpenGroupAPI.Room = OpenGroupAPI.Room(
            token: "test",
            name: "test",
            roomDescription: nil,
            infoUpdates: 10,
            messageSequence: 0,
            created: 0,
            activeUsers: 0,
            activeUsersCutoff: 0,
            imageId: nil,
            pinnedMessages: nil,
            admin: false,
            globalAdmin: false,
            admins: [],
            hiddenAdmins: nil,
            moderator: false,
            globalModerator: false,
            moderators: [],
            hiddenModerators: nil,
            read: false,
            defaultRead: nil,
            defaultAccessible: nil,
            write: false,
            defaultWrite: nil,
            upload: false,
            defaultUpload: nil
        )
        
        override class var mockResponse: Data? {
            let responses: [Data] = [
                try! JSONEncoder().encode(
                    HTTP.BatchSubResponse(
                        code: 200,
                        headers: [:],
                        body: capabilitiesData,
                        failedToParseBody: false
                    )
                ),
                try! JSONEncoder().encode(
                    HTTP.BatchSubResponse(
                        code: 200,
                        headers: [:],
                        body: roomData,
                        failedToParseBody: false
                    )
                )
            ]
            
            return "[\(responses.map { String(data: $0, encoding: .utf8)! }.joined(separator: ","))]".data(using: .utf8)
        }
    }
    
    // MARK: - Spec

    override func spec() {
        var mockOGMCache: MockOGMCache!
        var mockGeneralCache: MockGeneralCache!
        var mockStorage: Storage!
        var mockSodium: MockSodium!
        var mockAeadXChaCha20Poly1305Ietf: MockAeadXChaCha20Poly1305Ietf!
        var mockGenericHash: MockGenericHash!
        var mockSign: MockSign!
        var mockNonce16Generator: MockNonce16Generator!
        var mockNonce24Generator: MockNonce24Generator!
        var mockUserDefaults: MockUserDefaults!
        var dependencies: OpenGroupManager.OGMDependencies!
        var disposables: [AnyCancellable] = []
        
        var testInteraction1: Interaction!
        var testGroupThread: SessionThread!
        var testOpenGroup: OpenGroup!
        var testPollInfo: OpenGroupAPI.RoomPollInfo!
        var testMessage: OpenGroupAPI.Message!
        var testDirectMessage: OpenGroupAPI.DirectMessage!
        
        var cache: OpenGroupManager.Cache!
        var openGroupManager: OpenGroupManager!

        describe("an OpenGroupManager") {
            // MARK: - Configuration
            
            beforeEach {
                mockOGMCache = MockOGMCache()
                mockGeneralCache = MockGeneralCache()
                mockStorage = Storage(
                    customWriter: try! DatabaseQueue(),
                    customMigrations: [
                        SNUtilitiesKit.migrations(),
                        SNMessagingKit.migrations()
                    ]
                )
                mockSodium = MockSodium()
                mockAeadXChaCha20Poly1305Ietf = MockAeadXChaCha20Poly1305Ietf()
                mockGenericHash = MockGenericHash()
                mockSign = MockSign()
                mockNonce16Generator = MockNonce16Generator()
                mockNonce24Generator = MockNonce24Generator()
                mockUserDefaults = MockUserDefaults()
                dependencies = OpenGroupManager.OGMDependencies(
                    subscribeQueue: DispatchQueue.main,
                    receiveQueue: DispatchQueue.main,
                    cache: mockOGMCache,
                    onionApi: TestCapabilitiesAndRoomApi.self,
                    generalCache: mockGeneralCache,
                    storage: mockStorage,
                    sodium: mockSodium,
                    genericHash: mockGenericHash,
                    sign: mockSign,
                    aeadXChaCha20Poly1305Ietf: mockAeadXChaCha20Poly1305Ietf,
                    ed25519: MockEd25519(),
                    nonceGenerator16: mockNonce16Generator,
                    nonceGenerator24: mockNonce24Generator,
                    standardUserDefaults: mockUserDefaults,
                    date: Date(timeIntervalSince1970: 1234567890)
                )
                testInteraction1 = Interaction(
                    id: 234,
                    serverHash: "TestServerHash",
                    messageUuid: nil,
                    threadId: OpenGroup.idFor(roomToken: "testRoom", server: "testServer"),
                    authorId: "TestAuthorId",
                    variant: .standardOutgoing,
                    body: "Test",
                    timestampMs: 123,
                    receivedAtTimestampMs: 124,
                    wasRead: false,
                    hasMention: false,
                    expiresInSeconds: nil,
                    expiresStartedAtMs: nil,
                    linkPreviewUrl: nil,
                    openGroupServerMessageId: nil,
                    openGroupWhisperMods: false,
                    openGroupWhisperTo: nil
                )
                
                testGroupThread = SessionThread(
                    id: OpenGroup.idFor(roomToken: "testRoom", server: "testServer"),
                    variant: .community
                )
                testOpenGroup = OpenGroup(
                    server: "testServer",
                    roomToken: "testRoom",
                    publicKey: TestConstants.publicKey,
                    isActive: true,
                    name: "Test",
                    roomDescription: nil,
                    imageId: nil,
                    imageData: nil,
                    userCount: 0,
                    infoUpdates: 10,
                    sequenceNumber: 5
                )
                testPollInfo = OpenGroupAPI.RoomPollInfo(
                    token: "testRoom",
                    activeUsers: 10,
                    admin: false,
                    globalAdmin: false,
                    moderator: false,
                    globalModerator: false,
                    read: false,
                    defaultRead: nil,
                    defaultAccessible: nil,
                    write: false,
                    defaultWrite: nil,
                    upload: false,
                    defaultUpload: nil,
                    details: TestCapabilitiesAndRoomApi.roomData
                )
                testMessage = OpenGroupAPI.Message(
                    id: 127,
                    sender: "05\(TestConstants.publicKey)",
                    posted: 123,
                    edited: nil,
                    deleted: nil,
                    seqNo: 124,
                    whisper: false,
                    whisperMods: false,
                    whisperTo: nil,
                    base64EncodedData: [
                        "Cg0KC1Rlc3RNZXNzYWdlg",
                        "AAAAAAAAAAAAAAAAAAAAA",
                        "AAAAAAAAAAAAAAAAAAAAA",
                        "AAAAAAAAAAAAAAAAAAAAA",
                        "AAAAAAAAAAAAAAAAAAAAA",
                        "AAAAAAAAAAAAAAAAAAAAA",
                        "AAAAAAAAAAAAAAAAAAAAA",
                        "AAAAAAAAAAAAAAAAAAAAA",
                        "AAAAAAAAAAAAAAAAAAAAA",
                        "AAAAAAAAAAAAAAAAAAAAA",
                        "AA"
                    ].joined(),
                    base64EncodedSignature: nil,
                    reactions: nil
                )
                testDirectMessage = OpenGroupAPI.DirectMessage(
                    id: 128,
                    sender: "15\(TestConstants.publicKey)",
                    recipient: "15\(TestConstants.publicKey)",
                    posted: 1234567890,
                    expires: 1234567990,
                    base64EncodedMessage: Data(
                        Bytes(arrayLiteral: 0) +
                        "TestMessage".bytes +
                        Data(base64Encoded: "pbTUizreT0sqJ2R2LloseQDyVL2RYztD")!.bytes
                    ).base64EncodedString()
                )
                
                mockStorage.write { db in
                    try Identity(variant: .x25519PublicKey, data: Data.data(fromHex: TestConstants.publicKey)!).insert(db)
                    try Identity(variant: .x25519PrivateKey, data: Data.data(fromHex: TestConstants.privateKey)!).insert(db)
                    try Identity(variant: .ed25519PublicKey, data: Data.data(fromHex: TestConstants.edPublicKey)!).insert(db)
                    try Identity(variant: .ed25519SecretKey, data: Data.data(fromHex: TestConstants.edSecretKey)!).insert(db)
                    
                    try testGroupThread.insert(db)
                    try testOpenGroup.insert(db)
                    try Capability(openGroupServer: testOpenGroup.server, variant: .sogs, isMissing: false).insert(db)
                }
                mockOGMCache.when { $0.pendingChanges }.thenReturn([])
                mockGeneralCache.when { $0.encodedPublicKey }.thenReturn("05\(TestConstants.publicKey)")
                mockGenericHash.when { $0.hash(message: anyArray(), outputLength: any()) }.thenReturn([])
                mockSodium
                    .when { [mockGenericHash = mockGenericHash!] sodium in
                        sodium.blindedKeyPair(
                            serverPublicKey: any(),
                            edKeyPair: any(),
                            genericHash: mockGenericHash
                        )
                    }
                    .thenReturn(
                        KeyPair(
                            publicKey: Data.data(fromHex: TestConstants.publicKey)!.bytes,
                            secretKey: Data.data(fromHex: TestConstants.edSecretKey)!.bytes
                        )
                    )
                mockSodium
                    .when {
                        $0.sogsSignature(
                            message: anyArray(),
                            secretKey: anyArray(),
                            blindedSecretKey: anyArray(),
                            blindedPublicKey: anyArray()
                        )
                    }
                    .thenReturn("TestSogsSignature".bytes)
                mockSign.when { $0.signature(message: anyArray(), secretKey: anyArray()) }.thenReturn("TestSignature".bytes)
                
                mockNonce16Generator
                    .when { $0.nonce() }
                    .thenReturn(Data(base64Encoded: "pK6YRtQApl4NhECGizF0Cg==")!.bytes)
                mockNonce24Generator
                    .when { $0.nonce() }
                    .thenReturn(Data(base64Encoded: "pbTUizreT0sqJ2R2LloseQDyVL2RYztD")!.bytes)
                
                cache = OpenGroupManager.Cache()
                openGroupManager = OpenGroupManager()
            }

            afterEach {
                disposables.forEach { $0.cancel() }
                
                OpenGroupManager.shared.stopPolling()   // Need to stop any pollers which get created during tests
                openGroupManager.stopPolling()          // Assuming it's different from the above
                
                mockOGMCache = nil
                mockStorage = nil
                mockSodium = nil
                mockAeadXChaCha20Poly1305Ietf = nil
                mockGenericHash = nil
                mockSign = nil
                mockUserDefaults = nil
                dependencies = nil
                disposables = []
                
                testInteraction1 = nil
                testGroupThread = nil
                testOpenGroup = nil
                
                openGroupManager = nil
            }
            
            // MARK: - Cache
            
            context("cache data") {
                it("defaults the time since last open to greatestFiniteMagnitude") {
                    mockUserDefaults
                        .when { (defaults: inout any UserDefaultsType) -> Any? in
                            defaults.object(forKey: SNUserDefaults.Date.lastOpen.rawValue)
                        }
                        .thenReturn(nil)
                    
                    expect(cache.getTimeSinceLastOpen(using: dependencies))
                        .to(beCloseTo(.greatestFiniteMagnitude))
                }
                
                it("returns the time since the last open") {
                    mockUserDefaults
                        .when { (defaults: inout any UserDefaultsType) -> Any? in
                            defaults.object(forKey: SNUserDefaults.Date.lastOpen.rawValue)
                        }
                        .thenReturn(Date(timeIntervalSince1970: 1234567880))
                    dependencies = dependencies.with(date: Date(timeIntervalSince1970: 1234567890))
                    
                    expect(cache.getTimeSinceLastOpen(using: dependencies))
                        .to(beCloseTo(10))
                }
                
                it("caches the time since the last open") {
                    mockUserDefaults
                        .when { (defaults: inout any UserDefaultsType) -> Any? in
                            defaults.object(forKey: SNUserDefaults.Date.lastOpen.rawValue)
                        }
                        .thenReturn(Date(timeIntervalSince1970: 1234567770))
                    dependencies = dependencies.with(date: Date(timeIntervalSince1970: 1234567780))
                    
                    expect(cache.getTimeSinceLastOpen(using: dependencies))
                        .to(beCloseTo(10))
                    
                    mockUserDefaults
                        .when { (defaults: inout any UserDefaultsType) -> Any? in
                            defaults.object(forKey: SNUserDefaults.Date.lastOpen.rawValue)
                        }
                        .thenReturn(Date(timeIntervalSince1970: 1234567890))
                 
                    // Cached value shouldn't have been updated
                    expect(cache.getTimeSinceLastOpen(using: dependencies))
                        .to(beCloseTo(10))
                }
            }
            
            // MARK: - Polling
            
            context("when starting polling") {
                beforeEach {
                    mockStorage.write { db in
                        try OpenGroup(
                            server: "testServer1",
                            roomToken: "testRoom1",
                            publicKey: TestConstants.publicKey,
                            isActive: true,
                            name: "Test1",
                            roomDescription: nil,
                            imageId: nil,
                            imageData: nil,
                            userCount: 0,
                            infoUpdates: 0
                        ).insert(db)
                    }
                    
                    mockOGMCache.when { $0.hasPerformedInitialPoll }.thenReturn([:])
                    mockOGMCache.when { $0.timeSinceLastPoll }.thenReturn([:])
                    mockOGMCache
                        .when { [dependencies = dependencies!] cache in
                            cache.getTimeSinceLastOpen(using: dependencies)
                        }
                        .thenReturn(0)
                    mockOGMCache.when { $0.isPolling }.thenReturn(false)
                    mockOGMCache.when { $0.pollers }.thenReturn([:])
                    
                    mockUserDefaults
                        .when { (defaults: inout any UserDefaultsType) -> Any? in
                            defaults.object(forKey: SNUserDefaults.Date.lastOpen.rawValue)
                        }
                        .thenReturn(Date(timeIntervalSince1970: 1234567890))
                }
                
                it("creates pollers for all of the open groups") {
                    openGroupManager.startPolling(using: dependencies)
                    
                    expect(mockOGMCache)
                        .toEventually(
                            call(matchingParameters: true) {
                                $0.pollers = [
                                    "testserver": OpenGroupAPI.Poller(for: "testserver"),
                                    "testserver1": OpenGroupAPI.Poller(for: "testserver1")
                                ]
                            },
                            timeout: .milliseconds(50)
                        )
                }
                
                it("updates the isPolling flag") {
                    openGroupManager.startPolling(using: dependencies)
                    
                    expect(mockOGMCache)
                        .toEventually(
                            call(matchingParameters: true) { $0.isPolling = true },
                            timeout: .milliseconds(50)
                        )
                }
                
                it("does nothing if already polling") {
                    mockOGMCache.when { $0.isPolling }.thenReturn(true)
                    
                    openGroupManager.startPolling(using: dependencies)
                    
                    expect(mockOGMCache).toEventuallyNot(
                        call { $0.pollers },
                        timeout: .milliseconds(50)
                    )
                }
            }
            
            context("when stopping polling") {
                beforeEach {
                    mockStorage.write { db in
                        try OpenGroup(
                            server: "testServer1",
                            roomToken: "testRoom1",
                            publicKey: TestConstants.publicKey,
                            isActive: true,
                            name: "Test1",
                            roomDescription: nil,
                            imageId: nil,
                            imageData: nil,
                            userCount: 0,
                            infoUpdates: 0
                        ).insert(db)
                    }
                    
                    mockOGMCache.when { $0.isPolling }.thenReturn(true)
                    mockOGMCache.when { $0.pollers }.thenReturn(["testserver": OpenGroupAPI.Poller(for: "testserver")])
                }
                
                it("removes all pollers") {
                    openGroupManager.stopPolling(using: dependencies)
                    
                    expect(mockOGMCache).to(call(matchingParameters: true) { $0.pollers = [:] })
                }
                
                it("updates the isPolling flag") {
                    openGroupManager.stopPolling(using: dependencies)
                    
                    expect(mockOGMCache).to(call(matchingParameters: true) { $0.isPolling = false })
                }
            }
            
            // MARK: - Adding & Removing
            
            // MARK: - --isSessionRunOpenGroup
            
            context("when checking if an open group is run by session") {
                it("returns false when it does not match one of Sessions servers with no scheme") {
                    expect(OpenGroupManager.isSessionRunOpenGroup(server: "test.test"))
                        .to(beFalse())
                }
                
                it("returns false when it does not match one of Sessions servers in http") {
                    expect(OpenGroupManager.isSessionRunOpenGroup(server: "http://test.test"))
                        .to(beFalse())
                }
                
                it("returns false when it does not match one of Sessions servers in https") {
                    expect(OpenGroupManager.isSessionRunOpenGroup(server: "https://test.test"))
                        .to(beFalse())
                }
                
                it("returns true when it matches Sessions SOGS IP") {
                    expect(OpenGroupManager.isSessionRunOpenGroup(server: "116.203.70.33"))
                        .to(beTrue())
                }
                
                it("returns true when it matches Sessions SOGS IP with http") {
                    expect(OpenGroupManager.isSessionRunOpenGroup(server: "http://116.203.70.33"))
                        .to(beTrue())
                }
                
                it("returns true when it matches Sessions SOGS IP with https") {
                    expect(OpenGroupManager.isSessionRunOpenGroup(server: "https://116.203.70.33"))
                        .to(beTrue())
                }
                
                it("returns true when it matches Sessions SOGS IP with a port") {
                    expect(OpenGroupManager.isSessionRunOpenGroup(server: "116.203.70.33:80"))
                        .to(beTrue())
                }
                
                it("returns true when it matches Sessions SOGS domain") {
                    expect(OpenGroupManager.isSessionRunOpenGroup(server: "open.getsession.org"))
                        .to(beTrue())
                }
                
                it("returns true when it matches Sessions SOGS domain with http") {
                    expect(OpenGroupManager.isSessionRunOpenGroup(server: "http://open.getsession.org"))
                        .to(beTrue())
                }
                
                it("returns true when it matches Sessions SOGS domain with https") {
                    expect(OpenGroupManager.isSessionRunOpenGroup(server: "https://open.getsession.org"))
                        .to(beTrue())
                }
                
                it("returns true when it matches Sessions SOGS domain with a port") {
                    expect(OpenGroupManager.isSessionRunOpenGroup(server: "open.getsession.org:80"))
                        .to(beTrue())
                }
            }
            
            // MARK: - --hasExistingOpenGroup
            
            context("when checking it has an existing open group") {
                context("when there is a thread for the room and the cache has a poller") {
                    context("for the no-scheme variant") {
                        beforeEach {
                            mockOGMCache.when { $0.pollers }.thenReturn(["testserver": OpenGroupAPI.Poller(for: "testserver")])
                        }
                        
                        it("returns true when no scheme is provided") {
                            expect(
                                mockStorage.read { db -> Bool in
                                    openGroupManager
                                        .hasExistingOpenGroup(
                                            db,
                                            roomToken: "testRoom",
                                            server: "testServer",
                                            publicKey: TestConstants.serverPublicKey,
                                            dependencies: dependencies
                                        )
                                }
                            ).to(beTrue())
                        }
                        
                        it("returns true when a http scheme is provided") {
                            expect(
                                mockStorage.read { db -> Bool in
                                    openGroupManager
                                        .hasExistingOpenGroup(
                                            db,
                                            roomToken: "testRoom",
                                            server: "http://testServer",
                                            publicKey: TestConstants.serverPublicKey,
                                            dependencies: dependencies
                                        )
                                }
                            ).to(beTrue())
                        }
                        
                        it("returns true when a https scheme is provided") {
                            expect(
                                mockStorage.read { db -> Bool in
                                    openGroupManager
                                        .hasExistingOpenGroup(
                                            db,
                                            roomToken: "testRoom",
                                            server: "https://testServer",
                                            publicKey: TestConstants.serverPublicKey,
                                            dependencies: dependencies
                                        )
                                }
                            ).to(beTrue())
                        }
                    }
                    
                    context("for the http variant") {
                        beforeEach {
                            mockOGMCache.when { $0.pollers }.thenReturn(["http://testserver": OpenGroupAPI.Poller(for: "http://testserver")])
                        }
                        
                        it("returns true when no scheme is provided") {
                            expect(
                                mockStorage.read { db -> Bool in
                                    openGroupManager
                                        .hasExistingOpenGroup(
                                            db,
                                            roomToken: "testRoom",
                                            server: "testServer",
                                            publicKey: TestConstants.serverPublicKey,
                                            dependencies: dependencies
                                        )
                                }
                            ).to(beTrue())
                        }
                        
                        it("returns true when a http scheme is provided") {
                            expect(
                                mockStorage.read { db -> Bool in
                                    openGroupManager
                                        .hasExistingOpenGroup(
                                            db,
                                            roomToken: "testRoom",
                                            server: "http://testServer",
                                            publicKey: TestConstants.serverPublicKey,
                                            dependencies: dependencies
                                        )
                                }
                            ).to(beTrue())
                        }
                        
                        it("returns true when a https scheme is provided") {
                            expect(
                                mockStorage.read { db -> Bool in
                                    openGroupManager
                                        .hasExistingOpenGroup(
                                            db,
                                            roomToken: "testRoom",
                                            server: "https://testServer",
                                            publicKey: TestConstants.serverPublicKey,
                                            dependencies: dependencies
                                        )
                                }
                            ).to(beTrue())
                        }
                    }
                    
                    context("for the https variant") {
                        beforeEach {
                            mockOGMCache.when { $0.pollers }.thenReturn(["https://testserver": OpenGroupAPI.Poller(for: "https://testserver")])
                        }
                        
                        it("returns true when no scheme is provided") {
                            expect(
                                mockStorage.read { db -> Bool in
                                    openGroupManager
                                        .hasExistingOpenGroup(
                                            db,
                                            roomToken: "testRoom",
                                            server: "testServer",
                                            publicKey: TestConstants.serverPublicKey,
                                            dependencies: dependencies
                                        )
                                }
                            ).to(beTrue())
                        }
                        
                        it("returns true when a http scheme is provided") {
                            expect(
                                mockStorage.read { db -> Bool in
                                    openGroupManager
                                        .hasExistingOpenGroup(
                                            db,
                                            roomToken: "testRoom",
                                            server: "http://testServer",
                                            publicKey: TestConstants.serverPublicKey,
                                            dependencies: dependencies
                                        )
                                }
                            ).to(beTrue())
                        }
                        
                        it("returns true when a https scheme is provided") {
                            expect(
                                mockStorage.read { db -> Bool in
                                    openGroupManager
                                        .hasExistingOpenGroup(
                                            db,
                                            roomToken: "testRoom",
                                            server: "https://testServer",
                                            publicKey: TestConstants.serverPublicKey,
                                            dependencies: dependencies
                                        )
                                }
                            ).to(beTrue())
                        }
                    }
                }
                
                context("when given the legacy DNS host and there is a cached poller for the default server") {
                    it("returns true") {
                        mockOGMCache.when { $0.pollers }.thenReturn(["http://116.203.70.33": OpenGroupAPI.Poller(for: "http://116.203.70.33")])
                        mockStorage.write { db in
                            try SessionThread(
                                id: OpenGroup.idFor(roomToken: "testRoom", server: "http://116.203.70.33"),
                                variant: .community,
                                creationDateTimestamp: 0,
                                shouldBeVisible: true,
                                isPinned: false,
                                messageDraft: nil,
                                notificationSound: nil,
                                mutedUntilTimestamp: nil,
                                onlyNotifyForMentions: false
                            ).insert(db)
                        }
                        
                        expect(
                            mockStorage.read { db -> Bool in
                                openGroupManager
                                    .hasExistingOpenGroup(
                                        db,
                                        roomToken: "testRoom",
                                        server: "http://open.getsession.org",
                                        publicKey: TestConstants.serverPublicKey,
                                        dependencies: dependencies
                                    )
                            }
                        ).to(beTrue())
                    }
                }
                
                context("when given the default server and there is a cached poller for the legacy DNS host") {
                    it("returns true") {
                        mockOGMCache.when { $0.pollers }.thenReturn(["http://open.getsession.org": OpenGroupAPI.Poller(for: "http://open.getsession.org")])
                        mockStorage.write { db in
                            try SessionThread(
                                id: OpenGroup.idFor(roomToken: "testRoom", server: "http://open.getsession.org"),
                                variant: .community,
                                creationDateTimestamp: 0,
                                shouldBeVisible: true,
                                isPinned: false,
                                messageDraft: nil,
                                notificationSound: nil,
                                mutedUntilTimestamp: nil,
                                onlyNotifyForMentions: false
                            ).insert(db)
                        }
                        
                        expect(
                            mockStorage.read { db -> Bool in
                                openGroupManager
                                    .hasExistingOpenGroup(
                                        db,
                                        roomToken: "testRoom",
                                        server: "http://116.203.70.33",
                                        publicKey: TestConstants.serverPublicKey,
                                        dependencies: dependencies
                                    )
                            }
                        ).to(beTrue())
                    }
                }
                
                it("returns false when given an invalid server") {
                    mockOGMCache.when { $0.pollers }.thenReturn(["testserver": OpenGroupAPI.Poller(for: "testserver")])
                    
                    expect(
                        mockStorage.read { db -> Bool in
                            openGroupManager
                                .hasExistingOpenGroup(
                                    db,
                                    roomToken: "testRoom",
                                    server: "%%%",
                                    publicKey: TestConstants.serverPublicKey,
                                    dependencies: dependencies
                                )
                        }
                    ).to(beFalse())
                }
                
                it("returns false if there is not a poller for the server in the cache") {
                    mockOGMCache.when { $0.pollers }.thenReturn([:])
                    
                    expect(
                        mockStorage.read { db -> Bool in
                            openGroupManager
                                .hasExistingOpenGroup(
                                    db,
                                    roomToken: "testRoom",
                                    server: "testServer",
                                    publicKey: TestConstants.serverPublicKey,
                                    dependencies: dependencies
                                )
                        }
                    ).to(beFalse())
                }
                
                it("returns false if there is a poller for the server in the cache but no thread for the room") {
                    mockOGMCache.when { $0.pollers }.thenReturn(["testserver": OpenGroupAPI.Poller(for: "testserver")])
                    mockStorage.write { db in
                        try SessionThread.deleteAll(db)
                    }
                    
                    expect(
                        mockStorage.read { db -> Bool in
                            openGroupManager
                                .hasExistingOpenGroup(
                                    db,
                                    roomToken: "testRoom",
                                    server: "testServer",
                                    publicKey: TestConstants.serverPublicKey,
                                    dependencies: dependencies
                                )
                        }
                    ).to(beFalse())
                }
            }
            
            // MARK: - --add
            
            context("when adding") {
                beforeEach {
                    mockStorage.write { db in
                        try OpenGroup.deleteAll(db)
                    }
                    
                    mockOGMCache.when { $0.pollers }.thenReturn([:])
                    
                    mockUserDefaults
                        .when { (defaults: inout any UserDefaultsType) -> Any? in
                            defaults.object(forKey: SNUserDefaults.Date.lastOpen.rawValue)
                        }
                        .thenReturn(Date(timeIntervalSince1970: 1234567890))
                }
                
                it("stores the open group server") {
                    var didComplete: Bool = false   // Prevent multi-threading test bugs
                    
                    mockStorage
                        .writePublisher { (db: Database) -> Bool in
                            openGroupManager
                                .add(
                                    db,
                                    roomToken: "testRoom",
                                    server: "testServer",
                                    publicKey: TestConstants.serverPublicKey,
                                    calledFromConfigHandling: true, // Don't trigger SessionUtil logic
                                    dependencies: dependencies
                                )
                        }
                        .flatMap { successfullyAddedGroup in
                            openGroupManager.performInitialRequestsAfterAdd(
                                successfullyAddedGroup: successfullyAddedGroup,
                                roomToken: "testRoom",
                                server: "testServer",
                                publicKey: TestConstants.serverPublicKey,
                                calledFromConfigHandling: true, // Don't trigger SessionUtil logic
                                dependencies: dependencies
                            )
                        }
                        .handleEvents(receiveCompletion: { _ in didComplete = true })
                        .sinkAndStore(in: &disposables)
                    
                    expect(didComplete).toEventually(beTrue(), timeout: .milliseconds(50))
                    expect(
                        mockStorage
                            .read { (db: Database) in
                                try OpenGroup
                                    .select(.threadId)
                                    .asRequest(of: String.self)
                                    .fetchOne(db)
                            }
                    )
                        .to(equal(OpenGroup.idFor(roomToken: "testRoom", server: "testServer")))
                }
                
                it("adds a poller") {
                    var didComplete: Bool = false   // Prevent multi-threading test bugs
                    
                    mockStorage
                        .writePublisher { (db: Database) -> Bool in
                            openGroupManager
                                .add(
                                    db,
                                    roomToken: "testRoom",
                                    server: "testServer",
                                    publicKey: TestConstants.serverPublicKey,
                                    calledFromConfigHandling: true, // Don't trigger SessionUtil logic
                                    dependencies: dependencies
                                )
                        }
                        .flatMap { successfullyAddedGroup in
                            openGroupManager.performInitialRequestsAfterAdd(
                                successfullyAddedGroup: successfullyAddedGroup,
                                roomToken: "testRoom",
                                server: "testServer",
                                publicKey: TestConstants.serverPublicKey,
                                calledFromConfigHandling: true, // Don't trigger SessionUtil logic
                                dependencies: dependencies
                            )
                        }
                        .handleEvents(receiveCompletion: { _ in didComplete = true })
                        .sinkAndStore(in: &disposables)
                    
                    expect(didComplete).toEventually(beTrue(), timeout: .milliseconds(50))
                    expect(mockOGMCache)
                        .toEventually(
                            call(matchingParameters: true) {
                                $0.pollers = ["testserver": OpenGroupAPI.Poller(for: "testserver")]
                            },
                            timeout: .milliseconds(50)
                        )
                }
                
                context("an existing room") {
                    beforeEach {
                        mockOGMCache.when { $0.pollers }
                            .thenReturn(["testserver": OpenGroupAPI.Poller(for: "testserver")])
                        mockStorage.write { db in
                            try testOpenGroup.insert(db)
                        }
                    }
                    
                    it("does not reset the sequence number or update the public key") {
                        var didComplete: Bool = false   // Prevent multi-threading test bugs
                        
                        mockStorage
                            .writePublisher { (db: Database) -> Bool in
                                openGroupManager
                                    .add(
                                        db,
                                        roomToken: "testRoom",
                                        server: "testServer",
                                        publicKey: TestConstants.serverPublicKey
                                            .replacingOccurrences(of: "c3", with: "00")
                                            .replacingOccurrences(of: "b3", with: "00"),
                                        calledFromConfigHandling: true, // Don't trigger SessionUtil logic
                                        dependencies: dependencies
                                    )
                            }
                            .flatMap { successfullyAddedGroup in
                                openGroupManager.performInitialRequestsAfterAdd(
                                    successfullyAddedGroup: successfullyAddedGroup,
                                    roomToken: "testRoom",
                                    server: "testServer",
                                    publicKey: TestConstants.serverPublicKey
                                        .replacingOccurrences(of: "c3", with: "00")
                                        .replacingOccurrences(of: "b3", with: "00"),
                                    calledFromConfigHandling: true, // Don't trigger SessionUtil logic
                                    dependencies: dependencies
                                )
                            }
                            .handleEvents(receiveCompletion: { _ in didComplete = true })
                            .sinkAndStore(in: &disposables)
                        
                        expect(didComplete).toEventually(beTrue(), timeout: .milliseconds(50))
                        expect(
                            mockStorage
                                .read { db in
                                    try OpenGroup
                                        .select(.sequenceNumber)
                                        .asRequest(of: Int64.self)
                                        .fetchOne(db)
                                }
                        ).to(equal(5))
                        expect(
                            mockStorage
                                .read { db in
                                    try OpenGroup
                                        .select(.publicKey)
                                        .asRequest(of: String.self)
                                        .fetchOne(db)
                                }
                        ).to(equal(TestConstants.publicKey))
                    }
                }
                
                context("with an invalid response") {
                    beforeEach {
                        class TestApi: TestOnionRequestAPI {
                            override class var mockResponse: Data? { return Data() }
                        }
                        dependencies = dependencies.with(onionApi: TestApi.self)
                        
                        mockUserDefaults
                            .when { (defaults: inout any UserDefaultsType) -> Any? in
                                defaults.object(forKey: SNUserDefaults.Date.lastOpen.rawValue)
                            }
                            .thenReturn(Date(timeIntervalSince1970: 1234567890))
                    }
                
                    it("fails with the error") {
                        var error: Error?
                        
                        mockStorage
                            .writePublisher { (db: Database) -> Bool in
                                openGroupManager
                                    .add(
                                        db,
                                        roomToken: "testRoom",
                                        server: "testServer",
                                        publicKey: TestConstants.serverPublicKey,
                                        calledFromConfigHandling: true, // Don't trigger SessionUtil logic
                                        dependencies: dependencies
                                    )
                            }
                            .flatMap { successfullyAddedGroup in
                                openGroupManager.performInitialRequestsAfterAdd(
                                    successfullyAddedGroup: successfullyAddedGroup,
                                    roomToken: "testRoom",
                                    server: "testServer",
                                    publicKey: TestConstants.serverPublicKey,
                                    calledFromConfigHandling: true, // Don't trigger SessionUtil logic
                                    dependencies: dependencies
                                )
                            }
                            .mapError { result -> Error in error.setting(to: result) }
                            .sinkAndStore(in: &disposables)
                        
                        expect(error?.localizedDescription)
                            .toEventually(
                                equal(HTTPError.parsingFailed.localizedDescription),
                                timeout: .milliseconds(50)
                            )
                    }
                }
            }
            
            // MARK: - --delete
            
            context("when deleting") {
                beforeEach {
                    mockStorage.write { db in
                        try Interaction.deleteAll(db)
                        try SessionThread.deleteAll(db)
                        
                        try testGroupThread.insert(db)
                        try testOpenGroup.insert(db)
                        try testInteraction1.insert(db)
                        try Interaction
                            .updateAll(
                                db,
                                Interaction.Columns.threadId
                                    .set(to: OpenGroup.idFor(roomToken: "testRoom", server: "testServer"))
                            )
                    }
                    
                    mockOGMCache.when { $0.pollers }.thenReturn([:])
                }
                
                it("removes all interactions for the thread") {
                    mockStorage.write { db in
                        openGroupManager
                            .delete(
                                db,
                                openGroupId: OpenGroup.idFor(roomToken: "testRoom", server: "testServer"),
                                calledFromConfigHandling: true, // Don't trigger SessionUtil logic
                                using: dependencies
                            )
                    }
                    
                    expect(mockStorage.read { db in try Interaction.fetchCount(db) })
                        .to(equal(0))
                }
                
                it("removes the given thread") {
                    mockStorage.write { db in
                        openGroupManager
                            .delete(
                                db,
                                openGroupId: OpenGroup.idFor(roomToken: "testRoom", server: "testServer"),
                                calledFromConfigHandling: true, // Don't trigger SessionUtil logic
                                using: dependencies
                            )
                    }
                    
                    expect(mockStorage.read { db -> Int in try SessionThread.fetchCount(db) })
                        .to(equal(0))
                }
                
                context("and there is only one open group for this server") {
                    it("stops the poller") {
                        mockOGMCache.when { $0.pollers }.thenReturn(["testserver": OpenGroupAPI.Poller(for: "testserver")])
                        
                        mockStorage.write { db in
                            openGroupManager
                                .delete(
                                    db,
                                    openGroupId: OpenGroup.idFor(roomToken: "testRoom", server: "testServer"),
                                    calledFromConfigHandling: true, // Don't trigger SessionUtil logic
                                    using: dependencies
                                )
                        }
                        
                        expect(mockOGMCache).to(call(matchingParameters: true) { $0.pollers = [:] })
                    }
                    
                    it("removes the open group") {
                        mockStorage.write { db in
                            openGroupManager
                                .delete(
                                    db,
                                    openGroupId: OpenGroup.idFor(roomToken: "testRoom", server: "testServer"),
                                    calledFromConfigHandling: true, // Don't trigger SessionUtil logic
                                    using: dependencies
                                )
                        }
                        
                        expect(mockStorage.read { db in try OpenGroup.fetchCount(db) })
                            .to(equal(0))
                    }
                }
                
                context("and the are multiple open groups for this server") {
                    beforeEach {
                        mockStorage.write { db in
                            try OpenGroup.deleteAll(db)
                            try testOpenGroup.insert(db)
                            try OpenGroup(
                                server: "testServer",
                                roomToken: "testRoom1",
                                publicKey: TestConstants.publicKey,
                                isActive: true,
                                name: "Test1",
                                roomDescription: nil,
                                imageId: nil,
                                imageData: nil,
                                userCount: 0,
                                infoUpdates: 0,
                                sequenceNumber: 0,
                                inboxLatestMessageId: 0,
                                outboxLatestMessageId: 0
                            ).insert(db)
                        }
                    }
                    
                    it("removes the open group") {
                        mockStorage.write { db in
                            openGroupManager
                                .delete(
                                    db,
                                    openGroupId: OpenGroup.idFor(roomToken: "testRoom", server: "testServer"),
                                    calledFromConfigHandling: true, // Don't trigger SessionUtil logic
                                    using: dependencies
                                )
                        }
                        
                        expect(mockStorage.read { db in try OpenGroup.fetchCount(db) })
                            .to(equal(1))
                    }
                }
                
                context("and it is the default server") {
                    beforeEach {
                        mockStorage.write { db in
                            try OpenGroup.deleteAll(db)
                            try OpenGroup(
                                server: OpenGroupAPI.defaultServer,
                                roomToken: "testRoom",
                                publicKey: TestConstants.publicKey,
                                isActive: true,
                                name: "Test1",
                                roomDescription: nil,
                                imageId: nil,
                                imageData: nil,
                                userCount: 0,
                                infoUpdates: 0,
                                sequenceNumber: 0,
                                inboxLatestMessageId: 0,
                                outboxLatestMessageId: 0
                            ).insert(db)
                            try OpenGroup(
                                server: OpenGroupAPI.defaultServer,
                                roomToken: "testRoom1",
                                publicKey: TestConstants.publicKey,
                                isActive: true,
                                name: "Test1",
                                roomDescription: nil,
                                imageId: nil,
                                imageData: nil,
                                userCount: 0,
                                infoUpdates: 0,
                                sequenceNumber: 0,
                                inboxLatestMessageId: 0,
                                outboxLatestMessageId: 0
                            ).insert(db)
                        }
                    }
                    
                    it("does not remove the open group") {
                        mockStorage.write { db in
                            openGroupManager
                                .delete(
                                    db,
                                    openGroupId: OpenGroup.idFor(roomToken: "testRoom", server: OpenGroupAPI.defaultServer),
                                    calledFromConfigHandling: true, // Don't trigger SessionUtil logic
                                    using: dependencies
                                )
                        }
                        
                        expect(mockStorage.read { db in try OpenGroup.fetchCount(db) })
                            .to(equal(2))
                    }
                    
                    it("deactivates the open group") {
                        mockStorage.write { db in
                            openGroupManager
                                .delete(
                                    db,
                                    openGroupId: OpenGroup.idFor(roomToken: "testRoom", server: OpenGroupAPI.defaultServer),
                                    calledFromConfigHandling: true, // Don't trigger SessionUtil logic
                                    using: dependencies
                                )
                        }
                        
                        expect(
                            mockStorage.read { db in
                                try OpenGroup
                                    .select(.isActive)
                                    .filter(id: OpenGroup.idFor(roomToken: "testRoom", server: OpenGroupAPI.defaultServer))
                                    .asRequest(of: Bool.self)
                                    .fetchOne(db)
                            }
                        ).to(beFalse())
                    }
                }
            }
            
            // MARK: - Response Processing
            
            // MARK: - --handleCapabilities
            
            context("when handling capabilities") {
                beforeEach {
                    mockStorage.write { db in
                        OpenGroupManager
                            .handleCapabilities(
                                db,
                                capabilities: OpenGroupAPI.Capabilities(capabilities: [.sogs], missing: []),
                                on: "testserver"
                            )
                    }
                }
                
                it("stores the capabilities") {
                    expect(mockStorage.read { db in try Capability.fetchCount(db) })
                        .to(equal(1))
                }
            }
            
            // MARK: - --handlePollInfo
            
            context("when handling room poll info") {
                beforeEach {
                    mockStorage.write { db in
                        try OpenGroup.deleteAll(db)
                        
                        try testOpenGroup.insert(db)
                    }
                    
                    mockOGMCache.when { $0.pollers }.thenReturn([:])
                    
                    mockUserDefaults
                        .when { (defaults: inout any UserDefaultsType) -> Any? in
                            defaults.object(forKey: SNUserDefaults.Date.lastOpen.rawValue)
                        }
                        .thenReturn(nil)
                }
                
                it("saves the updated open group") {
                    var didComplete: Bool = false   // Prevent multi-threading test bugs
                    
                    mockStorage.write { db in
                        try OpenGroupManager.handlePollInfo(
                            db,
                            pollInfo: testPollInfo,
                            publicKey: TestConstants.publicKey,
                            for: "testRoom",
                            on: "testServer",
                            dependencies: dependencies
                        ) { didComplete = true }
                    }
                    
                    expect(didComplete).toEventually(beTrue(), timeout: .milliseconds(50))
                    expect(
                        mockStorage.read { db in
                            try OpenGroup
                                .select(.userCount)
                                .asRequest(of: Int64.self)
                                .fetchOne(db)
                        }
                    ).to(equal(10))
                }
                
                it("calls the completion block") {
                    var didCallComplete: Bool = false
                    
                    mockStorage.write { db in
                        try OpenGroupManager.handlePollInfo(
                            db,
                            pollInfo: testPollInfo,
                            publicKey: TestConstants.publicKey,
                            for: "testRoom",
                            on: "testServer",
                            dependencies: dependencies
                        ) { didCallComplete = true }
                    }
                    
                    expect(didCallComplete)
                        .toEventually(
                            beTrue(),
                            timeout: .milliseconds(50)
                        )
                }
                
                it("calls the room image completion block when waiting but there is no image") {
                    var didCallComplete: Bool = false
                    
                    mockStorage.write { db in
                        try OpenGroupManager.handlePollInfo(
                            db,
                            pollInfo: testPollInfo,
                            publicKey: TestConstants.publicKey,
                            for: "testRoom",
                            on: "testServer",
                            waitForImageToComplete: true,
                            dependencies: dependencies
                        ) { didCallComplete = true }
                    }
                    
                    expect(didCallComplete)
                        .toEventually(
                            beTrue(),
                            timeout: .milliseconds(50)
                        )
                }
                
                it("calls the room image completion block when waiting and there is an image") {
                    var didCallComplete: Bool = false
                    
                    mockStorage.write { db in
                        try OpenGroup.deleteAll(db)
                        try OpenGroup(
                            server: "testServer",
                            roomToken: "testRoom",
                            publicKey: TestConstants.publicKey,
                            isActive: true,
                            name: "Test",
                            imageId: "12",
                            imageData: nil,
                            userCount: 0,
                            infoUpdates: 10
                        ).insert(db)
                    }
                    
                    mockOGMCache.when { $0.groupImagePublishers }
                        .thenReturn([
                            OpenGroup.idFor(roomToken: "testRoom", server: "testServer"): Just(Data()).setFailureType(to: Error.self).eraseToAnyPublisher()
                        ])
                    
                    mockStorage.write { db in
                        try OpenGroupManager.handlePollInfo(
                            db,
                            pollInfo: testPollInfo,
                            publicKey: TestConstants.publicKey,
                            for: "testRoom",
                            on: "testServer",
                            waitForImageToComplete: true,
                            dependencies: dependencies
                        ) { didCallComplete = true }
                    }
                    
                    expect(didCallComplete)
                        .toEventually(
                            beTrue(),
                            timeout: .milliseconds(50)
                        )
                }
                
                context("and updating the moderator list") {
                    it("successfully updates") {
                        var didComplete: Bool = false   // Prevent multi-threading test bugs
                        
                        testPollInfo = OpenGroupAPI.RoomPollInfo(
                            token: "testRoom",
                            activeUsers: 10,
                            admin: false,
                            globalAdmin: false,
                            moderator: false,
                            globalModerator: false,
                            read: false,
                            defaultRead: nil,
                            defaultAccessible: nil,
                            write: false,
                            defaultWrite: nil,
                            upload: false,
                            defaultUpload: nil,
                            details: TestCapabilitiesAndRoomApi.roomData.with(
                                moderators: ["TestMod"],
                                hiddenModerators: [],
                                admins: [],
                                hiddenAdmins: []
                            )
                        )
                        
                        mockStorage.write { db in
                            try OpenGroupManager.handlePollInfo(
                                db,
                                pollInfo: testPollInfo,
                                publicKey: TestConstants.publicKey,
                                for: "testRoom",
                                on: "testServer",
                                dependencies: dependencies
                            ) { didComplete = true }
                        }
                        
                        expect(didComplete).toEventually(beTrue(), timeout: .milliseconds(50))
                        expect(
                            mockStorage.read { db -> GroupMember? in
                                try GroupMember
                                    .filter(GroupMember.Columns.groupId == OpenGroup.idFor(
                                        roomToken: "testRoom",
                                        server: "testServer"
                                    ))
                                    .fetchOne(db)
                            }
                        ).to(equal(
                            GroupMember(
                                groupId: OpenGroup.idFor(
                                    roomToken: "testRoom",
                                    server: "testServer"
                                ),
                                profileId: "TestMod",
                                role: .moderator,
                                isHidden: false
                            )
                        ))
                    }
                    
                    it("updates for hidden moderators") {
                        var didComplete: Bool = false   // Prevent multi-threading test bugs
                        
                        testPollInfo = OpenGroupAPI.RoomPollInfo(
                            token: "testRoom",
                            activeUsers: 10,
                            admin: false,
                            globalAdmin: false,
                            moderator: false,
                            globalModerator: false,
                            read: false,
                            defaultRead: nil,
                            defaultAccessible: nil,
                            write: false,
                            defaultWrite: nil,
                            upload: false,
                            defaultUpload: nil,
                            details: TestCapabilitiesAndRoomApi.roomData.with(
                                moderators: [],
                                hiddenModerators: ["TestMod2"],
                                admins: [],
                                hiddenAdmins: []
                            )
                        )
                        
                        mockStorage.write { db in
                            try OpenGroupManager.handlePollInfo(
                                db,
                                pollInfo: testPollInfo,
                                publicKey: TestConstants.publicKey,
                                for: "testRoom",
                                on: "testServer",
                                dependencies: dependencies
                            ) { didComplete = true }
                        }
                        
                        expect(didComplete).toEventually(beTrue(), timeout: .milliseconds(50))
                        expect(
                            mockStorage.read { db -> GroupMember? in
                                try GroupMember
                                    .filter(GroupMember.Columns.groupId == OpenGroup.idFor(
                                        roomToken: "testRoom",
                                        server: "testServer"
                                    ))
                                    .fetchOne(db)
                            }
                        ).to(equal(
                            GroupMember(
                                groupId: OpenGroup.idFor(
                                    roomToken: "testRoom",
                                    server: "testServer"
                                ),
                                profileId: "TestMod2",
                                role: .moderator,
                                isHidden: true
                            )
                        ))
                    }
                    
                    it("does not insert mods if no moderators are provided") {
                        var didComplete: Bool = false   // Prevent multi-threading test bugs
                        
                        testPollInfo = OpenGroupAPI.RoomPollInfo(
                            token: "testRoom",
                            activeUsers: 10,
                            admin: false,
                            globalAdmin: false,
                            moderator: false,
                            globalModerator: false,
                            read: false,
                            defaultRead: nil,
                            defaultAccessible: nil,
                            write: false,
                            defaultWrite: nil,
                            upload: false,
                            defaultUpload: nil,
                            details: nil
                        )
                        
                        mockStorage.write { db in
                            try OpenGroupManager.handlePollInfo(
                                db,
                                pollInfo: testPollInfo,
                                publicKey: TestConstants.publicKey,
                                for: "testRoom",
                                on: "testServer",
                                dependencies: dependencies
                            ) { didComplete = true }
                        }
                        
                        expect(didComplete).toEventually(beTrue(), timeout: .milliseconds(50))
                        expect(mockStorage.read { db -> Int in try GroupMember.fetchCount(db) })
                            .to(equal(0))
                    }
                }
                
                context("and updating the admin list") {
                    it("successfully updates") {
                        var didComplete: Bool = false   // Prevent multi-threading test bugs
                        
                        testPollInfo = OpenGroupAPI.RoomPollInfo(
                            token: "testRoom",
                            activeUsers: 10,
                            admin: false,
                            globalAdmin: false,
                            moderator: false,
                            globalModerator: false,
                            read: false,
                            defaultRead: nil,
                            defaultAccessible: nil,
                            write: false,
                            defaultWrite: nil,
                            upload: false,
                            defaultUpload: nil,
                            details: TestCapabilitiesAndRoomApi.roomData.with(
                                moderators: [],
                                hiddenModerators: [],
                                admins: ["TestAdmin"],
                                hiddenAdmins: []
                            )
                        )
                        
                        mockStorage.write { db in
                            try OpenGroupManager.handlePollInfo(
                                db,
                                pollInfo: testPollInfo,
                                publicKey: TestConstants.publicKey,
                                for: "testRoom",
                                on: "testServer",
                                dependencies: dependencies
                            ) { didComplete = true }
                        }
                        
                        expect(didComplete).toEventually(beTrue(), timeout: .milliseconds(50))
                        expect(
                            mockStorage.read { db -> GroupMember? in
                                try GroupMember
                                    .filter(GroupMember.Columns.groupId == OpenGroup.idFor(
                                        roomToken: "testRoom",
                                        server: "testServer"
                                    ))
                                    .fetchOne(db)
                            }
                        ).to(equal(
                            GroupMember(
                                groupId: OpenGroup.idFor(
                                    roomToken: "testRoom",
                                    server: "testServer"
                                ),
                                profileId: "TestAdmin",
                                role: .admin,
                                isHidden: false
                            )
                        ))
                    }
                    
                    it("updates for hidden admins") {
                        var didComplete: Bool = false   // Prevent multi-threading test bugs
                        
                        testPollInfo = OpenGroupAPI.RoomPollInfo(
                            token: "testRoom",
                            activeUsers: 10,
                            admin: false,
                            globalAdmin: false,
                            moderator: false,
                            globalModerator: false,
                            read: false,
                            defaultRead: nil,
                            defaultAccessible: nil,
                            write: false,
                            defaultWrite: nil,
                            upload: false,
                            defaultUpload: nil,
                            details: TestCapabilitiesAndRoomApi.roomData.with(
                                moderators: [],
                                hiddenModerators: [],
                                admins: [],
                                hiddenAdmins: ["TestAdmin2"]
                            )
                        )
                        
                        mockStorage.write { db in
                            try OpenGroupManager.handlePollInfo(
                                db,
                                pollInfo: testPollInfo,
                                publicKey: TestConstants.publicKey,
                                for: "testRoom",
                                on: "testServer",
                                dependencies: dependencies
                            ) { didComplete = true }
                        }
                        
                        expect(didComplete).toEventually(beTrue(), timeout: .milliseconds(50))
                        expect(
                            mockStorage.read { db -> GroupMember? in
                                try GroupMember
                                    .filter(GroupMember.Columns.groupId == OpenGroup.idFor(
                                        roomToken: "testRoom",
                                        server: "testServer"
                                    ))
                                    .fetchOne(db)
                            }
                        ).to(equal(
                            GroupMember(
                                groupId: OpenGroup.idFor(
                                    roomToken: "testRoom",
                                    server: "testServer"
                                ),
                                profileId: "TestAdmin2",
                                role: .admin,
                                isHidden: true
                            )
                        ))
                    }
                    
                    it("does not insert an admin if no admins are provided") {
                        var didComplete: Bool = false   // Prevent multi-threading test bugs
                        
                        testPollInfo = OpenGroupAPI.RoomPollInfo(
                            token: "testRoom",
                            activeUsers: 10,
                            admin: false,
                            globalAdmin: false,
                            moderator: false,
                            globalModerator: false,
                            read: false,
                            defaultRead: nil,
                            defaultAccessible: nil,
                            write: false,
                            defaultWrite: nil,
                            upload: false,
                            defaultUpload: nil,
                            details: nil
                        )
                        
                        mockStorage.write { db in
                            try OpenGroupManager.handlePollInfo(
                                db,
                                pollInfo: testPollInfo,
                                publicKey: TestConstants.publicKey,
                                for: "testRoom",
                                on: "testServer",
                                dependencies: dependencies
                            ) { didComplete = true }
                        }
                        
                        expect(didComplete).toEventually(beTrue(), timeout: .milliseconds(50))
                        expect(mockStorage.read { db -> Int in try GroupMember.fetchCount(db) })
                            .to(equal(0))
                    }
                }
                
                context("when it cannot get the open group") {
                    it("does not save the thread") {
                        mockStorage.write { db in
                            try OpenGroup.deleteAll(db)
                        }
                        
                        mockStorage.write { db in
                            try OpenGroupManager.handlePollInfo(
                                db,
                                pollInfo: testPollInfo,
                                publicKey: TestConstants.publicKey,
                                for: "testRoom",
                                on: "testServer",
                                dependencies: dependencies
                            )
                        }
                        
                        expect(mockStorage.read { db -> Int in try OpenGroup.fetchCount(db) }).to(equal(0))
                    }
                }
                
                context("when not given a public key") {
                    it("saves the open group with the existing public key") {
                        var didComplete: Bool = false   // Prevent multi-threading test bugs
                        
                        mockStorage.write { db in
                            try OpenGroupManager.handlePollInfo(
                                db,
                                pollInfo: testPollInfo,
                                publicKey: nil,
                                for: "testRoom",
                                on: "testServer",
                                dependencies: dependencies
                            ) { didComplete = true }
                        }
                        
                        expect(didComplete).toEventually(beTrue(), timeout: .milliseconds(50))
                        expect(
                            mockStorage.read { db -> String? in
                                try OpenGroup
                                    .select(.publicKey)
                                    .asRequest(of: String.self)
                                    .fetchOne(db)
                            }
                        ).to(equal(TestConstants.publicKey))
                    }
                }
                
                context("when checking to start polling") {
                    it("starts a new poller when not already polling") {
                        var didComplete: Bool = false   // Prevent multi-threading test bugs
                        
                        mockOGMCache.when { $0.pollers }.thenReturn([:])
                        
                        mockStorage.write { db in
                            try OpenGroupManager.handlePollInfo(
                                db,
                                pollInfo: testPollInfo,
                                publicKey: TestConstants.publicKey,
                                for: "testRoom",
                                on: "testServer",
                                dependencies: dependencies
                            ) { didComplete = true }
                        }
                        
                        expect(didComplete).toEventually(beTrue(), timeout: .milliseconds(50))
                        expect(mockOGMCache)
                            .to(call(matchingParameters: true) {
                                $0.pollers = ["testserver": OpenGroupAPI.Poller(for: "testserver")]
                            })
                    }
                    
                    it("does not start a new poller when already polling") {
                        var didComplete: Bool = false   // Prevent multi-threading test bugs
                        
                        mockOGMCache.when { $0.pollers }.thenReturn(["testserver": OpenGroupAPI.Poller(for: "testserver")])
                        
                        mockStorage.write { db in
                            try OpenGroupManager.handlePollInfo(
                                db,
                                pollInfo: testPollInfo,
                                publicKey: TestConstants.publicKey,
                                for: "testRoom",
                                on: "testServer",
                                dependencies: dependencies
                            ) { didComplete = true }
                        }
                        
                        expect(didComplete).toEventually(beTrue(), timeout: .milliseconds(50))
                        expect(mockOGMCache).to(call(.exactly(times: 1)) { $0.pollers })
                    }
                }
                
                context("when trying to get the room image") {
                    beforeEach {
                        let image: UIImage = UIImage(color: .red, size: CGSize(width: 1, height: 1))
                        let imageData: Data = image.pngData()!
                        
                        mockStorage.write { db in
                            try OpenGroup
                                .updateAll(db, OpenGroup.Columns.imageData.set(to: nil))
                        }
                        
                        mockOGMCache.when { $0.groupImagePublishers }
                            .thenReturn([
                                OpenGroup.idFor(roomToken: "testRoom", server: "testServer"): Just(imageData).setFailureType(to: Error.self).eraseToAnyPublisher()
                            ])
                    }
                    
                    it("uses the provided room image id if available") {
                        var didComplete: Bool = false   // Prevent multi-threading test bugs
                        
                        testPollInfo = OpenGroupAPI.RoomPollInfo(
                            token: "testRoom",
                            activeUsers: 10,
                            admin: false,
                            globalAdmin: false,
                            moderator: false,
                            globalModerator: false,
                            read: false,
                            defaultRead: nil,
                            defaultAccessible: nil,
                            write: false,
                            defaultWrite: nil,
                            upload: false,
                            defaultUpload: nil,
                            details: OpenGroupAPI.Room(
                                token: "test",
                                name: "test",
                                roomDescription: nil,
                                infoUpdates: 0,
                                messageSequence: 0,
                                created: 0,
                                activeUsers: 0,
                                activeUsersCutoff: 0,
                                imageId: "10",
                                pinnedMessages: nil,
                                admin: false,
                                globalAdmin: false,
                                admins: [],
                                hiddenAdmins: nil,
                                moderator: false,
                                globalModerator: false,
                                moderators: [],
                                hiddenModerators: nil,
                                read: false,
                                defaultRead: nil,
                                defaultAccessible: nil,
                                write: false,
                                defaultWrite: nil,
                                upload: false,
                                defaultUpload: nil
                            )
                        )
                        
                        mockStorage.write { db in
                            try OpenGroupManager.handlePollInfo(
                                db,
                                pollInfo: testPollInfo,
                                publicKey: TestConstants.publicKey,
                                for: "testRoom",
                                on: "testServer",
                                waitForImageToComplete: true,
                                dependencies: dependencies
                            ) { didComplete = true }
                        }
                        
                        expect(didComplete).toEventually(beTrue(), timeout: .milliseconds(50))
                        expect(
                            mockStorage.read { db -> String? in
                                try OpenGroup
                                    .select(.imageId)
                                    .asRequest(of: String.self)
                                    .fetchOne(db)
                            }
                        ).to(equal("10"))
                        expect(
                            mockStorage.read { db -> Data? in
                                try OpenGroup
                                    .select(.imageData)
                                    .asRequest(of: Data.self)
                                    .fetchOne(db)
                            }
                        ).toNot(beNil())
                    }
                    
                    it("uses the existing room image id if none is provided") {
                        var didComplete: Bool = false   // Prevent multi-threading test bugs
                        
                        mockStorage.write { db in
                            try OpenGroup.deleteAll(db)
                            try OpenGroup(
                                server: "testServer",
                                roomToken: "testRoom",
                                publicKey: TestConstants.publicKey,
                                isActive: true,
                                name: "Test",
                                imageId: "12",
                                imageData: Data([1, 2, 3]),
                                userCount: 0,
                                infoUpdates: 10
                            ).insert(db)
                        }
                        
                        testPollInfo = OpenGroupAPI.RoomPollInfo(
                            token: "testRoom",
                            activeUsers: 10,
                            admin: false,
                            globalAdmin: false,
                            moderator: false,
                            globalModerator: false,
                            read: false,
                            defaultRead: nil,
                            defaultAccessible: nil,
                            write: false,
                            defaultWrite: nil,
                            upload: false,
                            defaultUpload: nil,
                            details: nil
                        )
                        
                        mockStorage.write { db in
                            try OpenGroupManager.handlePollInfo(
                                db,
                                pollInfo: testPollInfo,
                                publicKey: TestConstants.publicKey,
                                for: "testRoom",
                                on: "testServer",
                                waitForImageToComplete: true,
                                dependencies: dependencies
                            ) { didComplete = true }
                        }
                        
                        expect(didComplete).toEventually(beTrue(), timeout: .milliseconds(50))
                        expect(
                            mockStorage.read { db -> String? in
                                try OpenGroup
                                    .select(.imageId)
                                    .asRequest(of: String.self)
                                    .fetchOne(db)
                            }
                        ).to(equal("12"))
                        expect(
                            mockStorage.read { db -> Data? in
                                try OpenGroup
                                    .select(.imageData)
                                    .asRequest(of: Data.self)
                                    .fetchOne(db)
                            }
                        ).toNot(beNil())
                    }
                    
                    it("uses the new room image id if there is an existing one") {
                        var didComplete: Bool = false   // Prevent multi-threading test bugs
                        
                        mockStorage.write { db in
                            try OpenGroup.deleteAll(db)
                            try OpenGroup(
                                server: "testServer",
                                roomToken: "testRoom",
                                publicKey: TestConstants.publicKey,
                                isActive: true,
                                name: "Test",
                                imageId: "12",
                                imageData: UIImage(color: .blue, size: CGSize(width: 1, height: 1)).pngData(),
                                userCount: 0,
                                infoUpdates: 10
                            ).insert(db)
                        }
                        
                        testPollInfo = OpenGroupAPI.RoomPollInfo(
                            token: "testRoom",
                            activeUsers: 10,
                            admin: false,
                            globalAdmin: false,
                            moderator: false,
                            globalModerator: false,
                            read: false,
                            defaultRead: nil,
                            defaultAccessible: nil,
                            write: false,
                            defaultWrite: nil,
                            upload: false,
                            defaultUpload: nil,
                            details: OpenGroupAPI.Room(
                                token: "test",
                                name: "test",
                                roomDescription: nil,
                                infoUpdates: 10,
                                messageSequence: 0,
                                created: 0,
                                activeUsers: 0,
                                activeUsersCutoff: 0,
                                imageId: "10",
                                pinnedMessages: nil,
                                admin: false,
                                globalAdmin: false,
                                admins: [],
                                hiddenAdmins: nil,
                                moderator: false,
                                globalModerator: false,
                                moderators: [],
                                hiddenModerators: nil,
                                read: false,
                                defaultRead: nil,
                                defaultAccessible: nil,
                                write: false,
                                defaultWrite: nil,
                                upload: false,
                                defaultUpload: nil
                            )
                        )
                        
                        mockStorage.write { db in
                            try OpenGroupManager.handlePollInfo(
                                db,
                                pollInfo: testPollInfo,
                                publicKey: TestConstants.publicKey,
                                for: "testRoom",
                                on: "testServer",
                                waitForImageToComplete: true,
                                dependencies: dependencies
                            ) { didComplete = true }
                        }
                        
                        expect(didComplete).toEventually(beTrue(), timeout: .milliseconds(50))
                        expect(
                            mockStorage.read { db -> String? in
                                try OpenGroup
                                    .select(.imageId)
                                    .asRequest(of: String.self)
                                    .fetchOne(db)
                            }
                        ).to(equal("10"))
                        expect(
                            mockStorage.read { db -> Data? in
                                try OpenGroup
                                    .select(.imageData)
                                    .asRequest(of: Data.self)
                                    .fetchOne(db)
                            }
                        ).toNot(beNil())
                        expect(mockOGMCache)
                            .toEventually(
                                call(.exactly(times: 1)) { $0.groupImagePublishers },
                                timeout: .milliseconds(50)
                            )
                    }
                    
                    it("does nothing if there is no room image") {
                        var didComplete: Bool = false   // Prevent multi-threading test bugs
                        
                        mockStorage.write { db in
                            try OpenGroupManager.handlePollInfo(
                                db,
                                pollInfo: testPollInfo,
                                publicKey: TestConstants.publicKey,
                                for: "testRoom",
                                on: "testServer",
                                waitForImageToComplete: true,
                                dependencies: dependencies
                            ) { didComplete = true }
                        }
                        
                        expect(didComplete).toEventually(beTrue(), timeout: .milliseconds(50))
                        expect(
                            mockStorage.read { db -> Data? in
                                try OpenGroup
                                    .select(.imageData)
                                    .asRequest(of: Data.self)
                                    .fetchOne(db)
                            }
                        ).to(beNil())
                    }
                    
                    it("does nothing if it fails to retrieve the room image") {
                        var didComplete: Bool = false   // Prevent multi-threading test bugs
                        
                        mockOGMCache.when { $0.groupImagePublishers }
                            .thenReturn([
                                OpenGroup.idFor(roomToken: "testRoom", server: "testServer"): Fail(error: HTTPError.generic).eraseToAnyPublisher()
                            ])
                        
                        testPollInfo = OpenGroupAPI.RoomPollInfo(
                            token: "testRoom",
                            activeUsers: 10,
                            admin: false,
                            globalAdmin: false,
                            moderator: false,
                            globalModerator: false,
                            read: false,
                            defaultRead: nil,
                            defaultAccessible: nil,
                            write: false,
                            defaultWrite: nil,
                            upload: false,
                            defaultUpload: nil,
                            details: OpenGroupAPI.Room(
                                token: "test",
                                name: "test",
                                roomDescription: nil,
                                infoUpdates: 0,
                                messageSequence: 0,
                                created: 0,
                                activeUsers: 0,
                                activeUsersCutoff: 0,
                                imageId: "10",
                                pinnedMessages: nil,
                                admin: false,
                                globalAdmin: false,
                                admins: [],
                                hiddenAdmins: nil,
                                moderator: false,
                                globalModerator: false,
                                moderators: [],
                                hiddenModerators: nil,
                                read: false,
                                defaultRead: nil,
                                defaultAccessible: nil,
                                write: false,
                                defaultWrite: nil,
                                upload: false,
                                defaultUpload: nil
                            )
                        )
                        
                        mockStorage.write { db in
                            try OpenGroupManager.handlePollInfo(
                                db,
                                pollInfo: testPollInfo,
                                publicKey: TestConstants.publicKey,
                                for: "testRoom",
                                on: "testServer",
                                waitForImageToComplete: true,
                                dependencies: dependencies
                            ) { didComplete = true }
                        }
                        
                        expect(didComplete).toEventually(beTrue(), timeout: .milliseconds(50))
                        expect(
                            mockStorage.read { db -> Data? in
                                try OpenGroup
                                    .select(.imageData)
                                    .asRequest(of: Data.self)
                                    .fetchOne(db)
                            }
                        ).to(beNil())
                    }
                    
                    it("saves the retrieved room image") {
                        var didComplete: Bool = false   // Prevent multi-threading test bugs
                        
                        testPollInfo = OpenGroupAPI.RoomPollInfo(
                            token: "testRoom",
                            activeUsers: 10,
                            admin: false,
                            globalAdmin: false,
                            moderator: false,
                            globalModerator: false,
                            read: false,
                            defaultRead: nil,
                            defaultAccessible: nil,
                            write: false,
                            defaultWrite: nil,
                            upload: false,
                            defaultUpload: nil,
                            details: OpenGroupAPI.Room(
                                token: "test",
                                name: "test",
                                roomDescription: nil,
                                infoUpdates: 10,
                                messageSequence: 0,
                                created: 0,
                                activeUsers: 0,
                                activeUsersCutoff: 0,
                                imageId: "10",
                                pinnedMessages: nil,
                                admin: false,
                                globalAdmin: false,
                                admins: [],
                                hiddenAdmins: nil,
                                moderator: false,
                                globalModerator: false,
                                moderators: [],
                                hiddenModerators: nil,
                                read: false,
                                defaultRead: nil,
                                defaultAccessible: nil,
                                write: false,
                                defaultWrite: nil,
                                upload: false,
                                defaultUpload: nil
                            )
                        )
                        mockStorage.write { db in
                            try OpenGroupManager.handlePollInfo(
                                db,
                                pollInfo: testPollInfo,
                                publicKey: TestConstants.publicKey,
                                for: "testRoom",
                                on: "testServer",
                                waitForImageToComplete: true,
                                dependencies: dependencies
                            ) { didComplete = true }
                        }
                        
                        expect(didComplete).toEventually(beTrue(), timeout: .milliseconds(50))
                        expect(
                            mockStorage.read { db -> Data? in
                                try OpenGroup
                                    .select(.imageData)
                                    .asRequest(of: Data.self)
                                    .fetchOne(db)
                            }
                        ).toNot(beNil())
                    }
                }
            }
            
            // MARK: - --handleMessages
            
            context("when handling messages") {
                beforeEach {
                    mockStorage.write { db in
                        try testGroupThread.insert(db)
                        try testOpenGroup.insert(db)
                        try testInteraction1.insert(db)
                    }
                }
                
                it("updates the sequence number when there are messages") {
                    mockStorage.write { db in
                        OpenGroupManager.handleMessages(
                            db,
                            messages: [
                                OpenGroupAPI.Message(
                                    id: 1,
                                    sender: nil,
                                    posted: 123,
                                    edited: nil,
                                    deleted: nil,
                                    seqNo: 124,
                                    whisper: false,
                                    whisperMods: false,
                                    whisperTo: nil,
                                    base64EncodedData: nil,
                                    base64EncodedSignature: nil,
                                    reactions: nil
                                )
                            ],
                            for: "testRoom",
                            on: "testServer",
                            dependencies: dependencies
                        )
                    }
                    
                    expect(
                        mockStorage.read { db -> Int64? in
                            try OpenGroup
                                .select(.sequenceNumber)
                                .asRequest(of: Int64.self)
                                .fetchOne(db)
                        }
                    ).to(equal(124))
                }
                
                it("does not update the sequence number if there are no messages") {
                    mockStorage.write { db in
                        OpenGroupManager.handleMessages(
                            db,
                            messages: [],
                            for: "testRoom",
                            on: "testServer",
                            dependencies: dependencies
                        )
                    }
                    
                    expect(
                        mockStorage.read { db -> Int64? in
                            try OpenGroup
                                .select(.sequenceNumber)
                                .asRequest(of: Int64.self)
                                .fetchOne(db)
                        }
                    ).to(equal(5))
                }
                
                it("ignores a message with no sender") {
                    mockStorage.write { db in
                        try Interaction.deleteAll(db)
                    }
                    
                    mockStorage.write { db in
                        OpenGroupManager.handleMessages(
                            db,
                            messages: [
                                OpenGroupAPI.Message(
                                    id: 1,
                                    sender: nil,
                                    posted: 123,
                                    edited: nil,
                                    deleted: nil,
                                    seqNo: 124,
                                    whisper: false,
                                    whisperMods: false,
                                    whisperTo: nil,
                                    base64EncodedData: Data([1, 2, 3]).base64EncodedString(),
                                    base64EncodedSignature: nil,
                                    reactions: nil
                                )
                            ],
                            for: "testRoom",
                            on: "testServer",
                            dependencies: dependencies
                        )
                    }
                    
                    expect(mockStorage.read { db -> Int in try Interaction.fetchCount(db) }).to(equal(0))
                }
                
                it("ignores a message with invalid data") {
                    mockStorage.write { db in
                        try Interaction.deleteAll(db)
                    }
                    
                    mockStorage.write { db in
                        OpenGroupManager.handleMessages(
                            db,
                            messages: [
                                OpenGroupAPI.Message(
                                    id: 1,
                                    sender: "05\(TestConstants.publicKey)",
                                    posted: 123,
                                    edited: nil,
                                    deleted: nil,
                                    seqNo: 124,
                                    whisper: false,
                                    whisperMods: false,
                                    whisperTo: nil,
                                    base64EncodedData: Data([1, 2, 3]).base64EncodedString(),
                                    base64EncodedSignature: nil,
                                    reactions: nil
                                )
                            ],
                            for: "testRoom",
                            on: "testServer",
                            dependencies: dependencies
                        )
                    }
                    
                    expect(mockStorage.read { db -> Int in try Interaction.fetchCount(db) }).to(equal(0))
                }
                
                it("processes a message with valid data") {
                    mockStorage.write { db in
                        OpenGroupManager.handleMessages(
                            db,
                            messages: [testMessage],
                            for: "testRoom",
                            on: "testServer",
                            dependencies: dependencies
                        )
                    }
                    
                    expect(mockStorage.read { db -> Int in try Interaction.fetchCount(db) }).to(equal(1))
                }
                
                it("processes valid messages when combined with invalid ones") {
                    mockStorage.write { db in
                        OpenGroupManager.handleMessages(
                            db,
                            messages: [
                                OpenGroupAPI.Message(
                                    id: 2,
                                    sender: "05\(TestConstants.publicKey)",
                                    posted: 122,
                                    edited: nil,
                                    deleted: nil,
                                    seqNo: 123,
                                    whisper: false,
                                    whisperMods: false,
                                    whisperTo: nil,
                                    base64EncodedData: Data([1, 2, 3]).base64EncodedString(),
                                    base64EncodedSignature: nil,
                                    reactions: nil
                                ),
                                testMessage,
                            ],
                            for: "testRoom",
                            on: "testServer",
                            dependencies: dependencies
                        )
                    }
                    
                    expect(mockStorage.read { db -> Int in try Interaction.fetchCount(db) }).to(equal(1))
                }
                
                context("with no data") {
                    it("deletes the message if we have the message") {
                        mockStorage.write { db in
                            try Interaction
                                .updateAll(
                                    db,
                                    Interaction.Columns.openGroupServerMessageId.set(to: 127)
                                )
                        }
                        
                        mockStorage.write { db in
                            OpenGroupManager.handleMessages(
                                db,
                                messages: [
                                    OpenGroupAPI.Message(
                                        id: 127,
                                        sender: "05\(TestConstants.publicKey)",
                                        posted: 123,
                                        edited: nil,
                                        deleted: nil,
                                        seqNo: 123,
                                        whisper: false,
                                        whisperMods: false,
                                        whisperTo: nil,
                                        base64EncodedData: nil,
                                        base64EncodedSignature: nil,
                                        reactions: nil
                                    )
                                ],
                                for: "testRoom",
                                on: "testServer",
                                dependencies: dependencies
                            )
                        }
                        
                        expect(mockStorage.read { db -> Int in try Interaction.fetchCount(db) }).to(equal(0))
                    }
                    
                    it("does nothing if we do not have the message") {
                        mockStorage.write { db in
                            OpenGroupManager.handleMessages(
                                db,
                                messages: [
                                    OpenGroupAPI.Message(
                                        id: 127,
                                        sender: "05\(TestConstants.publicKey)",
                                        posted: 123,
                                        edited: nil,
                                        deleted: nil,
                                        seqNo: 123,
                                        whisper: false,
                                        whisperMods: false,
                                        whisperTo: nil,
                                        base64EncodedData: nil,
                                        base64EncodedSignature: nil,
                                        reactions: nil
                                    )
                                ],
                                for: "testRoom",
                                on: "testServer",
                                dependencies: dependencies
                            )
                        }
                        
                        expect(mockStorage.read { db -> Int in try Interaction.fetchCount(db) }).to(equal(0))
                    }
                }
            }
            
            // MARK: - --handleDirectMessages
            
            context("when handling direct messages") {
                beforeEach {
                    mockSodium
                        .when {
                            $0.sharedBlindedEncryptionKey(
                                secretKey: anyArray(),
                                otherBlindedPublicKey: anyArray(),
                                fromBlindedPublicKey: anyArray(),
                                toBlindedPublicKey: anyArray(),
                                genericHash: mockGenericHash
                            )
                        }
                        .thenReturn([])
                    mockSodium
                        .when { $0.generateBlindingFactor(serverPublicKey: any(), genericHash: mockGenericHash) }
                        .thenReturn([])
                    mockAeadXChaCha20Poly1305Ietf
                        .when {
                            $0.decrypt(
                                authenticatedCipherText: anyArray(),
                                secretKey: anyArray(),
                                nonce: anyArray()
                            )
                        }
                        .thenReturn(
                            Data(base64Encoded:"ChQKC1Rlc3RNZXNzYWdlONCI7I/3Iw==")!.bytes +
                            [UInt8](repeating: 0, count: 32)
                        )
                    mockSign
                        .when { $0.toX25519(ed25519PublicKey: anyArray()) }
                        .thenReturn(Data(hex: TestConstants.publicKey).bytes)
                }
                
                it("does nothing if there are no messages") {
                    mockStorage.write { db in
                        OpenGroupManager.handleDirectMessages(
                            db,
                            messages: [],
                            fromOutbox: false,
                            on: "testServer",
                            dependencies: dependencies
                        )
                    }
                    
                    expect(
                        mockStorage.read { db -> Int64? in
                            try OpenGroup
                                .select(.inboxLatestMessageId)
                                .asRequest(of: Int64.self)
                                .fetchOne(db)
                        }
                    ).to(equal(0))
                    expect(
                        mockStorage.read { db -> Int64? in
                            try OpenGroup
                                .select(.outboxLatestMessageId)
                                .asRequest(of: Int64.self)
                                .fetchOne(db)
                        }
                    ).to(equal(0))
                }
                
                it("does nothing if it cannot get the open group") {
                    mockStorage.write { db in
                        try OpenGroup.deleteAll(db)
                    }
                    
                    mockStorage.write { db in
                        OpenGroupManager.handleDirectMessages(
                            db,
                            messages: [testDirectMessage],
                            fromOutbox: false,
                            on: "testServer",
                            dependencies: dependencies
                        )
                    }
                    
                    expect(
                        mockStorage.read { db -> Int64? in
                            try OpenGroup
                                .select(.inboxLatestMessageId)
                                .asRequest(of: Int64.self)
                                .fetchOne(db)
                        }
                    ).to(beNil())
                    expect(
                        mockStorage.read { db -> Int64? in
                            try OpenGroup
                                .select(.outboxLatestMessageId)
                                .asRequest(of: Int64.self)
                                .fetchOne(db)
                        }
                    ).to(beNil())
                }
                
                it("ignores messages with non base64 encoded data") {
                    testDirectMessage = OpenGroupAPI.DirectMessage(
                        id: testDirectMessage.id,
                        sender: testDirectMessage.sender.replacingOccurrences(of: "8", with: "9"),
                        recipient: testDirectMessage.recipient,
                        posted: testDirectMessage.posted,
                        expires: testDirectMessage.expires,
                        base64EncodedMessage: "TestMessage%%%"
                    )
                    
                    mockStorage.write { db in
                        OpenGroupManager.handleDirectMessages(
                            db,
                            messages: [testDirectMessage],
                            fromOutbox: false,
                            on: "testServer",
                            dependencies: dependencies
                        )
                    }
                    
                    expect(mockStorage.read { db -> Int in try Interaction.fetchCount(db) }).to(equal(0))
                }
                
                context("for the inbox") {
                    beforeEach {
                        mockSodium
                            .when { $0.combineKeys(lhsKeyBytes: anyArray(), rhsKeyBytes: anyArray()) }
                            .thenReturn(Data(hex: testDirectMessage.sender.removingIdPrefixIfNeeded()).bytes)
                        
                        mockSodium
                            .when { $0.sessionId(any(), matchesBlindedId: any(), serverPublicKey: any(), genericHash: mockGenericHash) }
                            .thenReturn(false)
                    }
                    
                    it("updates the inbox latest message id") {
                        mockStorage.write { db in
                            OpenGroupManager.handleDirectMessages(
                                db,
                                messages: [testDirectMessage],
                                fromOutbox: false,
                                on: "testServer",
                                dependencies: dependencies
                            )
                        }
                        
                        expect(
                            mockStorage.read { db -> Int64? in
                                try OpenGroup
                                    .select(.inboxLatestMessageId)
                                    .asRequest(of: Int64.self)
                                    .fetchOne(db)
                            }
                        ).to(equal(128))
                    }
                    
                    it("ignores a message with invalid data") {
                        testDirectMessage = OpenGroupAPI.DirectMessage(
                            id: testDirectMessage.id,
                            sender: testDirectMessage.sender.replacingOccurrences(of: "8", with: "9"),
                            recipient: testDirectMessage.recipient,
                            posted: testDirectMessage.posted,
                            expires: testDirectMessage.expires,
                            base64EncodedMessage: Data([1, 2, 3]).base64EncodedString()
                        )
                        
                        mockStorage.write { db in
                            OpenGroupManager.handleDirectMessages(
                                db,
                                messages: [testDirectMessage],
                                fromOutbox: false,
                                on: "testServer",
                                dependencies: dependencies
                            )
                        }
                        
                        expect(mockStorage.read { db -> Int in try Interaction.fetchCount(db) }).to(equal(0))
                    }
                    
                    it("processes a message with valid data") {
                        mockStorage.write { db in
                            OpenGroupManager.handleDirectMessages(
                                db,
                                messages: [testDirectMessage],
                                fromOutbox: false,
                                on: "testServer",
                                dependencies: dependencies
                            )
                        }
                        
                        expect(mockStorage.read { db -> Int in try Interaction.fetchCount(db) }).to(equal(1))
                    }
                    
                    it("processes valid messages when combined with invalid ones") {
                        mockStorage.write { db in
                            OpenGroupManager.handleDirectMessages(
                                db,
                                messages: [
                                    OpenGroupAPI.DirectMessage(
                                        id: testDirectMessage.id,
                                        sender: testDirectMessage.sender.replacingOccurrences(of: "8", with: "9"),
                                        recipient: testDirectMessage.recipient,
                                        posted: testDirectMessage.posted,
                                        expires: testDirectMessage.expires,
                                        base64EncodedMessage: Data([1, 2, 3]).base64EncodedString()
                                    ),
                                    testDirectMessage
                                ],
                                fromOutbox: false,
                                on: "testServer",
                                dependencies: dependencies
                            )
                        }
                        
                        expect(mockStorage.read { db -> Int in try Interaction.fetchCount(db) }).to(equal(1))
                    }
                }
                
                context("for the outbox") {
                    beforeEach {
                        mockSodium
                            .when { $0.combineKeys(lhsKeyBytes: anyArray(), rhsKeyBytes: anyArray()) }
                            .thenReturn(Data(hex: testDirectMessage.recipient.removingIdPrefixIfNeeded()).bytes)
                        
                        mockSodium
                            .when { $0.sessionId(any(), matchesBlindedId: any(), serverPublicKey: any(), genericHash: mockGenericHash) }
                            .thenReturn(false)
                    }
                    
                    it("updates the outbox latest message id") {
                        mockStorage.write { db in
                            OpenGroupManager.handleDirectMessages(
                                db,
                                messages: [testDirectMessage],
                                fromOutbox: true,
                                on: "testServer",
                                dependencies: dependencies
                            )
                        }
                        
                        expect(
                            mockStorage.read { db -> Int64? in
                                try OpenGroup
                                    .select(.outboxLatestMessageId)
                                    .asRequest(of: Int64.self)
                                    .fetchOne(db)
                            }
                        ).to(equal(128))
                    }
                    
                    it("retrieves an existing blinded id lookup") {
                        mockStorage.write { db in
                            try BlindedIdLookup(
                                blindedId: "15\(TestConstants.publicKey)",
                                sessionId: "TestSessionId",
                                openGroupServer: "testserver",
                                openGroupPublicKey: "05\(TestConstants.publicKey)"
                            ).insert(db)
                        }
                        
                        mockStorage.write { db in
                            OpenGroupManager.handleDirectMessages(
                                db,
                                messages: [testDirectMessage],
                                fromOutbox: true,
                                on: "testServer",
                                dependencies: dependencies
                            )
                        }
                        
                        expect(mockStorage.read { db -> Int in try BlindedIdLookup.fetchCount(db) }).to(equal(1))
                        expect(mockStorage.read { db -> Int in try SessionThread.fetchCount(db) }).to(equal(2))
                    }
                    
                    it("falls back to using the blinded id if no lookup is found") {
                        mockStorage.write { db in
                            OpenGroupManager.handleDirectMessages(
                                db,
                                messages: [testDirectMessage],
                                fromOutbox: true,
                                on: "testServer",
                                dependencies: dependencies
                            )
                        }
                        
                        expect(mockStorage.read { db -> Int in try BlindedIdLookup.fetchCount(db) }).to(equal(1))
                        expect(mockStorage
                            .read { db -> String? in
                                try BlindedIdLookup
                                    .select(.sessionId)
                                    .asRequest(of: String.self)
                                    .fetchOne(db)
                            }
                        ).to(beNil())
                        expect(mockStorage.read { db -> Int in try SessionThread.fetchCount(db) }).to(equal(2))
                        expect(
                            mockStorage.read { db -> SessionThread? in
                                try SessionThread.fetchOne(db, id: "15\(TestConstants.publicKey)")
                            }
                        ).toNot(beNil())
                    }
                    
                    it("ignores a message with invalid data") {
                        testDirectMessage = OpenGroupAPI.DirectMessage(
                            id: testDirectMessage.id,
                            sender: testDirectMessage.sender.replacingOccurrences(of: "8", with: "9"),
                            recipient: testDirectMessage.recipient,
                            posted: testDirectMessage.posted,
                            expires: testDirectMessage.expires,
                            base64EncodedMessage: Data([1, 2, 3]).base64EncodedString()
                        )
                        
                        mockStorage.write { db in
                            OpenGroupManager.handleDirectMessages(
                                db,
                                messages: [testDirectMessage],
                                fromOutbox: true,
                                on: "testServer",
                                dependencies: dependencies
                            )
                        }
                        
                        expect(mockStorage.read { db -> Int in try SessionThread.fetchCount(db) }).to(equal(1))
                    }
                    
                    it("processes a message with valid data") {
                        mockStorage.write { db in
                            OpenGroupManager.handleDirectMessages(
                                db,
                                messages: [testDirectMessage],
                                fromOutbox: true,
                                on: "testServer",
                                dependencies: dependencies
                            )
                        }
                        
                        expect(mockStorage.read { db -> Int in try SessionThread.fetchCount(db) }).to(equal(2))
                    }
                    
                    it("processes valid messages when combined with invalid ones") {
                        mockStorage.write { db in
                            OpenGroupManager.handleDirectMessages(
                                db,
                                messages: [
                                    OpenGroupAPI.DirectMessage(
                                        id: testDirectMessage.id,
                                        sender: testDirectMessage.sender.replacingOccurrences(of: "8", with: "9"),
                                        recipient: testDirectMessage.recipient,
                                        posted: testDirectMessage.posted,
                                        expires: testDirectMessage.expires,
                                        base64EncodedMessage: Data([1, 2, 3]).base64EncodedString()
                                    ),
                                    testDirectMessage
                                ],
                                fromOutbox: true,
                                on: "testServer",
                                dependencies: dependencies
                            )
                        }
                        
                        expect(mockStorage.read { db -> Int in try SessionThread.fetchCount(db) }).to(equal(2))
                    }
                }
            }
            
            // MARK: - Convenience
            
            // MARK: - --isUserModeratorOrAdmin
            
            context("when determining if a user is a moderator or an admin") {
                beforeEach {
                    mockStorage.write { db in
                        _ = try GroupMember.deleteAll(db)
                    }
                }
                
                it("uses an empty set for moderators by default") {
                    expect(
                        OpenGroupManager.isUserModeratorOrAdmin(
                            "05\(TestConstants.publicKey)",
                            for: "testRoom",
                            on: "testServer",
                            using: dependencies
                        )
                    ).to(beFalse())
                }
                
                it("uses an empty set for admins by default") {
                    expect(
                        OpenGroupManager.isUserModeratorOrAdmin(
                            "05\(TestConstants.publicKey)",
                            for: "testRoom",
                            on: "testServer",
                            using: dependencies
                        )
                    ).to(beFalse())
                }
                
                it("returns true if the key is in the moderator set") {
                    mockStorage.write { db in
                        try GroupMember(
                            groupId: OpenGroup.idFor(roomToken: "testRoom", server: "testServer"),
                            profileId: "05\(TestConstants.publicKey)",
                            role: .moderator,
                            isHidden: false
                        ).insert(db)
                    }
                    
                    expect(
                        OpenGroupManager.isUserModeratorOrAdmin(
                            "05\(TestConstants.publicKey)",
                            for: "testRoom",
                            on: "testServer",
                            using: dependencies
                        )
                    ).to(beTrue())
                }
                
                it("returns true if the key is in the admin set") {
                    mockStorage.write { db in
                        try GroupMember(
                            groupId: OpenGroup.idFor(roomToken: "testRoom", server: "testServer"),
                            profileId: "05\(TestConstants.publicKey)",
                            role: .admin,
                            isHidden: false
                        ).insert(db)
                    }
                    
                    expect(
                        OpenGroupManager.isUserModeratorOrAdmin(
                            "05\(TestConstants.publicKey)",
                            for: "testRoom",
                            on: "testServer",
                            using: dependencies
                        )
                    ).to(beTrue())
                }
                
                it("returns true if the moderator is hidden") {
                    mockStorage.write { db in
                        try GroupMember(
                            groupId: OpenGroup.idFor(roomToken: "testRoom", server: "testServer"),
                            profileId: "05\(TestConstants.publicKey)",
                            role: .moderator,
                            isHidden: true
                        ).insert(db)
                    }
                    
                    expect(
                        OpenGroupManager.isUserModeratorOrAdmin(
                            "05\(TestConstants.publicKey)",
                            for: "testRoom",
                            on: "testServer",
                            using: dependencies
                        )
                    ).to(beTrue())
                }
                
                it("returns true if the admin is hidden") {
                    mockStorage.write { db in
                        try GroupMember(
                            groupId: OpenGroup.idFor(roomToken: "testRoom", server: "testServer"),
                            profileId: "05\(TestConstants.publicKey)",
                            role: .admin,
                            isHidden: true
                        ).insert(db)
                    }
                    
                    expect(
                        OpenGroupManager.isUserModeratorOrAdmin(
                            "05\(TestConstants.publicKey)",
                            for: "testRoom",
                            on: "testServer",
                            using: dependencies
                        )
                    ).to(beTrue())
                }
                
                it("returns false if the key is not a valid session id") {
                    expect(
                        OpenGroupManager.isUserModeratorOrAdmin(
                            "InvalidValue",
                            for: "testRoom",
                            on: "testServer",
                            using: dependencies
                        )
                    ).to(beFalse())
                }
                
                context("and the key is a standard session id") {
                    it("returns false if the key is not the users session id") {
                        mockStorage.write { db in
                            let otherKey: String = TestConstants.publicKey.replacingOccurrences(of: "7", with: "6")
                            
                            try Identity(variant: .x25519PublicKey, data: Data.data(fromHex: otherKey)!).save(db)
                            try Identity(variant: .x25519PrivateKey, data: Data.data(fromHex: TestConstants.privateKey)!).save(db)
                        }
                        
                        expect(
                            OpenGroupManager.isUserModeratorOrAdmin(
                                "05\(TestConstants.publicKey)",
                                for: "testRoom",
                                on: "testServer",
                                using: dependencies
                            )
                        ).to(beFalse())
                    }
                    
                    it("returns true if the key is the current users and the users unblinded id is a moderator or admin") {
                        mockStorage.write { db in
                            let otherKey: String = TestConstants.publicKey.replacingOccurrences(of: "7", with: "6")
                            
                            try GroupMember(
                                groupId: OpenGroup.idFor(roomToken: "testRoom", server: "testServer"),
                                profileId: "00\(otherKey)",
                                role: .moderator,
                                isHidden: false
                            ).insert(db)
                            
                            try Identity(variant: .ed25519PublicKey, data: Data.data(fromHex: otherKey)!).save(db)
                            try Identity(variant: .ed25519SecretKey, data: Data.data(fromHex: TestConstants.edSecretKey)!).save(db)
                        }
                        
                        expect(
                            OpenGroupManager.isUserModeratorOrAdmin(
                                "05\(TestConstants.publicKey)",
                                for: "testRoom",
                                on: "testServer",
                                using: dependencies
                            )
                        ).to(beTrue())
                    }
                    
                    it("returns true if the key is the current users and the users blinded id is a moderator or admin") {
                        let otherKey: String = TestConstants.publicKey.replacingOccurrences(of: "7", with: "6")
                        mockSodium
                            .when {
                                $0.blindedKeyPair(
                                    serverPublicKey: any(),
                                    edKeyPair: any(),
                                    genericHash: mockGenericHash
                                )
                            }
                            .thenReturn(
                                KeyPair(
                                    publicKey: Data.data(fromHex: otherKey)!.bytes,
                                    secretKey: Data.data(fromHex: TestConstants.edSecretKey)!.bytes
                                )
                            )
                        mockStorage.write { db in
                            try GroupMember(
                                groupId: OpenGroup.idFor(roomToken: "testRoom", server: "testServer"),
                                profileId: "15\(otherKey)",
                                role: .moderator,
                                isHidden: false
                            ).insert(db)
                        }
                        
                        expect(
                            OpenGroupManager.isUserModeratorOrAdmin(
                                "05\(TestConstants.publicKey)",
                                for: "testRoom",
                                on: "testServer",
                                using: dependencies
                            )
                        ).to(beTrue())
                    }
                }
                
                context("and the key is unblinded") {
                    it("returns false if unable to retrieve the user ed25519 key") {
                        mockStorage.write { db in
                            try Identity.filter(id: .ed25519PublicKey).deleteAll(db)
                            try Identity.filter(id: .ed25519SecretKey).deleteAll(db)
                        }
                        
                        expect(
                            OpenGroupManager.isUserModeratorOrAdmin(
                                "00\(TestConstants.publicKey)",
                                for: "testRoom",
                                on: "testServer",
                                using: dependencies
                            )
                        ).to(beFalse())
                    }
                    
                    it("returns false if the key is not the users unblinded id") {
                        mockStorage.write { db in
                            let otherKey: String = TestConstants.publicKey.replacingOccurrences(of: "7", with: "6")
                            
                            try Identity(variant: .ed25519PublicKey, data: Data.data(fromHex: otherKey)!).save(db)
                            try Identity(variant: .ed25519SecretKey, data: Data.data(fromHex: TestConstants.edSecretKey)!).save(db)
                        }
                        
                        expect(
                            OpenGroupManager.isUserModeratorOrAdmin(
                                "00\(TestConstants.publicKey)",
                                for: "testRoom",
                                on: "testServer",
                                using: dependencies
                            )
                        ).to(beFalse())
                    }
                    
                    it("returns true if the key is the current users and the users session id is a moderator or admin") {
                        let otherKey: String = TestConstants.publicKey.replacingOccurrences(of: "7", with: "6")
                        mockGeneralCache.when { $0.encodedPublicKey }.thenReturn("05\(otherKey)")
                        mockStorage.write { db in
                            try GroupMember(
                                groupId: OpenGroup.idFor(roomToken: "testRoom", server: "testServer"),
                                profileId: "05\(otherKey)",
                                role: .moderator,
                                isHidden: false
                            ).insert(db)
                            
                            try Identity(variant: .x25519PublicKey, data: Data.data(fromHex: otherKey)!).save(db)
                            try Identity(variant: .x25519PrivateKey, data: Data.data(fromHex: TestConstants.privateKey)!).save(db)
                            try Identity(variant: .ed25519PublicKey, data: Data.data(fromHex: TestConstants.publicKey)!).save(db)
                            try Identity(variant: .ed25519SecretKey, data: Data.data(fromHex: TestConstants.edSecretKey)!).save(db)
                        }
                        
                        expect(
                            OpenGroupManager.isUserModeratorOrAdmin(
                                "00\(TestConstants.publicKey)",
                                for: "testRoom",
                                on: "testServer",
                                using: dependencies
                            )
                        ).to(beTrue())
                    }
                    
                    it("returns true if the key is the current users and the users blinded id is a moderator or admin") {
                        let otherKey: String = TestConstants.publicKey.replacingOccurrences(of: "7", with: "6")
                        mockSodium
                            .when {
                                $0.blindedKeyPair(
                                    serverPublicKey: any(),
                                    edKeyPair: any(),
                                    genericHash: mockGenericHash
                                )
                            }
                            .thenReturn(
                                KeyPair(
                                    publicKey: Data.data(fromHex: otherKey)!.bytes,
                                    secretKey: Data.data(fromHex: TestConstants.edSecretKey)!.bytes
                                )
                            )
                        mockStorage.write { db in
                            try GroupMember(
                                groupId: OpenGroup.idFor(roomToken: "testRoom", server: "testServer"),
                                profileId: "15\(otherKey)",
                                role: .moderator,
                                isHidden: false
                            ).insert(db)
                            
                            try Identity(variant: .x25519PublicKey, data: Data.data(fromHex: TestConstants.publicKey)!).save(db)
                            try Identity(variant: .x25519PrivateKey, data: Data.data(fromHex: TestConstants.privateKey)!).save(db)
                            try Identity(variant: .ed25519PublicKey, data: Data.data(fromHex: TestConstants.publicKey)!).save(db)
                            try Identity(variant: .ed25519SecretKey, data: Data.data(fromHex: TestConstants.edSecretKey)!).save(db)
                        }
                        
                        expect(
                            OpenGroupManager.isUserModeratorOrAdmin(
                                "00\(TestConstants.publicKey)",
                                for: "testRoom",
                                on: "testServer",
                                using: dependencies
                            )
                        ).to(beTrue())
                    }
                }
                
                context("and the key is blinded") {
                    it("returns false if unable to retrieve the user ed25519 key") {
                        mockStorage.write { db in
                            try Identity.filter(id: .ed25519PublicKey).deleteAll(db)
                            try Identity.filter(id: .ed25519SecretKey).deleteAll(db)
                        }
                        
                        expect(
                            OpenGroupManager.isUserModeratorOrAdmin(
                                "15\(TestConstants.publicKey)",
                                for: "testRoom",
                                on: "testServer",
                                using: dependencies
                            )
                        ).to(beFalse())
                    }
                    
                    it("returns false if unable generate a blinded key") {
                        mockSodium
                            .when {
                                $0.blindedKeyPair(
                                    serverPublicKey: any(),
                                    edKeyPair: any(),
                                    genericHash: mockGenericHash
                                )
                            }
                            .thenReturn(nil)
                        
                        expect(
                            OpenGroupManager.isUserModeratorOrAdmin(
                                "15\(TestConstants.publicKey)",
                                for: "testRoom",
                                on: "testServer",
                                using: dependencies
                            )
                        ).to(beFalse())
                    }
                    
                    it("returns false if the key is not the users blinded id") {
                        let otherKey: String = TestConstants.publicKey.replacingOccurrences(of: "7", with: "6")
                        mockSodium
                            .when {
                                $0.blindedKeyPair(
                                    serverPublicKey: any(),
                                    edKeyPair: any(),
                                    genericHash: mockGenericHash
                                )
                            }
                            .thenReturn(
                                KeyPair(
                                    publicKey: Data.data(fromHex: otherKey)!.bytes,
                                    secretKey: Data.data(fromHex: TestConstants.edSecretKey)!.bytes
                                )
                            )
                        
                        expect(
                            OpenGroupManager.isUserModeratorOrAdmin(
                                "15\(TestConstants.publicKey)",
                                for: "testRoom",
                                on: "testServer",
                                using: dependencies
                            )
                        ).to(beFalse())
                    }
                    
                    it("returns true if the key is the current users and the users session id is a moderator or admin") {
                        let otherKey: String = TestConstants.publicKey.replacingOccurrences(of: "7", with: "6")
                        mockGeneralCache.when { $0.encodedPublicKey }.thenReturn("05\(otherKey)")
                        mockSodium
                            .when {
                                $0.blindedKeyPair(
                                    serverPublicKey: any(),
                                    edKeyPair: any(),
                                    genericHash: mockGenericHash
                                )
                            }
                            .thenReturn(
                                KeyPair(
                                    publicKey: Data.data(fromHex: TestConstants.publicKey)!.bytes,
                                    secretKey: Data.data(fromHex: TestConstants.edSecretKey)!.bytes
                                )
                            )
                        mockStorage.write { db in
                            try GroupMember(
                                groupId: OpenGroup.idFor(roomToken: "testRoom", server: "testServer"),
                                profileId: "05\(otherKey)",
                                role: .moderator,
                                isHidden: false
                            ).insert(db)
                            
                            try Identity(variant: .x25519PublicKey, data: Data.data(fromHex: otherKey)!).save(db)
                            try Identity(variant: .x25519PrivateKey, data: Data.data(fromHex: TestConstants.privateKey)!).save(db)
                            try Identity(variant: .ed25519PublicKey, data: Data.data(fromHex: TestConstants.publicKey)!).save(db)
                            try Identity(variant: .ed25519SecretKey, data: Data.data(fromHex: TestConstants.edSecretKey)!).save(db)
                        }
                        
                        expect(
                            OpenGroupManager.isUserModeratorOrAdmin(
                                "15\(TestConstants.publicKey)",
                                for: "testRoom",
                                on: "testServer",
                                using: dependencies
                            )
                        ).to(beTrue())
                    }
                    
                    it("returns true if the key is the current users and the users unblinded id is a moderator or admin") {
                        mockSodium
                            .when {
                                $0.blindedKeyPair(
                                    serverPublicKey: any(),
                                    edKeyPair: any(),
                                    genericHash: mockGenericHash
                                )
                            }
                            .thenReturn(
                                KeyPair(
                                    publicKey: Data.data(fromHex: TestConstants.publicKey)!.bytes,
                                    secretKey: Data.data(fromHex: TestConstants.edSecretKey)!.bytes
                                )
                            )
                        mockStorage.write { db in
                            let otherKey: String = TestConstants.publicKey.replacingOccurrences(of: "7", with: "6")
                            
                            try GroupMember(
                                groupId: OpenGroup.idFor(roomToken: "testRoom", server: "testServer"),
                                profileId: "00\(otherKey)",
                                role: .moderator,
                                isHidden: false
                            ).insert(db)
                            
                            try Identity(variant: .x25519PublicKey, data: Data.data(fromHex: TestConstants.publicKey)!).save(db)
                            try Identity(variant: .x25519PrivateKey, data: Data.data(fromHex: TestConstants.privateKey)!).save(db)
                            try Identity(variant: .ed25519PublicKey, data: Data.data(fromHex: otherKey)!).save(db)
                            try Identity(variant: .ed25519SecretKey, data: Data.data(fromHex: TestConstants.edSecretKey)!).save(db)
                        }
                        
                        expect(
                            OpenGroupManager.isUserModeratorOrAdmin(
                                "15\(TestConstants.publicKey)",
                                for: "testRoom",
                                on: "testServer",
                                using: dependencies
                            )
                        ).to(beTrue())
                    }
                }
            }
            
            // MARK: - --getDefaultRoomsIfNeeded
            
            context("when getting the default rooms if needed") {
                beforeEach {
                    class TestRoomsApi: TestOnionRequestAPI {
                        static let capabilitiesData: OpenGroupAPI.Capabilities = OpenGroupAPI.Capabilities(capabilities: [.sogs], missing: nil)
                        static let roomsData: [OpenGroupAPI.Room] = [
                            TestCapabilitiesAndRoomApi.roomData,
                            OpenGroupAPI.Room(
                                token: "test2",
                                name: "test2",
                                roomDescription: nil,
                                infoUpdates: 11,
                                messageSequence: 0,
                                created: 0,
                                activeUsers: 0,
                                activeUsersCutoff: 0,
                                imageId: "12",
                                pinnedMessages: nil,
                                admin: false,
                                globalAdmin: false,
                                admins: [],
                                hiddenAdmins: nil,
                                moderator: false,
                                globalModerator: false,
                                moderators: [],
                                hiddenModerators: nil,
                                read: false,
                                defaultRead: nil,
                                defaultAccessible: nil,
                                write: false,
                                defaultWrite: nil,
                                upload: false,
                                defaultUpload: nil
                            )
                        ]
                        
                        override class var mockResponse: Data? {
                            let responses: [Data] = [
                                try! JSONEncoder().encode(
                                    HTTP.BatchSubResponse(
                                        code: 200,
                                        headers: [:],
                                        body: capabilitiesData,
                                        failedToParseBody: false
                                    )
                                ),
                                try! JSONEncoder().encode(
                                    HTTP.BatchSubResponse(
                                        code: 200,
                                        headers: [:],
                                        body: roomsData,
                                        failedToParseBody: false
                                    )
                                )
                            ]
                            
                            return "[\(responses.map { String(data: $0, encoding: .utf8)! }.joined(separator: ","))]".data(using: .utf8)
                        }
                    }
                    dependencies = dependencies.with(onionApi: TestRoomsApi.self)
                    
                    mockStorage.write { db in
                        try OpenGroup.deleteAll(db)
                        
                        // This is done in the 'RetrieveDefaultOpenGroupRoomsJob'
                        _ = try OpenGroup(
                            server: OpenGroupAPI.defaultServer,
                            roomToken: "",
                            publicKey: OpenGroupAPI.defaultServerPublicKey,
                            isActive: false,
                            name: "",
                            userCount: 0,
                            infoUpdates: 0
                        )
                        .insert(db)
                    }
                    
                    mockOGMCache.when { $0.defaultRoomsPublisher }.thenReturn(nil)
                    mockOGMCache.when { $0.groupImagePublishers }.thenReturn([:])
                    mockUserDefaults.when { (defaults: inout any UserDefaultsType) -> Any? in
                        defaults.object(forKey: any())
                    }.thenReturn(nil)
                    mockUserDefaults.when { (defaults: inout any UserDefaultsType) -> Any? in
                        defaults.set(anyAny(), forKey: any())
                    }.thenReturn(())
                }
                
                it("caches the promise if there is no cached promise") {
                    let publisher = OpenGroupManager.getDefaultRoomsIfNeeded(using: dependencies)
                    
                    expect(mockOGMCache)
                        .to(call(matchingParameters: true) {
                            $0.defaultRoomsPublisher = publisher
                        })
                }
                
                it("returns the cached promise if there is one") {
                    let uniqueRoomInstance: OpenGroupAPI.Room = OpenGroupAPI.Room(
                        token: "UniqueId",
                        name: "",
                        roomDescription: nil,
                        infoUpdates: 0,
                        messageSequence: 0,
                        created: 0,
                        activeUsers: 0,
                        activeUsersCutoff: 0,
                        imageId: nil,
                        pinnedMessages: nil,
                        admin: false,
                        globalAdmin: false,
                        admins: [],
                        hiddenAdmins: nil,
                        moderator: false,
                        globalModerator: false,
                        moderators: [],
                        hiddenModerators: nil,
                        read: false,
                        defaultRead: nil,
                        defaultAccessible: nil,
                        write: false,
                        defaultWrite: nil,
                        upload: false,
                        defaultUpload: nil
                    )
                    let publisher = Future<[OpenGroupManager.DefaultRoomInfo], Error> { resolver in
                        resolver(Result.success([(uniqueRoomInstance, nil)]))
                    }
                    .shareReplay(1)
                    .eraseToAnyPublisher()
                    mockOGMCache.when { $0.defaultRoomsPublisher }.thenReturn(publisher)
                    let publisher2 = OpenGroupManager.getDefaultRoomsIfNeeded(using: dependencies)
                    
                    expect(publisher2.firstValue()?.map { $0.room })
                        .to(equal(publisher.firstValue()?.map { $0.room }))
                }
                
                it("stores the open group information") {
                    OpenGroupManager.getDefaultRoomsIfNeeded(using: dependencies)
                    
                    expect(mockStorage.read { db -> Int in try OpenGroup.fetchCount(db) }).to(equal(1))
                    expect(
                        mockStorage.read { db -> String? in
                            try OpenGroup
                                .select(.server)
                                .asRequest(of: String.self)
                                .fetchOne(db)
                        }
                    ).to(equal("https://open.getsession.org"))
                    expect(
                        mockStorage.read { db -> String? in
                            try OpenGroup
                                .select(.publicKey)
                                .asRequest(of: String.self)
                                .fetchOne(db)
                        }
                    ).to(equal("a03c383cf63c3c4efe67acc52112a6dd734b3a946b9545f488aaa93da7991238"))
                    expect(
                        mockStorage.read { db -> Bool? in
                            try OpenGroup
                                .select(.isActive)
                                .asRequest(of: Bool.self)
                                .fetchOne(db)
                        }
                    ).to(beFalse())
                }
                
                it("fetches rooms for the server") {
                    var response: [OpenGroupManager.DefaultRoomInfo]?
                    
                    OpenGroupManager.getDefaultRoomsIfNeeded(using: dependencies)
                        .handleEvents(receiveOutput: { response = $0 })
                        .sinkAndStore(in: &disposables)
                    
                    expect(response?.map { $0.room })
                        .toEventually(
                            equal(
                                [
                                    TestCapabilitiesAndRoomApi.roomData,
                                    OpenGroupAPI.Room(
                                        token: "test2",
                                        name: "test2",
                                        roomDescription: nil,
                                        infoUpdates: 11,
                                        messageSequence: 0,
                                        created: 0,
                                        activeUsers: 0,
                                        activeUsersCutoff: 0,
                                        imageId: "12",
                                        pinnedMessages: nil,
                                        admin: false,
                                        globalAdmin: false,
                                        admins: [],
                                        hiddenAdmins: nil,
                                        moderator: false,
                                        globalModerator: false,
                                        moderators: [],
                                        hiddenModerators: nil,
                                        read: false,
                                        defaultRead: nil,
                                        defaultAccessible: nil,
                                        write: false,
                                        defaultWrite: nil,
                                        upload: false,
                                        defaultUpload: nil
                                    )
                                ]
                            ),
                            timeout: .milliseconds(50)
                        )
                }
                
                it("will retry fetching rooms 8 times before it fails") {
                    class TestRoomsApi: TestOnionRequestAPI {
                        static var callCounter: Int = 0
                        
                        override class var mockResponse: Data? {
                            callCounter += 1
                            return nil
                        }
                    }
                    dependencies = dependencies.with(onionApi: TestRoomsApi.self)
                    
                    var error: Error?
                    
                    OpenGroupManager.getDefaultRoomsIfNeeded(using: dependencies)
                        .mapError { result -> Error in error.setting(to: result) }
                        .sinkAndStore(in: &disposables)
                    
                    expect(error?.localizedDescription)
                        .toEventually(
                            equal(HTTPError.invalidResponse.localizedDescription),
                            timeout: .milliseconds(50)
                        )
                    expect(TestRoomsApi.callCounter).to(equal(9))   // First attempt + 8 retries
                }
                
                it("removes the cache promise if all retries fail") {
                    class TestRoomsApi: TestOnionRequestAPI {
                        override class var mockResponse: Data? { return nil }
                    }
                    dependencies = dependencies.with(onionApi: TestRoomsApi.self)
                    
                    var error: Error?
                    
                    OpenGroupManager.getDefaultRoomsIfNeeded(using: dependencies)
                        .mapError { result -> Error in error.setting(to: result) }
                        .sinkAndStore(in: &disposables)
                    
                    expect(error?.localizedDescription)
                        .toEventually(
                            equal(HTTPError.invalidResponse.localizedDescription),
                            timeout: .milliseconds(50)
                        )
                    expect(mockOGMCache)
                        .to(call(matchingParameters: true) {
                            $0.defaultRoomsPublisher = nil
                        })
                }
                
                it("fetches the image for any rooms with images") {
                    class TestRoomsApi: TestOnionRequestAPI {
                        static let capabilitiesData: OpenGroupAPI.Capabilities = OpenGroupAPI.Capabilities(capabilities: [.sogs], missing: nil)
                        static let roomsData: [OpenGroupAPI.Room] = [
                            OpenGroupAPI.Room(
                                token: "test2",
                                name: "test2",
                                roomDescription: nil,
                                infoUpdates: 11,
                                messageSequence: 0,
                                created: 0,
                                activeUsers: 0,
                                activeUsersCutoff: 0,
                                imageId: "12",
                                pinnedMessages: nil,
                                admin: false,
                                globalAdmin: false,
                                admins: [],
                                hiddenAdmins: nil,
                                moderator: false,
                                globalModerator: false,
                                moderators: [],
                                hiddenModerators: nil,
                                read: false,
                                defaultRead: nil,
                                defaultAccessible: nil,
                                write: false,
                                defaultWrite: nil,
                                upload: false,
                                defaultUpload: nil
                            )
                        ]
                        
                        override class var mockResponse: Data? {
                            let responses: [Data] = [
                                try! JSONEncoder().encode(
                                    HTTP.BatchSubResponse(
                                        code: 200,
                                        headers: [:],
                                        body: capabilitiesData,
                                        failedToParseBody: false
                                    )
                                ),
                                try! JSONEncoder().encode(
                                    HTTP.BatchSubResponse(
                                        code: 200,
                                        headers: [:],
                                        body: roomsData,
                                        failedToParseBody: false
                                    )
                                )
                            ]
                            
                            return "[\(responses.map { String(data: $0, encoding: .utf8)! }.joined(separator: ","))]".data(using: .utf8)
                        }
                    }
                    let testDate: Date = Date(timeIntervalSince1970: 1234567890)
                    dependencies = dependencies.with(
                        onionApi: TestRoomsApi.self,
                        date: testDate
                    )
                    
                    OpenGroupManager
                        .getDefaultRoomsIfNeeded(using: dependencies)
                        .sinkAndStore(in: &disposables)
                    
                    expect(mockUserDefaults)
                        .toEventually(
                            call(matchingParameters: true) {
                                $0.set(
                                    testDate,
                                    forKey: SNUserDefaults.Date.lastOpenGroupImageUpdate.rawValue
                                )
                            },
                            timeout: .milliseconds(100)
                        )
                    expect(
                        mockStorage.read { db -> Data? in
                            try OpenGroup
                                .select(.imageData)
                                .filter(id: OpenGroup.idFor(roomToken: "test2", server: OpenGroupAPI.defaultServer))
                                .asRequest(of: Data.self)
                                .fetchOne(db)
                        }
                    ).to(equal(TestRoomsApi.mockResponse!))
                }
            }
            
            // MARK: - --roomImage
            
            context("when getting a room image") {
                beforeEach {
                    class TestImageApi: TestOnionRequestAPI {
                        override class var mockResponse: Data? { return Data([1, 2, 3]) }
                    }
                    dependencies = dependencies.with(onionApi: TestImageApi.self)
                    
                    mockUserDefaults.when { (defaults: inout any UserDefaultsType) -> Any? in
                        defaults.object(forKey: any())
                    }.thenReturn(nil)
                    mockUserDefaults.when { (defaults: inout any UserDefaultsType) -> Any? in
                        defaults.set(anyAny(), forKey: any())
                    }.thenReturn(())
                    mockOGMCache.when { $0.groupImagePublishers }.thenReturn([:])
                    
                    mockStorage.write { db in
                        _ = try OpenGroup(
                            server: OpenGroupAPI.defaultServer,
                            roomToken: "testRoom",
                            publicKey: OpenGroupAPI.defaultServerPublicKey,
                            isActive: false,
                            name: "",
                            userCount: 0,
                            infoUpdates: 0
                        )
                        .insert(db)
                    }
                }
                
                it("retrieves the image retrieval promise from the cache if it exists") {
                    let publisher = Future<Data, Error> { resolver in
                        resolver(Result.success(Data([5, 4, 3, 2, 1])))
                    }
                    .shareReplay(1)
                    .eraseToAnyPublisher()
                    mockOGMCache
                        .when { $0.groupImagePublishers }
                        .thenReturn([OpenGroup.idFor(roomToken: "testRoom", server: "testServer"): publisher])
                    
                    var result: Data?
                    OpenGroupManager
                        .roomImage(
                            fileId: "1",
                            for: "testRoom",
                            on: "testServer",
                            existingData: nil,
                            using: dependencies
                        )
                        .handleEvents(receiveOutput: { result = $0 })
                        .sinkAndStore(in: &disposables)
                    
                    expect(result).toEventually(equal(publisher.firstValue()), timeout: .milliseconds(50))
                }
                
                it("does not save the fetched image to storage") {
                    var didComplete: Bool = false
                    OpenGroupManager
                        .roomImage(
                            fileId: "1",
                            for: "testRoom",
                            on: "testServer",
                            existingData: nil,
                            using: dependencies
                        )
                        .handleEvents(receiveCompletion: { _ in didComplete = true })
                        .sinkAndStore(in: &disposables)
                    
                    expect(didComplete).toEventually(beTrue(), timeout: .milliseconds(50))
                    expect(
                        mockStorage.read { db -> Data? in
                            try OpenGroup
                                .select(.imageData)
                                .filter(id: OpenGroup.idFor(roomToken: "testRoom", server: "testServer"))
                                .asRequest(of: Data.self)
                                .fetchOne(db)
                        }
                    ).toEventually(
                        beNil(),
                        timeout: .milliseconds(50)
                    )
                }
                
                it("does not update the image update timestamp") {
                    var didComplete: Bool = false
                    OpenGroupManager
                        .roomImage(
                            fileId: "1",
                            for: "testRoom",
                            on: "testServer",
                            existingData: nil,
                            using: dependencies
                        )
                        .handleEvents(receiveCompletion: { _ in didComplete = true })
                        .sinkAndStore(in: &disposables)
                    
                    expect(didComplete).toEventually(beTrue(), timeout: .milliseconds(50))
                    expect(mockUserDefaults)
                        .toEventuallyNot(
                            call(matchingParameters: true) {
                                $0.set(
                                    dependencies.date,
                                    forKey: SNUserDefaults.Date.lastOpenGroupImageUpdate.rawValue
                                )
                            },
                            timeout: .milliseconds(50)
                        )
                }
                
                it("adds the image retrieval promise to the cache") {
                    class TestNeverReturningApi: OnionRequestAPIType {
                        static func sendOnionRequest(_ request: URLRequest, to server: String, with x25519PublicKey: String, timeout: TimeInterval) -> AnyPublisher<(ResponseInfoType, Data?), Error> {
                            return Future<(ResponseInfoType, Data?), Error> { _ in }.eraseToAnyPublisher()
                        }
                        
                        static func sendOnionRequest(_ payload: Data, to snode: Snode, timeout: TimeInterval) -> AnyPublisher<(ResponseInfoType, Data?), Error> {
                            return Just(Data())
                                .setFailureType(to: Error.self)
                                .map { data in (HTTP.ResponseInfo(code: 0, headers: [:]), data) }
                                .eraseToAnyPublisher()
                        }
                    }
                    dependencies = dependencies.with(onionApi: TestNeverReturningApi.self)
                    
                    let publisher = OpenGroupManager
                        .roomImage(
                            fileId: "1",
                            for: "testRoom",
                            on: "testServer",
                            existingData: nil,
                            using: dependencies
                        )
                    publisher.sinkAndStore(in: &disposables)
                    
                    expect(mockOGMCache)
                        .toEventually(
                            call(matchingParameters: true) {
                                $0.groupImagePublishers = [OpenGroup.idFor(roomToken: "testRoom", server: "testServer"): publisher]
                            },
                            timeout: .milliseconds(50)
                        )
                }
                
                context("for the default server") {
                    it("fetches a new image if there is no cached one") {
                        var result: Data?
                        
                        OpenGroupManager
                            .roomImage(
                                fileId: "1",
                                for: "testRoom",
                                on: OpenGroupAPI.defaultServer,
                                existingData: nil,
                                using: dependencies
                            )
                            .handleEvents(receiveOutput: { (data: Data) in result = data })
                            .sinkAndStore(in: &disposables)
                        
                        expect(result).toEventually(equal(Data([1, 2, 3])), timeout: .milliseconds(50))
                    }
                    
                    it("saves the fetched image to storage") {
                        var didComplete: Bool = false
                        
                        OpenGroupManager
                            .roomImage(
                                fileId: "1",
                                for: "testRoom",
                                on: OpenGroupAPI.defaultServer,
                                existingData: nil,
                                using: dependencies
                            )
                            .handleEvents(receiveCompletion: { _ in didComplete = true })
                            .sinkAndStore(in: &disposables)
                        
                        expect(didComplete).toEventually(beTrue(), timeout: .milliseconds(50))
                        expect(
                            mockStorage.read { db -> Data? in
                                try OpenGroup
                                    .select(.imageData)
                                    .filter(id: OpenGroup.idFor(roomToken: "testRoom", server: OpenGroupAPI.defaultServer))
                                    .asRequest(of: Data.self)
                                    .fetchOne(db)
                            }
                        ).toEventuallyNot(
                            beNil(),
                            timeout: .milliseconds(50)
                        )
                    }
                    
                    it("updates the image update timestamp") {
                        var didComplete: Bool = false
                        
                        OpenGroupManager
                            .roomImage(
                                fileId: "1",
                                for: "testRoom",
                                on: OpenGroupAPI.defaultServer,
                                existingData: nil,
                                using: dependencies
                            )
                            .handleEvents(receiveCompletion: { _ in didComplete = true })
                            .sinkAndStore(in: &disposables)
                        
                        expect(didComplete).toEventually(beTrue(), timeout: .milliseconds(50))
                        expect(mockUserDefaults)
                            .toEventually(
                                call(matchingParameters: true) {
                                    $0.set(
                                        dependencies.date,
                                        forKey: SNUserDefaults.Date.lastOpenGroupImageUpdate.rawValue
                                    )
                                },
                                timeout: .milliseconds(50)
                            )
                    }
                    
                    context("and there is a cached image") {
                        beforeEach {
                            dependencies = dependencies.with(date: Date(timeIntervalSince1970: 1234567890))
                            mockUserDefaults
                                .when { (defaults: inout any UserDefaultsType) -> Any? in
                                    defaults.object(forKey: any())
                                }
                                .thenReturn(dependencies.date)
                            mockStorage.write(updates: { db in
                                try OpenGroup
                                    .filter(id: OpenGroup.idFor(roomToken: "testRoom", server: OpenGroupAPI.defaultServer))
                                    .updateAll(
                                        db,
                                        OpenGroup.Columns.imageData.set(to: Data([2, 3, 4]))
                                    )
                            })
                        }
                        
                        it("retrieves the cached image") {
                            var result: Data?
                            
                            OpenGroupManager
                                .roomImage(
                                    fileId: "1",
                                    for: "testRoom",
                                    on: OpenGroupAPI.defaultServer,
                                    existingData: Data([2, 3, 4]),
                                    using: dependencies
                                )
                                .handleEvents(receiveOutput: { (data: Data) in result = data })
                                .sinkAndStore(in: &disposables)
                            
                            expect(result).toEventually(equal(Data([2, 3, 4])), timeout: .milliseconds(50))
                        }
                        
                        it("fetches a new image if the cached on is older than a week") {
                            let weekInSeconds: TimeInterval = (7 * 24 * 60 * 60)
                            let targetTimestamp: TimeInterval = (
                                dependencies.date.timeIntervalSince1970 - weekInSeconds - 1
                            )
                            mockUserDefaults
                                .when { (defaults: inout any UserDefaultsType) -> Any? in
                                    defaults.object(forKey: any())
                                }
                                .thenReturn(Date(timeIntervalSince1970: targetTimestamp))
                            
                            var result: Data?
                            
                            OpenGroupManager
                                .roomImage(
                                    fileId: "1",
                                    for: "testRoom",
                                    on: OpenGroupAPI.defaultServer,
                                    existingData: Data([2, 3, 4]),
                                    using: dependencies
                                )
                                .handleEvents(receiveOutput: { (data: Data) in result = data })
                                .sinkAndStore(in: &disposables)
                            
                            expect(result).toEventually(equal(Data([1, 2, 3])), timeout: .milliseconds(50))
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Room Convenience Extensions

extension OpenGroupAPI.Room {
    func with(
        moderators: [String],
        hiddenModerators: [String],
        admins: [String],
        hiddenAdmins: [String]
    ) -> OpenGroupAPI.Room {
        return OpenGroupAPI.Room(
            token: self.token,
            name: self.name,
            roomDescription: self.roomDescription,
            infoUpdates: self.infoUpdates,
            messageSequence: self.messageSequence,
            created: self.created,
            activeUsers: self.activeUsers,
            activeUsersCutoff: self.activeUsersCutoff,
            imageId: self.imageId,
            pinnedMessages: self.pinnedMessages,
            admin: self.admin,
            globalAdmin: self.globalAdmin,
            admins: admins,
            hiddenAdmins: hiddenAdmins,
            moderator: self.moderator,
            globalModerator: self.globalModerator,
            moderators: moderators,
            hiddenModerators: hiddenModerators,
            read: self.read,
            defaultRead: self.defaultRead,
            defaultAccessible: self.defaultAccessible,
            write: self.write,
            defaultWrite: self.defaultWrite,
            upload: self.upload,
            defaultUpload: self.defaultUpload
        )
    }
}
