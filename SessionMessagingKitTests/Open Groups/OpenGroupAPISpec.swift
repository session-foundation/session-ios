// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import SessionSnodeKit
import SessionUtilitiesKit

import Quick
import Nimble

@testable import SessionMessagingKit

class OpenGroupAPISpec: QuickSpec {
    override class func spec() {
        // MARK: Configuration
        
        @TestState var dependencies: TestDependencies! = TestDependencies { dependencies in
            dependencies.dateNow = Date(timeIntervalSince1970: 1234567890)
        }
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
                
                try OpenGroup(
                    server: "testServer",
                    roomToken: "testRoom",
                    publicKey: TestConstants.publicKey,
                    isActive: true,
                    name: "Test",
                    roomDescription: nil,
                    imageId: nil,
                    userCount: 0,
                    infoUpdates: 0,
                    sequenceNumber: 0,
                    inboxLatestMessageId: 0,
                    outboxLatestMessageId: 0
                ).insert(db)
                try Capability(openGroupServer: "testserver", variant: .sogs, isMissing: false).insert(db)
            }
        )
        @TestState(singleton: .network, in: dependencies) var mockNetwork: MockNetwork! = MockNetwork()
        @TestState(singleton: .crypto, in: dependencies) var mockCrypto: MockCrypto! = MockCrypto(
            initialSetup: { crypto in
                crypto
                    .when { $0.generate(.hash(message: .any, key: .any, length: .any)) }
                    .thenReturn([])
                crypto
                    .when { $0.generate(.blinded15KeyPair(serverPublicKey: .any, ed25519SecretKey: .any)) }
                    .thenReturn(
                        KeyPair(
                            publicKey: Data(hex: TestConstants.publicKey).bytes,
                            secretKey: Data(hex: TestConstants.edSecretKey).bytes
                        )
                    )
                crypto
                    .when { $0.generate(.signatureBlind15(message: .any, serverPublicKey: .any, ed25519SecretKey: .any)) }
                    .thenReturn("TestSogsSignature".bytes)
                crypto
                    .when { $0.generate(.signature(message: .any, ed25519SecretKey: .any)) }
                    .thenReturn(Authentication.Signature.standard(signature: "TestSignature".bytes))
                crypto
                    .when { $0.generate(.signatureXed25519(data: .any, curve25519PrivateKey: .any)) }
                    .thenReturn("TestStandardSignature".bytes)
                crypto
                    .when { $0.generate(.randomBytes(16)) }
                    .thenReturn(Array(Data(base64Encoded: "pK6YRtQApl4NhECGizF0Cg==")!))
                crypto
                    .when { $0.generate(.randomBytes(24)) }
                    .thenReturn(Array(Data(base64Encoded: "pbTUizreT0sqJ2R2LloseQDyVL2RYztD")!))
            }
        )
        @TestState var disposables: [AnyCancellable]! = []
        @TestState var error: Error?
        
        // MARK: - an OpenGroupAPI
        describe("an OpenGroupAPI") {
            // MARK: -- when preparing a poll request
            context("when preparing a poll request") {
                // MARK: ---- generates the correct request
                it("generates the correct request") {
                    let preparedRequest:  Network.PreparedRequest<Network.BatchResponseMap<OpenGroupAPI.Endpoint>>? = mockStorage.read { db in
                        try OpenGroupAPI.preparedPoll(
                            db,
                            server: "testserver",
                            hasPerformedInitialPoll: false,
                            timeSinceLastPoll: 0,
                            using: dependencies
                        )
                    }
                    
                    expect(preparedRequest?.path).to(equal("/batch"))
                    expect(preparedRequest?.method.rawValue).to(equal("POST"))
                    expect(preparedRequest?.batchEndpoints.count).to(equal(3))
                    expect(preparedRequest?.batchEndpoints[test: 0].asType(OpenGroupAPI.Endpoint.self))
                        .to(equal(.capabilities))
                    expect(preparedRequest?.batchEndpoints[test: 1].asType(OpenGroupAPI.Endpoint.self))
                        .to(equal(.roomPollInfo("testRoom", 0)))
                    expect(preparedRequest?.batchEndpoints[test: 2].asType(OpenGroupAPI.Endpoint.self))
                        .to(equal(.roomMessagesRecent("testRoom")))
                }
                
                // MARK: ---- retrieves recent messages if there was no last message
                it("retrieves recent messages if there was no last message") {
                    let preparedRequest:  Network.PreparedRequest<Network.BatchResponseMap<OpenGroupAPI.Endpoint>>? = mockStorage.read { db in
                        try OpenGroupAPI.preparedPoll(
                            db,
                            server: "testserver",
                            hasPerformedInitialPoll: false,
                            timeSinceLastPoll: 0,
                            using: dependencies
                        )
                    }
                    
                    expect(preparedRequest?.batchEndpoints[test: 2].asType(OpenGroupAPI.Endpoint.self))
                        .to(equal(.roomMessagesRecent("testRoom")))
                }
                
                // MARK: ---- retrieves recent messages if there was a last message and it has not performed the initial poll and the last message was too long ago
                it("retrieves recent messages if there was a last message and it has not performed the initial poll and the last message was too long ago") {
                    mockStorage.write { db in
                        try OpenGroup
                            .updateAll(db, OpenGroup.Columns.sequenceNumber.set(to: 121))
                    }
                    
                    let preparedRequest:  Network.PreparedRequest<Network.BatchResponseMap<OpenGroupAPI.Endpoint>>? = mockStorage.read { db in
                        try OpenGroupAPI.preparedPoll(
                            db,
                            server: "testserver",
                            hasPerformedInitialPoll: false,
                            timeSinceLastPoll: (CommunityPoller.maxInactivityPeriod + 1),
                            using: dependencies
                        )
                    }
                    
                    expect(preparedRequest?.batchEndpoints[test: 2].asType(OpenGroupAPI.Endpoint.self))
                        .to(equal(.roomMessagesRecent("testRoom")))
                }
                
                // MARK: ---- retrieves recent messages if there was a last message and it has performed an initial poll but it was not too long ago
                it("retrieves recent messages if there was a last message and it has performed an initial poll but it was not too long ago") {
                    mockStorage.write { db in
                        try OpenGroup
                            .updateAll(db, OpenGroup.Columns.sequenceNumber.set(to: 122))
                    }
                    
                    let preparedRequest:  Network.PreparedRequest<Network.BatchResponseMap<OpenGroupAPI.Endpoint>>? = mockStorage.read { db in
                        try OpenGroupAPI.preparedPoll(
                            db,
                            server: "testserver",
                            hasPerformedInitialPoll: false,
                            timeSinceLastPoll: 0,
                            using: dependencies
                        )
                    }
                    
                    expect(preparedRequest?.batchEndpoints[test: 2].asType(OpenGroupAPI.Endpoint.self))
                        .to(equal(.roomMessagesSince("testRoom", seqNo: 122)))
                }
                
                // MARK: ---- retrieves recent messages if there was a last message and there has already been a poll this session
                it("retrieves recent messages if there was a last message and there has already been a poll this session") {
                    mockStorage.write { db in
                        try OpenGroup
                            .updateAll(db, OpenGroup.Columns.sequenceNumber.set(to: 123))
                    }

                    let preparedRequest:  Network.PreparedRequest<Network.BatchResponseMap<OpenGroupAPI.Endpoint>>? = mockStorage.read { db in
                        try OpenGroupAPI.preparedPoll(
                            db,
                            server: "testserver",
                            hasPerformedInitialPoll: true,
                            timeSinceLastPoll: 0,
                            using: dependencies
                        )
                    }
                    
                    expect(preparedRequest?.batchEndpoints[test: 2].asType(OpenGroupAPI.Endpoint.self))
                        .to(equal(.roomMessagesSince("testRoom", seqNo: 123)))
                }
                
                // MARK: ---- when unblinded
                context("when unblinded") {
                    beforeEach {
                        mockStorage.write { db in
                            _ = try Capability.deleteAll(db)
                            try Capability(openGroupServer: "testserver", variant: .sogs, isMissing: false).insert(db)
                        }
                    }
                
                    // MARK: ------ does not call the inbox and outbox endpoints
                    it("does not call the inbox and outbox endpoints") {
                        let preparedRequest:  Network.PreparedRequest<Network.BatchResponseMap<OpenGroupAPI.Endpoint>>? = mockStorage.read { db in
                            try OpenGroupAPI.preparedPoll(
                                db,
                                server: "testserver",
                                hasPerformedInitialPoll: false,
                                timeSinceLastPoll: 0,
                                using: dependencies
                            )
                        }
                        
                        expect(preparedRequest?.batchEndpoints as? [OpenGroupAPI.Endpoint]).toNot(contain(.inbox))
                        expect(preparedRequest?.batchEndpoints as? [OpenGroupAPI.Endpoint]).toNot(contain(.outbox))
                    }
                }
                
                // MARK: ---- when blinded and checking for message requests
                context("when blinded and checking for message requests") {
                    beforeEach {
                        mockStorage.write { db in
                            db[.checkForCommunityMessageRequests] = true
                            
                            _ = try Capability.deleteAll(db)
                            try Capability(openGroupServer: "testserver", variant: .sogs, isMissing: false).insert(db)
                            try Capability(openGroupServer: "testserver", variant: .blind, isMissing: false).insert(db)
                        }
                    }
                
                    // MARK: ------ includes the inbox and outbox endpoints
                    it("includes the inbox and outbox endpoints") {
                        let preparedRequest:  Network.PreparedRequest<Network.BatchResponseMap<OpenGroupAPI.Endpoint>>? = mockStorage.read { db in
                            try OpenGroupAPI.preparedPoll(
                                db,
                                server: "testserver",
                                hasPerformedInitialPoll: false,
                                timeSinceLastPoll: 0,
                                using: dependencies
                            )
                        }
                        
                        expect(preparedRequest?.batchEndpoints as? [OpenGroupAPI.Endpoint]).to(contain(.inbox))
                        expect(preparedRequest?.batchEndpoints as? [OpenGroupAPI.Endpoint]).to(contain(.outbox))
                    }
                    
                    // MARK: ------ retrieves recent inbox messages if there was no last message
                    it("retrieves recent inbox messages if there was no last message") {
                        let preparedRequest:  Network.PreparedRequest<Network.BatchResponseMap<OpenGroupAPI.Endpoint>>? = mockStorage.read { db in
                            try OpenGroupAPI.preparedPoll(
                                db,
                                server: "testserver",
                                hasPerformedInitialPoll: true,
                                timeSinceLastPoll: 0,
                                using: dependencies
                            )
                        }
                        
                        expect(preparedRequest?.batchEndpoints as? [OpenGroupAPI.Endpoint]).to(contain(.inbox))
                    }
                    
                    // MARK: ------ retrieves inbox messages since the last message if there was one
                    it("retrieves inbox messages since the last message if there was one") {
                        mockStorage.write { db in
                            try OpenGroup
                                .updateAll(db, OpenGroup.Columns.inboxLatestMessageId.set(to: 124))
                        }
                        
                        let preparedRequest:  Network.PreparedRequest<Network.BatchResponseMap<OpenGroupAPI.Endpoint>>? = mockStorage.read { db in
                            try OpenGroupAPI.preparedPoll(
                                db,
                                server: "testserver",
                                hasPerformedInitialPoll: true,
                                timeSinceLastPoll: 0,
                                using: dependencies
                            )
                        }
                        
                        expect(preparedRequest?.batchEndpoints as? [OpenGroupAPI.Endpoint]).to(contain(.inboxSince(id: 124)))
                    }
                    
                    // MARK: ------ retrieves recent outbox messages if there was no last message
                    it("retrieves recent outbox messages if there was no last message") {
                        let preparedRequest:  Network.PreparedRequest<Network.BatchResponseMap<OpenGroupAPI.Endpoint>>? = mockStorage.read { db in
                            try OpenGroupAPI.preparedPoll(
                                db,
                                server: "testserver",
                                hasPerformedInitialPoll: true,
                                timeSinceLastPoll: 0,
                                using: dependencies
                            )
                        }
                        
                        expect(preparedRequest?.batchEndpoints as? [OpenGroupAPI.Endpoint]).to(contain(.outbox))
                    }
                    
                    // MARK: ------ retrieves outbox messages since the last message if there was one
                    it("retrieves outbox messages since the last message if there was one") {
                        mockStorage.write { db in
                            try OpenGroup
                                .updateAll(db, OpenGroup.Columns.outboxLatestMessageId.set(to: 125))
                        }
                        
                        let preparedRequest:  Network.PreparedRequest<Network.BatchResponseMap<OpenGroupAPI.Endpoint>>? = mockStorage.read { db in
                            try OpenGroupAPI.preparedPoll(
                                db,
                                server: "testserver",
                                hasPerformedInitialPoll: true,
                                timeSinceLastPoll: 0,
                                using: dependencies
                            )
                        }
                        
                        expect(preparedRequest?.batchEndpoints as? [OpenGroupAPI.Endpoint]).to(contain(.outboxSince(id: 125)))
                    }
                }
                
                // MARK: ---- when blinded and not checking for message requests
                context("when blinded and not checking for message requests") {
                    beforeEach {
                        mockStorage.write { db in
                            db[.checkForCommunityMessageRequests] = false
                            
                            _ = try Capability.deleteAll(db)
                            try Capability(openGroupServer: "testserver", variant: .sogs, isMissing: false).insert(db)
                            try Capability(openGroupServer: "testserver", variant: .blind, isMissing: false).insert(db)
                        }
                    }
                    
                    // MARK: ------ includes the inbox and outbox endpoints
                    it("does not include the inbox endpoint") {
                        let preparedRequest:  Network.PreparedRequest<Network.BatchResponseMap<OpenGroupAPI.Endpoint>>? = mockStorage.read { db in
                            try OpenGroupAPI.preparedPoll(
                                db,
                                server: "testserver",
                                hasPerformedInitialPoll: false,
                                timeSinceLastPoll: 0,
                                using: dependencies
                            )
                        }
                        
                        expect(preparedRequest?.batchEndpoints as? [OpenGroupAPI.Endpoint]).toNot(contain(.inbox))
                    }
                    
                    // MARK: ------ does not retrieve recent inbox messages if there was no last message
                    it("does not retrieve recent inbox messages if there was no last message") {
                        let preparedRequest:  Network.PreparedRequest<Network.BatchResponseMap<OpenGroupAPI.Endpoint>>? = mockStorage.read { db in
                            try OpenGroupAPI.preparedPoll(
                                db,
                                server: "testserver",
                                hasPerformedInitialPoll: true,
                                timeSinceLastPoll: 0,
                                using: dependencies
                            )
                        }
                        
                        expect(preparedRequest?.batchEndpoints as? [OpenGroupAPI.Endpoint]).toNot(contain(.inbox))
                    }
                    
                    // MARK: ------ does not retrieve inbox messages since the last message if there was one
                    it("does not retrieve inbox messages since the last message if there was one") {
                        mockStorage.write { db in
                            try OpenGroup
                                .updateAll(db, OpenGroup.Columns.inboxLatestMessageId.set(to: 124))
                        }
                        
                        let preparedRequest:  Network.PreparedRequest<Network.BatchResponseMap<OpenGroupAPI.Endpoint>>? = mockStorage.read { db in
                            try OpenGroupAPI.preparedPoll(
                                db,
                                server: "testserver",
                                hasPerformedInitialPoll: true,
                                timeSinceLastPoll: 0,
                                using: dependencies
                            )
                        }
                        
                        expect(preparedRequest?.batchEndpoints as? [OpenGroupAPI.Endpoint]).toNot(contain(.inboxSince(id: 124)))
                    }
                }
            }
            
            // MARK: -- when preparing a capabilities request
            context("when preparing a capabilities request") {
                // MARK: ---- generates the request correctly
                it("generates the request and handles the response correctly") {
                    let preparedRequest: Network.PreparedRequest<OpenGroupAPI.Capabilities>? = mockStorage.read { db in
                        try OpenGroupAPI.preparedCapabilities(
                            db,
                            server: "testserver",
                            using: dependencies
                        )
                    }
                    
                    expect(preparedRequest?.path).to(equal("/capabilities"))
                    expect(preparedRequest?.method.rawValue).to(equal("GET"))
                }
            }
            
            // MARK: -- when preparing a rooms request
            context("when preparing a rooms request") {
                // MARK: ---- generates the request correctly
                it("generates the request correctly") {
                    let preparedRequest: Network.PreparedRequest<[OpenGroupAPI.Room]>? = mockStorage.read { db in
                        try OpenGroupAPI.preparedRooms(
                            db,
                            server: "testserver",
                            using: dependencies
                        )
                    }
                    
                    expect(preparedRequest?.path).to(equal("/rooms"))
                    expect(preparedRequest?.method.rawValue).to(equal("GET"))
                }
            }
            
            // MARK: -- when preparing a capabilitiesAndRoom request
            context("when preparing a capabilitiesAndRoom request") {
                // MARK: ---- generates the request correctly
                it("generates the request correctly") {
                    let preparedRequest: Network.PreparedRequest<OpenGroupAPI.CapabilitiesAndRoomResponse>? = mockStorage.read { db in
                        try OpenGroupAPI.preparedCapabilitiesAndRoom(
                            db,
                            for: "testRoom",
                            on: "testserver",
                            using: dependencies
                        )
                    }
                    
                    expect(preparedRequest?.batchEndpoints.count).to(equal(2))
                    expect(preparedRequest?.batchEndpoints[test: 0].asType(OpenGroupAPI.Endpoint.self))
                        .to(equal(.capabilities))
                    expect(preparedRequest?.batchEndpoints[test: 1].asType(OpenGroupAPI.Endpoint.self))
                        .to(equal(.room("testRoom")))
                    
                    expect(preparedRequest?.path).to(equal("/sequence"))
                    expect(preparedRequest?.method.rawValue).to(equal("POST"))
                }
                
                // MARK: ---- processes a valid response correctly
                it("processes a valid response correctly") {
                    mockNetwork
                        .when { $0.send(.any, to: .any, requestTimeout: .any, requestAndPathBuildTimeout: .any) }
                        .thenReturn(Network.BatchResponse.mockCapabilitiesAndRoomResponse)
                    
                    var response: (info: ResponseInfoType, data: OpenGroupAPI.CapabilitiesAndRoomResponse)?
                    
                    mockStorage
                        .readPublisher { db in
                            try OpenGroupAPI.preparedCapabilitiesAndRoom(
                                db,
                                for: "testRoom",
                                on: "testserver",
                                using: dependencies
                            )
                        }
                        .flatMap { $0.send(using: dependencies) }
                        .handleEvents(receiveOutput: { result in response = result })
                        .mapError { error.setting(to: $0) }
                        .sinkAndStore(in: &disposables)
                    
                    expect(response).toNot(beNil())
                    expect(error).to(beNil())
                }
                
                // MARK: ---- and given an invalid response
                
                context("and given an invalid response") {
                    // MARK: ------ errors when not given a room response
                    it("errors when not given a room response") {
                        mockNetwork
                            .when { $0.send(.any, to: .any, requestTimeout: .any, requestAndPathBuildTimeout: .any) }
                            .thenReturn(Network.BatchResponse.mockCapabilitiesAndBanResponse)
                        
                        var response: (info: ResponseInfoType, data: OpenGroupAPI.CapabilitiesAndRoomResponse)?
                        
                        mockStorage
                            .readPublisher { db in
                                try OpenGroupAPI.preparedCapabilitiesAndRoom(
                                    db,
                                    for: "testRoom",
                                    on: "testserver",
                                    using: dependencies
                                )
                            }
                            .flatMap { $0.send(using: dependencies) }
                            .handleEvents(receiveOutput: { result in response = result })
                            .mapError { error.setting(to: $0) }
                            .sinkAndStore(in: &disposables)
                        
                        expect(error).to(matchError(NetworkError.parsingFailed))
                        expect(response).to(beNil())
                    }
                    
                    // MARK: ------ errors when not given a capabilities response
                    it("errors when not given a capabilities response") {
                        mockNetwork
                            .when { $0.send(.any, to: .any, requestTimeout: .any, requestAndPathBuildTimeout: .any) }
                            .thenReturn(Network.BatchResponse.mockBanAndRoomResponse)
                        
                        var response: (info: ResponseInfoType, data: OpenGroupAPI.CapabilitiesAndRoomResponse)?
                        
                        mockStorage
                            .readPublisher { db in
                                try OpenGroupAPI.preparedCapabilitiesAndRoom(
                                    db,
                                    for: "testRoom",
                                    on: "testserver",
                                    using: dependencies
                                )
                            }
                            .flatMap { $0.send(using: dependencies) }
                            .handleEvents(receiveOutput: { result in response = result })
                            .mapError { error.setting(to: $0) }
                            .sinkAndStore(in: &disposables)
                        
                        expect(error).to(matchError(NetworkError.parsingFailed))
                        expect(response).to(beNil())
                    }
                }
            }
        }
        
        describe("an OpenGroupAPI") {
            // MARK: -- when preparing a capabilitiesAndRooms request
            context("when preparing a capabilitiesAndRooms request") {
                // MARK: ---- generates the request correctly
                it("generates the request correctly") {
                    let preparedRequest: Network.PreparedRequest<OpenGroupAPI.CapabilitiesAndRoomsResponse>? = mockStorage.read { db in
                        try OpenGroupAPI.preparedCapabilitiesAndRooms(
                            db,
                            on: "testserver",
                            using: dependencies
                        )
                    }
                    
                    expect(preparedRequest?.batchEndpoints.count).to(equal(2))
                    expect(preparedRequest?.batchEndpoints[test: 0].asType(OpenGroupAPI.Endpoint.self))
                        .to(equal(.capabilities))
                    expect(preparedRequest?.batchEndpoints[test: 1].asType(OpenGroupAPI.Endpoint.self))
                        .to(equal(.rooms))
                    
                    expect(preparedRequest?.path).to(equal("/sequence"))
                    expect(preparedRequest?.method.rawValue).to(equal("POST"))
                }
                
                // MARK: ---- processes a valid response correctly
                it("processes a valid response correctly") {
                    mockNetwork
                        .when { $0.send(.any, to: .any, requestTimeout: .any, requestAndPathBuildTimeout: .any) }
                        .thenReturn(Network.BatchResponse.mockCapabilitiesAndRoomsResponse)
                    
                    var response: (info: ResponseInfoType, data: OpenGroupAPI.CapabilitiesAndRoomsResponse)?
                    
                    mockStorage
                        .readPublisher { db in
                            try OpenGroupAPI.preparedCapabilitiesAndRooms(
                                db,
                                on: "testserver",
                                using: dependencies
                            )
                        }
                        .flatMap { $0.send(using: dependencies) }
                        .handleEvents(receiveOutput: { result in response = result })
                        .mapError { error.setting(to: $0) }
                        .sinkAndStore(in: &disposables)
                    
                    expect(response).toNot(beNil())
                    expect(error).to(beNil())
                }
                
                // MARK: ---- and given an invalid response
                context("and given an invalid response") {
                    // MARK: ------ errors when not given a room response
                    it("errors when not given a room response") {
                        mockNetwork
                            .when { $0.send(.any, to: .any, requestTimeout: .any, requestAndPathBuildTimeout: .any) }
                            .thenReturn(
                                MockNetwork.batchResponseData(with: [
                                    (OpenGroupAPI.Endpoint.capabilities, OpenGroupAPI.Capabilities.mockBatchSubResponse()),
                                    (
                                        OpenGroupAPI.Endpoint.userBan(""),
                                        OpenGroupAPI.DirectMessage.mockBatchSubResponse()
                                    )
                                ])
                            )
                        
                        var response: (info: ResponseInfoType, data: OpenGroupAPI.CapabilitiesAndRoomsResponse)?
                        
                        mockStorage
                            .readPublisher { db in
                                try OpenGroupAPI.preparedCapabilitiesAndRooms(
                                    db,
                                    on: "testserver",
                                    using: dependencies
                                )
                            }
                            .flatMap { $0.send(using: dependencies) }
                            .handleEvents(receiveOutput: { result in response = result })
                            .mapError { error.setting(to: $0) }
                            .sinkAndStore(in: &disposables)
                        
                        expect(error).to(matchError(NetworkError.parsingFailed))
                        expect(response).to(beNil())
                    }
                    
                    // MARK: ------ errors when not given a capabilities response
                    it("errors when not given a capabilities response") {
                        mockNetwork
                            .when { $0.send(.any, to: .any, requestTimeout: .any, requestAndPathBuildTimeout: .any) }
                            .thenReturn(Network.BatchResponse.mockBanAndRoomsResponse)
                        
                        var response: (info: ResponseInfoType, data: OpenGroupAPI.CapabilitiesAndRoomsResponse)?
                        
                        mockStorage
                            .readPublisher { db in
                                try OpenGroupAPI.preparedCapabilitiesAndRooms(
                                    db,
                                    on: "testserver",
                                    using: dependencies
                                )
                            }
                            .flatMap { $0.send(using: dependencies) }
                            .handleEvents(receiveOutput: { result in response = result })
                            .mapError { error.setting(to: $0) }
                            .sinkAndStore(in: &disposables)
                        
                        expect(error).to(matchError(NetworkError.parsingFailed))
                        expect(response).to(beNil())
                    }
                }
            }
            
            // MARK: -- when preparing a send message request
            context("when preparing a send message request") {
                // MARK: ---- generates the request correctly
                it("generates the request correctly") {
                    let preparedRequest: Network.PreparedRequest<OpenGroupAPI.Message>? = mockStorage.read { db in
                        try OpenGroupAPI.preparedSend(
                            db,
                            plaintext: "test".data(using: .utf8)!,
                            to: "testRoom",
                            on: "testServer",
                            whisperTo: nil,
                            whisperMods: false,
                            fileIds: nil,
                            using: dependencies
                        )
                    }
                    
                    expect(preparedRequest?.path).to(equal("/room/testRoom/message"))
                    expect(preparedRequest?.method.rawValue).to(equal("POST"))
                }
                
                // MARK: ---- when unblinded
                context("when unblinded") {
                    beforeEach {
                        mockStorage.write { db in
                            _ = try Capability.deleteAll(db)
                            try Capability(openGroupServer: "testserver", variant: .sogs, isMissing: false).insert(db)
                        }
                    }
                    
                    // MARK: ------ signs the message correctly
                    it("signs the message correctly") {
                        let preparedRequest: Network.PreparedRequest<OpenGroupAPI.Message>? = mockStorage.read { db in
                            try OpenGroupAPI.preparedSend(
                                db,
                                plaintext: "test".data(using: .utf8)!,
                                to: "testRoom",
                                on: "testServer",
                                whisperTo: nil,
                                whisperMods: false,
                                fileIds: nil,
                                using: dependencies
                            )
                        }
                        
                        let requestBody: OpenGroupAPI.SendMessageRequest? = try? preparedRequest?.body?
                            .decoded(as: OpenGroupAPI.SendMessageRequest.self, using: dependencies)
                        expect(requestBody?.data).to(equal("test".data(using: .utf8)))
                        expect(requestBody?.signature).to(equal("TestStandardSignature".data(using: .utf8)))
                    }
                    
                    // MARK: ------ fails to sign if there is no open group
                    it("fails to sign if there is no open group") {
                        mockStorage.write { db in
                            _ = try OpenGroup.deleteAll(db)
                        }
                        
                        var preparationError: Error?
                        let preparedRequest: Network.PreparedRequest<OpenGroupAPI.Message>? = mockStorage.read { db in
                            do {
                                return try OpenGroupAPI.preparedSend(
                                    db,
                                    plaintext: "test".data(using: .utf8)!,
                                    to: "testRoom",
                                    on: "testserver",
                                    whisperTo: nil,
                                    whisperMods: false,
                                    fileIds: nil,
                                    using: dependencies
                                )
                            }
                            catch {
                                preparationError = error
                                throw error
                            }
                        }
                        
                        expect(preparationError).to(matchError(OpenGroupAPIError.signingFailed))
                        expect(preparedRequest).to(beNil())
                    }
                    
                    // MARK: ------ fails to sign if there is no user key pair
                    it("fails to sign if there is no user key pair") {
                        mockStorage.write { db in
                            _ = try Identity.filter(id: .x25519PublicKey).deleteAll(db)
                            _ = try Identity.filter(id: .x25519PrivateKey).deleteAll(db)
                        }
                        
                        var preparationError: Error?
                        let preparedRequest: Network.PreparedRequest<OpenGroupAPI.Message>? = mockStorage.read { db in
                            do {
                                return try OpenGroupAPI.preparedSend(
                                    db,
                                    plaintext: "test".data(using: .utf8)!,
                                    to: "testRoom",
                                    on: "testserver",
                                    whisperTo: nil,
                                    whisperMods: false,
                                    fileIds: nil,
                                    using: dependencies
                                )
                            }
                            catch {
                                preparationError = error
                                throw error
                            }
                        }
                        
                        expect(preparationError).to(matchError(OpenGroupAPIError.signingFailed))
                        expect(preparedRequest).to(beNil())
                    }
                    
                    // MARK: ------ fails to sign if no signature is generated
                    it("fails to sign if no signature is generated") {
                        mockCrypto.reset() // The 'keyPair' value doesn't equate so have to explicitly reset
                        mockCrypto
                            .when { $0.generate(.signatureXed25519(data: .any, curve25519PrivateKey: .any)) }
                            .thenReturn(nil)
                        
                        var preparationError: Error?
                        let preparedRequest: Network.PreparedRequest<OpenGroupAPI.Message>? = mockStorage.read { db in
                            do {
                                return try OpenGroupAPI.preparedSend(
                                    db,
                                    plaintext: "test".data(using: .utf8)!,
                                    to: "testRoom",
                                    on: "testserver",
                                    whisperTo: nil,
                                    whisperMods: false,
                                    fileIds: nil,
                                    using: dependencies
                                )
                            }
                            catch {
                                preparationError = error
                                throw error
                            }
                        }
                        
                        expect(preparationError).to(matchError(OpenGroupAPIError.signingFailed))
                        expect(preparedRequest).to(beNil())
                    }
                }
                
                // MARK: ---- when blinded
                context("when blinded") {
                    beforeEach {
                        mockStorage.write { db in
                            _ = try Capability.deleteAll(db)
                            try Capability(openGroupServer: "testserver", variant: .sogs, isMissing: false).insert(db)
                            try Capability(openGroupServer: "testserver", variant: .blind, isMissing: false).insert(db)
                        }
                    }
                    
                    // MARK: ------ signs the message correctly
                    it("signs the message correctly") {
                        let preparedRequest: Network.PreparedRequest<OpenGroupAPI.Message>? = mockStorage.read { db in
                            try OpenGroupAPI.preparedSend(
                                db,
                                plaintext: "test".data(using: .utf8)!,
                                to: "testRoom",
                                on: "testserver",
                                whisperTo: nil,
                                whisperMods: false,
                                fileIds: nil,
                                using: dependencies
                            )
                        }
                        
                        let requestBody: OpenGroupAPI.SendMessageRequest? = try? preparedRequest?.body?
                            .decoded(as: OpenGroupAPI.SendMessageRequest.self, using: dependencies)
                        expect(requestBody?.data).to(equal("test".data(using: .utf8)))
                        expect(requestBody?.signature).to(equal("TestSogsSignature".data(using: .utf8)))
                    }
                    
                    // MARK: ------ fails to sign if there is no open group
                    it("fails to sign if there is no open group") {
                        mockStorage.write { db in
                            _ = try OpenGroup.deleteAll(db)
                        }
                        
                        var preparationError: Error?
                        let preparedRequest: Network.PreparedRequest<OpenGroupAPI.Message>? = mockStorage.read { db in
                            do {
                                return try OpenGroupAPI.preparedSend(
                                    db,
                                    plaintext: "test".data(using: .utf8)!,
                                    to: "testRoom",
                                    on: "testServer",
                                    whisperTo: nil,
                                    whisperMods: false,
                                    fileIds: nil,
                                    using: dependencies
                                )
                            }
                            catch {
                                preparationError = error
                                throw error
                            }
                        }
                        
                        expect(preparationError).to(matchError(OpenGroupAPIError.signingFailed))
                        expect(preparedRequest).to(beNil())
                    }
                    
                    // MARK: ------ fails to sign if there is no ed key pair key
                    it("fails to sign if there is no ed key pair key") {
                        mockStorage.write { db in
                            _ = try Identity.filter(id: .ed25519PublicKey).deleteAll(db)
                            _ = try Identity.filter(id: .ed25519SecretKey).deleteAll(db)
                        }
                        
                        var preparationError: Error?
                        let preparedRequest: Network.PreparedRequest<OpenGroupAPI.Message>? = mockStorage.read { db in
                            do {
                                return try OpenGroupAPI.preparedSend(
                                    db,
                                    plaintext: "test".data(using: .utf8)!,
                                    to: "testRoom",
                                    on: "testserver",
                                    whisperTo: nil,
                                    whisperMods: false,
                                    fileIds: nil,
                                    using: dependencies
                                )
                            }
                            catch {
                                preparationError = error
                                throw error
                            }
                        }
                        
                        expect(preparationError).to(matchError(OpenGroupAPIError.signingFailed))
                        expect(preparedRequest).to(beNil())
                    }
                    
                    // MARK: ------ fails to sign if no signature is generated
                    it("fails to sign if no signature is generated") {
                        mockCrypto
                            .when { $0.generate(.signatureBlind15(message: .any, serverPublicKey: .any, ed25519SecretKey: .any)) }
                            .thenReturn(nil)
                        
                        var preparationError: Error?
                        let preparedRequest: Network.PreparedRequest<OpenGroupAPI.Message>? = mockStorage.read { db in
                            do {
                                return try OpenGroupAPI.preparedSend(
                                    db,
                                    plaintext: "test".data(using: .utf8)!,
                                    to: "testRoom",
                                    on: "testserver",
                                    whisperTo: nil,
                                    whisperMods: false,
                                    fileIds: nil,
                                    using: dependencies
                                )
                            }
                            catch {
                                preparationError = error
                                throw error
                            }
                        }
                        
                        expect(preparationError).to(matchError(OpenGroupAPIError.signingFailed))
                        expect(preparedRequest).to(beNil())
                    }
                }
            }
            
            // MARK: -- when preparing an individual message request
            context("when preparing an individual message request") {
                // MARK: ---- generates the request correctly
                it("generates the request correctly") {
                    let preparedRequest: Network.PreparedRequest<OpenGroupAPI.Message>? = mockStorage.read { db in
                        try OpenGroupAPI.preparedMessage(
                            db,
                            id: 123,
                            in: "testRoom",
                            on: "testserver",
                            using: dependencies
                        )
                    }
                    
                    expect(preparedRequest?.path).to(equal("/room/testRoom/message/123"))
                    expect(preparedRequest?.method.rawValue).to(equal("GET"))
                }
            }
            
            // MARK: -- when preparing an update message request
            context("when preparing an update message request") {
                beforeEach {
                    mockStorage.write { db in
                        _ = try Identity
                            .filter(id: .ed25519PublicKey)
                            .updateAll(db, Identity.Columns.data.set(to: Data()))
                        _ = try Identity
                            .filter(id: .ed25519SecretKey)
                            .updateAll(db, Identity.Columns.data.set(to: Data()))
                    }
                }
                
                // MARK: ---- generates the request correctly
                it("generates the request correctly") {
                    let preparedRequest: Network.PreparedRequest<NoResponse>? = mockStorage.read { db in
                        try OpenGroupAPI.preparedMessageUpdate(
                            db,
                            id: 123,
                            plaintext: "test".data(using: .utf8)!,
                            fileIds: nil,
                            in: "testRoom",
                            on: "testserver",
                            using: dependencies
                        )
                    }
                    
                    expect(preparedRequest?.path).to(equal("/room/testRoom/message/123"))
                    expect(preparedRequest?.method.rawValue).to(equal("PUT"))
                }
                
                // MARK: ---- when unblinded
                context("when unblinded") {
                    beforeEach {
                        mockStorage.write { db in
                            _ = try Capability.deleteAll(db)
                            try Capability(openGroupServer: "testserver", variant: .sogs, isMissing: false).insert(db)
                        }
                    }
                    
                    // MARK: ------ signs the message correctly
                    it("signs the message correctly") {
                        let preparedRequest: Network.PreparedRequest<NoResponse>? = mockStorage.read { db in
                            try OpenGroupAPI.preparedMessageUpdate(
                                db,
                                id: 123,
                                plaintext: "test".data(using: .utf8)!,
                                fileIds: nil,
                                in: "testRoom",
                                on: "testserver",
                                using: dependencies
                            )
                        }
                        
                        let requestBody: OpenGroupAPI.UpdateMessageRequest? = try? preparedRequest?.body?
                            .decoded(as: OpenGroupAPI.UpdateMessageRequest.self, using: dependencies)
                        expect(requestBody?.data).to(equal("test".data(using: .utf8)))
                        expect(requestBody?.signature).to(equal("TestStandardSignature".data(using: .utf8)))
                    }
                    
                    // MARK: ------ fails to sign if there is no open group
                    it("fails to sign if there is no open group") {
                        mockStorage.write { db in
                            _ = try OpenGroup.deleteAll(db)
                        }
                        
                        var preparationError: Error?
                        let preparedRequest: Network.PreparedRequest<NoResponse>? = mockStorage.read { db in
                            do {
                                return try OpenGroupAPI.preparedMessageUpdate(
                                    db,
                                    id: 123,
                                    plaintext: "test".data(using: .utf8)!,
                                    fileIds: nil,
                                    in: "testRoom",
                                    on: "testserver",
                                    using: dependencies
                                )
                            }
                            catch {
                                preparationError = error
                                throw error
                            }
                        }
                            
                        expect(preparationError).to(matchError(OpenGroupAPIError.signingFailed))
                        expect(preparedRequest).to(beNil())
                    }
                    
                    // MARK: ------ fails to sign if there is no user key pair
                    it("fails to sign if there is no user key pair") {
                        mockStorage.write { db in
                            _ = try Identity.filter(id: .x25519PublicKey).deleteAll(db)
                            _ = try Identity.filter(id: .x25519PrivateKey).deleteAll(db)
                        }
                        
                        var preparationError: Error?
                        let preparedRequest: Network.PreparedRequest<NoResponse>? = mockStorage.read { db in
                            do {
                                return try OpenGroupAPI.preparedMessageUpdate(
                                    db,
                                    id: 123,
                                    plaintext: "test".data(using: .utf8)!,
                                    fileIds: nil,
                                    in: "testRoom",
                                    on: "testserver",
                                    using: dependencies
                                )
                            }
                            catch {
                                preparationError = error
                                throw error
                            }
                        }
                            
                        expect(preparationError).to(matchError(OpenGroupAPIError.signingFailed))
                        expect(preparedRequest).to(beNil())
                    }
                    
                    // MARK: ------ fails to sign if no signature is generated
                    it("fails to sign if no signature is generated") {
                        mockCrypto.reset() // The 'keyPair' value doesn't equate so have to explicitly reset
                        mockCrypto
                            .when { $0.generate(.signatureXed25519(data: .any, curve25519PrivateKey: .any)) }
                            .thenReturn(nil)
                        
                        var preparationError: Error?
                        let preparedRequest: Network.PreparedRequest<NoResponse>? = mockStorage.read { db in
                            do {
                                return try OpenGroupAPI.preparedMessageUpdate(
                                    db,
                                    id: 123,
                                    plaintext: "test".data(using: .utf8)!,
                                    fileIds: nil,
                                    in: "testRoom",
                                    on: "testServer",
                                    using: dependencies
                                )
                            }
                            catch {
                                preparationError = error
                                throw error
                            }
                        }
                            
                        expect(preparationError).to(matchError(OpenGroupAPIError.signingFailed))
                        expect(preparedRequest).to(beNil())
                    }
                }
                
                // MARK: ---- when blinded
                context("when blinded") {
                    beforeEach {
                        mockStorage.write { db in
                            _ = try Capability.deleteAll(db)
                            try Capability(openGroupServer: "testserver", variant: .sogs, isMissing: false).insert(db)
                            try Capability(openGroupServer: "testserver", variant: .blind, isMissing: false).insert(db)
                        }
                    }
                    
                    // MARK: ------ signs the message correctly
                    it("signs the message correctly") {
                        let preparedRequest: Network.PreparedRequest<NoResponse>? = mockStorage.read { db in
                            try OpenGroupAPI.preparedMessageUpdate(
                                db,
                                id: 123,
                                plaintext: "test".data(using: .utf8)!,
                                fileIds: nil,
                                in: "testRoom",
                                on: "testserver",
                                using: dependencies
                            )
                        }
                        
                        let requestBody: OpenGroupAPI.UpdateMessageRequest? = try? preparedRequest?.body?
                            .decoded(as: OpenGroupAPI.UpdateMessageRequest.self, using: dependencies)
                        expect(requestBody?.data).to(equal("test".data(using: .utf8)))
                        expect(requestBody?.signature).to(equal("TestSogsSignature".data(using: .utf8)))
                    }
                    
                    // MARK: ------ fails to sign if there is no open group
                    it("fails to sign if there is no open group") {
                        mockStorage.write { db in
                            _ = try OpenGroup.deleteAll(db)
                        }
                        
                        var preparationError: Error?
                        let preparedRequest: Network.PreparedRequest<NoResponse>? = mockStorage.read { db in
                            do {
                                return try OpenGroupAPI.preparedMessageUpdate(
                                    db,
                                    id: 123,
                                    plaintext: "test".data(using: .utf8)!,
                                    fileIds: nil,
                                    in: "testRoom",
                                    on: "testserver",
                                    using: dependencies
                                )
                            }
                            catch {
                                preparationError = error
                                throw error
                            }
                        }
                            
                        expect(preparationError).to(matchError(OpenGroupAPIError.signingFailed))
                        expect(preparedRequest).to(beNil())
                    }
                    
                    // MARK: ------ fails to sign if there is no ed key pair key
                    it("fails to sign if there is no ed key pair key") {
                        mockStorage.write { db in
                            _ = try Identity.filter(id: .ed25519PublicKey).deleteAll(db)
                            _ = try Identity.filter(id: .ed25519SecretKey).deleteAll(db)
                        }
                        
                        var preparationError: Error?
                        let preparedRequest: Network.PreparedRequest<NoResponse>? = mockStorage.read { db in
                            do {
                                return try OpenGroupAPI.preparedMessageUpdate(
                                    db,
                                    id: 123,
                                    plaintext: "test".data(using: .utf8)!,
                                    fileIds: nil,
                                    in: "testRoom",
                                    on: "testserver",
                                    using: dependencies
                                )
                            }
                            catch {
                                preparationError = error
                                throw error
                            }
                        }
                            
                        expect(preparationError).to(matchError(OpenGroupAPIError.signingFailed))
                        expect(preparedRequest).to(beNil())
                    }
                    
                    // MARK: ------ fails to sign if no signature is generated
                    it("fails to sign if no signature is generated") {
                        mockCrypto
                            .when { $0.generate(.signatureBlind15(message: .any, serverPublicKey: .any, ed25519SecretKey: .any)) }
                            .thenReturn(nil)
                        
                        var preparationError: Error?
                        let preparedRequest: Network.PreparedRequest<NoResponse>? = mockStorage.read { db in
                            do {
                                return try OpenGroupAPI.preparedMessageUpdate(
                                    db,
                                    id: 123,
                                    plaintext: "test".data(using: .utf8)!,
                                    fileIds: nil,
                                    in: "testRoom",
                                    on: "testserver",
                                    using: dependencies
                                )
                            }
                            catch {
                                preparationError = error
                                throw error
                            }
                        }
                            
                        expect(preparationError).to(matchError(OpenGroupAPIError.signingFailed))
                        expect(preparedRequest).to(beNil())
                    }
                }
            }
            
            // MARK: -- when preparing a delete message request
            context("when preparing a delete message request") {
                // MARK: ---- generates the request correctly
                it("generates the request correctly") {
                    let preparedRequest: Network.PreparedRequest<NoResponse>? = mockStorage.read { db in
                        try OpenGroupAPI.preparedMessageDelete(
                            db,
                            id: 123,
                            in: "testRoom",
                            on: "testserver",
                            using: dependencies
                        )
                    }
                    
                    expect(preparedRequest?.path).to(equal("/room/testRoom/message/123"))
                    expect(preparedRequest?.method.rawValue).to(equal("DELETE"))
                }
            }
            
            // MARK: -- when preparing a delete all messages request
            context("when preparing a delete all messages request") {
                // MARK: ---- generates the request correctly
                it("generates the request correctly") {
                    let preparedRequest: Network.PreparedRequest<NoResponse>? = mockStorage.read { db in
                        try OpenGroupAPI.preparedMessagesDeleteAll(
                            db,
                            sessionId: "testUserId",
                            in: "testRoom",
                            on: "testserver",
                            using: dependencies
                        )
                    }
                    
                    expect(preparedRequest?.path).to(equal("/room/testRoom/all/testUserId"))
                    expect(preparedRequest?.method.rawValue).to(equal("DELETE"))
                }
            }
            
            // MARK: -- when preparing a pin message request
            context("when preparing a pin message request") {
                // MARK: ---- generates the request correctly
                it("generates the request correctly") {
                    let preparedRequest: Network.PreparedRequest<NoResponse>? = mockStorage.read { db in
                        try OpenGroupAPI.preparedPinMessage(
                            db,
                            id: 123,
                            in: "testRoom",
                            on: "testserver",
                            using: dependencies
                        )
                    }
                    
                    expect(preparedRequest?.path).to(equal("/room/testRoom/pin/123"))
                    expect(preparedRequest?.method.rawValue).to(equal("POST"))
                }
            }
            
            // MARK: -- when preparing an unpin message request
            context("when preparing an unpin message request") {
                // MARK: ---- generates the request correctly
                it("generates the request correctly") {
                    let preparedRequest: Network.PreparedRequest<NoResponse>? = mockStorage.read { db in
                        try OpenGroupAPI.preparedUnpinMessage(
                            db,
                            id: 123,
                            in: "testRoom",
                            on: "testserver",
                            using: dependencies
                        )
                    }
                    
                    expect(preparedRequest?.path).to(equal("/room/testRoom/unpin/123"))
                    expect(preparedRequest?.method.rawValue).to(equal("POST"))
                }
            }
            
            // MARK: -- when preparing an unpin all request
            context("when preparing an unpin all request") {
                // MARK: ---- generates the request correctly
                it("generates the request correctly") {
                    let preparedRequest: Network.PreparedRequest<NoResponse>? = mockStorage.read { db in
                        try OpenGroupAPI.preparedUnpinAll(
                            db,
                            in: "testRoom",
                            on: "testserver",
                            using: dependencies
                        )
                    }
                    
                    expect(preparedRequest?.path).to(equal("/room/testRoom/unpin/all"))
                    expect(preparedRequest?.method.rawValue).to(equal("POST"))
                }
            }
            
            // MARK: -- when generaing an upload request
            context("when generaing an upload request") {
                beforeEach {
                    mockStorage.write { db in
                        try OpenGroup(
                            server: "http://oxen.io",
                            roomToken: "testRoom",
                            publicKey: TestConstants.publicKey,
                            isActive: true,
                            name: "Test",
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
                
                // MARK: ---- generates the request correctly
                it("generates the request correctly") {
                    let preparedRequest: Network.PreparedRequest<FileUploadResponse>? = mockStorage.read { db in
                        try OpenGroupAPI.preparedUpload(
                            db,
                            data: Data([1, 2, 3]),
                            to: "testRoom",
                            on: "testServer",
                            using: dependencies
                        )
                    }
                    
                    expect(preparedRequest?.path).to(equal("/room/testRoom/file"))
                    expect(preparedRequest?.method.rawValue).to(equal("POST"))
                }
            }
            
            // MARK: -- when generaing a download request
            context("when generaing a download request") {
                beforeEach {
                    mockStorage.write { db in
                        try OpenGroup(
                            server: "http://oxen.io",
                            roomToken: "testRoom",
                            publicKey: TestConstants.publicKey,
                            isActive: true,
                            name: "Test",
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
                
                // MARK: ---- generates the download url string correctly
                it("generates the download url string correctly") {
                    expect(OpenGroupAPI.downloadUrlString(for: "1", server: "testserver", roomToken: "roomToken"))
                        .to(equal("testserver/room/roomToken/file/1"))
                }
                
                // MARK: ---- generates the download destination correctly when given an id
                it("generates the download destination correctly when given an id") {
                    let preparedRequest: Network.PreparedRequest<Data>? = mockStorage.read { db in
                        try OpenGroupAPI.preparedDownload(
                            db,
                            fileId: "1",
                            from: "roomToken",
                            on: "http://oxen.io",
                            using: dependencies
                        )
                    }
                    
                    expect(preparedRequest?.path).to(equal("/room/roomToken/file/1"))
                    expect(preparedRequest?.method.rawValue).to(equal("GET"))
                    expect(preparedRequest?.headers).to(equal([
                        HTTPHeader.sogsNonce: "pK6YRtQApl4NhECGizF0Cg==",
                        HTTPHeader.sogsTimestamp: "1234567890",
                        HTTPHeader.sogsSignature: "VGVzdFNvZ3NTaWduYXR1cmU=",
                        HTTPHeader.sogsPubKey: "1588672ccb97f40bb57238989226cf429b575ba355443f47bc76c5ab144a96c65b"
                    ]))
                }
                
                // MARK: ---- generates the download request correctly when given a URL
                it("generates the download request correctly when given a URL") {
                    let preparedRequest: Network.PreparedRequest<Data>? = mockStorage.read { db in
                        try OpenGroupAPI.preparedDownload(
                            db,
                            url: URL(string: "http://oxen.io/room/roomToken/file/1")!,
                            from: "roomToken",
                            on: "http://oxen.io",
                            using: dependencies
                        )
                    }
                    
                    expect(preparedRequest?.path).to(equal("/room/roomToken/file/1"))
                    expect(preparedRequest?.method.rawValue).to(equal("GET"))
                    expect(preparedRequest?.headers).to(equal([
                        HTTPHeader.sogsNonce: "pK6YRtQApl4NhECGizF0Cg==",
                        HTTPHeader.sogsTimestamp: "1234567890",
                        HTTPHeader.sogsSignature: "VGVzdFNvZ3NTaWduYXR1cmU=",
                        HTTPHeader.sogsPubKey: "1588672ccb97f40bb57238989226cf429b575ba355443f47bc76c5ab144a96c65b"
                    ]))
                }
            }
            
            // MARK: -- when preparing an inbox request
            context("when preparing an inbox request") {
                // MARK: ---- generates the request correctly
                it("generates the request correctly") {
                    let preparedRequest: Network.PreparedRequest<[OpenGroupAPI.DirectMessage]?>? = mockStorage.read { db in
                        try OpenGroupAPI.preparedInbox(
                            db,
                            on: "testserver",
                            using: dependencies
                        )
                    }
                    
                    expect(preparedRequest?.path).to(equal("/inbox"))
                    expect(preparedRequest?.method.rawValue).to(equal("GET"))
                }
            }
            
            // MARK: -- when preparing an inbox since request
            context("when preparing an inbox since request") {
                // MARK: ---- generates the request correctly
                it("generates the request correctly") {
                    let preparedRequest: Network.PreparedRequest<[OpenGroupAPI.DirectMessage]?>? = mockStorage.read { db in
                        try OpenGroupAPI.preparedInboxSince(
                            db,
                            id: 1,
                            on: "testserver",
                            using: dependencies
                        )
                    }
                    
                    expect(preparedRequest?.path).to(equal("/inbox/since/1"))
                    expect(preparedRequest?.method.rawValue).to(equal("GET"))
                }
            }
            
            // MARK: -- when preparing a clear inbox request
            context("when preparing an inbox since request") {
                // MARK: ---- generates the request correctly
                it("generates the request correctly") {
                    let preparedRequest: Network.PreparedRequest<OpenGroupAPI.DeleteInboxResponse>? = mockStorage.read { db in
                        try OpenGroupAPI.preparedClearInbox(
                            db,
                            on: "testserver",
                            using: dependencies
                        )
                    }
                    
                    expect(preparedRequest?.path).to(equal("/inbox"))
                    expect(preparedRequest?.method.rawValue).to(equal("DELETE"))
                }
            }
            
            // MARK: -- when preparing a send direct message request
            context("when preparing a send direct message request") {
                // MARK: ---- generates the request correctly
                it("generates the request correctly") {
                    let preparedRequest: Network.PreparedRequest<OpenGroupAPI.SendDirectMessageResponse>? = mockStorage.read { db in
                        try OpenGroupAPI.preparedSend(
                            db,
                            ciphertext: "test".data(using: .utf8)!,
                            toInboxFor: "testUserId",
                            on: "testserver",
                            using: dependencies
                        )
                    }
                    
                    expect(preparedRequest?.path).to(equal("/inbox/testUserId"))
                    expect(preparedRequest?.method.rawValue).to(equal("POST"))
                }
            }
        }
        
        describe("an OpenGroupAPI") {
            // MARK: -- when preparing a ban user request
            context("when preparing a ban user request") {
                // MARK: ---- generates the request correctly
                it("generates the request correctly") {
                    let preparedRequest: Network.PreparedRequest<NoResponse>? = mockStorage.read { db in
                        try OpenGroupAPI.preparedUserBan(
                            db,
                            sessionId: "testUserId",
                            for: nil,
                            from: nil,
                            on: "testserver",
                            using: dependencies
                        )
                    }
                    
                    expect(preparedRequest?.path).to(equal("/user/testUserId/ban"))
                    expect(preparedRequest?.method.rawValue).to(equal("POST"))
                }
                
                // MARK: ---- does a global ban if no room tokens are provided
                it("does a global ban if no room tokens are provided") {
                    let preparedRequest: Network.PreparedRequest<NoResponse>? = mockStorage.read { db in
                        try OpenGroupAPI.preparedUserBan(
                            db,
                            sessionId: "testUserId",
                            for: nil,
                            from: nil,
                            on: "testserver",
                            using: dependencies
                        )
                    }
                    
                    let requestBody: OpenGroupAPI.UserBanRequest? = try? preparedRequest?.body?
                        .decoded(as: OpenGroupAPI.UserBanRequest.self, using: dependencies)
                    expect(requestBody?.global).to(beTrue())
                    expect(requestBody?.rooms).to(beNil())
                }
                
                // MARK: ---- does room specific bans if room tokens are provided
                it("does room specific bans if room tokens are provided") {
                    let preparedRequest: Network.PreparedRequest<NoResponse>? = mockStorage.read { db in
                        try OpenGroupAPI.preparedUserBan(
                            db,
                            sessionId: "testUserId",
                            for: nil,
                            from: ["testRoom"],
                            on: "testserver",
                            using: dependencies
                        )
                    }
                    
                    let requestBody: OpenGroupAPI.UserBanRequest? = try? preparedRequest?.body?
                        .decoded(as: OpenGroupAPI.UserBanRequest.self, using: dependencies)
                    expect(requestBody?.global).to(beNil())
                    expect(requestBody?.rooms).to(equal(["testRoom"]))
                }
            }
            
            // MARK: -- when preparing an unban user request
            context("when preparing an unban user request") {
                // MARK: ---- generates the request correctly
                it("generates the request correctly") {
                    let preparedRequest: Network.PreparedRequest<NoResponse>? = mockStorage.read { db in
                        try OpenGroupAPI.preparedUserUnban(
                            db,
                            sessionId: "testUserId",
                            from: nil,
                            on: "testserver",
                            using: dependencies
                        )
                    }
                    
                    expect(preparedRequest?.path).to(equal("/user/testUserId/unban"))
                    expect(preparedRequest?.method.rawValue).to(equal("POST"))
                }
                
                // MARK: ---- does a global unban if no room tokens are provided
                it("does a global unban if no room tokens are provided") {
                    let preparedRequest: Network.PreparedRequest<NoResponse>? = mockStorage.read { db in
                        try OpenGroupAPI.preparedUserUnban(
                            db,
                            sessionId: "testUserId",
                            from: nil,
                            on: "testserver",
                            using: dependencies
                        )
                    }
                    
                    let requestBody: OpenGroupAPI.UserUnbanRequest? = try? preparedRequest?.body?
                        .decoded(as: OpenGroupAPI.UserUnbanRequest.self, using: dependencies)
                    expect(requestBody?.global).to(beTrue())
                    expect(requestBody?.rooms).to(beNil())
                }
                
                // MARK: ---- does room specific unbans if room tokens are provided
                it("does room specific unbans if room tokens are provided") {
                    let preparedRequest: Network.PreparedRequest<NoResponse>? = mockStorage.read { db in
                        try OpenGroupAPI.preparedUserUnban(
                            db,
                            sessionId: "testUserId",
                            from: ["testRoom"],
                            on: "testserver",
                            using: dependencies
                        )
                    }
                    
                    let requestBody: OpenGroupAPI.UserUnbanRequest? = try? preparedRequest?.body?
                        .decoded(as: OpenGroupAPI.UserUnbanRequest.self, using: dependencies)
                    expect(requestBody?.global).to(beNil())
                    expect(requestBody?.rooms).to(equal(["testRoom"]))
                }
            }
            
            // MARK: -- when preparing a user permissions request
            context("when preparing a user permissions request") {
                // MARK: ---- generates the request correctly
                it("generates the request correctly") {
                    let preparedRequest: Network.PreparedRequest<NoResponse>? = mockStorage.read { db in
                        try OpenGroupAPI.preparedUserModeratorUpdate(
                            db,
                            sessionId: "testUserId",
                            moderator: true,
                            admin: nil,
                            visible: true,
                            for: nil,
                            on: "testserver",
                            using: dependencies
                        )
                    }
                    
                    expect(preparedRequest?.path).to(equal("/user/testUserId/moderator"))
                    expect(preparedRequest?.method.rawValue).to(equal("POST"))
                }
                
                // MARK: ---- does a global update if no room tokens are provided
                it("does a global update if no room tokens are provided") {
                    let preparedRequest: Network.PreparedRequest<NoResponse>? = mockStorage.read { db in
                        try OpenGroupAPI.preparedUserModeratorUpdate(
                            db,
                            sessionId: "testUserId",
                            moderator: true,
                            admin: nil,
                            visible: true,
                            for: nil,
                            on: "testserver",
                            using: dependencies
                        )
                    }
                    
                    let requestBody: OpenGroupAPI.UserModeratorRequest? = try? preparedRequest?.body?
                        .decoded(as: OpenGroupAPI.UserModeratorRequest.self, using: dependencies)
                    expect(requestBody?.global).to(beTrue())
                    expect(requestBody?.rooms).to(beNil())
                }
                
                // MARK: ---- does room specific updates if room tokens are provided
                it("does room specific updates if room tokens are provided") {
                    let preparedRequest: Network.PreparedRequest<NoResponse>? = mockStorage.read { db in
                        try OpenGroupAPI.preparedUserModeratorUpdate(
                            db,
                            sessionId: "testUserId",
                            moderator: true,
                            admin: nil,
                            visible: true,
                            for: ["testRoom"],
                            on: "testserver",
                            using: dependencies
                        )
                    }
                    
                    let requestBody: OpenGroupAPI.UserModeratorRequest? = try? preparedRequest?.body?
                        .decoded(as: OpenGroupAPI.UserModeratorRequest.self, using: dependencies)
                    expect(requestBody?.global).to(beNil())
                    expect(requestBody?.rooms).to(equal(["testRoom"]))
                }
                
                // MARK: ---- fails if neither moderator or admin are set
                it("fails if neither moderator or admin are set") {
                    var preparationError: Error?
                    let preparedRequest: Network.PreparedRequest<NoResponse>? = mockStorage.read { db in
                        do {
                            return try OpenGroupAPI.preparedUserModeratorUpdate(
                                db,
                                sessionId: "testUserId",
                                moderator: nil,
                                admin: nil,
                                visible: true,
                                for: nil,
                                on: "testserver",
                                using: dependencies
                            )
                        }
                        catch {
                            preparationError = error
                            throw error
                        }
                    }
                    
                    expect(preparationError).to(matchError(NetworkError.invalidPreparedRequest))
                    expect(preparedRequest).to(beNil())
                }
            }
            
            // MARK: -- when preparing a ban and delete all request
            context("when preparing a ban and delete all request") {
                // MARK: ---- generates the request correctly
                it("generates the request correctly") {
                    let preparedRequest:  Network.PreparedRequest<Network.BatchResponseMap<OpenGroupAPI.Endpoint>>? = mockStorage.read { db in
                        try OpenGroupAPI.preparedUserBanAndDeleteAllMessages(
                            db,
                            sessionId: "testUserId",
                            in: "testRoom",
                            on: "testserver",
                            using: dependencies
                        )
                    }
                    
                    expect(preparedRequest?.path).to(equal("/sequence"))
                    expect(preparedRequest?.method.rawValue).to(equal("POST"))
                    expect(preparedRequest?.batchEndpoints.count).to(equal(2))
                    expect(preparedRequest?.batchEndpoints[test: 0].asType(OpenGroupAPI.Endpoint.self))
                        .to(equal(.userBan("testUserId")))
                    expect(preparedRequest?.batchEndpoints[test: 1].asType(OpenGroupAPI.Endpoint.self))
                        .to(equal(.roomDeleteMessages("testRoom", sessionId: "testUserId")))
                }
            }
        }
        
        describe("an OpenGroupAPI") {
            // MARK: -- when signing
            context("when signing") {
                // MARK: ---- fails when there is no serverPublicKey
                it("fails when there is no serverPublicKey") {
                    mockStorage.write { db in
                        _ = try OpenGroup.deleteAll(db)
                    }
                    
                    var preparationError: Error?
                    let preparedRequest: Network.PreparedRequest<[OpenGroupAPI.Room]>? = mockStorage.read { db in
                        do {
                            return try OpenGroupAPI.preparedRooms(
                                db,
                                server: "testserver",
                                using: dependencies
                            )
                        }
                        catch {
                            preparationError = error
                            throw error
                        }
                    }
                    
                    expect(preparationError).to(matchError(OpenGroupAPIError.noPublicKey))
                    expect(preparedRequest).to(beNil())
                }
                
                // MARK: ---- fails when there is no userEdKeyPair
                it("fails when there is no userEdKeyPair") {
                    mockStorage.write { db in
                        _ = try Identity.filter(id: .ed25519PublicKey).deleteAll(db)
                        _ = try Identity.filter(id: .ed25519SecretKey).deleteAll(db)
                    }
                    
                    var preparationError: Error?
                    let preparedRequest: Network.PreparedRequest<[OpenGroupAPI.Room]>? = mockStorage.read { db in
                        do {
                            return try OpenGroupAPI.preparedRooms(
                                db,
                                server: "testserver",
                                using: dependencies
                            )
                        }
                        catch {
                            preparationError = error
                            throw error
                        }
                    }
                    
                    expect(preparationError).to(matchError(OpenGroupAPIError.signingFailed))
                    expect(preparedRequest).to(beNil())
                }
                
                // MARK: ---- fails when the serverPublicKey is not a hex string
                it("fails when the serverPublicKey is not a hex string") {
                    mockStorage.write { db in
                        _ = try OpenGroup.updateAll(db, OpenGroup.Columns.publicKey.set(to: "TestString!!!"))
                    }
                    
                    var preparationError: Error?
                    let preparedRequest: Network.PreparedRequest<[OpenGroupAPI.Room]>? = mockStorage.read { db in
                        do {
                            return try OpenGroupAPI.preparedRooms(
                                db,
                                server: "testserver",
                                using: dependencies
                            )
                        }
                        catch {
                            preparationError = error
                            throw error
                        }
                    }
                    
                    expect(preparationError).to(matchError(OpenGroupAPIError.signingFailed))
                    expect(preparedRequest).to(beNil())
                }
                
                // MARK: ---- when unblinded
                context("when unblinded") {
                    beforeEach {
                        mockStorage.write { db in
                            _ = try Capability.deleteAll(db)
                            try Capability(openGroupServer: "testserver", variant: .sogs, isMissing: false).insert(db)
                        }
                    }
                    
                    // MARK: ------ signs correctly
                    it("signs correctly") {
                        let preparedRequest: Network.PreparedRequest<[OpenGroupAPI.Room]>? = mockStorage.read { db in
                            try OpenGroupAPI.preparedRooms(
                                db,
                                server: "testserver",
                                using: dependencies
                            )
                        }
                        
                        expect(preparedRequest?.path).to(equal("/rooms"))
                        expect(preparedRequest?.method.rawValue).to(equal("GET"))
                        expect(preparedRequest?.destination.testX25519Pubkey)
                            .to(equal("88672ccb97f40bb57238989226cf429b575ba355443f47bc76c5ab144a96c65b"))
                        expect(preparedRequest?.destination.testHeaders).to(haveCount(4))
                        expect(preparedRequest?.destination.testHeaders?[HTTPHeader.sogsPubKey])
                            .to(equal("00bac6e71efd7dfa4a83c98ed24f254ab2c267f9ccdb172a5280a0444ad24e89cc"))
                        expect(preparedRequest?.destination.testHeaders?[HTTPHeader.sogsTimestamp])
                            .to(equal("1234567890"))
                        expect(preparedRequest?.destination.testHeaders?[HTTPHeader.sogsNonce])
                            .to(equal("pK6YRtQApl4NhECGizF0Cg=="))
                        expect(preparedRequest?.destination.testHeaders?[HTTPHeader.sogsSignature])
                            .to(equal("TestSignature".bytes.toBase64()))
                    }
                    
                    // MARK: ------ fails when the signature is not generated
                    it("fails when the signature is not generated") {
                        mockCrypto
                            .when { $0.generate(.signature(message: .any, ed25519SecretKey: .any)) }
                            .thenThrow(CryptoError.failedToGenerateOutput)
                        
                        var preparationError: Error?
                        let preparedRequest: Network.PreparedRequest<[OpenGroupAPI.Room]>? = mockStorage.read { db in
                            do {
                                return try OpenGroupAPI.preparedRooms(
                                    db,
                                    server: "testserver",
                                    using: dependencies
                                )
                            }
                            catch {
                                preparationError = error
                                throw error
                            }
                        }
                        
                        expect(preparationError).to(matchError(OpenGroupAPIError.signingFailed))
                        expect(preparedRequest).to(beNil())
                    }
                }
                
                // MARK: ---- when blinded
                context("when blinded") {
                    beforeEach {
                        mockStorage.write { db in
                            _ = try Capability.deleteAll(db)
                            try Capability(openGroupServer: "testserver", variant: .sogs, isMissing: false).insert(db)
                            try Capability(openGroupServer: "testserver", variant: .blind, isMissing: false).insert(db)
                        }
                    }
                    
                    // MARK: ------ signs correctly
                    it("signs correctly") {
                        let preparedRequest: Network.PreparedRequest<[OpenGroupAPI.Room]>? = mockStorage.read { db in
                            try OpenGroupAPI.preparedRooms(
                                db,
                                server: "testserver",
                                using: dependencies
                            )
                        }
                        
                        expect(preparedRequest?.path).to(equal("/rooms"))
                        expect(preparedRequest?.method.rawValue).to(equal("GET"))
                        expect(preparedRequest?.destination.testX25519Pubkey)
                            .to(equal("88672ccb97f40bb57238989226cf429b575ba355443f47bc76c5ab144a96c65b"))
                        expect(preparedRequest?.destination.testHeaders).to(haveCount(4))
                        expect(preparedRequest?.destination.testHeaders?[HTTPHeader.sogsPubKey])
                            .to(equal("1588672ccb97f40bb57238989226cf429b575ba355443f47bc76c5ab144a96c65b"))
                        expect(preparedRequest?.destination.testHeaders?[HTTPHeader.sogsTimestamp])
                            .to(equal("1234567890"))
                        expect(preparedRequest?.destination.testHeaders?[HTTPHeader.sogsNonce])
                            .to(equal("pK6YRtQApl4NhECGizF0Cg=="))
                        expect(preparedRequest?.destination.testHeaders?[HTTPHeader.sogsSignature])
                            .to(equal("TestSogsSignature".bytes.toBase64()))
                    }
                    
                    // MARK: ------ fails when the blindedKeyPair is not generated
                    it("fails when the blindedKeyPair is not generated") {
                        mockCrypto
                            .when { $0.generate(.blinded15KeyPair(serverPublicKey: .any, ed25519SecretKey: .any)) }
                            .thenReturn(nil)
                        
                        var preparationError: Error?
                        let preparedRequest: Network.PreparedRequest<[OpenGroupAPI.Room]>? = mockStorage.read { db in
                            do {
                                return try OpenGroupAPI.preparedRooms(
                                    db,
                                    server: "testserver",
                                    using: dependencies
                                )
                            }
                            catch {
                                preparationError = error
                                throw error
                            }
                        }
                        
                        expect(preparationError).to(matchError(OpenGroupAPIError.signingFailed))
                        expect(preparedRequest).to(beNil())
                    }
                    
                    // MARK: ------ fails when the sogsSignature is not generated
                    it("fails when the sogsSignature is not generated") {
                        mockCrypto
                            .when { $0.generate(.blinded15KeyPair(serverPublicKey: .any, ed25519SecretKey: .any)) }
                            .thenReturn(nil)
                        
                        var preparationError: Error?
                        let preparedRequest: Network.PreparedRequest<[OpenGroupAPI.Room]>? = mockStorage.read { db in
                            do {
                                return try OpenGroupAPI.preparedRooms(
                                    db,
                                    server: "testserver",
                                    using: dependencies
                                )
                            }
                            catch {
                                preparationError = error
                                throw error
                            }
                        }
                        
                        expect(preparationError).to(matchError(OpenGroupAPIError.signingFailed))
                        expect(preparedRequest).to(beNil())
                    }
                }
            }
            
            // MARK: -- when sending
            context("when sending") {
                beforeEach {
                    mockNetwork
                        .when { $0.send(.any, to: .any, requestTimeout: .any, requestAndPathBuildTimeout: .any) }
                        .thenReturn(MockNetwork.response(type: [OpenGroupAPI.Room].self))
                }
                
                // MARK: ---- triggers sending correctly
                it("triggers sending correctly") {
                    var response: (info: ResponseInfoType, data: [OpenGroupAPI.Room])?
                    
                    mockStorage
                        .readPublisher { db in
                            try OpenGroupAPI.preparedRooms(
                                db,
                                server: "testserver",
                                using: dependencies
                            )
                        }
                        .flatMap { $0.send(using: dependencies) }
                        .handleEvents(receiveOutput: { result in response = result })
                        .mapError { error.setting(to: $0) }
                        .sinkAndStore(in: &disposables)

                    expect(response).toNot(beNil())
                    expect(error).to(beNil())
                }
            }
        }
    }
}

// MARK: - Mock Batch Responses
                        
extension Network.BatchResponse {
    // MARK: - Valid Responses
    
    static let mockCapabilitiesAndRoomResponse: AnyPublisher<(ResponseInfoType, Data?), Error> = MockNetwork.batchResponseData(
        with: [
            (OpenGroupAPI.Endpoint.capabilities, OpenGroupAPI.Capabilities.mockBatchSubResponse()),
            (OpenGroupAPI.Endpoint.room("testRoom"), OpenGroupAPI.Room.mockBatchSubResponse())
        ]
    )
    
    static let mockCapabilitiesAndRoomsResponse: AnyPublisher<(ResponseInfoType, Data?), Error> = MockNetwork.batchResponseData(
        with: [
            (OpenGroupAPI.Endpoint.capabilities, OpenGroupAPI.Capabilities.mockBatchSubResponse()),
            (OpenGroupAPI.Endpoint.rooms, [OpenGroupAPI.Room].mockBatchSubResponse())
        ]
    )
    
    // MARK: - Invalid Responses
        
    static let mockCapabilitiesAndBanResponse: AnyPublisher<(ResponseInfoType, Data?), Error> = MockNetwork.batchResponseData(
        with: [
            (OpenGroupAPI.Endpoint.capabilities, OpenGroupAPI.Capabilities.mockBatchSubResponse()),
            (OpenGroupAPI.Endpoint.userBan(""), NoResponse.mockBatchSubResponse())
        ]
    )
    
    static let mockBanAndRoomResponse: AnyPublisher<(ResponseInfoType, Data?), Error> = MockNetwork.batchResponseData(
        with: [
            (OpenGroupAPI.Endpoint.userBan(""), NoResponse.mockBatchSubResponse()),
            (OpenGroupAPI.Endpoint.room("testRoom"), OpenGroupAPI.Room.mockBatchSubResponse())
        ]
    )
    
    static let mockBanAndRoomsResponse: AnyPublisher<(ResponseInfoType, Data?), Error> = MockNetwork.batchResponseData(
        with: [
            (OpenGroupAPI.Endpoint.userBan(""), NoResponse.mockBatchSubResponse()),
            (OpenGroupAPI.Endpoint.rooms, [OpenGroupAPI.Room].mockBatchSubResponse())
        ]
    )
}

private extension Network.Destination {
    var testX25519Pubkey: String? {
        switch self {
            case .cached: return nil
            case .snode(_, let swarmPublicKey): return swarmPublicKey
            case .randomSnode(let swarmPublicKey, _), .randomSnodeLatestNetworkTimeTarget(let swarmPublicKey, _, _):
                return swarmPublicKey
            case .server(let info), .serverDownload(let info), .serverUpload(let info, _): return info.x25519PublicKey
        }
    }
    
    var testHeaders: [HTTPHeader: String]? {
        switch self {
            case .cached, .snode, .randomSnode, .randomSnodeLatestNetworkTimeTarget: return nil
            case .server(let info), .serverDownload(let info), .serverUpload(let info, _): return info.headers
        }
    }
}
