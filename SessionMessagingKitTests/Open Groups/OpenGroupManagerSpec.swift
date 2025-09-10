// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import Combine
import GRDB
import SessionUtil
import SessionNetworkingKit
import SessionUtilitiesKit
import TestUtilities

import Quick
import Nimble

@testable import SessionMessagingKit

class OpenGroupManagerSpec: AsyncSpec {
    override class func spec() {
        // MARK: Configuration
        
        @TestState var dependencies: TestDependencies! = TestDependencies { dependencies in
            dependencies.dateNow = Date(timeIntervalSince1970: 1234567890)
            dependencies.forceSynchronous = true
        }
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
            mostRecentFailureText: nil,
            isProMessage: false
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
            userCount: 0,
            infoUpdates: 10,
            sequenceNumber: 5
        )
        @TestState var testPollInfo: OpenGroupAPI.RoomPollInfo! = OpenGroupAPI.RoomPollInfo.mock.with(
            token: "testRoom",
            activeUsers: 10,
            details: .mock
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
        @TestState var testDirectMessage: OpenGroupAPI.DirectMessage! = {
            let proto = SNProtoContent.builder()
            let protoDataBuilder = SNProtoDataMessage.builder()
            proto.setSigTimestamp(1234567890000)
            protoDataBuilder.setBody("TestMessage")
            proto.setDataMessage(try! protoDataBuilder.build())
            
            return OpenGroupAPI.DirectMessage(
                id: 128,
                sender: "15\(TestConstants.blind15PublicKey)",
                recipient: "15\(TestConstants.blind15PublicKey)",
                posted: 1234567890,
                expires: 1234567990,
                base64EncodedMessage: try! proto.build().serializedData().base64EncodedString()
            )
        }()
        @TestState(singleton: .storage, in: dependencies) var mockStorage: Storage! = SynchronousStorage(
            customWriter: try! DatabaseQueue(),
            using: dependencies
        )
        @TestState(singleton: .jobRunner, in: dependencies) var mockJobRunner: MockJobRunner! = MockJobRunner(
            initialSetup: { jobRunner in
                jobRunner
                    .when { $0.add(.any, job: .any, dependantJob: .any, canStartJob: .any) }
                    .thenReturn(nil)
                jobRunner
                    .when { $0.upsert(.any, job: .any, canStartJob: .any) }
                    .thenReturn(nil)
                jobRunner
                    .when { $0.jobInfoFor(jobs: .any, state: .any, variant: .any) }
                    .thenReturn([:])
            }
        )
        @TestState var mockNetwork: MockNetwork! = .create()
        @TestState(singleton: .crypto, in: dependencies) var mockCrypto: MockCrypto! = .create()
        @TestState var mockUserDefaults: MockUserDefaults! = .create()
        @TestState var mockAppGroupDefaults: MockUserDefaults! = .create()
        @TestState var mockGeneralCache: MockGeneralCache! = .create()
        @TestState var mockLibSessionCache: MockLibSessionCache! = MockLibSessionCache()
        @TestState var mockOGMCache: MockOGMCache! = MockOGMCache()
        @TestState var mockPoller: MockPoller! = .create()
        @TestState(singleton: .communityPollerManager, in: dependencies) var mockCommunityPollerManager: MockCommunityPollerManager! = .create()
        @TestState(singleton: .keychain, in: dependencies) var mockKeychain: MockKeychain! = MockKeychain(
            initialSetup: { keychain in
                keychain
                    .when {
                        try $0.getOrGenerateEncryptionKey(
                            forKey: .any,
                            length: .any,
                            cat: .any,
                            legacyKey: .any,
                            legacyService: .any
                        )
                    }
                    .thenReturn(Data([1, 2, 3]))
            }
        )
        @TestState(singleton: .fileManager, in: dependencies) var mockFileManager: MockFileManager! = MockFileManager(
            initialSetup: { $0.defaultInitialSetup() }
        )
        @TestState var userGroupsConf: UnsafeMutablePointer<config_object>!
        @TestState var userGroupsInitResult: Int32! = {
            var secretKey: [UInt8] = Array(Data(hex: TestConstants.edSecretKey))
            
            return user_groups_init(&userGroupsConf, &secretKey, nil, 0, nil)
        }()
        @TestState var disposables: [AnyCancellable]! = []
        
        @TestState var cache: OpenGroupManager.Cache! = OpenGroupManager.Cache(using: dependencies)
        @TestState var openGroupManager: OpenGroupManager! = OpenGroupManager(using: dependencies)
        
        beforeEach {
            /// The compiler kept crashing when doing this via `@TestState` so need to do it here instead
            try await mockGeneralCache.defaultInitialSetup()
            dependencies.set(cache: .general, to: mockGeneralCache)
            
            mockLibSessionCache.defaultInitialSetup()
            dependencies.set(cache: .libSession, to: mockLibSessionCache)
            
            mockOGMCache.when { $0.pendingChanges }.thenReturn([])
            mockOGMCache.when { $0.pendingChanges = .any }.thenReturn(())
            mockOGMCache.when { $0.getLastSuccessfulCommunityPollTimestamp() }.thenReturn(0)
            mockOGMCache.when { $0.setDefaultRoomInfo(.any) }.thenReturn(())
            dependencies.set(cache: .openGroupManager, to: mockOGMCache)
            
            try await mockStorage.perform(migrations: SNMessagingKit.migrations)
            try await mockStorage.writeAsync { db in
                try Identity(variant: .x25519PublicKey, data: Data(hex: TestConstants.publicKey)).insert(db)
                try Identity(variant: .x25519PrivateKey, data: Data(hex: TestConstants.privateKey)).insert(db)
                try Identity(variant: .ed25519PublicKey, data: Data(hex: TestConstants.edPublicKey)).insert(db)
                try Identity(variant: .ed25519SecretKey, data: Data(hex: TestConstants.edSecretKey)).insert(db)
                
                try testGroupThread.insert(db)
                try testOpenGroup.insert(db)
                try Capability(openGroupServer: testOpenGroup.server, variant: .sogs, isMissing: false).insert(db)
            }
            
            try await mockCrypto.when { $0.generate(.hash(message: .any, length: .any)) }.thenReturn([])
            try await mockCrypto
                .when { $0.generate(.blinded15KeyPair(serverPublicKey: .any, ed25519SecretKey: .any)) }
                .thenReturn(
                    KeyPair(
                        publicKey: Data(hex: TestConstants.publicKey).bytes,
                        secretKey: Data(hex: TestConstants.edSecretKey).bytes
                    )
                )
            try await mockCrypto
                .when { $0.generate(.blinded25KeyPair(serverPublicKey: .any, ed25519SecretKey: .any)) }
                .thenReturn(
                    KeyPair(
                        publicKey: Data(hex: TestConstants.publicKey).bytes,
                        secretKey: Data(hex: TestConstants.edSecretKey).bytes
                    )
                )
            try await mockCrypto
                .when { $0.generate(.signatureBlind15(message: .any, serverPublicKey: .any, ed25519SecretKey: .any)) }
                .thenReturn("TestSogsSignature".bytes)
            try await mockCrypto
                .when { $0.generate(.signature(message: .any, ed25519SecretKey: .any)) }
                .thenReturn(Authentication.Signature.standard(signature: "TestSignature".bytes))
            try await mockCrypto
                .when { $0.generate(.randomBytes(16)) }
                .thenReturn(Array(Data(base64Encoded: "pK6YRtQApl4NhECGizF0Cg==")!))
            try await mockCrypto
                .when { $0.generate(.randomBytes(24)) }
                .thenReturn(Array(Data(base64Encoded: "pbTUizreT0sqJ2R2LloseQDyVL2RYztD")!))
            try await mockCrypto
                .when { $0.generate(.ed25519KeyPair(seed: .any)) }
                .thenReturn(
                    KeyPair(
                        publicKey: Array(Data(hex: TestConstants.edPublicKey)),
                        secretKey: Array(Data(hex: TestConstants.edSecretKey))
                    )
                )
            try await mockCrypto
                .when { $0.generate(.ciphertextWithXChaCha20(plaintext: .any, encKey: .any)) }
                .thenReturn(Data([1, 2, 3]))
            
            try await mockPoller.when { await $0.startIfNeeded() }.thenReturn(())
            try await mockPoller.when { await $0.stop() }.thenReturn(())
            
            try await mockCommunityPollerManager.when { await $0.serversBeingPolled }.thenReturn([])
            try await mockCommunityPollerManager.when { await $0.startAllPollers() }.thenReturn(())
            try await mockCommunityPollerManager
                .when { await $0.getOrCreatePoller(for: .any) }
                .thenReturn(mockPoller)
            try await mockCommunityPollerManager.when { await $0.stopAndRemovePoller(for: .any) }.thenReturn(())
            try await mockCommunityPollerManager.when { await $0.stopAndRemoveAllPollers() }.thenReturn(())
            try await mockCommunityPollerManager
                .when { $0.syncState }
                .thenReturn(CommunityPollerManagerSyncState())
            
            try await mockUserDefaults.defaultInitialSetup()
            try await mockUserDefaults.when { $0.integer(forKey: .any) }.thenReturn(0)
            dependencies.set(defaults: .standard, to: mockUserDefaults)
            
            try await mockAppGroupDefaults.defaultInitialSetup()
            try await mockAppGroupDefaults.when { $0.bool(forKey: .any) }.thenReturn(false)
            dependencies.set(defaults: .appGroup, to: mockAppGroupDefaults)
            
            try await mockNetwork.when { $0.networkStatus }.thenReturn(.singleValue(value: .connected))
            try await mockNetwork
                .when {
                    $0.send(
                        endpoint: MockEndpoint.any,
                        destination: .any,
                        body: .any,
                        category: .any,
                        requestTimeout: .any,
                        overallTimeout: .any
                    )
                }
                .thenReturn(MockNetwork.errorResponse())
            try await mockNetwork.when { $0.syncState }.thenReturn(NetworkSyncState(isSuspended: false))
            dependencies.set(singleton: .network, to: mockNetwork)
        }
        
        // MARK: - an OpenGroupManager
        describe("an OpenGroupManager") {
            beforeEach {
                _ = userGroupsInitResult
            }
            
            // MARK: -- cache data
            context("cache data") {
                // MARK: ---- defaults the time since last open to zero
                it("defaults the time since last open to zero") {
                    try await mockUserDefaults
                        .when { $0.object(forKey: UserDefaults.DateKey.lastOpen.rawValue) }
                        .thenReturn(nil)
                    
                    expect(cache.getLastSuccessfulCommunityPollTimestamp()).to(equal(0))
                }
                
                // MARK: ---- returns the time since the last poll
                it("returns the time since the last poll") {
                    try await mockUserDefaults
                        .when { $0.object(forKey: UserDefaults.DateKey.lastOpen.rawValue) }
                        .thenReturn(Date(timeIntervalSince1970: 1234567880))
                    dependencies.dateNow = Date(timeIntervalSince1970: 1234567890)
                    
                    expect(cache.getLastSuccessfulCommunityPollTimestamp())
                        .to(equal(1234567880))
                }
                
                // MARK: ---- caches the time since the last poll in memory
                it("caches the time since the last poll in memory") {
                    try await mockUserDefaults
                        .when { $0.object(forKey: UserDefaults.DateKey.lastOpen.rawValue) }
                        .thenReturn(Date(timeIntervalSince1970: 1234567770))
                    dependencies.dateNow = Date(timeIntervalSince1970: 1234567780)
                    
                    expect(cache.getLastSuccessfulCommunityPollTimestamp())
                        .to(equal(1234567770))
                    
                    try await mockUserDefaults
                        .when { $0.object(forKey: UserDefaults.DateKey.lastOpen.rawValue) }
                        .thenReturn(Date(timeIntervalSince1970: 1234567890))
                 
                    // Cached value shouldn't have been updated
                    expect(cache.getLastSuccessfulCommunityPollTimestamp())
                        .to(equal(1234567770))
                }
                
                // MARK: ---- updates the time since the last poll in user defaults
                it("updates the time since the last poll in user defaults") {
                    cache.setLastSuccessfulCommunityPollTimestamp(12345)
                    
                    await mockUserDefaults
                        .verify {
                            $0.set(
                                Date(timeIntervalSince1970: 12345),
                                forKey: UserDefaults.DateKey.lastOpen.rawValue
                            )
                        }
                        .wasCalled(exactly: 1)
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
                        try await mockCommunityPollerManager
                            .when { await $0.syncState }
                            .thenReturn(CommunityPollerManagerSyncState(
                                serversBeingPolled: ["http://127.0.0.1"]
                            ))
                    }
                    
                    // MARK: ------ for the no-scheme variant
                    context("for the no-scheme variant") {
                        // MARK: -------- returns true when no scheme is provided
                        it("returns true when no scheme is provided") {
                            expect(
                                mockStorage.read { db -> Bool in
                                    openGroupManager.hasExistingOpenGroup(
                                        db,
                                        roomToken: "testRoom",
                                        server: "http://127.0.0.1",
                                        publicKey: TestConstants.serverPublicKey
                                    )
                                }
                            ).to(beTrue())
                        }
                        
                        // MARK: -------- returns true when a http scheme is provided
                        it("returns true when a http scheme is provided") {
                            expect(
                                mockStorage.read { db -> Bool in
                                    openGroupManager.hasExistingOpenGroup(
                                        db,
                                        roomToken: "testRoom",
                                        server: "http://127.0.0.1",
                                        publicKey: TestConstants.serverPublicKey
                                    )
                                }
                            ).to(beTrue())
                        }
                        
                        // MARK: -------- returns true when a https scheme is provided
                        it("returns true when a https scheme is provided") {
                            expect(
                                mockStorage.read { db -> Bool in
                                    openGroupManager.hasExistingOpenGroup(
                                        db,
                                        roomToken: "testRoom",
                                        server: "http://127.0.0.1",
                                        publicKey: TestConstants.serverPublicKey
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
                                    openGroupManager.hasExistingOpenGroup(
                                        db,
                                        roomToken: "testRoom",
                                        server: "http://127.0.0.1",
                                        publicKey: TestConstants.serverPublicKey
                                    )
                                }
                            ).to(beTrue())
                        }
                        
                        // MARK: -------- returns true when a http scheme is provided
                        it("returns true when a http scheme is provided") {
                            expect(
                                mockStorage.read { db -> Bool in
                                    openGroupManager.hasExistingOpenGroup(
                                        db,
                                        roomToken: "testRoom",
                                        server: "http://127.0.0.1",
                                        publicKey: TestConstants.serverPublicKey
                                    )
                                }
                            ).to(beTrue())
                        }
                        
                        // MARK: -------- returns true when a https scheme is provided
                        it("returns true when a https scheme is provided") {
                            expect(
                                mockStorage.read { db -> Bool in
                                    openGroupManager.hasExistingOpenGroup(
                                        db,
                                        roomToken: "testRoom",
                                        server: "http://127.0.0.1",
                                        publicKey: TestConstants.serverPublicKey
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
                                    openGroupManager.hasExistingOpenGroup(
                                        db,
                                        roomToken: "testRoom",
                                        server: "http://127.0.0.1",
                                        publicKey: TestConstants.serverPublicKey
                                    )
                                }
                            ).to(beTrue())
                        }
                        
                        // MARK: -------- returns true when a http scheme is provided
                        it("returns true when a http scheme is provided") {
                            expect(
                                mockStorage.read { db -> Bool in
                                    openGroupManager.hasExistingOpenGroup(
                                        db,
                                        roomToken: "testRoom",
                                        server: "http://127.0.0.1",
                                        publicKey: TestConstants.serverPublicKey
                                    )
                                }
                            ).to(beTrue())
                        }
                        
                        // MARK: -------- returns true when a https scheme is provided
                        it("returns true when a https scheme is provided") {
                            expect(
                                mockStorage.read { db -> Bool in
                                    openGroupManager.hasExistingOpenGroup(
                                        db,
                                        roomToken: "testRoom",
                                        server: "http://127.0.0.1",
                                        publicKey: TestConstants.serverPublicKey
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
                        try await mockCommunityPollerManager
                            .when { await $0.serversBeingPolled }
                            .thenReturn(["http://116.203.70.33"])
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
                                openGroupManager.hasExistingOpenGroup(
                                    db,
                                    roomToken: "testRoom",
                                    server: "http://open.getsession.org",
                                    publicKey: TestConstants.serverPublicKey
                                )
                            }
                        ).to(beTrue())
                    }
                }
                
                // MARK: ---- when given the default server and there is a cached poller for the legacy DNS host
                context("when given the default server and there is a cached poller for the legacy DNS host") {
                    // MARK: ------ returns true
                    it("returns true") {
                        try await mockCommunityPollerManager
                            .when { await $0.serversBeingPolled }
                            .thenReturn(["http://open.getsession.org"])
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
                                openGroupManager.hasExistingOpenGroup(
                                    db,
                                    roomToken: "testRoom",
                                    server: "http://116.203.70.33",
                                    publicKey: TestConstants.serverPublicKey
                                )
                            }
                        ).to(beTrue())
                    }
                }
                
                // MARK: ---- returns false when given an invalid server
                it("returns false when given an invalid server") {
                    expect(
                        mockStorage.read { db -> Bool in
                            openGroupManager.hasExistingOpenGroup(
                                db,
                                roomToken: "testRoom",
                                server: "%%%",
                                publicKey: TestConstants.serverPublicKey
                            )
                        }
                    ).to(beFalse())
                }
                
                // MARK: ---- returns false if there is not a poller for the server in the cache
                it("returns false if there is not a poller for the server in the cache") {
                    try await mockCommunityPollerManager
                        .when { await $0.serversBeingPolled }
                        .thenReturn([])
                    
                    expect(
                        mockStorage.read { db -> Bool in
                            openGroupManager.hasExistingOpenGroup(
                                db,
                                roomToken: "testRoom",
                                server: "http://127.0.0.1",
                                publicKey: TestConstants.serverPublicKey
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
                            openGroupManager.hasExistingOpenGroup(
                                db,
                                roomToken: "testRoom",
                                server: "http://127.0.0.1",
                                publicKey: TestConstants.serverPublicKey
                            )
                        }
                    ).to(beFalse())
                }
            }
        }
        
        // MARK: - an OpenGroupManager
        describe("an OpenGroupManager") {
            // MARK: -- when adding
            context("when adding") {
                beforeEach {
                    mockStorage.write { db in
                        try OpenGroup.deleteAll(db)
                    }
                    
                    try await mockNetwork
                        .when {
                            $0.send(
                                endpoint: MockEndpoint.any,
                                destination: .any,
                                body: .any,
                                category: .any,
                                requestTimeout: .any,
                                overallTimeout: .any
                            )
                        }
                        .thenReturn(Network.BatchResponse.mockCapabilitiesAndRoomResponse)
                    
                    try await mockUserDefaults
                        .when { $0.object(forKey: UserDefaults.DateKey.lastOpen.rawValue) }
                        .thenReturn(Date(timeIntervalSince1970: 1234567890))
                }
                
                // MARK: ---- stores the open group server
                it("stores the open group server") {
                    mockStorage
                        .writePublisher { db -> Bool in
                            openGroupManager.add(
                                db,
                                roomToken: "testRoom",
                                server: "http://127.0.0.1",
                                publicKey: TestConstants.serverPublicKey,
                                forceVisible: false
                            )
                        }
                        .flatMap { successfullyAddedGroup in
                            openGroupManager.performInitialRequestsAfterAdd(
                                queue: DispatchQueue.main,
                                successfullyAddedGroup: successfullyAddedGroup,
                                roomToken: "testRoom",
                                server: "http://127.0.0.1",
                                publicKey: TestConstants.serverPublicKey
                            )
                        }
                        .sinkAndStore(in: &disposables)
                    
                    expect(
                        mockStorage.read { db in
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
                        .writePublisher { db -> Bool in
                            openGroupManager.add(
                                db,
                                roomToken: "testRoom",
                                server: "http://127.0.0.1",
                                publicKey: TestConstants.serverPublicKey,
                                forceVisible: false
                            )
                        }
                        .flatMap { successfullyAddedGroup in
                            openGroupManager.performInitialRequestsAfterAdd(
                                queue: DispatchQueue.main,
                                successfullyAddedGroup: successfullyAddedGroup,
                                roomToken: "testRoom",
                                server: "http://127.0.0.1",
                                publicKey: TestConstants.serverPublicKey
                            )
                        }
                        .sinkAndStore(in: &disposables)
                    
                    await mockCommunityPollerManager
                        .verify {
                            await $0.getOrCreatePoller(
                                for: CommunityPoller.Info(
                                    server: "http://127.0.0.1",
                                    pollFailureCount: 0
                                )
                            )
                        }
                        .wasCalled(timeout: .milliseconds(100))
                    await mockPoller.verify { await $0.startIfNeeded() }.wasCalled()
                }
                
                // MARK: ---- an existing room
                context("an existing room") {
                    beforeEach {
                        try await mockCommunityPollerManager
                            .when { await $0.serversBeingPolled }
                            .thenReturn(["http://127.0.0.1"])
                        mockStorage.write { db in
                            try testOpenGroup.insert(db)
                        }
                    }
                    
                    // MARK: ------ does not reset the sequence number or update the public key
                    it("does not reset the sequence number or update the public key") {
                        mockStorage
                            .writePublisher { db -> Bool in
                                openGroupManager.add(
                                    db,
                                    roomToken: "testRoom",
                                    server: "http://127.0.0.1",
                                    publicKey: TestConstants.serverPublicKey
                                        .replacingOccurrences(of: "c3", with: "00")
                                        .replacingOccurrences(of: "b3", with: "00"),
                                    forceVisible: false
                                )
                            }
                            .flatMap { successfullyAddedGroup in
                                openGroupManager.performInitialRequestsAfterAdd(
                                    queue: DispatchQueue.main,
                                    successfullyAddedGroup: successfullyAddedGroup,
                                    roomToken: "testRoom",
                                    server: "http://127.0.0.1",
                                    publicKey: TestConstants.serverPublicKey
                                        .replacingOccurrences(of: "c3", with: "00")
                                        .replacingOccurrences(of: "b3", with: "00")
                                )
                            }
                            .sinkAndStore(in: &disposables)
                        
                        expect(
                            mockStorage.read { db in
                                try OpenGroup
                                    .select(.sequenceNumber)
                                    .asRequest(of: Int64.self)
                                    .fetchOne(db)
                            }
                        ).to(equal(5))
                        expect(
                            mockStorage.read { db in
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
                        try await mockNetwork
                            .when {
                                $0.send(
                                    endpoint: MockEndpoint.any,
                                    destination: .any,
                                    body: .any,
                                    category: .any,
                                    requestTimeout: .any,
                                    overallTimeout: .any
                                )
                            }
                            .thenReturn(MockNetwork.response(data: Data()))
                        
                        try await mockUserDefaults
                            .when { $0.object(forKey: UserDefaults.DateKey.lastOpen.rawValue) }
                            .thenReturn(Date(timeIntervalSince1970: 1234567890))
                    }
                
                    // MARK: ------ fails with the error
                    it("fails with the error") {
                        var error: Error?
                        
                        mockStorage
                            .writePublisher { db -> Bool in
                                openGroupManager.add(
                                    db,
                                    roomToken: "testRoom",
                                    server: "http://127.0.0.1",
                                    publicKey: TestConstants.serverPublicKey,
                                    forceVisible: false
                                )
                            }
                            .flatMap { successfullyAddedGroup in
                                openGroupManager.performInitialRequestsAfterAdd(
                                    queue: DispatchQueue.main,
                                    successfullyAddedGroup: successfullyAddedGroup,
                                    roomToken: "testRoom",
                                    server: "http://127.0.0.1",
                                    publicKey: TestConstants.serverPublicKey
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
                        try Interaction.deleteWhere(db, .deleteAll)
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
                        try openGroupManager.delete(
                            db,
                            openGroupId: OpenGroup.idFor(roomToken: "testRoom", server: "http://127.0.0.1"),
                            skipLibSessionUpdate: true
                        )
                    }
                    
                    expect(mockStorage.read { db in try Interaction.fetchCount(db) })
                        .to(equal(0))
                }
                
                // MARK: ---- removes the given thread
                it("removes the given thread") {
                    mockStorage.write { db in
                        try openGroupManager.delete(
                            db,
                            openGroupId: OpenGroup.idFor(roomToken: "testRoom", server: "http://127.0.0.1"),
                            skipLibSessionUpdate: true
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
                            try openGroupManager.delete(
                                db,
                                openGroupId: OpenGroup.idFor(roomToken: "testRoom", server: "http://127.0.0.1"),
                                skipLibSessionUpdate: true
                            )
                        }
                        
                        await mockCommunityPollerManager
                            .verify { await $0.stopAndRemovePoller(for: "http://127.0.0.1") }
                            .wasCalled()
                    }
                    
                    // MARK: ------ removes the open group
                    it("removes the open group") {
                        mockStorage.write { db in
                            try openGroupManager.delete(
                                db,
                                openGroupId: OpenGroup.idFor(roomToken: "testRoom", server: "http://127.0.0.1"),
                                skipLibSessionUpdate: true
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
                            try openGroupManager.delete(
                                db,
                                openGroupId: OpenGroup.idFor(roomToken: "testRoom", server: "http://127.0.0.1"),
                                skipLibSessionUpdate: true
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
                            try openGroupManager.delete(
                                db,
                                openGroupId: OpenGroup.idFor(roomToken: "testRoom", server: OpenGroupAPI.defaultServer),
                                skipLibSessionUpdate: true
                            )
                        }
                        
                        expect(mockStorage.read { db in try OpenGroup.fetchCount(db) })
                            .to(equal(2))
                    }
                    
                    // MARK: ------ deactivates the open group
                    it("deactivates the open group") {
                        mockStorage.write { db in
                            try openGroupManager.delete(
                                db,
                                openGroupId: OpenGroup.idFor(roomToken: "testRoom", server: OpenGroupAPI.defaultServer),
                                skipLibSessionUpdate: true
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
            // MARK: -- when handling room poll info
            context("when handling room poll info") {
                beforeEach {
                    mockStorage.write { db in
                        try OpenGroup.deleteAll(db)
                        
                        try testOpenGroup.insert(db)
                    }
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
                        )
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
                
                // MARK: ---- does not schedule the displayPictureDownload job if there is no image
                it("does not schedule the displayPictureDownload job if there is no image") {
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
                    
                    expect(mockJobRunner)
                        .toNot(call(matchingParameters: .all) {
                            $0.add(
                                .any,
                                job: Job(
                                    variant: .displayPictureDownload,
                                    shouldBeUnique: true,
                                    details: DisplayPictureDownloadJob.Details(
                                        target: .community(
                                            imageId: "12",
                                            roomToken: "testRoom",
                                            server: "testServer"
                                        ),
                                        timestamp: 1234567890
                                    )
                                ),
                                dependantJob: nil,
                                canStartJob: true
                            )
                        })
                }
                
                // MARK: ---- schedules the displayPictureDownload job if there is an image
                it("schedules the displayPictureDownload job if there is an image") {
                    mockStorage.write { db in
                        try OpenGroup.deleteAll(db)
                        try OpenGroup(
                            server: "http://127.0.0.1",
                            roomToken: "testRoom",
                            publicKey: TestConstants.publicKey,
                            isActive: true,
                            name: "Test",
                            imageId: "12",
                            userCount: 0,
                            infoUpdates: 10
                        ).insert(db)
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
                    
                    expect(mockJobRunner)
                        .to(call(matchingParameters: .all) {
                            $0.add(
                                .any,
                                job: Job(
                                    variant: .displayPictureDownload,
                                    shouldBeUnique: true,
                                    details: DisplayPictureDownloadJob.Details(
                                        target: .community(
                                            imageId: "12",
                                            roomToken: "testRoom",
                                            server: "http://127.0.0.1"
                                        ),
                                        timestamp: 1234567890
                                    )
                                ),
                                dependantJob: nil,
                                canStartJob: true
                            )
                        })
                }
                
                // MARK: ---- and updating the moderator list
                context("and updating the moderator list") {
                    // MARK: ------ successfully updates
                    it("successfully updates") {
                        testPollInfo = OpenGroupAPI.RoomPollInfo.mock.with(
                            token: "testRoom",
                            activeUsers: 10,
                            details: OpenGroupAPI.Room.mock.with(
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
                                roleStatus: .accepted,
                                isHidden: false
                            )
                        ))
                    }
                    
                    // MARK: ------ updates for hidden moderators
                    it("updates for hidden moderators") {
                        testPollInfo = OpenGroupAPI.RoomPollInfo.mock.with(
                            token: "testRoom",
                            activeUsers: 10,
                            details: OpenGroupAPI.Room.mock.with(
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
                                roleStatus: .accepted,
                                isHidden: true
                            )
                        ))
                    }
                    
                    // MARK: ------ does not insert mods if no moderators are provided
                    it("does not insert mods if no moderators are provided") {
                        testPollInfo = OpenGroupAPI.RoomPollInfo.mock.with(
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
                        testPollInfo = OpenGroupAPI.RoomPollInfo.mock.with(
                            token: "testRoom",
                            activeUsers: 10,
                            details: OpenGroupAPI.Room.mock.with(
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
                                roleStatus: .accepted,
                                isHidden: false
                            )
                        ))
                    }
                    
                    // MARK: ------ updates for hidden admins
                    it("updates for hidden admins") {
                        testPollInfo = OpenGroupAPI.RoomPollInfo.mock.with(
                            token: "testRoom",
                            activeUsers: 10,
                            details: OpenGroupAPI.Room.mock.with(
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
                                roleStatus: .accepted,
                                isHidden: true
                            )
                        ))
                    }
                    
                    // MARK: ------ does not insert an admin if no admins are provided
                    it("does not insert an admin if no admins are provided") {
                        testPollInfo = OpenGroupAPI.RoomPollInfo.mock.with(
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
                        mockStorage.write { db in
                            try OpenGroup
                                .updateAll(db, OpenGroup.Columns.displayPictureOriginalUrl.set(to: nil))
                        }
                    }
                    
                    // MARK: ------ schedules a download for the room image
                    it("schedules a download for the room image") {
                        testPollInfo = OpenGroupAPI.RoomPollInfo.mock.with(
                            token: "testRoom",
                            activeUsers: 10,
                            details: OpenGroupAPI.Room.mock.with(
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
                        expect(mockJobRunner)
                            .to(call(.exactly(times: 1), matchingParameters: .all) {
                                $0.add(
                                    .any,
                                    job: Job(
                                        variant: .displayPictureDownload,
                                        shouldBeUnique: true,
                                        details: DisplayPictureDownloadJob.Details(
                                            target: .community(
                                                imageId: "10",
                                                roomToken: "testRoom",
                                                server: "http://127.0.0.1"
                                            ),
                                            timestamp: 1234567890
                                        )
                                    ),
                                    dependantJob: nil,
                                    canStartJob: true
                                )
                            })
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
                                userCount: 0,
                                infoUpdates: 10,
                                displayPictureOriginalUrl: "http://127.0.0.1/room/testRoom/12"
                            ).insert(db)
                        }
                        
                        testPollInfo = OpenGroupAPI.RoomPollInfo.mock.with(
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
                        
                        expect(
                            mockStorage.read { db -> String? in
                                try OpenGroup
                                    .select(.imageId)
                                    .asRequest(of: String.self)
                                    .fetchOne(db)
                            }
                        ).to(equal("12"))
                        expect(
                            mockStorage.read { db -> String? in
                                try OpenGroup
                                    .select(.displayPictureOriginalUrl)
                                    .asRequest(of: String.self)
                                    .fetchOne(db)
                            }
                        ).toNot(beNil())
                        expect(mockJobRunner).toNot(call { $0.add(.any, job: .any, dependantJob: .any, canStartJob: .any) })
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
                                userCount: 0,
                                infoUpdates: 10,
                                displayPictureOriginalUrl: "http://127.0.0.1/room/testRoom/10"
                            ).insert(db)
                        }
                        
                        testPollInfo = OpenGroupAPI.RoomPollInfo.mock.with(
                            token: "testRoom",
                            activeUsers: 10,
                            details: OpenGroupAPI.Room.mock.with(
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
                            mockStorage.read { db -> String? in
                                try OpenGroup
                                    .select(.displayPictureOriginalUrl)
                                    .asRequest(of: String.self)
                                    .fetchOne(db)
                            }
                        ).toNot(beNil())
                        expect(mockJobRunner)
                            .to(call(.exactly(times: 1), matchingParameters: .all) {
                                $0.add(
                                    .any,
                                    job: Job(
                                        variant: .displayPictureDownload,
                                        shouldBeUnique: true,
                                        details: DisplayPictureDownloadJob.Details(
                                            target: .community(
                                                imageId: "10",
                                                roomToken: "testRoom",
                                                server: "http://127.0.0.1"
                                            ),
                                            timestamp: 1234567890
                                        )
                                    ),
                                    dependantJob: nil,
                                    canStartJob: true
                                )
                            })
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
                                using: dependencies
                            )
                        }
                        
                        expect(
                            mockStorage.read { db -> String? in
                                try OpenGroup
                                    .select(.displayPictureOriginalUrl)
                                    .asRequest(of: String.self)
                                    .fetchOne(db)
                            }
                        ).to(beNil())
                    }
                }
            }
        }
        
        // MARK: - an OpenGroupManager
        describe("an OpenGroupManager") {
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
                        try Interaction.deleteWhere(db, .deleteAll)
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
                        try Interaction.deleteWhere(db, .deleteAll)
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
                    try await mockCrypto
                        .when {
                            $0.generate(
                                .plaintextWithSessionBlindingProtocol(
                                    ciphertext: .any,
                                    senderId: .any,
                                    recipientId: .any,
                                    serverPublicKey: .any
                                )
                            )
                        }
                        .thenReturn((
                            plaintext: Data(base64Encoded:"Cg0KC1Rlc3RNZXNzYWdlcNCI7I/3Iw==")! +
                            Data([0x80]) +
                            Data([UInt8](repeating: 0, count: 32)),
                            senderSessionIdHex: "05\(TestConstants.publicKey)"
                        ))
                    try await mockCrypto
                        .when { $0.generate(.x25519(ed25519Pubkey: .any)) }
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
                        try await mockCrypto
                            .when { $0.verify(.sessionId(.any, matchesBlindedId: .any, serverPublicKey: .any)) }
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
                        try await mockCrypto
                            .when {
                                $0.generate(
                                    .plaintextWithSessionBlindingProtocol(
                                        ciphertext: .any,
                                        senderId: .any,
                                        recipientId: .any,
                                        serverPublicKey: .any
                                    )
                                )
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
                        try await mockCrypto
                            .when { $0.verify(.sessionId(.any, matchesBlindedId: .any, serverPublicKey: .any)) }
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
                                blindedId: "15\(TestConstants.blind15PublicKey)",
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
                                try SessionThread.fetchOne(db, id: "15\(TestConstants.blind15PublicKey)")
                            }
                        ).toNot(beNil())
                    }
                    
                    // MARK: ------ ignores a message with invalid data
                    it("ignores a message with invalid data") {
                        try await mockCrypto
                            .when {
                                $0.generate(
                                    .plaintextWithSessionBlindingProtocol(
                                        ciphertext: .any,
                                        senderId: .any,
                                        recipientId: .any,
                                        serverPublicKey: .any
                                    )
                                )
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
            // MARK: -- when determining if a user is a moderator or an admin
            context("when determining if a user is a moderator or an admin") {
                beforeEach {
                    mockStorage.write { db in
                        _ = try GroupMember.deleteAll(db)
                    }
                }
                
                // MARK: ---- has no moderators by default
                it("has no moderators by default") {
                    expect(
                        mockStorage.read { db in
                            openGroupManager.isUserModeratorOrAdmin(
                                db,
                                publicKey: "05\(TestConstants.publicKey)",
                                for: "testRoom",
                                on: "http://127.0.0.1",
                                currentUserSessionIds: ["05\(TestConstants.publicKey)"]
                            )
                        }
                    ).to(beFalse())
                }
                
                // MARK: ----has no admins by default
                it("has no admins by default") {
                    expect(
                        mockStorage.read { db in
                            openGroupManager.isUserModeratorOrAdmin(
                                db,
                                publicKey: "05\(TestConstants.publicKey)",
                                for: "testRoom",
                                on: "http://127.0.0.1",
                                currentUserSessionIds: ["05\(TestConstants.publicKey)"]
                            )
                        }
                    ).to(beFalse())
                }
                
                // MARK: ---- returns true if the key is in the moderator set
                it("returns true if the key is in the moderator set") {
                    mockStorage.write { db in
                        try GroupMember(
                            groupId: OpenGroup.idFor(roomToken: "testRoom", server: "http://127.0.0.1"),
                            profileId: "05\(TestConstants.publicKey.replacingOccurrences(of: "1", with: "2"))",
                            role: .moderator,
                            roleStatus: .accepted,
                            isHidden: false
                        ).insert(db)
                    }
                    
                    expect(
                        mockStorage.read { db in
                            openGroupManager.isUserModeratorOrAdmin(
                                db,
                                publicKey: "05\(TestConstants.publicKey.replacingOccurrences(of: "1", with: "2"))",
                                for: "testRoom",
                                on: "http://127.0.0.1",
                                currentUserSessionIds: ["05\(TestConstants.publicKey)"]
                            )
                        }
                    ).to(beTrue())
                }
                
                // MARK: ---- returns true if the key is in the admin set
                it("returns true if the key is in the admin set") {
                    mockStorage.write { db in
                        try GroupMember(
                            groupId: OpenGroup.idFor(roomToken: "testRoom", server: "http://127.0.0.1"),
                            profileId: "05\(TestConstants.publicKey.replacingOccurrences(of: "1", with: "2"))",
                            role: .admin,
                            roleStatus: .accepted,
                            isHidden: false
                        ).insert(db)
                    }
                    
                    expect(
                        mockStorage.read { db in
                            openGroupManager.isUserModeratorOrAdmin(
                                db,
                                publicKey: "05\(TestConstants.publicKey.replacingOccurrences(of: "1", with: "2"))",
                                for: "testRoom",
                                on: "http://127.0.0.1",
                                currentUserSessionIds: ["05\(TestConstants.publicKey)"]
                            )
                        }
                    ).to(beTrue())
                }
                
                // MARK: ---- returns true if the moderator is hidden
                it("returns true if the moderator is hidden") {
                    mockStorage.write { db in
                        try GroupMember(
                            groupId: OpenGroup.idFor(roomToken: "testRoom", server: "http://127.0.0.1"),
                            profileId: "05\(TestConstants.publicKey.replacingOccurrences(of: "1", with: "2"))",
                            role: .moderator,
                            roleStatus: .accepted,
                            isHidden: true
                        ).insert(db)
                    }
                    
                    expect(
                        mockStorage.read { db in
                            openGroupManager.isUserModeratorOrAdmin(
                                db,
                                publicKey: "05\(TestConstants.publicKey.replacingOccurrences(of: "1", with: "2"))",
                                for: "testRoom",
                                on: "http://127.0.0.1",
                                currentUserSessionIds: ["05\(TestConstants.publicKey)"]
                            )
                        }
                    ).to(beTrue())
                }
                
                // MARK: ---- returns true if the admin is hidden
                it("returns true if the admin is hidden") {
                    mockStorage.write { db in
                        try GroupMember(
                            groupId: OpenGroup.idFor(roomToken: "testRoom", server: "http://127.0.0.1"),
                            profileId: "05\(TestConstants.publicKey.replacingOccurrences(of: "1", with: "2"))",
                            role: .admin,
                            roleStatus: .accepted,
                            isHidden: true
                        ).insert(db)
                    }
                    
                    expect(
                        mockStorage.read { db in
                            openGroupManager.isUserModeratorOrAdmin(
                                db,
                                publicKey: "05\(TestConstants.publicKey.replacingOccurrences(of: "1", with: "2"))",
                                for: "testRoom",
                                on: "http://127.0.0.1",
                                currentUserSessionIds: ["05\(TestConstants.publicKey)"]
                            )
                        }
                    ).to(beTrue())
                }
                
                // MARK: ---- returns false if the key is not a valid session id
                it("returns false if the key is not a valid session id") {
                    expect(
                        mockStorage.read { db in
                            openGroupManager.isUserModeratorOrAdmin(
                                db,
                                publicKey: "InvalidValue",
                                for: "testRoom",
                                on: "http://127.0.0.1",
                                currentUserSessionIds: ["05\(TestConstants.publicKey)"]
                            )
                        }
                    ).to(beFalse())
                }
                
                // MARK: ---- and the key belongs to the current user
                context("and the key belongs to the current user") {
                    // MARK: ------ matches a blinded key
                    it("matches a blinded key ") {
                        mockStorage.write { db in
                            try GroupMember(
                                groupId: OpenGroup.idFor(roomToken: "testRoom", server: "http://127.0.0.1"),
                                profileId: "15\(TestConstants.publicKey.replacingOccurrences(of: "1", with: "2"))",
                                role: .admin,
                                roleStatus: .accepted,
                                isHidden: true
                            ).insert(db)
                        }
                        
                        expect(
                            mockStorage.read { db in
                                openGroupManager.isUserModeratorOrAdmin(
                                    db,
                                    publicKey: "05\(TestConstants.publicKey)",
                                    for: "testRoom",
                                    on: "http://127.0.0.1",
                                    currentUserSessionIds: [
                                        "05\(TestConstants.publicKey)",
                                        "15\(TestConstants.publicKey.replacingOccurrences(of: "1", with: "2"))"
                                    ]
                                )
                            }
                        ).to(beTrue())
                    }
                    
                    // MARK: ------ generates and unblinded key if the key belongs to the current user
                    it("generates and unblinded key if the key belongs to the current user") {
                        try await mockGeneralCache.when { $0.ed25519Seed }.thenReturn([4, 5, 6])
                        mockStorage.read { db in
                            openGroupManager.isUserModeratorOrAdmin(
                                db,
                                publicKey: "05\(TestConstants.publicKey)",
                                for: "testRoom",
                                on: "http://127.0.0.1",
                                currentUserSessionIds: ["05\(TestConstants.publicKey)"]
                            )
                        }
                        
                        await mockCrypto
                            .verify { $0.generate(.ed25519KeyPair(seed: [4, 5, 6])) }
                            .wasCalled(exactly: 1)
                    }
                }
            }
            
            // MARK: -- when accessing the default rooms publisher
            context("when accessing the default rooms publisher") {
                // MARK: ---- starts a job to retrieve the default rooms if we have none
                it("starts a job to retrieve the default rooms if we have none") {
                    try await mockAppGroupDefaults
                        .when { $0.bool(forKey: UserDefaults.BoolKey.isMainAppActive.rawValue) }
                        .thenReturn(true)
                    mockStorage.write { db in
                        try OpenGroup(
                            server: OpenGroupAPI.defaultServer,
                            roomToken: "",
                            publicKey: OpenGroupAPI.defaultServerPublicKey,
                            isActive: false,
                            name: "TestExisting",
                            userCount: 0,
                            infoUpdates: 0
                        )
                        .insert(db)
                    }
                    let expectedRequest: Network.PreparedRequest<OpenGroupAPI.CapabilitiesAndRoomsResponse>! = mockStorage.read { db in
                        try OpenGroupAPI.preparedCapabilitiesAndRooms(
                            authMethod: Authentication.community(
                                info: LibSession.OpenGroupCapabilityInfo(
                                    roomToken: "",
                                    server: OpenGroupAPI.defaultServer,
                                    publicKey: OpenGroupAPI.defaultServerPublicKey,
                                    capabilities: []
                                ),
                                forceBlinded: false
                            ),
                            using: dependencies
                        )
                    }
                    cache.defaultRoomsPublisher.sinkUntilComplete()
                    
                    await mockNetwork
                        .verify {
                            $0.send(
                                endpoint: OpenGroupAPI.Endpoint.sequence,
                                destination: expectedRequest.destination,
                                body: expectedRequest.body,
                                category: .standard,
                                requestTimeout: expectedRequest.requestTimeout,
                                overallTimeout: expectedRequest.overallTimeout
                            )
                        }
                        .wasCalled(exactly: 1)
                }
                
                // MARK: ---- does not start a job to retrieve the default rooms if we already have rooms
                it("does not start a job to retrieve the default rooms if we already have rooms") {
                    try await mockAppGroupDefaults
                        .when { $0.bool(forKey: UserDefaults.BoolKey.isMainAppActive.rawValue) }
                        .thenReturn(true)
                    cache.setDefaultRoomInfo([(room: OpenGroupAPI.Room.mock, openGroup: OpenGroup.mock)])
                    cache.defaultRoomsPublisher.sinkUntilComplete()
                    
                    await mockNetwork
                        .verify {
                            $0.send(
                                endpoint: MockEndpoint.any,
                                destination: .any,
                                body: .any,
                                category: .any,
                                requestTimeout: .any,
                                overallTimeout: .any
                            )
                        }
                        .wasNotCalled()
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
        details: OpenGroupAPI.Room? = .mock
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

extension OpenGroup: @retroactive Mocked {
    public static var any: OpenGroup = OpenGroup(
        server: .any,
        roomToken: .any,
        publicKey: .any,
        isActive: .any,
        name: .any,
        userCount: .any,
        infoUpdates: .any
    )
    public static var mock: OpenGroup = OpenGroup(
        server: "testserver",
        roomToken: "testRoom",
        publicKey: TestConstants.serverPublicKey,
        isActive: true,
        name: "testRoom",
        userCount: 0,
        infoUpdates: 0
    )
}

extension OpenGroupAPI.Capabilities: @retroactive Mocked {
    public static var any: OpenGroupAPI.Capabilities = OpenGroupAPI.Capabilities(capabilities: .any, missing: .any)
    public static var mock: OpenGroupAPI.Capabilities = OpenGroupAPI.Capabilities(capabilities: [], missing: nil)
}

extension OpenGroupAPI.Room: @retroactive Mocked {
    public static var any:  OpenGroupAPI.Room = OpenGroupAPI.Room(
        token: .any,
        name: .any,
        roomDescription: .any,
        infoUpdates: .any,
        messageSequence: .any,
        created: .any,
        activeUsers: .any,
        activeUsersCutoff: .any,
        imageId: .any,
        pinnedMessages: .any,
        admin: .any,
        globalAdmin: .any,
        admins: .any,
        hiddenAdmins: .any,
        moderator: .any,
        globalModerator: .any,
        moderators: .any,
        hiddenModerators: .any,
        read: .any,
        defaultRead: .any,
        defaultAccessible: .any,
        write: .any,
        defaultWrite: .any,
        upload: .any,
        defaultUpload: .any
    )

    public static var mock: OpenGroupAPI.Room = OpenGroupAPI.Room(
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

extension OpenGroupAPI.RoomPollInfo: @retroactive Mocked {
    public static var any: OpenGroupAPI.RoomPollInfo = OpenGroupAPI.RoomPollInfo(
        token: .any,
        activeUsers: .any,
        admin: .any,
        globalAdmin: .any,
        moderator: .any,
        globalModerator: .any,
        read: .any,
        defaultRead: .any,
        defaultAccessible: .any,
        write: .any,
        defaultWrite: .any,
        upload: .any,
        defaultUpload: .any,
        details: .any
    )
    public static var mock: OpenGroupAPI.RoomPollInfo = OpenGroupAPI.RoomPollInfo(
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
        details: .mock
    )
}

extension OpenGroupAPI.Message: @retroactive Mocked {
    public static var any: OpenGroupAPI.Message = OpenGroupAPI.Message(
        id: .any,
        sender: .any,
        posted: .any,
        edited: .any,
        deleted: .any,
        seqNo: .any,
        whisper: .any,
        whisperMods: .any,
        whisperTo: .any,
        base64EncodedData: .any,
        base64EncodedSignature: .any,
        reactions: .any
    )
    public static var mock: OpenGroupAPI.Message = OpenGroupAPI.Message(
        id: 100,
        sender: TestConstants.blind15PublicKey,
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

extension OpenGroupAPI.SendDirectMessageResponse: @retroactive Mocked {
    public static var any: OpenGroupAPI.SendDirectMessageResponse = OpenGroupAPI.SendDirectMessageResponse(
        id: .any,
        sender: .any,
        recipient: .any,
        posted: .any,
        expires: .any
    )
    public static var mock: OpenGroupAPI.SendDirectMessageResponse = OpenGroupAPI.SendDirectMessageResponse(
        id: 1,
        sender: TestConstants.blind15PublicKey,
        recipient: "testRecipient",
        posted: 1122,
        expires: 2233
    )
}

extension OpenGroupAPI.DirectMessage: @retroactive Mocked {
    public static var any: OpenGroupAPI.DirectMessage = OpenGroupAPI.DirectMessage(
        id: .any,
        sender: .any,
        recipient: .any,
        posted: .any,
        expires: .any,
        base64EncodedMessage: .any
    )
    public static var mock: OpenGroupAPI.DirectMessage = OpenGroupAPI.DirectMessage(
        id: 101,
        sender: TestConstants.blind15PublicKey,
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
