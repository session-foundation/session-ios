// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import Combine
import GRDB
import SessionSnodeKit
import SessionUtilitiesKit

import Quick
import Nimble

@testable import SessionMessagingKit

class OpenGroupManagerSpec: QuickSpec {
    override class func spec() {
        // MARK: Configuration
        
        @TestState var testInteraction1: Interaction! = Interaction(
            id: 234,
            serverHash: "TestServerHash",
            messageUuid: nil,
            threadId: OpenGroup.idFor(roomToken: "testRoom", server: "http://127.0.0.1"),
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
            openGroupWhisper: false,
            openGroupWhisperMods: false,
            openGroupWhisperTo: nil,
            state: .sending,
            recipientReadTimestampMs: nil,
            mostRecentFailureText: nil
        )
        @TestState var testGroupThread: SessionThread! = SessionThread(
            id: OpenGroup.idFor(roomToken: "testRoom", server: "http://127.0.0.1"),
            variant: .community,
            creationDateTimestamp: 0
        )
        @TestState var testOpenGroup: OpenGroup! = OpenGroup(
            server: "http://127.0.0.1",
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
        @TestState var testPollInfo: OpenGroupAPI.RoomPollInfo! = OpenGroupAPI.RoomPollInfo.mockValue.with(
            token: "testRoom",
            activeUsers: 10,
            details: .mockValue
        )
        @TestState var testMessage: OpenGroupAPI.Message! = OpenGroupAPI.Message(
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
        @TestState var testDirectMessage: OpenGroupAPI.DirectMessage! = OpenGroupAPI.DirectMessage(
            id: 128,
            sender: "15\(TestConstants.publicKey)",
            recipient: "15\(TestConstants.publicKey)",
            posted: 1234567890,
            expires: 1234567990,
            base64EncodedMessage: Data(
                [UInt8](arrayLiteral: 0) +
                "TestMessage".bytes +
                Data(base64Encoded: "pbTUizreT0sqJ2R2LloseQDyVL2RYztD")!.bytes
            ).base64EncodedString()
        )
        
        @TestState var mockNetwork: MockNetwork! = MockNetwork()
        @TestState var mockCrypto: MockCrypto! = MockCrypto(
            initialSetup: { crypto in
                crypto.when { $0.generate(.hash(message: anyArray(), length: any())) }.thenReturn([])
                crypto
                    .when { $0.generate(.blinded15KeyPair(serverPublicKey: any(), ed25519SecretKey: anyArray())) }
                    .thenReturn(
                        KeyPair(
                            publicKey: Data(hex: TestConstants.publicKey).bytes,
                            secretKey: Data(hex: TestConstants.edSecretKey).bytes
                        )
                    )
                crypto
                    .when { $0.generate(.blinded25KeyPair(serverPublicKey: any(), ed25519SecretKey: anyArray())) }
                    .thenReturn(
                        KeyPair(
                            publicKey: Data(hex: TestConstants.publicKey).bytes,
                            secretKey: Data(hex: TestConstants.edSecretKey).bytes
                        )
                    )
                crypto
                    .when { $0.generate(.signatureBlind15(message: anyArray(), serverPublicKey: any(), ed25519SecretKey: anyArray())) }
                    .thenReturn("TestSignature".bytes)
                crypto
                    .when { $0.generate(.signature(message: anyArray(), ed25519SecretKey: anyArray())) }
                    .thenReturn("TestSignature".bytes)
                crypto
                    .when { $0.generate(.randomBytes(16)) }
                    .thenReturn(Data(base64Encoded: "pK6YRtQApl4NhECGizF0Cg==")!.bytes)
                crypto
                    .when { $0.generate(.randomBytes(24)) }
                    .thenReturn(Data(base64Encoded: "pbTUizreT0sqJ2R2LloseQDyVL2RYztD")!.bytes)
            }
        )
        @TestState var mockUserDefaults: MockUserDefaults! = MockUserDefaults()
        @TestState var mockGeneralCache: MockGeneralCache! = MockGeneralCache(
            initialSetup: { cache in
                cache.when { $0.encodedPublicKey }.thenReturn("05\(TestConstants.publicKey)")
            }
        )
        @TestState var mockPoller: MockOGPoller! = MockOGPoller(
            initialSetup: { poller in
                poller.when { $0.stop() }.thenReturn(())
                poller.when { $0.startIfNeeded(using: any()) }.thenReturn(())
            }
        )
        @TestState var mockOGMCache: MockOGMCache! = MockOGMCache(
            initialSetup: { cache in
                cache.when { $0.pendingChanges }.thenReturn([])
                cache.when { $0.isPolling = any() }.thenReturn(())
                cache.when { $0.serversBeingPolled }.thenReturn([])
                cache.when { $0.hasPerformedInitialPoll }.thenReturn([:])
                cache.when { $0.timeSinceLastPoll }.thenReturn([:])
                cache.when { $0.getTimeSinceLastOpen(using: any()) }.thenReturn(0)
                cache
                    .when { $0.defaultRoomsPublisher = any(type: [OpenGroupManager.DefaultRoomInfo].self) }
                    .thenReturn(())
                cache
                    .when { $0.groupImagePublishers = any(typeA: String.self, typeB: AnyPublisher<Data, Error>.self) }
                    .thenReturn(())
                cache
                    .when { $0.pendingChanges = any(type: OpenGroupAPI.PendingChange.self) }
                    .thenReturn(())
                cache.when { $0.getOrCreatePoller(for: any()) }.thenReturn(mockPoller)
                cache.when { $0.stopAndRemovePoller(for: any()) }.thenReturn(())
                cache.when { $0.stopAndRemoveAllPollers() }.thenReturn(())
            }
        )
        @TestState var mockCaches: MockCaches! = MockCaches()
            .setting(cache: .general, to: mockGeneralCache)
            .setting(cache: .openGroupManager, to: mockOGMCache)
        @TestState var dependencies: Dependencies! = Dependencies(
            storage: nil,
            network: mockNetwork,
            crypto: mockCrypto,
            standardUserDefaults: mockUserDefaults,
            caches: mockCaches,
            dateNow: Date(timeIntervalSince1970: 1234567890),
            forceSynchronous: true
        )
        @TestState var mockStorage: Storage! = {
            let result = SynchronousStorage(
                customWriter: try! DatabaseQueue(),
                migrationTargets: [
                    SNUtilitiesKit.self,
                    SNMessagingKit.self
                ],
                initialData: { db in
                    try Identity(variant: .x25519PublicKey, data: Data(hex: TestConstants.publicKey)).insert(db)
                    try Identity(variant: .x25519PrivateKey, data: Data(hex: TestConstants.privateKey)).insert(db)
                    try Identity(variant: .ed25519PublicKey, data: Data(hex: TestConstants.edPublicKey)).insert(db)
                    try Identity(variant: .ed25519SecretKey, data: Data(hex: TestConstants.edSecretKey)).insert(db)
                    
                    try testGroupThread.insert(db)
                    try testOpenGroup.insert(db)
                    try Capability(openGroupServer: testOpenGroup.server, variant: .sogs, isMissing: false).insert(db)
                },
                using: dependencies
            )
            dependencies.storage = result
            
            return result
        }()
        @TestState var disposables: [AnyCancellable]! = []
        
        @TestState var cache: OpenGroupManager.Cache! = OpenGroupManager.Cache()
        @TestState var openGroupManager: OpenGroupManager! = OpenGroupManager()
        
        // MARK: - an OpenGroupManager
        describe("an OpenGroupManager") {
            beforeEach {
                LibSession.loadState(
                    userPublicKey: "05\(TestConstants.publicKey)",
                    ed25519SecretKey: Array(Data(hex: TestConstants.edSecretKey)),
                    using: dependencies
                )
            }
            
            // MARK: -- cache data
            context("cache data") {
                // MARK: ---- defaults the time since last open to greatestFiniteMagnitude
                it("defaults the time since last open to greatestFiniteMagnitude") {
                    mockUserDefaults
                        .when { (defaults: inout any UserDefaultsType) -> Any? in
                            defaults.object(forKey: SNUserDefaults.Date.lastOpen.rawValue)
                        }
                        .thenReturn(nil)
                    
                    expect(cache.getTimeSinceLastOpen(using: dependencies))
                        .to(beCloseTo(.greatestFiniteMagnitude))
                }
                
                // MARK: ---- returns the time since the last open
                it("returns the time since the last open") {
                    mockUserDefaults
                        .when { (defaults: inout any UserDefaultsType) -> Any? in
                            defaults.object(forKey: SNUserDefaults.Date.lastOpen.rawValue)
                        }
                        .thenReturn(Date(timeIntervalSince1970: 1234567880))
                    dependencies.dateNow = Date(timeIntervalSince1970: 1234567890)
                    
                    expect(cache.getTimeSinceLastOpen(using: dependencies))
                        .to(beCloseTo(10))
                }
                
                // MARK: ---- caches the time since the last open
                it("caches the time since the last open") {
                    mockUserDefaults
                        .when { (defaults: inout any UserDefaultsType) -> Any? in
                            defaults.object(forKey: SNUserDefaults.Date.lastOpen.rawValue)
                        }
                        .thenReturn(Date(timeIntervalSince1970: 1234567770))
                    dependencies.dateNow = Date(timeIntervalSince1970: 1234567780)
                    
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
            
            // MARK: -- when starting polling
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
                    
                    mockUserDefaults
                        .when { (defaults: inout any UserDefaultsType) -> Any? in
                            defaults.object(forKey: SNUserDefaults.Date.lastOpen.rawValue)
                        }
                        .thenReturn(Date(timeIntervalSince1970: 1234567890))
                }
                
                // MARK: ---- creates pollers for all of the open groups
                it("creates pollers for all of the open groups") {
                    openGroupManager.startPolling(using: dependencies)
                    
                    expect(mockOGMCache)
                        .to(call(matchingParameters: true) {
                            $0.getOrCreatePoller(for: "http://127.0.0.1")
                        })
                    expect(mockOGMCache)
                        .to(call(matchingParameters: true) {
                            $0.getOrCreatePoller(for: "testserver1")
                        })
                }
                
                // MARK: ---- updates the isPolling flag
                it("updates the isPolling flag") {
                    openGroupManager.startPolling(using: dependencies)
                    
                    expect(mockOGMCache)
                        .to(call(matchingParameters: true) { $0.isPolling = true })
                }
                
                // MARK: ---- does nothing if already polling
                it("does nothing if already polling") {
                    mockOGMCache.when { $0.isPolling }.thenReturn(true)
                    
                    openGroupManager.startPolling(using: dependencies)
                    
                    expect(mockOGMCache).toNot(call { $0.getOrCreatePoller(for: any()) })
                }
            }
            
            // MARK: -- when stopping polling
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
                }
                
                // MARK: ---- removes all pollers
                it("removes all pollers") {
                    openGroupManager.stopPolling(using: dependencies)
                    
                    expect(mockOGMCache).to(call(matchingParameters: true) { $0.stopAndRemoveAllPollers() })
                }
                
                // MARK: ---- updates the isPolling flag
                it("updates the isPolling flag") {
                    openGroupManager.stopPolling(using: dependencies)
                    
                    expect(mockOGMCache).to(call(matchingParameters: true) { $0.isPolling = false })
                }
            }
            
            // MARK: -- when checking if an open group is run by session
            context("when checking if an open group is run by session") {
                // MARK: ---- returns false when it does not match one of Sessions servers with no scheme
                it("returns false when it does not match one of Sessions servers with no scheme") {
                    expect(OpenGroupManager.isSessionRunOpenGroup(server: "test.test"))
                        .to(beFalse())
                }
                
                // MARK: ---- returns false when it does not match one of Sessions servers in http
                it("returns false when it does not match one of Sessions servers in http") {
                    expect(OpenGroupManager.isSessionRunOpenGroup(server: "http://test.test"))
                        .to(beFalse())
                }
                
                // MARK: ---- returns false when it does not match one of Sessions servers in https
                it("returns false when it does not match one of Sessions servers in https") {
                    expect(OpenGroupManager.isSessionRunOpenGroup(server: "https://test.test"))
                        .to(beFalse())
                }
                
                // MARK: ---- returns true when it matches Sessions SOGS IP
                it("returns true when it matches Sessions SOGS IP") {
                    expect(OpenGroupManager.isSessionRunOpenGroup(server: "116.203.70.33"))
                        .to(beTrue())
                }
                
                // MARK: ---- returns true when it matches Sessions SOGS IP with http
                it("returns true when it matches Sessions SOGS IP with http") {
                    expect(OpenGroupManager.isSessionRunOpenGroup(server: "http://116.203.70.33"))
                        .to(beTrue())
                }
                
                // MARK: ---- returns true when it matches Sessions SOGS IP with https
                it("returns true when it matches Sessions SOGS IP with https") {
                    expect(OpenGroupManager.isSessionRunOpenGroup(server: "https://116.203.70.33"))
                        .to(beTrue())
                }
                
                // MARK: ---- returns true when it matches Sessions SOGS IP with a port
                it("returns true when it matches Sessions SOGS IP with a port") {
                    expect(OpenGroupManager.isSessionRunOpenGroup(server: "116.203.70.33:80"))
                        .to(beTrue())
                }
                
                // MARK: ---- returns true when it matches Sessions SOGS domain
                it("returns true when it matches Sessions SOGS domain") {
                    expect(OpenGroupManager.isSessionRunOpenGroup(server: "open.getsession.org"))
                        .to(beTrue())
                }
                
                // MARK: ---- returns true when it matches Sessions SOGS domain with http
                it("returns true when it matches Sessions SOGS domain with http") {
                    expect(OpenGroupManager.isSessionRunOpenGroup(server: "http://open.getsession.org"))
                        .to(beTrue())
                }
                
                // MARK: ---- returns true when it matches Sessions SOGS domain with https
                it("returns true when it matches Sessions SOGS domain with https") {
                    expect(OpenGroupManager.isSessionRunOpenGroup(server: "https://open.getsession.org"))
                        .to(beTrue())
                }
                
                // MARK: ---- returns true when it matches Sessions SOGS domain with a port
                it("returns true when it matches Sessions SOGS domain with a port") {
                    expect(OpenGroupManager.isSessionRunOpenGroup(server: "open.getsession.org:80"))
                        .to(beTrue())
                }
            }
            
            // MARK: -- when checking it has an existing open group
            context("when checking it has an existing open group") {
                // MARK: ---- when there is a thread for the room and the cache has a poller
                context("when there is a thread for the room and the cache has a poller") {
                    beforeEach {
                        mockOGMCache.when { $0.serversBeingPolled }.thenReturn(["http://127.0.0.1"])
                    }
                    
                    // MARK: ------ for the no-scheme variant
                    context("for the no-scheme variant") {
                        // MARK: -------- returns true when no scheme is provided
                        it("returns true when no scheme is provided") {
                            expect(
                                mockStorage.read { db -> Bool in
                                    openGroupManager
                                        .hasExistingOpenGroup(
                                            db,
                                            roomToken: "testRoom",
                                            server: "http://127.0.0.1",
                                            publicKey: TestConstants.serverPublicKey,
                                            using: dependencies
                                        )
                                }
                            ).to(beTrue())
                        }
                        
                        // MARK: -------- returns true when a http scheme is provided
                        it("returns true when a http scheme is provided") {
                            expect(
                                mockStorage.read { db -> Bool in
                                    openGroupManager
                                        .hasExistingOpenGroup(
                                            db,
                                            roomToken: "testRoom",
                                            server: "http://127.0.0.1",
                                            publicKey: TestConstants.serverPublicKey,
                                            using: dependencies
                                        )
                                }
                            ).to(beTrue())
                        }
                        
                        // MARK: -------- returns true when a https scheme is provided
                        it("returns true when a https scheme is provided") {
                            expect(
                                mockStorage.read { db -> Bool in
                                    openGroupManager
                                        .hasExistingOpenGroup(
                                            db,
                                            roomToken: "testRoom",
                                            server: "http://127.0.0.1",
                                            publicKey: TestConstants.serverPublicKey,
                                            using: dependencies
                                        )
                                }
                            ).to(beTrue())
                        }
                    }
                    
                    // MARK: ------ for the http variant
                    context("for the http variant") {
                        // MARK: -------- returns true when no scheme is provided
                        it("returns true when no scheme is provided") {
                            expect(
                                mockStorage.read { db -> Bool in
                                    openGroupManager
                                        .hasExistingOpenGroup(
                                            db,
                                            roomToken: "testRoom",
                                            server: "http://127.0.0.1",
                                            publicKey: TestConstants.serverPublicKey,
                                            using: dependencies
                                        )
                                }
                            ).to(beTrue())
                        }
                        
                        // MARK: -------- returns true when a http scheme is provided
                        it("returns true when a http scheme is provided") {
                            expect(
                                mockStorage.read { db -> Bool in
                                    openGroupManager
                                        .hasExistingOpenGroup(
                                            db,
                                            roomToken: "testRoom",
                                            server: "http://127.0.0.1",
                                            publicKey: TestConstants.serverPublicKey,
                                            using: dependencies
                                        )
                                }
                            ).to(beTrue())
                        }
                        
                        // MARK: -------- returns true when a https scheme is provided
                        it("returns true when a https scheme is provided") {
                            expect(
                                mockStorage.read { db -> Bool in
                                    openGroupManager
                                        .hasExistingOpenGroup(
                                            db,
                                            roomToken: "testRoom",
                                            server: "http://127.0.0.1",
                                            publicKey: TestConstants.serverPublicKey,
                                            using: dependencies
                                        )
                                }
                            ).to(beTrue())
                        }
                    }
                    
                    // MARK: ------ for the https variant
                    context("for the https variant") {
                        // MARK: -------- returns true when no scheme is provided
                        it("returns true when no scheme is provided") {
                            expect(
                                mockStorage.read { db -> Bool in
                                    openGroupManager
                                        .hasExistingOpenGroup(
                                            db,
                                            roomToken: "testRoom",
                                            server: "http://127.0.0.1",
                                            publicKey: TestConstants.serverPublicKey,
                                            using: dependencies
                                        )
                                }
                            ).to(beTrue())
                        }
                        
                        // MARK: -------- returns true when a http scheme is provided
                        it("returns true when a http scheme is provided") {
                            expect(
                                mockStorage.read { db -> Bool in
                                    openGroupManager
                                        .hasExistingOpenGroup(
                                            db,
                                            roomToken: "testRoom",
                                            server: "http://127.0.0.1",
                                            publicKey: TestConstants.serverPublicKey,
                                            using: dependencies
                                        )
                                }
                            ).to(beTrue())
                        }
                        
                        // MARK: -------- returns true when a https scheme is provided
                        it("returns true when a https scheme is provided") {
                            expect(
                                mockStorage.read { db -> Bool in
                                    openGroupManager
                                        .hasExistingOpenGroup(
                                            db,
                                            roomToken: "testRoom",
                                            server: "http://127.0.0.1",
                                            publicKey: TestConstants.serverPublicKey,
                                            using: dependencies
                                        )
                                }
                            ).to(beTrue())
                        }
                    }
                }
                
                // MARK: ---- when given the legacy DNS host and there is a cached poller for the default server
                context("when given the legacy DNS host and there is a cached poller for the default server") {
                    // MARK: ------ returns true
                    it("returns true") {
                        mockOGMCache.when { $0.serversBeingPolled }.thenReturn(["http://116.203.70.33"])
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
                                        using: dependencies
                                    )
                            }
                        ).to(beTrue())
                    }
                }
                
                // MARK: ---- when given the default server and there is a cached poller for the legacy DNS host
                context("when given the default server and there is a cached poller for the legacy DNS host") {
                    // MARK: ------ returns true
                    it("returns true") {
                        mockOGMCache.when { $0.serversBeingPolled }.thenReturn(["http://open.getsession.org"])
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
                                        using: dependencies
                                    )
                            }
                        ).to(beTrue())
                    }
                }
                
                // MARK: ---- returns false when given an invalid server
                it("returns false when given an invalid server") {
                    expect(
                        mockStorage.read { db -> Bool in
                            openGroupManager
                                .hasExistingOpenGroup(
                                    db,
                                    roomToken: "testRoom",
                                    server: "%%%",
                                    publicKey: TestConstants.serverPublicKey,
                                    using: dependencies
                                )
                        }
                    ).to(beFalse())
                }
                
                // MARK: ---- returns false if there is not a poller for the server in the cache
                it("returns false if there is not a poller for the server in the cache") {
                    mockOGMCache.when { $0.serversBeingPolled }.thenReturn([])
                    
                    expect(
                        mockStorage.read { db -> Bool in
                            openGroupManager
                                .hasExistingOpenGroup(
                                    db,
                                    roomToken: "testRoom",
                                    server: "http://127.0.0.1",
                                    publicKey: TestConstants.serverPublicKey,
                                    using: dependencies
                                )
                        }
                    ).to(beFalse())
                }
                
                // MARK: ---- returns false if there is a poller for the server in the cache but no thread for the room
                it("returns false if there is a poller for the server in the cache but no thread for the room") {
                    mockStorage.write { db in
                        try SessionThread.deleteAll(db)
                    }
                    
                    expect(
                        mockStorage.read { db -> Bool in
                            openGroupManager
                                .hasExistingOpenGroup(
                                    db,
                                    roomToken: "testRoom",
                                    server: "http://127.0.0.1",
                                    publicKey: TestConstants.serverPublicKey,
                                    using: dependencies
                                )
                        }
                    ).to(beFalse())
                }
            }
        }
        
        // MARK: - an OpenGroupManager
        describe("an OpenGroupManager") {
            beforeEach {
                LibSession.loadState(
                    userPublicKey: "05\(TestConstants.publicKey)",
                    ed25519SecretKey: Array(Data(hex: TestConstants.edSecretKey)),
                    using: dependencies
                )
            }
            
            // MARK: -- when adding
            context("when adding") {
                beforeEach {
                    mockStorage.write { db in
                        try OpenGroup.deleteAll(db)
                    }
                    
                    mockNetwork
                        .when { $0.send(.onionRequest(any(), to: any(), with: any()), using: dependencies) }
                        .thenReturn(Network.BatchResponse.mockCapabilitiesAndRoomResponse)
                    
                    mockUserDefaults
                        .when { (defaults: inout any UserDefaultsType) -> Any? in
                            defaults.object(forKey: SNUserDefaults.Date.lastOpen.rawValue)
                        }
                        .thenReturn(Date(timeIntervalSince1970: 1234567890))
                }
                
                // MARK: ---- stores the open group server
                it("stores the open group server") {
                    mockStorage
                        .writePublisher { (db: Database) -> Bool in
                            openGroupManager.add(
                                db,
                                roomToken: "testRoom",
                                server: "http://127.0.0.1",
                                publicKey: TestConstants.serverPublicKey,
                                forceVisible: false,
                                using: dependencies
                            )
                        }
                        .flatMap { successfullyAddedGroup in
                            openGroupManager.performInitialRequestsAfterAdd(
                                successfullyAddedGroup: successfullyAddedGroup,
                                roomToken: "testRoom",
                                server: "http://127.0.0.1",
                                publicKey: TestConstants.serverPublicKey,
                                using: dependencies
                            )
                        }
                        .sinkAndStore(in: &disposables)
                    
                    expect(
                        mockStorage
                            .read { (db: Database) in
                                try OpenGroup
                                    .select(.threadId)
                                    .asRequest(of: String.self)
                                    .fetchOne(db)
                            }
                    )
                    .to(equal(OpenGroup.idFor(roomToken: "testRoom", server: "http://127.0.0.1")))
                }
                
                // MARK: ---- adds a poller
                it("adds a poller") {
                    mockStorage
                        .writePublisher { (db: Database) -> Bool in
                            openGroupManager.add(
                                db,
                                roomToken: "testRoom",
                                server: "http://127.0.0.1",
                                publicKey: TestConstants.serverPublicKey,
                                forceVisible: false,
                                using: dependencies
                            )
                        }
                        .flatMap { successfullyAddedGroup in
                            openGroupManager.performInitialRequestsAfterAdd(
                                successfullyAddedGroup: successfullyAddedGroup,
                                roomToken: "testRoom",
                                server: "http://127.0.0.1",
                                publicKey: TestConstants.serverPublicKey,
                                using: dependencies
                            )
                        }
                        .sinkAndStore(in: &disposables)
                    
                    expect(mockOGMCache)
                        .to(call(matchingParameters: true) {
                            $0.getOrCreatePoller(for: "http://127.0.0.1")
                        })
                    expect(mockPoller)
                        .to(call(matchingParameters: true) { [dependencies = dependencies!] in
                            $0.startIfNeeded(using: dependencies)
                        })
                }
                
                // MARK: ---- an existing room
                context("an existing room") {
                    beforeEach {
                        mockOGMCache.when { $0.serversBeingPolled }.thenReturn(["http://127.0.0.1"])
                        mockStorage.write { db in
                            try testOpenGroup.insert(db)
                        }
                    }
                    
                    // MARK: ------ does not reset the sequence number or update the public key
                    it("does not reset the sequence number or update the public key") {
                        mockStorage
                            .writePublisher { (db: Database) -> Bool in
                                openGroupManager.add(
                                    db,
                                    roomToken: "testRoom",
                                    server: "http://127.0.0.1",
                                    publicKey: TestConstants.serverPublicKey
                                        .replacingOccurrences(of: "c3", with: "00")
                                        .replacingOccurrences(of: "b3", with: "00"),
                                    forceVisible: false,
                                    using: dependencies
                                )
                            }
                            .flatMap { successfullyAddedGroup in
                                openGroupManager.performInitialRequestsAfterAdd(
                                    successfullyAddedGroup: successfullyAddedGroup,
                                    roomToken: "testRoom",
                                    server: "http://127.0.0.1",
                                    publicKey: TestConstants.serverPublicKey
                                        .replacingOccurrences(of: "c3", with: "00")
                                        .replacingOccurrences(of: "b3", with: "00"),
                                    using: dependencies
                                )
                            }
                            .sinkAndStore(in: &disposables)
                        
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
                
                // MARK: ---- with an invalid response
                context("with an invalid response") {
                    beforeEach {
                        mockNetwork
                            .when { $0.send(.onionRequest(any(), to: any(), with: any()), using: dependencies) }
                            .thenReturn(MockNetwork.response(data: Data()))
                        
                        mockUserDefaults
                            .when { (defaults: inout any UserDefaultsType) -> Any? in
                                defaults.object(forKey: SNUserDefaults.Date.lastOpen.rawValue)
                            }
                            .thenReturn(Date(timeIntervalSince1970: 1234567890))
                    }
                
                    // MARK: ------ fails with the error
                    it("fails with the error") {
                        var error: Error?
                        
                        mockStorage
                            .writePublisher { (db: Database) -> Bool in
                                openGroupManager.add(
                                    db,
                                    roomToken: "testRoom",
                                    server: "http://127.0.0.1",
                                    publicKey: TestConstants.serverPublicKey,
                                    forceVisible: false,
                                    using: dependencies
                                )
                            }
                            .flatMap { successfullyAddedGroup in
                                openGroupManager.performInitialRequestsAfterAdd(
                                    successfullyAddedGroup: successfullyAddedGroup,
                                    roomToken: "testRoom",
                                    server: "http://127.0.0.1",
                                    publicKey: TestConstants.serverPublicKey,
                                    using: dependencies
                                )
                            }
                            .mapError { result -> Error in error.setting(to: result) }
                            .sinkAndStore(in: &disposables)
                        
                        expect(error).to(matchError(NetworkError.parsingFailed))
                    }
                }
            }
            
            // MARK: -- when deleting
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
                                    .set(to: OpenGroup.idFor(roomToken: "testRoom", server: "http://127.0.0.1"))
                            )
                    }
                }
                
                // MARK: ---- removes all interactions for the thread
                it("removes all interactions for the thread") {
                    mockStorage.write { db in
                        openGroupManager.delete(
                            db,
                            openGroupId: OpenGroup.idFor(roomToken: "testRoom", server: "http://127.0.0.1"),
                            skipLibSessionUpdate: true, // Don't trigger LibSession logic
                            using: dependencies
                        )
                    }
                    
                    expect(mockStorage.read { db in try Interaction.fetchCount(db) })
                        .to(equal(0))
                }
                
                // MARK: ---- removes the given thread
                it("removes the given thread") {
                    mockStorage.write { db in
                        openGroupManager.delete(
                            db,
                            openGroupId: OpenGroup.idFor(roomToken: "testRoom", server: "http://127.0.0.1"),
                            skipLibSessionUpdate: true, // Don't trigger LibSession logic
                            using: dependencies
                        )
                    }
                    
                    expect(mockStorage.read { db -> Int in try SessionThread.fetchCount(db) })
                        .to(equal(0))
                }
                
                // MARK: ---- and there is only one open group for this server
                context("and there is only one open group for this server") {
                    // MARK: ------ stops the poller
                    it("stops the poller") {
                        mockStorage.write { db in
                            openGroupManager.delete(
                                db,
                                openGroupId: OpenGroup.idFor(roomToken: "testRoom", server: "http://127.0.0.1"),
                                skipLibSessionUpdate: true, // Don't trigger LibSession logic
                                using: dependencies
                            )
                        }
                        
                        expect(mockOGMCache).to(call(matchingParameters: true) { $0.stopAndRemovePoller(for: "http://127.0.0.1") })
                    }
                    
                    // MARK: ------ removes the open group
                    it("removes the open group") {
                        mockStorage.write { db in
                            openGroupManager.delete(
                                db,
                                openGroupId: OpenGroup.idFor(roomToken: "testRoom", server: "http://127.0.0.1"),
                                skipLibSessionUpdate: true, // Don't trigger LibSession logic
                                using: dependencies
                            )
                        }
                        
                        expect(mockStorage.read { db in try OpenGroup.fetchCount(db) })
                            .to(equal(0))
                    }
                }
                
                // MARK: ---- and the are multiple open groups for this server
                context("and the are multiple open groups for this server") {
                    beforeEach {
                        mockStorage.write { db in
                            try OpenGroup.deleteAll(db)
                            try testOpenGroup.insert(db)
                            try OpenGroup(
                                server: "http://127.0.0.1",
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
                    
                    // MARK: ------ removes the open group
                    it("removes the open group") {
                        mockStorage.write { db in
                            openGroupManager.delete(
                                db,
                                openGroupId: OpenGroup.idFor(roomToken: "testRoom", server: "http://127.0.0.1"),
                                skipLibSessionUpdate: true, // Don't trigger LibSession logic
                                using: dependencies
                            )
                        }
                        
                        expect(mockStorage.read { db in try OpenGroup.fetchCount(db) })
                            .to(equal(1))
                    }
                }
                
                // MARK: ---- and it is the default server
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
                    
                    // MARK: ------ does not remove the open group
                    it("does not remove the open group") {
                        mockStorage.write { db in
                            openGroupManager.delete(
                                db,
                                openGroupId: OpenGroup.idFor(roomToken: "testRoom", server: OpenGroupAPI.defaultServer),
                                skipLibSessionUpdate: true, // Don't trigger LibSession logic
                                using: dependencies
                            )
                        }
                        
                        expect(mockStorage.read { db in try OpenGroup.fetchCount(db) })
                            .to(equal(2))
                    }
                    
                    // MARK: ------ deactivates the open group
                    it("deactivates the open group") {
                        mockStorage.write { db in
                            openGroupManager.delete(
                                db,
                                openGroupId: OpenGroup.idFor(roomToken: "testRoom", server: OpenGroupAPI.defaultServer),
                                skipLibSessionUpdate: true, // Don't trigger LibSession logic
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
            
            // MARK: -- when handling capabilities
            context("when handling capabilities") {
                beforeEach {
                    mockStorage.write { db in
                        OpenGroupManager
                            .handleCapabilities(
                                db,
                                capabilities: OpenGroupAPI.Capabilities(capabilities: [.sogs], missing: []),
                                on: "http://127.0.0.1"
                            )
                    }
                }
                
                // MARK: ---- stores the capabilities
                it("stores the capabilities") {
                    expect(mockStorage.read { db in try Capability.fetchCount(db) })
                        .to(equal(1))
                }
            }
        }
        
        // MARK: - an OpenGroupManager
        describe("an OpenGroupManager") {
            beforeEach {
                LibSession.loadState(
                    userPublicKey: "05\(TestConstants.publicKey)",
                    ed25519SecretKey: Array(Data(hex: TestConstants.edSecretKey)),
                    using: dependencies
                )
            }
            
            // MARK: -- when handling room poll info
            context("when handling room poll info") {
                beforeEach {
                    mockStorage.write { db in
                        try OpenGroup.deleteAll(db)
                        
                        try testOpenGroup.insert(db)
                    }
                    
                    mockOGMCache.when { $0.hasPerformedInitialPoll }.thenReturn([:])
                    mockOGMCache.when { $0.timeSinceLastPoll }.thenReturn([:])
                    mockOGMCache
                        .when { [dependencies = dependencies!] cache in
                            cache.getTimeSinceLastOpen(using: dependencies)
                        }
                        .thenReturn(0)
                    mockOGMCache.when { $0.isPolling }.thenReturn(false)
                    
                    mockUserDefaults
                        .when { (defaults: inout any UserDefaultsType) -> Any? in
                            defaults.object(forKey: SNUserDefaults.Date.lastOpen.rawValue)
                        }
                        .thenReturn(nil)
                }
                
                // MARK: ---- saves the updated open group
                it("saves the updated open group") {
                    mockStorage.write { db in
                        try OpenGroupManager.handlePollInfo(
                            db,
                            pollInfo: testPollInfo,
                            publicKey: TestConstants.publicKey,
                            for: "testRoom",
                            on: "http://127.0.0.1",
                            using: dependencies
                        )// { didComplete = true }
                    }
                    
                    expect(
                        mockStorage.read { db in
                            try OpenGroup
                                .select(.userCount)
                                .asRequest(of: Int64.self)
                                .fetchOne(db)
                        }
                    ).to(equal(10))
                }
                
                // MARK: ---- calls the completion block
                it("calls the completion block") {
                    var didCallComplete: Bool = false
                    
                    mockStorage.write { db in
                        try OpenGroupManager.handlePollInfo(
                            db,
                            pollInfo: testPollInfo,
                            publicKey: TestConstants.publicKey,
                            for: "testRoom",
                            on: "http://127.0.0.1",
                            using: dependencies
                        ) { didCallComplete = true }
                    }
                    
                    expect(didCallComplete).to(beTrue())
                }
                
                // MARK: ---- calls the room image completion block when waiting but there is no image
                it("calls the room image completion block when waiting but there is no image") {
                    var didCallComplete: Bool = false
                    
                    mockStorage.write { db in
                        try OpenGroupManager.handlePollInfo(
                            db,
                            pollInfo: testPollInfo,
                            publicKey: TestConstants.publicKey,
                            for: "testRoom",
                            on: "http://127.0.0.1",
                            waitForImageToComplete: true,
                            using: dependencies
                        ) { didCallComplete = true }
                    }
                    
                    expect(didCallComplete).to(beTrue())
                }
                
                // MARK: ---- calls the room image completion block when waiting and there is an image
                it("calls the room image completion block when waiting and there is an image") {
                    var didCallComplete: Bool = false
                    
                    mockStorage.write { db in
                        try OpenGroup.deleteAll(db)
                        try OpenGroup(
                            server: "http://127.0.0.1",
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
                            OpenGroup.idFor(roomToken: "testRoom", server: "http://127.0.0.1"): Just(Data()).setFailureType(to: Error.self).eraseToAnyPublisher()
                        ])
                    
                    mockStorage.write { db in
                        try OpenGroupManager.handlePollInfo(
                            db,
                            pollInfo: testPollInfo,
                            publicKey: TestConstants.publicKey,
                            for: "testRoom",
                            on: "http://127.0.0.1",
                            waitForImageToComplete: true,
                            using: dependencies
                        ) { didCallComplete = true }
                    }
                    
                    expect(didCallComplete).to(beTrue())
                }
                
                // MARK: ---- and updating the moderator list
                context("and updating the moderator list") {
                    // MARK: ------ successfully updates
                    it("successfully updates") {
                        testPollInfo = OpenGroupAPI.RoomPollInfo.mockValue.with(
                            token: "testRoom",
                            activeUsers: 10,
                            details: OpenGroupAPI.Room.mockValue.with(
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
                                on: "http://127.0.0.1",
                                using: dependencies
                            )
                        }
                        
                        expect(
                            mockStorage.read { db -> GroupMember? in
                                try GroupMember
                                    .filter(GroupMember.Columns.groupId == OpenGroup.idFor(
                                        roomToken: "testRoom",
                                        server: "http://127.0.0.1"
                                    ))
                                    .fetchOne(db)
                            }
                        ).to(equal(
                            GroupMember(
                                groupId: OpenGroup.idFor(
                                    roomToken: "testRoom",
                                    server: "http://127.0.0.1"
                                ),
                                profileId: "TestMod",
                                role: .moderator,
                                isHidden: false
                            )
                        ))
                    }
                    
                    // MARK: ------ updates for hidden moderators
                    it("updates for hidden moderators") {
                        testPollInfo = OpenGroupAPI.RoomPollInfo.mockValue.with(
                            token: "testRoom",
                            activeUsers: 10,
                            details: OpenGroupAPI.Room.mockValue.with(
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
                                on: "http://127.0.0.1",
                                using: dependencies
                            )
                        }
                        
                        expect(
                            mockStorage.read { db -> GroupMember? in
                                try GroupMember
                                    .filter(GroupMember.Columns.groupId == OpenGroup.idFor(
                                        roomToken: "testRoom",
                                        server: "http://127.0.0.1"
                                    ))
                                    .fetchOne(db)
                            }
                        ).to(equal(
                            GroupMember(
                                groupId: OpenGroup.idFor(
                                    roomToken: "testRoom",
                                    server: "http://127.0.0.1"
                                ),
                                profileId: "TestMod2",
                                role: .moderator,
                                isHidden: true
                            )
                        ))
                    }
                    
                    // MARK: ------ does not insert mods if no moderators are provided
                    it("does not insert mods if no moderators are provided") {
                        testPollInfo = OpenGroupAPI.RoomPollInfo.mockValue.with(
                            token: "testRoom",
                            activeUsers: 10
                        )
                        
                        mockStorage.write { db in
                            try OpenGroupManager.handlePollInfo(
                                db,
                                pollInfo: testPollInfo,
                                publicKey: TestConstants.publicKey,
                                for: "testRoom",
                                on: "http://127.0.0.1",
                                using: dependencies
                            )
                        }
                        
                        expect(mockStorage.read { db -> Int in try GroupMember.fetchCount(db) })
                            .to(equal(0))
                    }
                }
                
                // MARK: ---- and updating the admin list
                context("and updating the admin list") {
                    // MARK: ------ successfully updates
                    it("successfully updates") {
                        testPollInfo = OpenGroupAPI.RoomPollInfo.mockValue.with(
                            token: "testRoom",
                            activeUsers: 10,
                            details: OpenGroupAPI.Room.mockValue.with(
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
                                on: "http://127.0.0.1",
                                using: dependencies
                            )
                        }
                        
                        expect(
                            mockStorage.read { db -> GroupMember? in
                                try GroupMember
                                    .filter(GroupMember.Columns.groupId == OpenGroup.idFor(
                                        roomToken: "testRoom",
                                        server: "http://127.0.0.1"
                                    ))
                                    .fetchOne(db)
                            }
                        ).to(equal(
                            GroupMember(
                                groupId: OpenGroup.idFor(
                                    roomToken: "testRoom",
                                    server: "http://127.0.0.1"
                                ),
                                profileId: "TestAdmin",
                                role: .admin,
                                isHidden: false
                            )
                        ))
                    }
                    
                    // MARK: ------ updates for hidden admins
                    it("updates for hidden admins") {
                        testPollInfo = OpenGroupAPI.RoomPollInfo.mockValue.with(
                            token: "testRoom",
                            activeUsers: 10,
                            details: OpenGroupAPI.Room.mockValue.with(
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
                                on: "http://127.0.0.1",
                                using: dependencies
                            )
                        }
                        
                        expect(
                            mockStorage.read { db -> GroupMember? in
                                try GroupMember
                                    .filter(GroupMember.Columns.groupId == OpenGroup.idFor(
                                        roomToken: "testRoom",
                                        server: "http://127.0.0.1"
                                    ))
                                    .fetchOne(db)
                            }
                        ).to(equal(
                            GroupMember(
                                groupId: OpenGroup.idFor(
                                    roomToken: "testRoom",
                                    server: "http://127.0.0.1"
                                ),
                                profileId: "TestAdmin2",
                                role: .admin,
                                isHidden: true
                            )
                        ))
                    }
                    
                    // MARK: ------ does not insert an admin if no admins are provided
                    it("does not insert an admin if no admins are provided") {
                        testPollInfo = OpenGroupAPI.RoomPollInfo.mockValue.with(
                            token: "testRoom",
                            activeUsers: 10,
                            details: nil
                        )
                        
                        mockStorage.write { db in
                            try OpenGroupManager.handlePollInfo(
                                db,
                                pollInfo: testPollInfo,
                                publicKey: TestConstants.publicKey,
                                for: "testRoom",
                                on: "http://127.0.0.1",
                                using: dependencies
                            )
                        }
                        
                        expect(mockStorage.read { db -> Int in try GroupMember.fetchCount(db) })
                            .to(equal(0))
                    }
                }
                
                // MARK: ---- when it cannot get the open group
                context("when it cannot get the open group") {
                    // MARK: ------ does not save the thread
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
                                on: "http://127.0.0.1",
                                using: dependencies
                            )
                        }
                        
                        expect(mockStorage.read { db -> Int in try OpenGroup.fetchCount(db) }).to(equal(0))
                    }
                }
                
                // MARK: ---- when not given a public key
                context("when not given a public key") {
                    // MARK: ------ saves the open group with the existing public key
                    it("saves the open group with the existing public key") {
                        mockStorage.write { db in
                            try OpenGroupManager.handlePollInfo(
                                db,
                                pollInfo: testPollInfo,
                                publicKey: nil,
                                for: "testRoom",
                                on: "http://127.0.0.1",
                                using: dependencies
                            )
                        }
                        
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
                
                // MARK: ---- when trying to get the room image
                context("when trying to get the room image") {
                    beforeEach {
                        let image = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1))
                            .image { context in
                                UIColor.red.setFill()
                                context.fill(CGRect(origin: .zero, size: CGSize(width: 1, height: 1)))
                            }
                        let imageData: Data = image.pngData()!
                        
                        mockStorage.write { db in
                            try OpenGroup
                                .updateAll(db, OpenGroup.Columns.imageData.set(to: nil))
                        }
                        
                        mockOGMCache.when { $0.groupImagePublishers }
                            .thenReturn([
                                OpenGroup.idFor(roomToken: "testRoom", server: "http://127.0.0.1"): Just(imageData).setFailureType(to: Error.self).eraseToAnyPublisher()
                            ])
                    }
                    
                    // MARK: ------ uses the provided room image id if available
                    it("uses the provided room image id if available") {
                        testPollInfo = OpenGroupAPI.RoomPollInfo.mockValue.with(
                            token: "testRoom",
                            activeUsers: 10,
                            details: OpenGroupAPI.Room.mockValue.with(
                                token: "test",
                                name: "test",
                                imageId: "10"
                            )
                        )
                        
                        mockStorage.write { db in
                            try OpenGroupManager.handlePollInfo(
                                db,
                                pollInfo: testPollInfo,
                                publicKey: TestConstants.publicKey,
                                for: "testRoom",
                                on: "http://127.0.0.1",
                                waitForImageToComplete: true,
                                using: dependencies
                            )
                        }
                        
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
                    
                    // MARK: ------ uses the existing room image id if none is provided
                    it("uses the existing room image id if none is provided") {
                        mockStorage.write { db in
                            try OpenGroup.deleteAll(db)
                            try OpenGroup(
                                server: "http://127.0.0.1",
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
                        
                        testPollInfo = OpenGroupAPI.RoomPollInfo.mockValue.with(
                            token: "testRoom",
                            activeUsers: 10,
                            details: nil
                        )
                        
                        mockStorage.write { db in
                            try OpenGroupManager.handlePollInfo(
                                db,
                                pollInfo: testPollInfo,
                                publicKey: TestConstants.publicKey,
                                for: "testRoom",
                                on: "http://127.0.0.1",
                                waitForImageToComplete: true,
                                using: dependencies
                            )
                        }
                        
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
                    
                    // MARK: ------ uses the new room image id if there is an existing one
                    it("uses the new room image id if there is an existing one") {
                        mockStorage.write { db in
                            try OpenGroup.deleteAll(db)
                            try OpenGroup(
                                server: "http://127.0.0.1",
                                roomToken: "testRoom",
                                publicKey: TestConstants.publicKey,
                                isActive: true,
                                name: "Test",
                                imageId: "12",
                                imageData: {
                                    UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1))
                                        .image { context in
                                            UIColor.blue.setFill()
                                            context.fill(CGRect(origin: .zero, size: CGSize(width: 1, height: 1)))
                                        }
                                        .pngData()
                                }(),
                                userCount: 0,
                                infoUpdates: 10
                            ).insert(db)
                        }
                        
                        testPollInfo = OpenGroupAPI.RoomPollInfo.mockValue.with(
                            token: "testRoom",
                            activeUsers: 10,
                            details: OpenGroupAPI.Room.mockValue.with(
                                token: "test",
                                name: "test",
                                infoUpdates: 10,
                                imageId: "10"
                            )
                        )
                        
                        mockStorage.write { db in
                            try OpenGroupManager.handlePollInfo(
                                db,
                                pollInfo: testPollInfo,
                                publicKey: TestConstants.publicKey,
                                for: "testRoom",
                                on: "http://127.0.0.1",
                                waitForImageToComplete: true,
                                using: dependencies
                            )
                        }
                        
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
                        expect(mockOGMCache).to(call(.exactly(times: 1)) { $0.groupImagePublishers })
                    }
                    
                    // MARK: ------ does nothing if there is no room image
                    it("does nothing if there is no room image") {
                        mockStorage.write { db in
                            try OpenGroupManager.handlePollInfo(
                                db,
                                pollInfo: testPollInfo,
                                publicKey: TestConstants.publicKey,
                                for: "testRoom",
                                on: "http://127.0.0.1",
                                waitForImageToComplete: true,
                                using: dependencies
                            )
                        }
                        
                        expect(
                            mockStorage.read { db -> Data? in
                                try OpenGroup
                                    .select(.imageData)
                                    .asRequest(of: Data.self)
                                    .fetchOne(db)
                            }
                        ).to(beNil())
                    }
                    
                    // MARK: ------ does nothing if it fails to retrieve the room image
                    it("does nothing if it fails to retrieve the room image") {
                        mockOGMCache.when { $0.groupImagePublishers }
                            .thenReturn([
                                OpenGroup.idFor(roomToken: "testRoom", server: "http://127.0.0.1"): Fail(error: NetworkError.unknown).eraseToAnyPublisher()
                            ])
                        
                        testPollInfo = OpenGroupAPI.RoomPollInfo.mockValue.with(
                            token: "testRoom",
                            activeUsers: 10,
                            details: OpenGroupAPI.Room.mockValue.with(
                                token: "test",
                                name: "test",
                                imageId: "10"
                            )
                        )
                        
                        mockStorage.write { db in
                            try OpenGroupManager.handlePollInfo(
                                db,
                                pollInfo: testPollInfo,
                                publicKey: TestConstants.publicKey,
                                for: "testRoom",
                                on: "http://127.0.0.1",
                                waitForImageToComplete: true,
                                using: dependencies
                            )
                        }
                        
                        expect(
                            mockStorage.read { db -> Data? in
                                try OpenGroup
                                    .select(.imageData)
                                    .asRequest(of: Data.self)
                                    .fetchOne(db)
                            }
                        ).to(beNil())
                    }
                    
                    // MARK: ------ saves the retrieved room image
                    it("saves the retrieved room image") {
                        testPollInfo = OpenGroupAPI.RoomPollInfo.mockValue.with(
                            token: "testRoom",
                            activeUsers: 10,
                            details: OpenGroupAPI.Room.mockValue.with(
                                token: "test",
                                name: "test",
                                infoUpdates: 10,
                                imageId: "10"
                            )
                        )
                        mockStorage.write { db in
                            try OpenGroupManager.handlePollInfo(
                                db,
                                pollInfo: testPollInfo,
                                publicKey: TestConstants.publicKey,
                                for: "testRoom",
                                on: "http://127.0.0.1",
                                waitForImageToComplete: true,
                                using: dependencies
                            )
                        }
                        
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
        }
        
        // MARK: - an OpenGroupManager
        describe("an OpenGroupManager") {
            beforeEach {
                LibSession.loadState(
                    userPublicKey: "05\(TestConstants.publicKey)",
                    ed25519SecretKey: Array(Data(hex: TestConstants.edSecretKey)),
                    using: dependencies
                )
            }
            
            // MARK: -- when handling messages
            context("when handling messages") {
                beforeEach {
                    mockStorage.write { db in
                        try testGroupThread.insert(db)
                        try testOpenGroup.insert(db)
                        try testInteraction1.insert(db)
                    }
                }
                
                // MARK: ---- updates the sequence number when there are messages
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
                            on: "http://127.0.0.1",
                            using: dependencies
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
                
                // MARK: ---- does not update the sequence number if there are no messages
                it("does not update the sequence number if there are no messages") {
                    mockStorage.write { db in
                        OpenGroupManager.handleMessages(
                            db,
                            messages: [],
                            for: "testRoom",
                            on: "http://127.0.0.1",
                            using: dependencies
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
                
                // MARK: ---- ignores a message with no sender
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
                            on: "http://127.0.0.1",
                            using: dependencies
                        )
                    }
                    
                    expect(mockStorage.read { db -> Int in try Interaction.fetchCount(db) }).to(equal(0))
                }
                
                // MARK: ---- ignores a message with invalid data
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
                            on: "http://127.0.0.1",
                            using: dependencies
                        )
                    }
                    
                    expect(mockStorage.read { db -> Int in try Interaction.fetchCount(db) }).to(equal(0))
                }
                
                // MARK: ---- processes a message with valid data
                it("processes a message with valid data") {
                    mockStorage.write { db in
                        OpenGroupManager.handleMessages(
                            db,
                            messages: [testMessage],
                            for: "testRoom",
                            on: "http://127.0.0.1",
                            using: dependencies
                        )
                    }
                    
                    expect(mockStorage.read { db -> Int in try Interaction.fetchCount(db) }).to(equal(1))
                }
                
                // MARK: ---- processes valid messages when combined with invalid ones
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
                            on: "http://127.0.0.1",
                            using: dependencies
                        )
                    }
                    
                    expect(mockStorage.read { db -> Int in try Interaction.fetchCount(db) }).to(equal(1))
                }
                
                // MARK: ---- with no data
                context("with no data") {
                    // MARK: ------ deletes the message if we have the message
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
                                on: "http://127.0.0.1",
                                using: dependencies
                            )
                        }
                        
                        expect(mockStorage.read { db -> Int in try Interaction.fetchCount(db) }).to(equal(0))
                    }
                    
                    // MARK: ------ does nothing if we do not have the message
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
                                on: "http://127.0.0.1",
                                using: dependencies
                            )
                        }
                        
                        expect(mockStorage.read { db -> Int in try Interaction.fetchCount(db) }).to(equal(0))
                    }
                }
            }
            
            // MARK: -- when handling direct messages
            context("when handling direct messages") {
                beforeEach {
                    let result: (plaintext: Data, senderSessionIdHex: String) = (
                        plaintext: Data(base64Encoded:"ChQKC1Rlc3RNZXNzYWdlONCI7I/3Iw==")! +
                            Data([0x80]) +
                            Data([UInt8](repeating: 0, count: 32)),
                        senderSessionIdHex: "05\(TestConstants.publicKey)"
                    )
                    mockCrypto
                        .when { [dependencies = dependencies!] crypto in
                            dependencies.storage.read(using: dependencies) { [crypto] db in
                                crypto.generate(
                                    .plaintextWithSessionBlindingProtocol(
                                        db,
                                        ciphertext: any(),
                                        senderId: any(),
                                        recipientId: any(),
                                        serverPublicKey: any(),
                                        using: dependencies
                                    )
                                )
                            }
                        }
                        .thenReturn(result)
                    mockCrypto
                        .when { $0.generate(.x25519(ed25519Pubkey: anyArray())) }
                        .thenReturn(Data(hex: TestConstants.publicKey).bytes)
                }
                
                // MARK: ---- does nothing if there are no messages
                it("does nothing if there are no messages") {
                    mockStorage.write { db in
                        OpenGroupManager.handleDirectMessages(
                            db,
                            messages: [],
                            fromOutbox: false,
                            on: "http://127.0.0.1",
                            using: dependencies
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
                
                // MARK: ---- does nothing if it cannot get the open group
                it("does nothing if it cannot get the open group") {
                    mockStorage.write { db in
                        try OpenGroup.deleteAll(db)
                    }
                    
                    mockStorage.write { db in
                        OpenGroupManager.handleDirectMessages(
                            db,
                            messages: [testDirectMessage],
                            fromOutbox: false,
                            on: "http://127.0.0.1",
                            using: dependencies
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
                
                // MARK: ---- ignores messages with non base64 encoded data
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
                            on: "http://127.0.0.1",
                            using: dependencies
                        )
                    }
                    
                    expect(mockStorage.read { db -> Int in try Interaction.fetchCount(db) }).to(equal(0))
                }
                
                // MARK: ---- for the inbox
                context("for the inbox") {
                    beforeEach {
                        mockCrypto
                            .when { $0.verify(.sessionId(any(), matchesBlindedId: any(), serverPublicKey: any())) }
                            .thenReturn(false)
                    }
                    
                    // MARK: ------ updates the inbox latest message id
                    it("updates the inbox latest message id") {
                        mockStorage.write { db in
                            OpenGroupManager.handleDirectMessages(
                                db,
                                messages: [testDirectMessage],
                                fromOutbox: false,
                                on: "http://127.0.0.1",
                                using: dependencies
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
                    
                    // MARK: ------ ignores a message with invalid data
                    it("ignores a message with invalid data") {
                        mockCrypto
                            .when { [dependencies = dependencies!] crypto in
                                dependencies.storage.read(using: dependencies) { [crypto] db in
                                    crypto.generate(
                                        .plaintextWithSessionBlindingProtocol(
                                            db,
                                            ciphertext: any(),
                                            senderId: any(),
                                            recipientId: any(),
                                            serverPublicKey: any(),
                                            using: dependencies
                                        )
                                    )
                                }
                            }
                            .thenReturn((
                                plaintext: Data("TestInvalid".bytes),
                                senderSessionIdHex: "05\(TestConstants.publicKey)"
                            ))
                        
                        mockStorage.write { db in
                            OpenGroupManager.handleDirectMessages(
                                db,
                                messages: [testDirectMessage],
                                fromOutbox: false,
                                on: "http://127.0.0.1",
                                using: dependencies
                            )
                        }
                        
                        expect(mockStorage.read { db -> Int in try Interaction.fetchCount(db) }).to(equal(0))
                    }
                    
                    // MARK: ------ processes a message with valid data
                    it("processes a message with valid data") {
                        mockStorage.write { db in
                            OpenGroupManager.handleDirectMessages(
                                db,
                                messages: [testDirectMessage],
                                fromOutbox: false,
                                on: "http://127.0.0.1",
                                using: dependencies
                            )
                        }
                        
                        expect(mockStorage.read { db -> Int in try Interaction.fetchCount(db) }).to(equal(1))
                    }
                    
                    // MARK: ------ processes valid messages when combined with invalid ones
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
                                on: "http://127.0.0.1",
                                using: dependencies
                            )
                        }
                        
                        expect(mockStorage.read { db -> Int in try Interaction.fetchCount(db) }).to(equal(1))
                    }
                }
                
                // MARK: ---- for the outbox
                context("for the outbox") {
                    beforeEach {
                        mockCrypto
                            .when { $0.verify(.sessionId(any(), matchesBlindedId: any(), serverPublicKey: any())) }
                            .thenReturn(false)
                    }
                    
                    // MARK: ------ updates the outbox latest message id
                    it("updates the outbox latest message id") {
                        mockStorage.write { db in
                            OpenGroupManager.handleDirectMessages(
                                db,
                                messages: [testDirectMessage],
                                fromOutbox: true,
                                on: "http://127.0.0.1",
                                using: dependencies
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
                    
                    // MARK: ------ retrieves an existing blinded id lookup
                    it("retrieves an existing blinded id lookup") {
                        mockStorage.write { db in
                            try BlindedIdLookup(
                                blindedId: "15\(TestConstants.publicKey)",
                                sessionId: "TestSessionId",
                                openGroupServer: "http://127.0.0.1",
                                openGroupPublicKey: "05\(TestConstants.publicKey)"
                            ).insert(db)
                        }
                        
                        mockStorage.write { db in
                            OpenGroupManager.handleDirectMessages(
                                db,
                                messages: [testDirectMessage],
                                fromOutbox: true,
                                on: "http://127.0.0.1",
                                using: dependencies
                            )
                        }
                        
                        expect(mockStorage.read { db -> Int in try BlindedIdLookup.fetchCount(db) }).to(equal(1))
                        expect(mockStorage.read { db -> Int in try SessionThread.fetchCount(db) }).to(equal(2))
                    }
                    
                    // MARK: ------ falls back to using the blinded id if no lookup is found
                    it("falls back to using the blinded id if no lookup is found") {
                        mockStorage.write { db in
                            OpenGroupManager.handleDirectMessages(
                                db,
                                messages: [testDirectMessage],
                                fromOutbox: true,
                                on: "http://127.0.0.1",
                                using: dependencies
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
                    
                    // MARK: ------ ignores a message with invalid data
                    it("ignores a message with invalid data") {
                        mockCrypto
                            .when { [dependencies = dependencies!] crypto in
                                dependencies.storage.read(using: dependencies) { [crypto] db in
                                    crypto.generate(
                                        .plaintextWithSessionBlindingProtocol(
                                            db,
                                            ciphertext: any(),
                                            senderId: any(),
                                            recipientId: any(),
                                            serverPublicKey: any(),
                                            using: dependencies
                                        )
                                    )
                                }
                            }
                            .thenReturn((
                                plaintext: Data("TestInvalid".bytes),
                                senderSessionIdHex: "05\(TestConstants.publicKey)"
                            ))
                        
                        mockStorage.write { db in
                            OpenGroupManager.handleDirectMessages(
                                db,
                                messages: [testDirectMessage],
                                fromOutbox: true,
                                on: "http://127.0.0.1",
                                using: dependencies
                            )
                        }
                        
                        expect(mockStorage.read { db -> Int in try SessionThread.fetchCount(db) }).to(equal(1))
                    }
                    
                    // MARK: ------ processes a message with valid data
                    it("processes a message with valid data") {
                        mockStorage.write { db in
                            OpenGroupManager.handleDirectMessages(
                                db,
                                messages: [testDirectMessage],
                                fromOutbox: true,
                                on: "http://127.0.0.1",
                                using: dependencies
                            )
                        }
                        
                        expect(mockStorage.read { db -> Int in try SessionThread.fetchCount(db) }).to(equal(2))
                    }
                    
                    // MARK: ------ processes valid messages when combined with invalid ones
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
                                on: "http://127.0.0.1",
                                using: dependencies
                            )
                        }
                        
                        expect(mockStorage.read { db -> Int in try SessionThread.fetchCount(db) }).to(equal(2))
                    }
                }
            }
        }
        
        // MARK: - an OpenGroupManager
        describe("an OpenGroupManager") {
            beforeEach {
                LibSession.loadState(
                    userPublicKey: "05\(TestConstants.publicKey)",
                    ed25519SecretKey: Array(Data(hex: TestConstants.edSecretKey)),
                    using: dependencies
                )
            }
            
            // MARK: -- when determining if a user is a moderator or an admin
            context("when determining if a user is a moderator or an admin") {
                beforeEach {
                    mockStorage.write { db in
                        _ = try GroupMember.deleteAll(db)
                    }
                }
                
                // MARK: ---- uses an empty set for moderators by default
                it("uses an empty set for moderators by default") {
                    expect(
                        OpenGroupManager.isUserModeratorOrAdmin(
                            "05\(TestConstants.publicKey)",
                            for: "testRoom",
                            on: "http://127.0.0.1",
                            using: dependencies
                        )
                    ).to(beFalse())
                }
                
                // MARK: ---- uses an empty set for admins by default
                it("uses an empty set for admins by default") {
                    expect(
                        OpenGroupManager.isUserModeratorOrAdmin(
                            "05\(TestConstants.publicKey)",
                            for: "testRoom",
                            on: "http://127.0.0.1",
                            using: dependencies
                        )
                    ).to(beFalse())
                }
                
                // MARK: ---- returns true if the key is in the moderator set
                it("returns true if the key is in the moderator set") {
                    mockStorage.write { db in
                        try GroupMember(
                            groupId: OpenGroup.idFor(roomToken: "testRoom", server: "http://127.0.0.1"),
                            profileId: "05\(TestConstants.publicKey)",
                            role: .moderator,
                            isHidden: false
                        ).insert(db)
                    }
                    
                    expect(
                        OpenGroupManager.isUserModeratorOrAdmin(
                            "05\(TestConstants.publicKey)",
                            for: "testRoom",
                            on: "http://127.0.0.1",
                            using: dependencies
                        )
                    ).to(beTrue())
                }
                
                // MARK: ---- returns true if the key is in the admin set
                it("returns true if the key is in the admin set") {
                    mockStorage.write { db in
                        try GroupMember(
                            groupId: OpenGroup.idFor(roomToken: "testRoom", server: "http://127.0.0.1"),
                            profileId: "05\(TestConstants.publicKey)",
                            role: .admin,
                            isHidden: false
                        ).insert(db)
                    }
                    
                    expect(
                        OpenGroupManager.isUserModeratorOrAdmin(
                            "05\(TestConstants.publicKey)",
                            for: "testRoom",
                            on: "http://127.0.0.1",
                            using: dependencies
                        )
                    ).to(beTrue())
                }
                
                // MARK: ---- returns true if the moderator is hidden
                it("returns true if the moderator is hidden") {
                    mockStorage.write { db in
                        try GroupMember(
                            groupId: OpenGroup.idFor(roomToken: "testRoom", server: "http://127.0.0.1"),
                            profileId: "05\(TestConstants.publicKey)",
                            role: .moderator,
                            isHidden: true
                        ).insert(db)
                    }
                    
                    expect(
                        OpenGroupManager.isUserModeratorOrAdmin(
                            "05\(TestConstants.publicKey)",
                            for: "testRoom",
                            on: "http://127.0.0.1",
                            using: dependencies
                        )
                    ).to(beTrue())
                }
                
                // MARK: ---- returns true if the admin is hidden
                it("returns true if the admin is hidden") {
                    mockStorage.write { db in
                        try GroupMember(
                            groupId: OpenGroup.idFor(roomToken: "testRoom", server: "http://127.0.0.1"),
                            profileId: "05\(TestConstants.publicKey)",
                            role: .admin,
                            isHidden: true
                        ).insert(db)
                    }
                    
                    expect(
                        OpenGroupManager.isUserModeratorOrAdmin(
                            "05\(TestConstants.publicKey)",
                            for: "testRoom",
                            on: "http://127.0.0.1",
                            using: dependencies
                        )
                    ).to(beTrue())
                }
                
                // MARK: ---- returns false if the key is not a valid session id
                it("returns false if the key is not a valid session id") {
                    expect(
                        OpenGroupManager.isUserModeratorOrAdmin(
                            "InvalidValue",
                            for: "testRoom",
                            on: "http://127.0.0.1",
                            using: dependencies
                        )
                    ).to(beFalse())
                }
                
                // MARK: ---- and the key is a standard session id
                context("and the key is a standard session id") {
                    // MARK: ------ returns false if the key is not the users session id
                    it("returns false if the key is not the users session id") {
                        mockStorage.write { db in
                            let otherKey: String = TestConstants.publicKey.replacingOccurrences(of: "7", with: "6")
                            
                            try Identity(variant: .x25519PublicKey, data: Data(hex: otherKey)).save(db)
                            try Identity(variant: .x25519PrivateKey, data: Data(hex: TestConstants.privateKey)).save(db)
                        }
                        
                        expect(
                            OpenGroupManager.isUserModeratorOrAdmin(
                                "05\(TestConstants.publicKey)",
                                for: "testRoom",
                                on: "http://127.0.0.1",
                                using: dependencies
                            )
                        ).to(beFalse())
                    }
                    
                    // MARK: ------ returns true if the key is the current users and the users unblinded id is a moderator or admin
                    it("returns true if the key is the current users and the users unblinded id is a moderator or admin") {
                        mockStorage.write { db in
                            let otherKey: String = TestConstants.publicKey.replacingOccurrences(of: "7", with: "6")
                            
                            try GroupMember(
                                groupId: OpenGroup.idFor(roomToken: "testRoom", server: "http://127.0.0.1"),
                                profileId: "00\(otherKey)",
                                role: .moderator,
                                isHidden: false
                            ).insert(db)
                            
                            try Identity(variant: .ed25519PublicKey, data: Data(hex: otherKey)).save(db)
                            try Identity(variant: .ed25519SecretKey, data: Data(hex: TestConstants.edSecretKey)).save(db)
                        }
                        
                        expect(
                            OpenGroupManager.isUserModeratorOrAdmin(
                                "05\(TestConstants.publicKey)",
                                for: "testRoom",
                                on: "http://127.0.0.1",
                                using: dependencies
                            )
                        ).to(beTrue())
                    }
                    
                    // MARK: ------ returns true if the key is the current users and the users blinded id is a moderator or admin
                    it("returns true if the key is the current users and the users blinded id is a moderator or admin") {
                        let otherKey: String = TestConstants.publicKey.replacingOccurrences(of: "7", with: "6")
                        mockCrypto
                            .when { $0.generate(.blinded15KeyPair(serverPublicKey: any(), ed25519SecretKey: anyArray())) }
                            .thenReturn(
                                KeyPair(
                                    publicKey: Data(hex: otherKey).bytes,
                                    secretKey: Data(hex: TestConstants.edSecretKey).bytes
                                )
                            )
                        mockStorage.write { db in
                            try GroupMember(
                                groupId: OpenGroup.idFor(roomToken: "testRoom", server: "http://127.0.0.1"),
                                profileId: "15\(otherKey)",
                                role: .moderator,
                                isHidden: false
                            ).insert(db)
                        }
                        
                        expect(
                            OpenGroupManager.isUserModeratorOrAdmin(
                                "05\(TestConstants.publicKey)",
                                for: "testRoom",
                                on: "http://127.0.0.1",
                                using: dependencies
                            )
                        ).to(beTrue())
                    }
                }
                
                // MARK: ---- and the key is unblinded
                context("and the key is unblinded") {
                    // MARK: ------ returns false if unable to retrieve the user ed25519 key
                    it("returns false if unable to retrieve the user ed25519 key") {
                        mockStorage.write { db in
                            try Identity.filter(id: .ed25519PublicKey).deleteAll(db)
                            try Identity.filter(id: .ed25519SecretKey).deleteAll(db)
                        }
                        
                        expect(
                            OpenGroupManager.isUserModeratorOrAdmin(
                                "00\(TestConstants.publicKey)",
                                for: "testRoom",
                                on: "http://127.0.0.1",
                                using: dependencies
                            )
                        ).to(beFalse())
                    }
                    
                    // MARK: ------ returns false if the key is not the users unblinded id
                    it("returns false if the key is not the users unblinded id") {
                        mockStorage.write { db in
                            let otherKey: String = TestConstants.publicKey.replacingOccurrences(of: "7", with: "6")
                            
                            try Identity(variant: .ed25519PublicKey, data: Data(hex: otherKey)).save(db)
                            try Identity(variant: .ed25519SecretKey, data: Data(hex: TestConstants.edSecretKey)).save(db)
                        }
                        
                        expect(
                            OpenGroupManager.isUserModeratorOrAdmin(
                                "00\(TestConstants.publicKey)",
                                for: "testRoom",
                                on: "http://127.0.0.1",
                                using: dependencies
                            )
                        ).to(beFalse())
                    }
                    
                    // MARK: ------ returns true if the key is the current users and the users session id is a moderator or admin
                    it("returns true if the key is the current users and the users session id is a moderator or admin") {
                        let otherKey: String = TestConstants.publicKey.replacingOccurrences(of: "7", with: "6")
                        mockGeneralCache.when { $0.encodedPublicKey }.thenReturn("05\(otherKey)")
                        mockStorage.write { db in
                            try GroupMember(
                                groupId: OpenGroup.idFor(roomToken: "testRoom", server: "http://127.0.0.1"),
                                profileId: "05\(otherKey)",
                                role: .moderator,
                                isHidden: false
                            ).insert(db)
                            
                            try Identity(variant: .x25519PublicKey, data: Data(hex: otherKey)).save(db)
                            try Identity(variant: .x25519PrivateKey, data: Data(hex: TestConstants.privateKey)).save(db)
                            try Identity(variant: .ed25519PublicKey, data: Data(hex: TestConstants.publicKey)).save(db)
                            try Identity(variant: .ed25519SecretKey, data: Data(hex: TestConstants.edSecretKey)).save(db)
                        }
                        
                        expect(
                            OpenGroupManager.isUserModeratorOrAdmin(
                                "00\(TestConstants.publicKey)",
                                for: "testRoom",
                                on: "http://127.0.0.1",
                                using: dependencies
                            )
                        ).to(beTrue())
                    }
                    
                    // MARK: ------ returns true if the key is the current users and the users blinded id is a moderator or admin
                    it("returns true if the key is the current users and the users blinded id is a moderator or admin") {
                        let otherKey: String = TestConstants.publicKey.replacingOccurrences(of: "7", with: "6")
                        mockCrypto
                            .when { $0.generate(.blinded15KeyPair(serverPublicKey: any(), ed25519SecretKey: anyArray())) }
                            .thenReturn(
                                KeyPair(
                                    publicKey: Data(hex: otherKey).bytes,
                                    secretKey: Data(hex: TestConstants.edSecretKey).bytes
                                )
                            )
                        mockStorage.write { db in
                            try GroupMember(
                                groupId: OpenGroup.idFor(roomToken: "testRoom", server: "http://127.0.0.1"),
                                profileId: "15\(otherKey)",
                                role: .moderator,
                                isHidden: false
                            ).insert(db)
                            
                            try Identity(variant: .x25519PublicKey, data: Data(hex: TestConstants.publicKey)).save(db)
                            try Identity(variant: .x25519PrivateKey, data: Data(hex: TestConstants.privateKey)).save(db)
                            try Identity(variant: .ed25519PublicKey, data: Data(hex: TestConstants.publicKey)).save(db)
                            try Identity(variant: .ed25519SecretKey, data: Data(hex: TestConstants.edSecretKey)).save(db)
                        }
                        
                        expect(
                            OpenGroupManager.isUserModeratorOrAdmin(
                                "00\(TestConstants.publicKey)",
                                for: "testRoom",
                                on: "http://127.0.0.1",
                                using: dependencies
                            )
                        ).to(beTrue())
                    }
                }
                
                // MARK: ---- and the key is blinded
                context("and the key is blinded") {
                    // MARK: ------ returns false if unable to retrieve the user ed25519 key
                    it("returns false if unable to retrieve the user ed25519 key") {
                        mockStorage.write { db in
                            try Identity.filter(id: .ed25519PublicKey).deleteAll(db)
                            try Identity.filter(id: .ed25519SecretKey).deleteAll(db)
                        }
                        
                        expect(
                            OpenGroupManager.isUserModeratorOrAdmin(
                                "15\(TestConstants.publicKey)",
                                for: "testRoom",
                                on: "http://127.0.0.1",
                                using: dependencies
                            )
                        ).to(beFalse())
                    }
                    
                    // MARK: ------ returns false if unable generate a blinded key
                    it("returns false if unable generate a blinded key") {
                        mockCrypto
                            .when { $0.generate(.blinded15KeyPair(serverPublicKey: any(), ed25519SecretKey: anyArray())) }
                            .thenReturn(nil)
                        
                        expect(
                            OpenGroupManager.isUserModeratorOrAdmin(
                                "15\(TestConstants.publicKey)",
                                for: "testRoom",
                                on: "http://127.0.0.1",
                                using: dependencies
                            )
                        ).to(beFalse())
                    }
                    
                    // MARK: ------ returns false if the key is not the users blinded id
                    it("returns false if the key is not the users blinded id") {
                        let otherKey: String = TestConstants.publicKey.replacingOccurrences(of: "7", with: "6")
                        mockCrypto
                            .when { $0.generate(.blinded15KeyPair(serverPublicKey: any(), ed25519SecretKey: anyArray())) }
                            .thenReturn(
                                KeyPair(
                                    publicKey: Data(hex: otherKey).bytes,
                                    secretKey: Data(hex: TestConstants.edSecretKey).bytes
                                )
                            )
                        
                        expect(
                            OpenGroupManager.isUserModeratorOrAdmin(
                                "15\(TestConstants.publicKey)",
                                for: "testRoom",
                                on: "http://127.0.0.1",
                                using: dependencies
                            )
                        ).to(beFalse())
                    }
                    
                    // MARK: ------ returns true if the key is the current users and the users session id is a moderator or admin
                    it("returns true if the key is the current users and the users session id is a moderator or admin") {
                        let otherKey: String = TestConstants.publicKey.replacingOccurrences(of: "7", with: "6")
                        mockGeneralCache.when { $0.encodedPublicKey }.thenReturn("05\(otherKey)")
                        mockCrypto
                            .when { $0.generate(.blinded15KeyPair(serverPublicKey: any(), ed25519SecretKey: anyArray())) }
                            .thenReturn(
                                KeyPair(
                                    publicKey: Data(hex: TestConstants.publicKey).bytes,
                                    secretKey: Data(hex: TestConstants.edSecretKey).bytes
                                )
                            )
                        mockStorage.write { db in
                            try GroupMember(
                                groupId: OpenGroup.idFor(roomToken: "testRoom", server: "http://127.0.0.1"),
                                profileId: "05\(otherKey)",
                                role: .moderator,
                                isHidden: false
                            ).insert(db)
                            
                            try Identity(variant: .x25519PublicKey, data: Data(hex: otherKey)).save(db)
                            try Identity(variant: .x25519PrivateKey, data: Data(hex: TestConstants.privateKey)).save(db)
                            try Identity(variant: .ed25519PublicKey, data: Data(hex: TestConstants.publicKey)).save(db)
                            try Identity(variant: .ed25519SecretKey, data: Data(hex: TestConstants.edSecretKey)).save(db)
                        }
                        
                        expect(
                            OpenGroupManager.isUserModeratorOrAdmin(
                                "15\(TestConstants.publicKey)",
                                for: "testRoom",
                                on: "http://127.0.0.1",
                                using: dependencies
                            )
                        ).to(beTrue())
                    }
                    
                    // MARK: ------ returns true if the key is the current users and the users unblinded id is a moderator or admin
                    it("returns true if the key is the current users and the users unblinded id is a moderator or admin") {
                        mockCrypto
                            .when { $0.generate(.blinded15KeyPair(serverPublicKey: any(), ed25519SecretKey: anyArray())) }
                            .thenReturn(
                                KeyPair(
                                    publicKey: Data(hex: TestConstants.publicKey).bytes,
                                    secretKey: Data(hex: TestConstants.edSecretKey).bytes
                                )
                            )
                        mockStorage.write { db in
                            let otherKey: String = TestConstants.publicKey.replacingOccurrences(of: "7", with: "6")
                            
                            try GroupMember(
                                groupId: OpenGroup.idFor(roomToken: "testRoom", server: "http://127.0.0.1"),
                                profileId: "00\(otherKey)",
                                role: .moderator,
                                isHidden: false
                            ).insert(db)
                            
                            try Identity(variant: .x25519PublicKey, data: Data(hex: TestConstants.publicKey)).save(db)
                            try Identity(variant: .x25519PrivateKey, data: Data(hex: TestConstants.privateKey)).save(db)
                            try Identity(variant: .ed25519PublicKey, data: Data(hex: otherKey)).save(db)
                            try Identity(variant: .ed25519SecretKey, data: Data(hex: TestConstants.edSecretKey)).save(db)
                        }
                        
                        expect(
                            OpenGroupManager.isUserModeratorOrAdmin(
                                "15\(TestConstants.publicKey)",
                                for: "testRoom",
                                on: "http://127.0.0.1",
                                using: dependencies
                            )
                        ).to(beTrue())
                    }
                }
            }
            
            // MARK: -- when getting the default rooms if needed
            context("when getting the default rooms if needed") {
                beforeEach {
                    mockNetwork
                        .when { $0.send(.onionRequest(any(), to: any(), with: any()), using: dependencies) }
                        .thenReturn(Network.BatchResponse.mockCapabilitiesAndRoomsResponse)
                    
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
                
                // MARK: ---- caches the publisher if there is no cached publisher
                it("caches the publisher if there is no cached publisher") {
                    let publisher = OpenGroupManager.getDefaultRoomsIfNeeded(using: dependencies)
                    
                    expect(mockOGMCache)
                        .to(call(matchingParameters: true) {
                            $0.defaultRoomsPublisher = publisher
                        })
                }
                
                // MARK: ---- returns the cached publisher if there is one
                it("returns the cached publisher if there is one") {
                    let uniqueRoomInstance: OpenGroupAPI.Room = OpenGroupAPI.Room.mockValue.with(
                        token: "UniqueId",
                        name: ""
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
                
                // MARK: ---- stores the open group information
                it("stores the open group information") {
                    OpenGroupManager.getDefaultRoomsIfNeeded(using: dependencies)
                    
                    // 1 for the value returned from the API and 1 for the default added
                    // by the 'RetrieveDefaultOpenGroupRoomsJob' logic
                    expect(mockStorage.read { db -> Int in try OpenGroup.fetchCount(db) }).to(equal(2))
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
                
                // MARK: ---- fetches rooms for the server
                it("fetches rooms for the server") {
                    var response: [OpenGroupManager.DefaultRoomInfo]?
                    
                    OpenGroupManager.getDefaultRoomsIfNeeded(using: dependencies)
                        .handleEvents(receiveOutput: { response = $0 })
                        .sinkAndStore(in: &disposables)
                    
                    expect(response?.map { $0.room })
                        .to(equal([OpenGroupAPI.Room.mockValue]))
                }
                
                // MARK: ---- will retry fetching rooms 8 times before it fails
                it("will retry fetching rooms 8 times before it fails") {
                    mockNetwork
                        .when { $0.send(.onionRequest(any(), to: any(), with: any()), using: dependencies) }
                        .thenReturn(MockNetwork.nullResponse())
                    
                    var error: Error?
                    
                    OpenGroupManager.getDefaultRoomsIfNeeded(using: dependencies)
                        .mapError { result -> Error in error.setting(to: result) }
                        .sinkAndStore(in: &disposables)
                    
                    expect(error).to(matchError(NetworkError.parsingFailed))
                    expect(mockNetwork)   // First attempt + 8 retries
                        .to(call(.exactly(times: 9)) {
                            $0.send(.onionRequest(any(), to: any(), with: any()), using: dependencies)
                        })
                }
                
                // MARK: ---- removes the cache publisher if all retries fail
                it("removes the cache publisher if all retries fail") {
                    mockNetwork
                        .when { $0.send(.onionRequest(any(), to: any(), with: any()), using: dependencies) }
                        .thenReturn(MockNetwork.nullResponse())
                    
                    var error: Error?
                    
                    OpenGroupManager.getDefaultRoomsIfNeeded(using: dependencies)
                        .mapError { result -> Error in error.setting(to: result) }
                        .sinkAndStore(in: &disposables)
                    
                    expect(error)
                        .to(matchError(NetworkError.parsingFailed))
                    expect(mockOGMCache)
                        .to(call(matchingParameters: true) {
                            $0.defaultRoomsPublisher = nil
                        })
                }
                
                // MARK: ---- fetches the image for any rooms with images
                it("fetches the image for any rooms with images") {
                    mockNetwork
                        .when {
                            $0.send(.onionRequest(
                                URLRequest(url: URL(string: "https://open.getsession.org/sequence")!),
                                to: OpenGroupAPI.defaultServer,
                                with: OpenGroupAPI.defaultServerPublicKey
                            ), using: dependencies)
                        }
                        .thenReturn(
                            MockNetwork.batchResponseData(
                                with: [
                                    (OpenGroupAPI.Endpoint.capabilities, OpenGroupAPI.Capabilities.mockBatchSubResponse()),
                                    (
                                        OpenGroupAPI.Endpoint.rooms,
                                        [
                                            OpenGroupAPI.Room.mockValue.with(
                                                token: "test2",
                                                name: "test2",
                                                infoUpdates: 11,
                                                imageId: "12"
                                            )
                                        ].batchSubResponse()
                                    )
                                ]
                            )
                        )
                    mockNetwork
                        .when {
                            $0.send(
                                .downloadFile(
                                    from: .server(
                                        url: URL(string: "https://open.getsession.org/room/test2/file/12")!,
                                        method: .get,
                                        headers: nil,
                                        x25519PublicKey: TestConstants.publicKey
                                    )
                                ),
                                using: dependencies
                            )
                        }
                        .thenReturn(
                            Just((MockResponseInfo.mockValue, Data([1, 2, 3])))
                                .setFailureType(to: Error.self)
                                .eraseToAnyPublisher()
                        )

                    let testDate: Date = Date(timeIntervalSince1970: 1234567890)
                    dependencies.dateNow = testDate
                    
                    OpenGroupManager
                        .getDefaultRoomsIfNeeded(using: dependencies)
                        .sinkAndStore(in: &disposables)
                    
                    expect(mockUserDefaults)
                        .to(call(matchingParameters: true) {
                            $0.set(
                                testDate,
                                forKey: SNUserDefaults.Date.lastOpenGroupImageUpdate.rawValue
                            )
                        })
                    expect(
                        mockStorage.read { db -> Data? in
                            try OpenGroup
                                .select(.imageData)
                                .filter(id: OpenGroup.idFor(roomToken: "test2", server: OpenGroupAPI.defaultServer))
                                .asRequest(of: Data.self)
                                .fetchOne(db)
                        }
                    ).to(equal(Data([1, 2, 3])))
                }
            }
            
            // MARK: -- when getting a room image
            context("when getting a room image") {
                beforeEach {
                    mockNetwork
                        .when { $0.send(.downloadFile(from: any()), using: dependencies) }
                        .thenReturn(
                            Just((MockResponseInfo.mockValue, Data([1, 2, 3])))
                                .setFailureType(to: Error.self)
                                .eraseToAnyPublisher()
                        )
                    
                    mockUserDefaults
                        .when { (defaults: inout any UserDefaultsType) -> Any? in defaults.object(forKey: any()) }
                        .thenReturn(nil)
                    mockUserDefaults
                        .when { (defaults: inout any UserDefaultsType) -> Any? in defaults.set(anyAny(), forKey: any()) }
                        .thenReturn(())
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
                
                // MARK: ---- retrieves the image retrieval publisher from the cache if it exists
                it("retrieves the image retrieval publisher from the cache if it exists") {
                    let publisher = Future<Data, Error> { resolver in
                        resolver(Result.success(Data([5, 4, 3, 2, 1])))
                    }
                    .shareReplay(1)
                    .eraseToAnyPublisher()
                    mockOGMCache
                        .when { $0.groupImagePublishers }
                        .thenReturn([OpenGroup.idFor(roomToken: "testRoom", server: "http://127.0.0.1"): publisher])
                    
                    var result: Data?
                    OpenGroupManager
                        .roomImage(
                            fileId: "1",
                            for: "testRoom",
                            on: "http://127.0.0.1",
                            existingData: nil,
                            using: dependencies
                        )
                        .handleEvents(receiveOutput: { result = $0 })
                        .sinkAndStore(in: &disposables)
                    
                    expect(result).to(equal(publisher.firstValue()))
                }
                
                // MARK: ---- does not save the fetched image to storage
                it("does not save the fetched image to storage") {
                    OpenGroupManager
                        .roomImage(
                            fileId: "1",
                            for: "testRoom",
                            on: "http://127.0.0.1",
                            existingData: nil,
                            using: dependencies
                        )
                        .sinkAndStore(in: &disposables)
                    
                    expect(
                        mockStorage.read { db -> Data? in
                            try OpenGroup
                                .select(.imageData)
                                .filter(id: OpenGroup.idFor(roomToken: "testRoom", server: "http://127.0.0.1"))
                                .asRequest(of: Data.self)
                                .fetchOne(db)
                        }
                    ).to(beNil())
                }
                
                // MARK: ---- does not update the image update timestamp
                it("does not update the image update timestamp") {
                    OpenGroupManager
                        .roomImage(
                            fileId: "1",
                            for: "testRoom",
                            on: "http://127.0.0.1",
                            existingData: nil,
                            using: dependencies
                        )
                        .sinkAndStore(in: &disposables)
                    
                    expect(mockUserDefaults)
                        .toNot(call(matchingParameters: true) {
                            $0.set(
                                dependencies.dateNow,
                                forKey: SNUserDefaults.Date.lastOpenGroupImageUpdate.rawValue
                            )
                        })
                }
                
                // MARK: ---- adds the image retrieval publisher to the cache
                it("adds the image retrieval publisher to the cache") {
                    let publisher = OpenGroupManager
                        .roomImage(
                            fileId: "1",
                            for: "testRoom",
                            on: "http://127.0.0.1",
                            existingData: nil,
                            using: dependencies
                        )
                    publisher.sinkAndStore(in: &disposables)
                    
                    expect(mockOGMCache)
                        .to(call(matchingParameters: true) {
                            $0.groupImagePublishers = [OpenGroup.idFor(roomToken: "testRoom", server: "http://127.0.0.1"): publisher]
                        })
                }
                
                // MARK: ---- for the default server
                context("for the default server") {
                    // MARK: ------ fetches a new image if there is no cached one
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
                        
                        expect(result).to(equal(Data([1, 2, 3])))
                    }
                    
                    // MARK: ------ saves the fetched image to storage
                    it("saves the fetched image to storage") {
                        OpenGroupManager
                            .roomImage(
                                fileId: "1",
                                for: "testRoom",
                                on: OpenGroupAPI.defaultServer,
                                existingData: nil,
                                using: dependencies
                            )
                            .sinkAndStore(in: &disposables)
                        
                        expect(
                            mockStorage.read { db -> Data? in
                                try OpenGroup
                                    .select(.imageData)
                                    .filter(id: OpenGroup.idFor(roomToken: "testRoom", server: OpenGroupAPI.defaultServer))
                                    .asRequest(of: Data.self)
                                    .fetchOne(db)
                            }
                        ).toNot(beNil())
                    }
                    
                    // MARK: ------ updates the image update timestamp
                    it("updates the image update timestamp") {
                        OpenGroupManager
                            .roomImage(
                                fileId: "1",
                                for: "testRoom",
                                on: OpenGroupAPI.defaultServer,
                                existingData: nil,
                                using: dependencies
                            )
                            .sinkAndStore(in: &disposables)
                        
                        expect(mockUserDefaults)
                            .to(call(matchingParameters: true) {
                                $0.set(
                                    dependencies.dateNow,
                                    forKey: SNUserDefaults.Date.lastOpenGroupImageUpdate.rawValue
                                )
                            })
                    }
                    
                    // MARK: ------ and there is a cached image
                    context("and there is a cached image") {
                        beforeEach {
                            dependencies.dateNow = Date(timeIntervalSince1970: 1234567890)
                            mockUserDefaults
                                .when { (defaults: inout any UserDefaultsType) -> Any? in
                                    defaults.object(forKey: any())
                                }
                                .thenReturn(dependencies.dateNow)
                            mockStorage.write(updates: { db in
                                try OpenGroup
                                    .filter(id: OpenGroup.idFor(roomToken: "testRoom", server: OpenGroupAPI.defaultServer))
                                    .updateAll(
                                        db,
                                        OpenGroup.Columns.imageData.set(to: Data([2, 3, 4]))
                                    )
                            })
                        }
                        
                        // MARK: -------- retrieves the cached image
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
                            
                            expect(result).to(equal(Data([2, 3, 4])))
                        }
                        
                        // MARK: -------- fetches a new image if the cached on is older than a week
                        it("fetches a new image if the cached on is older than a week") {
                            let weekInSeconds: TimeInterval = (7 * 24 * 60 * 60)
                            let targetTimestamp: TimeInterval = (
                                dependencies.dateNow.timeIntervalSince1970 - weekInSeconds - 1
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
                            
                            expect(result).to(equal(Data([1, 2, 3])))
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Convenience Extensions

extension OpenGroupAPI.Room {
    func with(
        token: String? = nil,
        name: String? = nil,
        infoUpdates: Int64? = nil,
        imageId: String? = nil,
        moderators: [String]? = nil,
        hiddenModerators: [String]? = nil,
        admins: [String]? = nil,
        hiddenAdmins: [String]? = nil
    ) -> OpenGroupAPI.Room {
        return OpenGroupAPI.Room(
            token: (token ?? self.token),
            name: (name ?? self.name),
            roomDescription: self.roomDescription,
            infoUpdates: (infoUpdates ?? self.infoUpdates),
            messageSequence: self.messageSequence,
            created: self.created,
            activeUsers: self.activeUsers,
            activeUsersCutoff: self.activeUsersCutoff,
            imageId: (imageId ?? self.imageId),
            pinnedMessages: self.pinnedMessages,
            admin: self.admin,
            globalAdmin: self.globalAdmin,
            admins: (admins ?? self.admins),
            hiddenAdmins: (hiddenAdmins ?? self.hiddenAdmins),
            moderator: self.moderator,
            globalModerator: self.globalModerator,
            moderators: (moderators ?? self.moderators),
            hiddenModerators: (hiddenModerators ?? self.hiddenModerators),
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

extension OpenGroupAPI.RoomPollInfo {
    func with(
        token: String? = nil,
        activeUsers: Int64? = nil,
        details: OpenGroupAPI.Room? = .mockValue
    ) -> OpenGroupAPI.RoomPollInfo {
        return OpenGroupAPI.RoomPollInfo(
            token: (token ?? self.token),
            activeUsers: (activeUsers ?? self.activeUsers),
            admin: self.admin,
            globalAdmin: self.globalAdmin,
            moderator: self.moderator,
            globalModerator: self.globalModerator,
            read: self.read,
            defaultRead: self.defaultRead,
            defaultAccessible: self.defaultAccessible,
            write: self.write,
            defaultWrite: self.defaultWrite,
            upload: self.upload,
            defaultUpload: self.defaultUpload,
            details: details
        )
    }
}

// MARK: - Mock Types

extension OpenGroupAPI.Capabilities: Mocked {
    static var mockValue: OpenGroupAPI.Capabilities = OpenGroupAPI.Capabilities(capabilities: [], missing: nil)
}

extension OpenGroupAPI.Room: Mocked {
    static var mockValue: OpenGroupAPI.Room = OpenGroupAPI.Room(
        token: "test",
        name: "testRoom",
        roomDescription: nil,
        infoUpdates: 1,
        messageSequence: 1,
        created: 1,
        activeUsers: 1,
        activeUsersCutoff: 1,
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
        read: true,
        defaultRead: nil,
        defaultAccessible: nil,
        write: true,
        defaultWrite: nil,
        upload: true,
        defaultUpload: nil
    )
}

extension OpenGroupAPI.RoomPollInfo: Mocked {
    static var mockValue: OpenGroupAPI.RoomPollInfo = OpenGroupAPI.RoomPollInfo(
        token: "test",
        activeUsers: 1,
        admin: false,
        globalAdmin: false,
        moderator: false,
        globalModerator: false,
        read: true,
        defaultRead: nil,
        defaultAccessible: nil,
        write: true,
        defaultWrite: nil,
        upload: true,
        defaultUpload: false,
        details: .mockValue
    )
}

extension OpenGroupAPI.Message: Mocked {
    static var mockValue: OpenGroupAPI.Message = OpenGroupAPI.Message(
        id: 100,
        sender: TestConstants.blindedPublicKey,
        posted: 1,
        edited: nil,
        deleted: nil,
        seqNo: 1,
        whisper: false,
        whisperMods: false,
        whisperTo: nil,
        base64EncodedData: nil,
        base64EncodedSignature: nil,
        reactions: nil
    )
}

extension OpenGroupAPI.SendDirectMessageResponse: Mocked {
    static var mockValue: OpenGroupAPI.SendDirectMessageResponse = OpenGroupAPI.SendDirectMessageResponse(
        id: 1,
        sender: TestConstants.blindedPublicKey,
        recipient: "testRecipient",
        posted: 1122,
        expires: 2233
    )
}

extension OpenGroupAPI.DirectMessage: Mocked {
    static var mockValue: OpenGroupAPI.DirectMessage = OpenGroupAPI.DirectMessage(
        id: 101,
        sender: TestConstants.blindedPublicKey,
        recipient: "testRecipient",
        posted: 1212,
        expires: 2323,
        base64EncodedMessage: "TestMessage".data(using: .utf8)!.base64EncodedString()
    )
}
                        
extension Network.BatchResponse {
    static let mockUnblindedPollResponse: AnyPublisher<(ResponseInfoType, Data?), Error> = MockNetwork.batchResponseData(
        with: [
            (OpenGroupAPI.Endpoint.capabilities, OpenGroupAPI.Capabilities.mockBatchSubResponse()),
            (OpenGroupAPI.Endpoint.roomPollInfo("testRoom", 0), OpenGroupAPI.RoomPollInfo.mockBatchSubResponse()),
            (OpenGroupAPI.Endpoint.roomMessagesRecent("testRoom"), [OpenGroupAPI.Message].mockBatchSubResponse())
        ]
    )
    
    static let mockBlindedPollResponse: AnyPublisher<(ResponseInfoType, Data?), Error> = MockNetwork.batchResponseData(
        with: [
            (OpenGroupAPI.Endpoint.capabilities, OpenGroupAPI.Capabilities.mockBatchSubResponse()),
            (OpenGroupAPI.Endpoint.roomPollInfo("testRoom", 0), OpenGroupAPI.RoomPollInfo.mockBatchSubResponse()),
            (OpenGroupAPI.Endpoint.roomMessagesRecent("testRoom"), OpenGroupAPI.Message.mockBatchSubResponse()),
            (OpenGroupAPI.Endpoint.inboxSince(id: 0), OpenGroupAPI.DirectMessage.mockBatchSubResponse()),
            (OpenGroupAPI.Endpoint.outboxSince(id: 0), OpenGroupAPI.DirectMessage.self.mockBatchSubResponse())
        ]
    )
    
    static let mockCapabilitiesResponse: AnyPublisher<(ResponseInfoType, Data?), Error> = MockNetwork.batchResponseData(
        with: [
            (OpenGroupAPI.Endpoint.capabilities, OpenGroupAPI.Capabilities.mockBatchSubResponse())
        ]
    )
    
    static let mockRoomResponse: AnyPublisher<(ResponseInfoType, Data?), Error> = MockNetwork.batchResponseData(
        with: [
            (OpenGroupAPI.Endpoint.capabilities, OpenGroupAPI.Room.mockBatchSubResponse())
        ]
    )
    
    static let mockBanAndDeleteAllResponse: AnyPublisher<(ResponseInfoType, Data?), Error> = MockNetwork.batchResponseData(
        with: [
            (OpenGroupAPI.Endpoint.userBan(""), NoResponse.mockBatchSubResponse()),
            (OpenGroupAPI.Endpoint.roomDeleteMessages("testRoon", sessionId: ""), NoResponse.mockBatchSubResponse())
        ]
    )
}
