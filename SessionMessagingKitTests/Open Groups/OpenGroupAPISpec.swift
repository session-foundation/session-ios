// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import SessionNetworkingKit
import SessionUtilitiesKit
import TestUtilities

import Quick
import Nimble

@testable import SessionMessagingKit

class OpenGroupAPISpec: AsyncSpec {
    override class func spec() {
        // MARK: Configuration
        
        @TestState var dependencies: TestDependencies! = TestDependencies { dependencies in
            dependencies.dateNow = Date(timeIntervalSince1970: 1234567890)
            dependencies.forceSynchronous = true
        }
        @TestState var mockNetwork: MockNetwork! = .create(using: dependencies)
        @TestState(singleton: .crypto, in: dependencies) var mockCrypto: MockCrypto! = .create(using: dependencies)
        @TestState var mockGeneralCache: MockGeneralCache! = .create(using: dependencies)
        @TestState var mockLibSessionCache: MockLibSessionCache! = MockLibSessionCache()
        @TestState var disposables: [AnyCancellable]! = []
        @TestState var error: Error?
        
        beforeEach {
            /// The compiler kept crashing when doing this via `@TestState` so need to do it here instead
            try await mockGeneralCache.defaultInitialSetup()
            dependencies.set(cache: .general, to: mockGeneralCache)
            
            mockLibSessionCache.defaultInitialSetup()
            dependencies.set(cache: .libSession, to: mockLibSessionCache)
            
            try await mockCrypto
                .when { $0.generate(.hash(message: .any, key: .any, length: .any)) }
                .thenReturn([])
            try await mockCrypto
                .when { $0.generate(.blinded15KeyPair(serverPublicKey: .any, ed25519SecretKey: .any)) }
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
                .when { $0.generate(.signatureXed25519(data: .any, curve25519PrivateKey: .any)) }
                .thenReturn("TestStandardSignature".bytes)
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
                .when { $0.generate(.x25519(ed25519Pubkey: .any)) }
                .thenReturn(Array(Data(hex: TestConstants.publicKey)))
            try await mockCrypto
                .when { $0.generate(.x25519(ed25519Seckey: .any)) }
                .thenReturn(Array(Data(hex: TestConstants.privateKey)))
            
            dependencies.set(singleton: .network, to: mockNetwork)
        }
        
        // MARK: - an OpenGroupAPI
        describe("an OpenGroupAPI") {
            // MARK: -- when preparing a poll request
            context("when preparing a poll request") {
                @TestState var preparedRequest: Network.PreparedRequest<Network.BatchResponseMap<OpenGroupAPI.Endpoint>>?
                
                // MARK: ---- generates the correct request
                it("generates the correct request") {
                    expect {
                        preparedRequest = try OpenGroupAPI.preparedPoll(
                            roomInfo: [
                                OpenGroupAPI.RoomInfo(
                                    roomToken: "testRoom",
                                    infoUpdates: 0,
                                    sequenceNumber: 0
                                )
                            ],
                            lastInboxMessageId: 0,
                            lastOutboxMessageId: 0,
                            hasPerformedInitialPoll: false,
                            timeSinceLastPoll: 0,
                            authMethod: Authentication.community(
                                info: LibSession.OpenGroupCapabilityInfo(
                                    roomToken: "",
                                    server: "testserver",
                                    publicKey: TestConstants.publicKey,
                                    capabilities: []
                                ),
                                forceBlinded: false
                            ),
                            using: dependencies
                        )
                    }.toNot(throwError())
                    
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
                    expect {
                        preparedRequest = try OpenGroupAPI.preparedPoll(
                            roomInfo: [
                                OpenGroupAPI.RoomInfo(
                                    roomToken: "testRoom",
                                    infoUpdates: 0,
                                    sequenceNumber: 0
                                )
                            ],
                            lastInboxMessageId: 0,
                            lastOutboxMessageId: 0,
                            hasPerformedInitialPoll: false,
                            timeSinceLastPoll: 0,
                            authMethod: Authentication.community(
                                info: LibSession.OpenGroupCapabilityInfo(
                                    roomToken: "",
                                    server: "testserver",
                                    publicKey: TestConstants.publicKey,
                                    capabilities: []
                                ),
                                forceBlinded: false
                            ),
                            using: dependencies
                        )
                    }.toNot(throwError())
                    
                    expect(preparedRequest?.batchEndpoints[test: 2].asType(OpenGroupAPI.Endpoint.self))
                        .to(equal(.roomMessagesRecent("testRoom")))
                }
                
                // MARK: ---- retrieves recent messages if there was a last message and it has not performed the initial poll and the last message was too long ago
                it("retrieves recent messages if there was a last message and it has not performed the initial poll and the last message was too long ago") {
                    expect {
                        preparedRequest = try OpenGroupAPI.preparedPoll(
                            roomInfo: [
                                OpenGroupAPI.RoomInfo(
                                    roomToken: "testRoom",
                                    infoUpdates: 0,
                                    sequenceNumber: 121
                                )
                            ],
                            lastInboxMessageId: 0,
                            lastOutboxMessageId: 0,
                            hasPerformedInitialPoll: false,
                            timeSinceLastPoll: (CommunityPoller.maxInactivityPeriod + 1),
                            authMethod: Authentication.community(
                                info: LibSession.OpenGroupCapabilityInfo(
                                    roomToken: "",
                                    server: "testserver",
                                    publicKey: TestConstants.publicKey,
                                    capabilities: []
                                ),
                                forceBlinded: false
                            ),
                            using: dependencies
                        )
                    }.toNot(throwError())
                    
                    expect(preparedRequest?.batchEndpoints[test: 2].asType(OpenGroupAPI.Endpoint.self))
                        .to(equal(.roomMessagesRecent("testRoom")))
                }
                
                // MARK: ---- retrieves recent messages if there was a last message and it has performed an initial poll but it was not too long ago
                it("retrieves recent messages if there was a last message and it has performed an initial poll but it was not too long ago") {
                    expect {
                        preparedRequest = try OpenGroupAPI.preparedPoll(
                            roomInfo: [
                                OpenGroupAPI.RoomInfo(
                                    roomToken: "testRoom",
                                    infoUpdates: 0,
                                    sequenceNumber: 122
                                )
                            ],
                            lastInboxMessageId: 0,
                            lastOutboxMessageId: 0,
                            hasPerformedInitialPoll: false,
                            timeSinceLastPoll: 0,
                            authMethod: Authentication.community(
                                info: LibSession.OpenGroupCapabilityInfo(
                                    roomToken: "",
                                    server: "testserver",
                                    publicKey: TestConstants.publicKey,
                                    capabilities: []
                                ),
                                forceBlinded: false
                            ),
                            using: dependencies
                        )
                    }.toNot(throwError())
                    
                    expect(preparedRequest?.batchEndpoints[test: 2].asType(OpenGroupAPI.Endpoint.self))
                        .to(equal(.roomMessagesSince("testRoom", seqNo: 122)))
                }
                
                // MARK: ---- retrieves recent messages if there was a last message and there has already been a poll this session
                it("retrieves recent messages if there was a last message and there has already been a poll this session") {
                    expect {
                        preparedRequest = try OpenGroupAPI.preparedPoll(
                            roomInfo: [
                                OpenGroupAPI.RoomInfo(
                                    roomToken: "testRoom",
                                    infoUpdates: 0,
                                    sequenceNumber: 123
                                )
                            ],
                            lastInboxMessageId: 0,
                            lastOutboxMessageId: 0,
                            hasPerformedInitialPoll: true,
                            timeSinceLastPoll: 0,
                            authMethod: Authentication.community(
                                info: LibSession.OpenGroupCapabilityInfo(
                                    roomToken: "",
                                    server: "testserver",
                                    publicKey: TestConstants.publicKey,
                                    capabilities: []
                                ),
                                forceBlinded: false
                            ),
                            using: dependencies
                        )
                    }.toNot(throwError())
                    
                    expect(preparedRequest?.batchEndpoints[test: 2].asType(OpenGroupAPI.Endpoint.self))
                        .to(equal(.roomMessagesSince("testRoom", seqNo: 123)))
                }
                
                // MARK: ---- when unblinded
                context("when unblinded") {
                    // MARK: ------ does not call the inbox and outbox endpoints
                    it("does not call the inbox and outbox endpoints") {
                        expect {
                            preparedRequest = try OpenGroupAPI.preparedPoll(
                                roomInfo: [
                                    OpenGroupAPI.RoomInfo(
                                        roomToken: "testRoom",
                                        infoUpdates: 0,
                                        sequenceNumber: 0
                                    )
                                ],
                                lastInboxMessageId: 0,
                                lastOutboxMessageId: 0,
                                hasPerformedInitialPoll: true,
                                timeSinceLastPoll: 0,
                                authMethod: Authentication.community(
                                    info: LibSession.OpenGroupCapabilityInfo(
                                        roomToken: "",
                                        server: "testserver",
                                        publicKey: TestConstants.publicKey,
                                        capabilities: [.sogs]
                                    ),
                                    forceBlinded: false
                                ),
                                using: dependencies
                            )
                        }.toNot(throwError())
                        
                        expect(preparedRequest?.batchEndpoints as? [OpenGroupAPI.Endpoint]).toNot(contain(.inbox))
                        expect(preparedRequest?.batchEndpoints as? [OpenGroupAPI.Endpoint]).toNot(contain(.outbox))
                    }
                }
                
                // MARK: ---- when blinded and checking for message requests
                context("when blinded and checking for message requests") {
                    beforeEach {
                        mockLibSessionCache.when { $0.get(.checkForCommunityMessageRequests) }.thenReturn(true)
                    }
                
                    // MARK: ------ includes the inbox and outbox endpoints
                    it("includes the inbox and outbox endpoints") {
                        expect {
                            preparedRequest = try OpenGroupAPI.preparedPoll(
                                roomInfo: [
                                    OpenGroupAPI.RoomInfo(
                                        roomToken: "testRoom",
                                        infoUpdates: 0,
                                        sequenceNumber: 0
                                    )
                                ],
                                lastInboxMessageId: 0,
                                lastOutboxMessageId: 0,
                                hasPerformedInitialPoll: true,
                                timeSinceLastPoll: 0,
                                authMethod: Authentication.community(
                                    info: LibSession.OpenGroupCapabilityInfo(
                                        roomToken: "",
                                        server: "testserver",
                                        publicKey: TestConstants.publicKey,
                                        capabilities: [.sogs, .blind]
                                    ),
                                    forceBlinded: false
                                ),
                                using: dependencies
                            )
                        }.toNot(throwError())
                        
                        expect(preparedRequest?.batchEndpoints as? [OpenGroupAPI.Endpoint]).to(contain(.inbox))
                        expect(preparedRequest?.batchEndpoints as? [OpenGroupAPI.Endpoint]).to(contain(.outbox))
                    }
                    
                    // MARK: ------ retrieves recent inbox messages if there was no last message
                    it("retrieves recent inbox messages if there was no last message") {
                        expect {
                            preparedRequest = try OpenGroupAPI.preparedPoll(
                                roomInfo: [
                                    OpenGroupAPI.RoomInfo(
                                        roomToken: "testRoom",
                                        infoUpdates: 0,
                                        sequenceNumber: 0
                                    )
                                ],
                                lastInboxMessageId: 0,
                                lastOutboxMessageId: 0,
                                hasPerformedInitialPoll: true,
                                timeSinceLastPoll: 0,
                                authMethod: Authentication.community(
                                    info: LibSession.OpenGroupCapabilityInfo(
                                        roomToken: "",
                                        server: "testserver",
                                        publicKey: TestConstants.publicKey,
                                        capabilities: [.sogs, .blind]
                                    ),
                                    forceBlinded: false
                                ),
                                using: dependencies
                            )
                        }.toNot(throwError())
                        
                        expect(preparedRequest?.batchEndpoints as? [OpenGroupAPI.Endpoint]).to(contain(.inbox))
                    }
                    
                    // MARK: ------ retrieves inbox messages since the last message if there was one
                    it("retrieves inbox messages since the last message if there was one") {
                        expect {
                            preparedRequest = try OpenGroupAPI.preparedPoll(
                                roomInfo: [
                                    OpenGroupAPI.RoomInfo(
                                        roomToken: "testRoom",
                                        infoUpdates: 0,
                                        sequenceNumber: 0
                                    )
                                ],
                                lastInboxMessageId: 124,
                                lastOutboxMessageId: 0,
                                hasPerformedInitialPoll: true,
                                timeSinceLastPoll: 0,
                                authMethod: Authentication.community(
                                    info: LibSession.OpenGroupCapabilityInfo(
                                        roomToken: "",
                                        server: "testserver",
                                        publicKey: TestConstants.publicKey,
                                        capabilities: [.sogs, .blind]
                                    ),
                                    forceBlinded: false
                                ),
                                using: dependencies
                            )
                        }.toNot(throwError())
                        
                        expect(preparedRequest?.batchEndpoints as? [OpenGroupAPI.Endpoint]).to(contain(.inboxSince(id: 124)))
                    }
                    
                    // MARK: ------ retrieves recent outbox messages if there was no last message
                    it("retrieves recent outbox messages if there was no last message") {
                        expect {
                            preparedRequest = try OpenGroupAPI.preparedPoll(
                                roomInfo: [
                                    OpenGroupAPI.RoomInfo(
                                        roomToken: "testRoom",
                                        infoUpdates: 0,
                                        sequenceNumber: 0
                                    )
                                ],
                                lastInboxMessageId: 0,
                                lastOutboxMessageId: 0,
                                hasPerformedInitialPoll: true,
                                timeSinceLastPoll: 0,
                                authMethod: Authentication.community(
                                    info: LibSession.OpenGroupCapabilityInfo(
                                        roomToken: "",
                                        server: "testserver",
                                        publicKey: TestConstants.publicKey,
                                        capabilities: [.sogs, .blind]
                                    ),
                                    forceBlinded: false
                                ),
                                using: dependencies
                            )
                        }.toNot(throwError())
                        
                        expect(preparedRequest?.batchEndpoints as? [OpenGroupAPI.Endpoint]).to(contain(.outbox))
                    }
                    
                    // MARK: ------ retrieves outbox messages since the last message if there was one
                    it("retrieves outbox messages since the last message if there was one") {
                        expect {
                            preparedRequest = try OpenGroupAPI.preparedPoll(
                                roomInfo: [
                                    OpenGroupAPI.RoomInfo(
                                        roomToken: "testRoom",
                                        infoUpdates: 0,
                                        sequenceNumber: 0
                                    )
                                ],
                                lastInboxMessageId: 0,
                                lastOutboxMessageId: 125,
                                hasPerformedInitialPoll: true,
                                timeSinceLastPoll: 0,
                                authMethod: Authentication.community(
                                    info: LibSession.OpenGroupCapabilityInfo(
                                        roomToken: "",
                                        server: "testserver",
                                        publicKey: TestConstants.publicKey,
                                        capabilities: [.sogs, .blind]
                                    ),
                                    forceBlinded: false
                                ),
                                using: dependencies
                            )
                        }.toNot(throwError())
                        
                        expect(preparedRequest?.batchEndpoints as? [OpenGroupAPI.Endpoint]).to(contain(.outboxSince(id: 125)))
                    }
                }
                
                // MARK: ---- when blinded and not checking for message requests
                context("when blinded and not checking for message requests") {
                    beforeEach {
                        mockLibSessionCache.when { $0.get(.checkForCommunityMessageRequests) }.thenReturn(false)
                    }
                    
                    // MARK: ------ includes the inbox and outbox endpoints
                    it("does not include the inbox endpoint") {
                        expect {
                            preparedRequest = try OpenGroupAPI.preparedPoll(
                                roomInfo: [
                                    OpenGroupAPI.RoomInfo(
                                        roomToken: "testRoom",
                                        infoUpdates: 0,
                                        sequenceNumber: 0
                                    )
                                ],
                                lastInboxMessageId: 0,
                                lastOutboxMessageId: 0,
                                hasPerformedInitialPoll: true,
                                timeSinceLastPoll: 0,
                                authMethod: Authentication.community(
                                    info: LibSession.OpenGroupCapabilityInfo(
                                        roomToken: "",
                                        server: "testserver",
                                        publicKey: TestConstants.publicKey,
                                        capabilities: [.sogs, .blind]
                                    ),
                                    forceBlinded: false
                                ),
                                using: dependencies
                            )
                        }.toNot(throwError())
                        
                        expect(preparedRequest?.batchEndpoints as? [OpenGroupAPI.Endpoint]).toNot(contain(.inbox))
                    }
                    
                    // MARK: ------ does not retrieve recent inbox messages if there was no last message
                    it("does not retrieve recent inbox messages if there was no last message") {
                        expect {
                            preparedRequest = try OpenGroupAPI.preparedPoll(
                                roomInfo: [
                                    OpenGroupAPI.RoomInfo(
                                        roomToken: "testRoom",
                                        infoUpdates: 0,
                                        sequenceNumber: 0
                                    )
                                ],
                                lastInboxMessageId: 0,
                                lastOutboxMessageId: 0,
                                hasPerformedInitialPoll: true,
                                timeSinceLastPoll: 0,
                                authMethod: Authentication.community(
                                    info: LibSession.OpenGroupCapabilityInfo(
                                        roomToken: "",
                                        server: "testserver",
                                        publicKey: TestConstants.publicKey,
                                        capabilities: [.sogs, .blind]
                                    ),
                                    forceBlinded: false
                                ),
                                using: dependencies
                            )
                        }.toNot(throwError())
                        
                        expect(preparedRequest?.batchEndpoints as? [OpenGroupAPI.Endpoint]).toNot(contain(.inbox))
                    }
                    
                    // MARK: ------ does not retrieve inbox messages since the last message if there was one
                    it("does not retrieve inbox messages since the last message if there was one") {
                        expect {
                            preparedRequest = try OpenGroupAPI.preparedPoll(
                                roomInfo: [
                                    OpenGroupAPI.RoomInfo(
                                        roomToken: "testRoom",
                                        infoUpdates: 0,
                                        sequenceNumber: 0
                                    )
                                ],
                                lastInboxMessageId: 124,
                                lastOutboxMessageId: 0,
                                hasPerformedInitialPoll: true,
                                timeSinceLastPoll: 0,
                                authMethod: Authentication.community(
                                    info: LibSession.OpenGroupCapabilityInfo(
                                        roomToken: "",
                                        server: "testserver",
                                        publicKey: TestConstants.publicKey,
                                        capabilities: [.sogs, .blind]
                                    ),
                                    forceBlinded: false
                                ),
                                using: dependencies
                            )
                        }.toNot(throwError())
                        
                        expect(preparedRequest?.batchEndpoints as? [OpenGroupAPI.Endpoint]).toNot(contain(.inboxSince(id: 124)))
                    }
                }
            }
            
            // MARK: -- when preparing a capabilities request
            context("when preparing a capabilities request") {
                // MARK: ---- generates the request correctly
                it("generates the request and handles the response correctly") {
                    var preparedRequest: Network.PreparedRequest<OpenGroupAPI.Capabilities>?
                    expect {
                        preparedRequest = try OpenGroupAPI.preparedCapabilities(
                            authMethod: Authentication.community(
                                info: LibSession.OpenGroupCapabilityInfo(
                                    roomToken: "",
                                    server: "testserver",
                                    publicKey: TestConstants.publicKey,
                                    capabilities: []
                                ),
                                forceBlinded: false
                            ),
                            using: dependencies
                        )
                    }.toNot(throwError())
                    
                    expect(preparedRequest?.path).to(equal("/capabilities"))
                    expect(preparedRequest?.method.rawValue).to(equal("GET"))
                }
            }
            
            // MARK: -- when preparing a rooms request
            context("when preparing a rooms request") {
                // MARK: ---- generates the request correctly
                it("generates the request correctly") {
                    var preparedRequest: Network.PreparedRequest<[OpenGroupAPI.Room]>?
                    expect {
                        preparedRequest = try OpenGroupAPI.preparedRooms(
                            authMethod: Authentication.community(
                                info: LibSession.OpenGroupCapabilityInfo(
                                    roomToken: "",
                                    server: "testserver",
                                    publicKey: TestConstants.publicKey,
                                    capabilities: []
                                ),
                                forceBlinded: false
                            ),
                            using: dependencies
                        )
                    }.toNot(throwError())
                    
                    expect(preparedRequest?.path).to(equal("/rooms"))
                    expect(preparedRequest?.method.rawValue).to(equal("GET"))
                }
            }
            
            // MARK: -- when preparing a capabilitiesAndRoom request
            context("when preparing a capabilitiesAndRoom request") {
                @TestState var preparedRequest: Network.PreparedRequest<OpenGroupAPI.CapabilitiesAndRoomResponse>?
                
                // MARK: ---- generates the request correctly
                it("generates the request correctly") {
                    expect {
                        preparedRequest = try OpenGroupAPI.preparedCapabilitiesAndRoom(
                            roomToken: "testRoom",
                            authMethod: Authentication.community(
                                info: LibSession.OpenGroupCapabilityInfo(
                                    roomToken: "",
                                    server: "testserver",
                                    publicKey: TestConstants.publicKey,
                                    capabilities: []
                                ),
                                forceBlinded: false
                            ),
                            using: dependencies
                        )
                    }.toNot(throwError())
                    
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
                    
                    var response: (info: ResponseInfoType, data: OpenGroupAPI.CapabilitiesAndRoomResponse)?
                    
                    expect {
                        preparedRequest = try OpenGroupAPI.preparedCapabilitiesAndRoom(
                            roomToken: "testRoom",
                            authMethod: Authentication.community(
                                info: LibSession.OpenGroupCapabilityInfo(
                                    roomToken: "",
                                    server: "testserver",
                                    publicKey: TestConstants.publicKey,
                                    capabilities: []
                                ),
                                forceBlinded: false
                            ),
                            using: dependencies
                        )
                    }.toNot(throwError())
                    
                    preparedRequest?
                        .send(using: dependencies)
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
                            .thenReturn(Network.BatchResponse.mockCapabilitiesAndBanResponse)
                        
                        var response: (info: ResponseInfoType, data: OpenGroupAPI.CapabilitiesAndRoomResponse)?
                        
                        expect {
                            preparedRequest = try OpenGroupAPI.preparedCapabilitiesAndRoom(
                                roomToken: "testRoom",
                                authMethod: Authentication.community(
                                    info: LibSession.OpenGroupCapabilityInfo(
                                        roomToken: "",
                                        server: "testserver",
                                        publicKey: TestConstants.publicKey,
                                        capabilities: []
                                    ),
                                    forceBlinded: false
                                ),
                                using: dependencies
                            )
                        }.toNot(throwError())
                        
                        preparedRequest?
                            .send(using: dependencies)
                            .handleEvents(receiveOutput: { result in response = result })
                            .mapError { error.setting(to: $0) }
                            .sinkAndStore(in: &disposables)
                        
                        expect(error).to(matchError(NetworkError.parsingFailed))
                        expect(response).to(beNil())
                    }
                    
                    // MARK: ------ errors when not given a capabilities response
                    it("errors when not given a capabilities response") {
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
                            .thenReturn(Network.BatchResponse.mockBanAndRoomResponse)
                        
                        var response: (info: ResponseInfoType, data: OpenGroupAPI.CapabilitiesAndRoomResponse)?
                        
                        expect {
                            preparedRequest = try OpenGroupAPI.preparedCapabilitiesAndRoom(
                                roomToken: "testRoom",
                                authMethod: Authentication.community(
                                    info: LibSession.OpenGroupCapabilityInfo(
                                        roomToken: "",
                                        server: "testserver",
                                        publicKey: TestConstants.publicKey,
                                        capabilities: []
                                    ),
                                    forceBlinded: false
                                ),
                                using: dependencies
                            )
                        }.toNot(throwError())
                        
                        preparedRequest?
                            .send(using: dependencies)
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
                @TestState var preparedRequest: Network.PreparedRequest<OpenGroupAPI.CapabilitiesAndRoomsResponse>?
                
                // MARK: ---- generates the request correctly
                it("generates the request correctly") {
                    expect {
                        preparedRequest = try OpenGroupAPI.preparedCapabilitiesAndRooms(
                            authMethod: Authentication.community(
                                info: LibSession.OpenGroupCapabilityInfo(
                                    roomToken: "",
                                    server: "testserver",
                                    publicKey: TestConstants.publicKey,
                                    capabilities: []
                                ),
                                forceBlinded: false
                            ),
                            using: dependencies
                        )
                    }.toNot(throwError())
                    
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
                        .thenReturn(Network.BatchResponse.mockCapabilitiesAndRoomsResponse)
                    
                    var response: (info: ResponseInfoType, data: OpenGroupAPI.CapabilitiesAndRoomsResponse)?
                    
                    expect {
                        preparedRequest = try OpenGroupAPI.preparedCapabilitiesAndRooms(
                            authMethod: Authentication.community(
                                info: LibSession.OpenGroupCapabilityInfo(
                                    roomToken: "",
                                    server: "testserver",
                                    publicKey: TestConstants.publicKey,
                                    capabilities: []
                                ),
                                forceBlinded: false
                            ),
                            using: dependencies
                        )
                    }.toNot(throwError())
                    
                    preparedRequest?
                        .send(using: dependencies)
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
                        
                        expect {
                            preparedRequest = try OpenGroupAPI.preparedCapabilitiesAndRooms(
                                authMethod: Authentication.community(
                                    info: LibSession.OpenGroupCapabilityInfo(
                                        roomToken: "",
                                        server: "testserver",
                                        publicKey: TestConstants.publicKey,
                                        capabilities: []
                                    ),
                                    forceBlinded: false
                                ),
                                using: dependencies
                            )
                        }.toNot(throwError())
                        
                        preparedRequest?
                            .send(using: dependencies)
                            .handleEvents(receiveOutput: { result in response = result })
                            .mapError { error.setting(to: $0) }
                            .sinkAndStore(in: &disposables)
                        
                        expect(error).to(matchError(NetworkError.parsingFailed))
                        expect(response).to(beNil())
                    }
                    
                    // MARK: ------ errors when not given a capabilities response
                    it("errors when not given a capabilities response") {
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
                            .thenReturn(Network.BatchResponse.mockBanAndRoomsResponse)
                        
                        var response: (info: ResponseInfoType, data: OpenGroupAPI.CapabilitiesAndRoomsResponse)?
                        
                        expect {
                            preparedRequest = try OpenGroupAPI.preparedCapabilitiesAndRooms(
                                authMethod: Authentication.community(
                                    info: LibSession.OpenGroupCapabilityInfo(
                                        roomToken: "",
                                        server: "testserver",
                                        publicKey: TestConstants.publicKey,
                                        capabilities: []
                                    ),
                                    forceBlinded: false
                                ),
                                using: dependencies
                            )
                        }.toNot(throwError())
                        
                        preparedRequest?
                            .send(using: dependencies)
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
                @TestState var preparedRequest: Network.PreparedRequest<OpenGroupAPI.Message>?
                
                // MARK: ---- generates the request correctly
                it("generates the request correctly") {
                    expect {
                        preparedRequest = try OpenGroupAPI.preparedSend(
                            plaintext: "test".data(using: .utf8)!,
                            roomToken: "testRoom",
                            whisperTo: nil,
                            whisperMods: false,
                            fileIds: nil,
                            authMethod: Authentication.community(
                                info: LibSession.OpenGroupCapabilityInfo(
                                    roomToken: "",
                                    server: "testserver",
                                    publicKey: TestConstants.publicKey,
                                    capabilities: []
                                ),
                                forceBlinded: false
                            ),
                            using: dependencies
                        )
                    }.toNot(throwError())
                    
                    expect(preparedRequest?.path).to(equal("/room/testRoom/message"))
                    expect(preparedRequest?.method.rawValue).to(equal("POST"))
                }
                
                // MARK: ---- when unblinded
                context("when unblinded") {
                    // MARK: ------ signs the message correctly
                    it("signs the message correctly") {
                        expect {
                            preparedRequest = try OpenGroupAPI.preparedSend(
                                plaintext: "test".data(using: .utf8)!,
                                roomToken: "testRoom",
                                whisperTo: nil,
                                whisperMods: false,
                                fileIds: nil,
                                authMethod: Authentication.community(
                                    info: LibSession.OpenGroupCapabilityInfo(
                                        roomToken: "",
                                        server: "testserver",
                                        publicKey: TestConstants.publicKey,
                                        capabilities: [.sogs]
                                    ),
                                    forceBlinded: false
                                ),
                                using: dependencies
                            )
                        }.toNot(throwError())
                        
                        let requestBody: OpenGroupAPI.SendMessageRequest? = try? preparedRequest?.body?
                            .decoded(as: OpenGroupAPI.SendMessageRequest.self, using: dependencies)
                        expect(requestBody?.data).to(equal("test".data(using: .utf8)))
                        expect(requestBody?.signature).to(equal("TestStandardSignature".data(using: .utf8)))
                    }
                    
                    // MARK: ------ fails to sign if there is no ed25519SecretKey
                    it("fails to sign if there is no ed25519SecretKey") {
                        try await mockGeneralCache.when { $0.ed25519SecretKey }.thenReturn([])
                        
                        expect {
                            preparedRequest = try OpenGroupAPI.preparedSend(
                                plaintext: "test".data(using: .utf8)!,
                                roomToken: "testRoom",
                                whisperTo: nil,
                                whisperMods: false,
                                fileIds: nil,
                                authMethod: Authentication.community(
                                    info: LibSession.OpenGroupCapabilityInfo(
                                        roomToken: "",
                                        server: "testserver",
                                        publicKey: TestConstants.publicKey,
                                        capabilities: [.sogs]
                                    ),
                                    forceBlinded: false
                                ),
                                using: dependencies
                            )
                        }.to(throwError(OpenGroupAPIError.signingFailed))
                        
                        expect(preparedRequest).to(beNil())
                    }
                    
                    // MARK: ------ fails to sign if there is ed25519Seed
                    it("fails to sign if there is ed25519Seed") {
                        try await mockGeneralCache.when { $0.ed25519Seed }.thenReturn([])
                        
                        expect {
                            preparedRequest = try OpenGroupAPI.preparedSend(
                                plaintext: "test".data(using: .utf8)!,
                                roomToken: "testRoom",
                                whisperTo: nil,
                                whisperMods: false,
                                fileIds: nil,
                                authMethod: Authentication.community(
                                    info: LibSession.OpenGroupCapabilityInfo(
                                        roomToken: "",
                                        server: "testserver",
                                        publicKey: TestConstants.publicKey,
                                        capabilities: [.sogs]
                                    ),
                                    forceBlinded: false
                                ),
                                using: dependencies
                            )
                        }.to(throwError(OpenGroupAPIError.signingFailed))
                        
                        expect(preparedRequest).to(beNil())
                    }
                    
                    // MARK: ------ fails to sign if no signature is generated
                    it("fails to sign if no signature is generated") {
                        try await mockCrypto
                            .when { $0.generate(.signatureXed25519(data: .any, curve25519PrivateKey: .any)) }
                            .thenReturn(nil)
                        
                        expect {
                            preparedRequest = try OpenGroupAPI.preparedSend(
                                plaintext: "test".data(using: .utf8)!,
                                roomToken: "testRoom",
                                whisperTo: nil,
                                whisperMods: false,
                                fileIds: nil,
                                authMethod: Authentication.community(
                                    info: LibSession.OpenGroupCapabilityInfo(
                                        roomToken: "",
                                        server: "testserver",
                                        publicKey: TestConstants.publicKey,
                                        capabilities: [.sogs]
                                    ),
                                    forceBlinded: false
                                ),
                                using: dependencies
                            )
                        }.to(throwError(OpenGroupAPIError.signingFailed))
                        
                        expect(preparedRequest).to(beNil())
                    }
                }
                
                // MARK: ---- when blinded
                context("when blinded") {
                    // MARK: ------ signs the message correctly
                    it("signs the message correctly") {
                        expect {
                            preparedRequest = try OpenGroupAPI.preparedSend(
                                plaintext: "test".data(using: .utf8)!,
                                roomToken: "testRoom",
                                whisperTo: nil,
                                whisperMods: false,
                                fileIds: nil,
                                authMethod: Authentication.community(
                                    info: LibSession.OpenGroupCapabilityInfo(
                                        roomToken: "",
                                        server: "testserver",
                                        publicKey: TestConstants.publicKey,
                                        capabilities: [.sogs, .blind]
                                    ),
                                    forceBlinded: false
                                ),
                                using: dependencies
                            )
                        }.toNot(throwError())
                        
                        let requestBody: OpenGroupAPI.SendMessageRequest? = try? preparedRequest?.body?
                            .decoded(as: OpenGroupAPI.SendMessageRequest.self, using: dependencies)
                        expect(requestBody?.data).to(equal("test".data(using: .utf8)))
                        expect(requestBody?.signature).to(equal("TestSogsSignature".data(using: .utf8)))
                    }
                    
                    // MARK: ------ fails to sign if there is no ed25519SecretKey
                    it("fails to sign if there is no ed25519SecretKey") {
                        try await mockGeneralCache.when { $0.ed25519SecretKey }.thenReturn([])
                        
                        expect {
                            preparedRequest = try OpenGroupAPI.preparedSend(
                                plaintext: "test".data(using: .utf8)!,
                                roomToken: "testRoom",
                                whisperTo: nil,
                                whisperMods: false,
                                fileIds: nil,
                                authMethod: Authentication.community(
                                    info: LibSession.OpenGroupCapabilityInfo(
                                        roomToken: "",
                                        server: "testserver",
                                        publicKey: TestConstants.publicKey,
                                        capabilities: [.sogs, .blind]
                                    ),
                                    forceBlinded: false
                                ),
                                using: dependencies
                            )
                        }.to(throwError(OpenGroupAPIError.signingFailed))
                        
                        expect(preparedRequest).to(beNil())
                    }
                    
                    // MARK: ------ fails to sign if there is no ed25519Seed
                    it("fails to sign if there is no ed25519Seed") {
                        try await mockGeneralCache.when { $0.ed25519Seed }.thenReturn([])
                        
                        expect {
                            preparedRequest = try OpenGroupAPI.preparedSend(
                                plaintext: "test".data(using: .utf8)!,
                                roomToken: "testRoom",
                                whisperTo: nil,
                                whisperMods: false,
                                fileIds: nil,
                                authMethod: Authentication.community(
                                    info: LibSession.OpenGroupCapabilityInfo(
                                        roomToken: "",
                                        server: "testserver",
                                        publicKey: TestConstants.publicKey,
                                        capabilities: [.sogs, .blind]
                                    ),
                                    forceBlinded: false
                                ),
                                using: dependencies
                            )
                        }.to(throwError(OpenGroupAPIError.signingFailed))
                        
                        expect(preparedRequest).to(beNil())
                    }
                    
                    // MARK: ------ fails to sign if no signature is generated
                    it("fails to sign if no signature is generated") {
                        try await mockCrypto
                            .when { $0.generate(.signatureBlind15(message: .any, serverPublicKey: .any, ed25519SecretKey: .any)) }
                            .thenReturn(nil)
                        
                        expect {
                            preparedRequest = try OpenGroupAPI.preparedSend(
                                plaintext: "test".data(using: .utf8)!,
                                roomToken: "testRoom",
                                whisperTo: nil,
                                whisperMods: false,
                                fileIds: nil,
                                authMethod: Authentication.community(
                                    info: LibSession.OpenGroupCapabilityInfo(
                                        roomToken: "",
                                        server: "testserver",
                                        publicKey: TestConstants.publicKey,
                                        capabilities: [.sogs, .blind]
                                    ),
                                    forceBlinded: false
                                ),
                                using: dependencies
                            )
                        }.to(throwError(OpenGroupAPIError.signingFailed))
                        
                        expect(preparedRequest).to(beNil())
                    }
                }
            }
            
            // MARK: -- when preparing an individual message request
            context("when preparing an individual message request") {
                var preparedRequest: Network.PreparedRequest<OpenGroupAPI.Message>?
                
                // MARK: ---- generates the request correctly
                it("generates the request correctly") {
                    expect {
                        preparedRequest = try OpenGroupAPI.preparedMessage(
                            id: 123,
                            roomToken: "testRoom",
                            authMethod: Authentication.community(
                                info: LibSession.OpenGroupCapabilityInfo(
                                    roomToken: "",
                                    server: "testserver",
                                    publicKey: TestConstants.publicKey,
                                    capabilities: []
                                ),
                                forceBlinded: false
                            ),
                            using: dependencies
                        )
                    }.toNot(throwError())
                    
                    expect(preparedRequest?.path).to(equal("/room/testRoom/message/123"))
                    expect(preparedRequest?.method.rawValue).to(equal("GET"))
                }
            }
            
            // MARK: -- when preparing an update message request
            context("when preparing an update message request") {
                @TestState var preparedRequest: Network.PreparedRequest<NoResponse>?
                
                // MARK: ---- generates the request correctly
                it("generates the request correctly") {
                    expect {
                        preparedRequest = try OpenGroupAPI.preparedMessageUpdate(
                            id: 123,
                            plaintext: "test".data(using: .utf8)!,
                            fileIds: nil,
                            roomToken: "testRoom",
                            authMethod: Authentication.community(
                                info: LibSession.OpenGroupCapabilityInfo(
                                    roomToken: "",
                                    server: "testserver",
                                    publicKey: TestConstants.publicKey,
                                    capabilities: []
                                ),
                                forceBlinded: false
                            ),
                            using: dependencies
                        )
                    }.toNot(throwError())
                    
                    expect(preparedRequest?.path).to(equal("/room/testRoom/message/123"))
                    expect(preparedRequest?.method.rawValue).to(equal("PUT"))
                }
                
                // MARK: ---- when unblinded
                context("when unblinded") {
                    // MARK: ------ signs the message correctly
                    it("signs the message correctly") {
                        expect {
                            preparedRequest = try OpenGroupAPI.preparedMessageUpdate(
                                id: 123,
                                plaintext: "test".data(using: .utf8)!,
                                fileIds: nil,
                                roomToken: "testRoom",
                                authMethod: Authentication.community(
                                    info: LibSession.OpenGroupCapabilityInfo(
                                        roomToken: "",
                                        server: "testserver",
                                        publicKey: TestConstants.publicKey,
                                        capabilities: [.sogs]
                                    ),
                                    forceBlinded: false
                                ),
                                using: dependencies
                            )
                        }.toNot(throwError())
                        
                        let requestBody: OpenGroupAPI.UpdateMessageRequest? = try? preparedRequest?.body?
                            .decoded(as: OpenGroupAPI.UpdateMessageRequest.self, using: dependencies)
                        expect(requestBody?.data).to(equal("test".data(using: .utf8)))
                        expect(requestBody?.signature).to(equal("TestStandardSignature".data(using: .utf8)))
                    }
                    
                    // MARK: ------ fails to sign if there is no ed25519SecretKey
                    it("fails to sign if there is no ed25519SecretKey") {
                        try await mockGeneralCache.when { $0.ed25519SecretKey }.thenReturn([])
                        
                        expect {
                            preparedRequest = try OpenGroupAPI.preparedMessageUpdate(
                                id: 123,
                                plaintext: "test".data(using: .utf8)!,
                                fileIds: nil,
                                roomToken: "testRoom",
                                authMethod: Authentication.community(
                                    info: LibSession.OpenGroupCapabilityInfo(
                                        roomToken: "",
                                        server: "testserver",
                                        publicKey: TestConstants.publicKey,
                                        capabilities: [.sogs]
                                    ),
                                    forceBlinded: false
                                ),
                                using: dependencies
                            )
                        }.to(throwError(OpenGroupAPIError.signingFailed))
                        
                        expect(preparedRequest).to(beNil())
                    }
                    
                    // MARK: ------ fails to sign if there is no ed25519Seed
                    it("fails to sign if there is no ed25519Seed") {
                        try await mockGeneralCache.when { $0.ed25519Seed }.thenReturn([])
                        
                        expect {
                            preparedRequest = try OpenGroupAPI.preparedMessageUpdate(
                                id: 123,
                                plaintext: "test".data(using: .utf8)!,
                                fileIds: nil,
                                roomToken: "testRoom",
                                authMethod: Authentication.community(
                                    info: LibSession.OpenGroupCapabilityInfo(
                                        roomToken: "",
                                        server: "testserver",
                                        publicKey: TestConstants.publicKey,
                                        capabilities: [.sogs]
                                    ),
                                    forceBlinded: false
                                ),
                                using: dependencies
                            )
                        }.to(throwError(OpenGroupAPIError.signingFailed))
                        
                        expect(preparedRequest).to(beNil())
                    }
                    
                    // MARK: ------ fails to sign if no signature is generated
                    it("fails to sign if no signature is generated") {
                        try await mockCrypto
                            .when { $0.generate(.signatureXed25519(data: .any, curve25519PrivateKey: .any)) }
                            .thenReturn(nil)
                        
                        expect {
                            preparedRequest = try OpenGroupAPI.preparedMessageUpdate(
                                id: 123,
                                plaintext: "test".data(using: .utf8)!,
                                fileIds: nil,
                                roomToken: "testRoom",
                                authMethod: Authentication.community(
                                    info: LibSession.OpenGroupCapabilityInfo(
                                        roomToken: "",
                                        server: "testserver",
                                        publicKey: TestConstants.publicKey,
                                        capabilities: [.sogs]
                                    ),
                                    forceBlinded: false
                                ),
                                using: dependencies
                            )
                        }.to(throwError(OpenGroupAPIError.signingFailed))
                        
                        expect(preparedRequest).to(beNil())
                    }
                }
                
                // MARK: ---- when blinded
                context("when blinded") {
                    // MARK: ------ signs the message correctly
                    it("signs the message correctly") {
                        expect {
                            preparedRequest = try OpenGroupAPI.preparedMessageUpdate(
                                id: 123,
                                plaintext: "test".data(using: .utf8)!,
                                fileIds: nil,
                                roomToken: "testRoom",
                                authMethod: Authentication.community(
                                    info: LibSession.OpenGroupCapabilityInfo(
                                        roomToken: "",
                                        server: "testserver",
                                        publicKey: TestConstants.publicKey,
                                        capabilities: [.sogs, .blind]
                                    ),
                                    forceBlinded: false
                                ),
                                using: dependencies
                            )
                        }.toNot(throwError())
                        
                        let requestBody: OpenGroupAPI.UpdateMessageRequest? = try? preparedRequest?.body?
                            .decoded(as: OpenGroupAPI.UpdateMessageRequest.self, using: dependencies)
                        expect(requestBody?.data).to(equal("test".data(using: .utf8)))
                        expect(requestBody?.signature).to(equal("TestSogsSignature".data(using: .utf8)))
                    }
                    
                    // MARK: ------ fails to sign if there is no ed25519SecretKey
                    it("fails to sign if there is no ed25519SecretKey") {
                        try await mockGeneralCache.when { $0.ed25519SecretKey }.thenReturn([])
                        
                        expect {
                            preparedRequest = try OpenGroupAPI.preparedMessageUpdate(
                                id: 123,
                                plaintext: "test".data(using: .utf8)!,
                                fileIds: nil,
                                roomToken: "testRoom",
                                authMethod: Authentication.community(
                                    info: LibSession.OpenGroupCapabilityInfo(
                                        roomToken: "",
                                        server: "testserver",
                                        publicKey: TestConstants.publicKey,
                                        capabilities: [.sogs, .blind]
                                    ),
                                    forceBlinded: false
                                ),
                                using: dependencies
                            )
                        }.to(throwError(OpenGroupAPIError.signingFailed))
                        
                        expect(preparedRequest).to(beNil())
                    }
                    
                    // MARK: ------ fails to sign if there is no ed25519Seed
                    it("fails to sign if there is no ed25519Seed") {
                        try await mockGeneralCache.when { $0.ed25519Seed }.thenReturn([])
                        
                        expect {
                            preparedRequest = try OpenGroupAPI.preparedMessageUpdate(
                                id: 123,
                                plaintext: "test".data(using: .utf8)!,
                                fileIds: nil,
                                roomToken: "testRoom",
                                authMethod: Authentication.community(
                                    info: LibSession.OpenGroupCapabilityInfo(
                                        roomToken: "",
                                        server: "testserver",
                                        publicKey: TestConstants.publicKey,
                                        capabilities: [.sogs, .blind]
                                    ),
                                    forceBlinded: false
                                ),
                                using: dependencies
                            )
                        }.to(throwError(OpenGroupAPIError.signingFailed))
                        
                        expect(preparedRequest).to(beNil())
                    }
                    
                    // MARK: ------ fails to sign if no signature is generated
                    it("fails to sign if no signature is generated") {
                        try await mockCrypto
                            .when { $0.generate(.signatureBlind15(message: .any, serverPublicKey: .any, ed25519SecretKey: .any)) }
                            .thenReturn(nil)
                        
                        expect {
                            preparedRequest = try OpenGroupAPI.preparedMessageUpdate(
                                id: 123,
                                plaintext: "test".data(using: .utf8)!,
                                fileIds: nil,
                                roomToken: "testRoom",
                                authMethod: Authentication.community(
                                    info: LibSession.OpenGroupCapabilityInfo(
                                        roomToken: "",
                                        server: "testserver",
                                        publicKey: TestConstants.publicKey,
                                        capabilities: [.sogs, .blind]
                                    ),
                                    forceBlinded: false
                                ),
                                using: dependencies
                            )
                        }.to(throwError(OpenGroupAPIError.signingFailed))
                        
                        expect(preparedRequest).to(beNil())
                    }
                }
            }
            
            // MARK: -- when preparing a delete message request
            context("when preparing a delete message request") {
                @TestState var preparedRequest: Network.PreparedRequest<NoResponse>?
                
                // MARK: ---- generates the request correctly
                it("generates the request correctly") {
                    expect {
                        preparedRequest = try OpenGroupAPI.preparedMessageDelete(
                            id: 123,
                            roomToken: "testRoom",
                            authMethod: Authentication.community(
                                info: LibSession.OpenGroupCapabilityInfo(
                                    roomToken: "",
                                    server: "testserver",
                                    publicKey: TestConstants.publicKey,
                                    capabilities: []
                                ),
                                forceBlinded: false
                            ),
                            using: dependencies
                        )
                    }.toNot(throwError())
                    
                    expect(preparedRequest?.path).to(equal("/room/testRoom/message/123"))
                    expect(preparedRequest?.method.rawValue).to(equal("DELETE"))
                }
            }
            
            // MARK: -- when preparing a delete all messages request
            context("when preparing a delete all messages request") {
                @TestState var preparedRequest: Network.PreparedRequest<NoResponse>?
                
                // MARK: ---- generates the request correctly
                it("generates the request correctly") {
                    expect {
                        preparedRequest = try OpenGroupAPI.preparedMessagesDeleteAll(
                            sessionId: "testUserId",
                            roomToken: "testRoom",
                            authMethod: Authentication.community(
                                info: LibSession.OpenGroupCapabilityInfo(
                                    roomToken: "",
                                    server: "testserver",
                                    publicKey: TestConstants.publicKey,
                                    capabilities: []
                                ),
                                forceBlinded: false
                            ),
                            using: dependencies
                        )
                    }.toNot(throwError())
                    
                    expect(preparedRequest?.path).to(equal("/room/testRoom/all/testUserId"))
                    expect(preparedRequest?.method.rawValue).to(equal("DELETE"))
                }
            }
            
            // MARK: -- when preparing a pin message request
            context("when preparing a pin message request") {
                @TestState var preparedRequest: Network.PreparedRequest<NoResponse>?
                
                // MARK: ---- generates the request correctly
                it("generates the request correctly") {
                    expect {
                        preparedRequest = try OpenGroupAPI.preparedPinMessage(
                            id: 123,
                            roomToken: "testRoom",
                            authMethod: Authentication.community(
                                info: LibSession.OpenGroupCapabilityInfo(
                                    roomToken: "",
                                    server: "testserver",
                                    publicKey: TestConstants.publicKey,
                                    capabilities: []
                                ),
                                forceBlinded: false
                            ),
                            using: dependencies
                        )
                    }.toNot(throwError())
                    
                    expect(preparedRequest?.path).to(equal("/room/testRoom/pin/123"))
                    expect(preparedRequest?.method.rawValue).to(equal("POST"))
                }
            }
            
            // MARK: -- when preparing an unpin message request
            context("when preparing an unpin message request") {
                @TestState var preparedRequest: Network.PreparedRequest<NoResponse>?
                
                // MARK: ---- generates the request correctly
                it("generates the request correctly") {
                    expect {
                        preparedRequest = try OpenGroupAPI.preparedUnpinMessage(
                            id: 123,
                            roomToken: "testRoom",
                            authMethod: Authentication.community(
                                info: LibSession.OpenGroupCapabilityInfo(
                                    roomToken: "",
                                    server: "testserver",
                                    publicKey: TestConstants.publicKey,
                                    capabilities: []
                                ),
                                forceBlinded: false
                            ),
                            using: dependencies
                        )
                    }.toNot(throwError())
                    
                    expect(preparedRequest?.path).to(equal("/room/testRoom/unpin/123"))
                    expect(preparedRequest?.method.rawValue).to(equal("POST"))
                }
            }
            
            // MARK: -- when preparing an unpin all request
            context("when preparing an unpin all request") {
                @TestState var preparedRequest: Network.PreparedRequest<NoResponse>?
                
                // MARK: ---- generates the request correctly
                it("generates the request correctly") {
                    expect {
                        preparedRequest = try OpenGroupAPI.preparedUnpinAll(
                            roomToken: "testRoom",
                            authMethod: Authentication.community(
                                info: LibSession.OpenGroupCapabilityInfo(
                                    roomToken: "",
                                    server: "testserver",
                                    publicKey: TestConstants.publicKey,
                                    capabilities: []
                                ),
                                forceBlinded: false
                            ),
                            using: dependencies
                        )
                    }.toNot(throwError())
                    
                    expect(preparedRequest?.path).to(equal("/room/testRoom/unpin/all"))
                    expect(preparedRequest?.method.rawValue).to(equal("POST"))
                }
            }
            
            // MARK: -- when generaing an upload request
            context("when generaing an upload request") {
                @TestState var preparedRequest: Network.PreparedRequest<FileUploadResponse>?
                
                // MARK: ---- generates the request correctly
                it("generates the request correctly") {
                    expect {
                        preparedRequest = try OpenGroupAPI.preparedUpload(
                            data: Data([1, 2, 3]),
                            roomToken: "testRoom",
                            authMethod: Authentication.community(
                                info: LibSession.OpenGroupCapabilityInfo(
                                    roomToken: "",
                                    server: "testserver",
                                    publicKey: TestConstants.publicKey,
                                    capabilities: []
                                ),
                                forceBlinded: false
                            ),
                            using: dependencies
                        )
                    }.toNot(throwError())
                    
                    expect(preparedRequest?.path).to(equal("/room/testRoom/file"))
                    expect(preparedRequest?.method.rawValue).to(equal("POST"))
                }
            }
            
            // MARK: -- when generaing a download request
            context("when generaing a download request") {
                @TestState var preparedRequest: Network.PreparedRequest<Data>?
                
                // MARK: ---- generates the download url string correctly
                it("generates the download url string correctly") {
                    expect(OpenGroupAPI.downloadUrlString(for: "1", server: "testserver", roomToken: "roomToken"))
                        .to(equal("testserver/room/roomToken/file/1"))
                }
                
                // MARK: ---- generates the download destination correctly when given an id
                it("generates the download destination correctly when given an id") {
                    expect {
                        preparedRequest = try OpenGroupAPI.preparedDownload(
                            fileId: "1",
                            roomToken: "roomToken",
                            authMethod: Authentication.community(
                                info: LibSession.OpenGroupCapabilityInfo(
                                    roomToken: "",
                                    server: "testserver",
                                    publicKey: TestConstants.publicKey,
                                    capabilities: []
                                ),
                                forceBlinded: false
                            ),
                            using: dependencies
                        )
                    }.toNot(throwError())
                    
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
                    expect {
                        preparedRequest = try OpenGroupAPI.preparedDownload(
                            url: URL(string: "http://oxen.io/room/roomToken/file/1")!,
                            roomToken: "roomToken",
                            authMethod: Authentication.community(
                                info: LibSession.OpenGroupCapabilityInfo(
                                    roomToken: "",
                                    server: "testserver",
                                    publicKey: TestConstants.publicKey,
                                    capabilities: []
                                ),
                                forceBlinded: false
                            ),
                            using: dependencies
                        )
                    }.toNot(throwError())
                    
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
                @TestState var preparedRequest: Network.PreparedRequest<[OpenGroupAPI.DirectMessage]?>?
                
                // MARK: ---- generates the request correctly
                it("generates the request correctly") {
                    expect {
                        preparedRequest = try OpenGroupAPI.preparedInbox(
                            authMethod: Authentication.community(
                                info: LibSession.OpenGroupCapabilityInfo(
                                    roomToken: "",
                                    server: "testserver",
                                    publicKey: TestConstants.publicKey,
                                    capabilities: []
                                ),
                                forceBlinded: false
                            ),
                            using: dependencies
                        )
                    }.toNot(throwError())
                    
                    expect(preparedRequest?.path).to(equal("/inbox"))
                    expect(preparedRequest?.method.rawValue).to(equal("GET"))
                }
            }
            
            // MARK: -- when preparing an inbox since request
            context("when preparing an inbox since request") {
                @TestState var preparedRequest: Network.PreparedRequest<[OpenGroupAPI.DirectMessage]?>?
                
                // MARK: ---- generates the request correctly
                it("generates the request correctly") {
                    expect {
                        preparedRequest = try OpenGroupAPI.preparedInboxSince(
                            id: 1,
                            authMethod: Authentication.community(
                                info: LibSession.OpenGroupCapabilityInfo(
                                    roomToken: "",
                                    server: "testserver",
                                    publicKey: TestConstants.publicKey,
                                    capabilities: []
                                ),
                                forceBlinded: false
                            ),
                            using: dependencies
                        )
                    }.toNot(throwError())
                    
                    expect(preparedRequest?.path).to(equal("/inbox/since/1"))
                    expect(preparedRequest?.method.rawValue).to(equal("GET"))
                }
            }
            
            // MARK: -- when preparing a clear inbox request
            context("when preparing an inbox since request") {
                @TestState var preparedRequest: Network.PreparedRequest<OpenGroupAPI.DeleteInboxResponse>?
                
                // MARK: ---- generates the request correctly
                it("generates the request correctly") {
                    expect {
                        preparedRequest = try OpenGroupAPI.preparedClearInbox(
                            authMethod: Authentication.community(
                                info: LibSession.OpenGroupCapabilityInfo(
                                    roomToken: "",
                                    server: "testserver",
                                    publicKey: TestConstants.publicKey,
                                    capabilities: []
                                ),
                                forceBlinded: false
                            ),
                            using: dependencies
                        )
                    }.toNot(throwError())
                    
                    expect(preparedRequest?.path).to(equal("/inbox"))
                    expect(preparedRequest?.method.rawValue).to(equal("DELETE"))
                }
            }
            
            // MARK: -- when preparing a send direct message request
            context("when preparing a send direct message request") {
                @TestState var preparedRequest: Network.PreparedRequest<OpenGroupAPI.SendDirectMessageResponse>?
                
                // MARK: ---- generates the request correctly
                it("generates the request correctly") {
                    expect {
                        preparedRequest = try OpenGroupAPI.preparedSend(
                            ciphertext: "test".data(using: .utf8)!,
                            toInboxFor: "testUserId",
                            authMethod: Authentication.community(
                                info: LibSession.OpenGroupCapabilityInfo(
                                    roomToken: "",
                                    server: "testserver",
                                    publicKey: TestConstants.publicKey,
                                    capabilities: []
                                ),
                                forceBlinded: false
                            ),
                            using: dependencies
                        )
                    }.toNot(throwError())
                    
                    expect(preparedRequest?.path).to(equal("/inbox/testUserId"))
                    expect(preparedRequest?.method.rawValue).to(equal("POST"))
                }
            }
        }
        
        describe("an OpenGroupAPI") {
            // MARK: -- when preparing a ban user request
            context("when preparing a ban user request") {
                @TestState var preparedRequest: Network.PreparedRequest<NoResponse>?
                
                // MARK: ---- generates the request correctly
                it("generates the request correctly") {
                    expect {
                        preparedRequest = try OpenGroupAPI.preparedUserBan(
                            sessionId: "testUserId",
                            for: nil,
                            from: nil,
                            authMethod: Authentication.community(
                                info: LibSession.OpenGroupCapabilityInfo(
                                    roomToken: "",
                                    server: "testserver",
                                    publicKey: TestConstants.publicKey,
                                    capabilities: []
                                ),
                                forceBlinded: false
                            ),
                            using: dependencies
                        )
                    }.toNot(throwError())
                    
                    expect(preparedRequest?.path).to(equal("/user/testUserId/ban"))
                    expect(preparedRequest?.method.rawValue).to(equal("POST"))
                }
                
                // MARK: ---- does a global ban if no room tokens are provided
                it("does a global ban if no room tokens are provided") {
                    expect {
                        preparedRequest = try OpenGroupAPI.preparedUserBan(
                            sessionId: "testUserId",
                            for: nil,
                            from: nil,
                            authMethod: Authentication.community(
                                info: LibSession.OpenGroupCapabilityInfo(
                                    roomToken: "",
                                    server: "testserver",
                                    publicKey: TestConstants.publicKey,
                                    capabilities: []
                                ),
                                forceBlinded: false
                            ),
                            using: dependencies
                        )
                    }.toNot(throwError())
                    
                    let requestBody: OpenGroupAPI.UserBanRequest? = try? preparedRequest?.body?
                        .decoded(as: OpenGroupAPI.UserBanRequest.self, using: dependencies)
                    expect(requestBody?.global).to(beTrue())
                    expect(requestBody?.rooms).to(beNil())
                }
                
                // MARK: ---- does room specific bans if room tokens are provided
                it("does room specific bans if room tokens are provided") {
                    expect {
                        preparedRequest = try OpenGroupAPI.preparedUserBan(
                            sessionId: "testUserId",
                            for: nil,
                            from: ["testRoom"],
                            authMethod: Authentication.community(
                                info: LibSession.OpenGroupCapabilityInfo(
                                    roomToken: "",
                                    server: "testserver",
                                    publicKey: TestConstants.publicKey,
                                    capabilities: []
                                ),
                                forceBlinded: false
                            ),
                            using: dependencies
                        )
                    }.toNot(throwError())
                    
                    let requestBody: OpenGroupAPI.UserBanRequest? = try? preparedRequest?.body?
                        .decoded(as: OpenGroupAPI.UserBanRequest.self, using: dependencies)
                    expect(requestBody?.global).to(beNil())
                    expect(requestBody?.rooms).to(equal(["testRoom"]))
                }
            }
            
            // MARK: -- when preparing an unban user request
            context("when preparing an unban user request") {
                @TestState var preparedRequest: Network.PreparedRequest<NoResponse>?
                
                // MARK: ---- generates the request correctly
                it("generates the request correctly") {
                    expect {
                        preparedRequest = try OpenGroupAPI.preparedUserUnban(
                            sessionId: "testUserId",
                            from: nil,
                            authMethod: Authentication.community(
                                info: LibSession.OpenGroupCapabilityInfo(
                                    roomToken: "",
                                    server: "testserver",
                                    publicKey: TestConstants.publicKey,
                                    capabilities: []
                                ),
                                forceBlinded: false
                            ),
                            using: dependencies
                        )
                    }.toNot(throwError())
                    
                    expect(preparedRequest?.path).to(equal("/user/testUserId/unban"))
                    expect(preparedRequest?.method.rawValue).to(equal("POST"))
                }
                
                // MARK: ---- does a global unban if no room tokens are provided
                it("does a global unban if no room tokens are provided") {
                    expect {
                        preparedRequest = try OpenGroupAPI.preparedUserUnban(
                            sessionId: "testUserId",
                            from: nil,
                            authMethod: Authentication.community(
                                info: LibSession.OpenGroupCapabilityInfo(
                                    roomToken: "",
                                    server: "testserver",
                                    publicKey: TestConstants.publicKey,
                                    capabilities: []
                                ),
                                forceBlinded: false
                            ),
                            using: dependencies
                        )
                    }.toNot(throwError())
                    
                    let requestBody: OpenGroupAPI.UserUnbanRequest? = try? preparedRequest?.body?
                        .decoded(as: OpenGroupAPI.UserUnbanRequest.self, using: dependencies)
                    expect(requestBody?.global).to(beTrue())
                    expect(requestBody?.rooms).to(beNil())
                }
                
                // MARK: ---- does room specific unbans if room tokens are provided
                it("does room specific unbans if room tokens are provided") {
                    expect {
                        preparedRequest = try OpenGroupAPI.preparedUserUnban(
                            sessionId: "testUserId",
                            from: ["testRoom"],
                            authMethod: Authentication.community(
                                info: LibSession.OpenGroupCapabilityInfo(
                                    roomToken: "",
                                    server: "testserver",
                                    publicKey: TestConstants.publicKey,
                                    capabilities: []
                                ),
                                forceBlinded: false
                            ),
                            using: dependencies
                        )
                    }.toNot(throwError())
                    
                    let requestBody: OpenGroupAPI.UserUnbanRequest? = try? preparedRequest?.body?
                        .decoded(as: OpenGroupAPI.UserUnbanRequest.self, using: dependencies)
                    expect(requestBody?.global).to(beNil())
                    expect(requestBody?.rooms).to(equal(["testRoom"]))
                }
            }
            
            // MARK: -- when preparing a user permissions request
            context("when preparing a user permissions request") {
                @TestState var preparedRequest: Network.PreparedRequest<NoResponse>?
                
                // MARK: ---- generates the request correctly
                it("generates the request correctly") {
                    expect {
                        preparedRequest = try OpenGroupAPI.preparedUserModeratorUpdate(
                            sessionId: "testUserId",
                            moderator: true,
                            admin: nil,
                            visible: true,
                            for: nil,
                            authMethod: Authentication.community(
                                info: LibSession.OpenGroupCapabilityInfo(
                                    roomToken: "",
                                    server: "testserver",
                                    publicKey: TestConstants.publicKey,
                                    capabilities: []
                                ),
                                forceBlinded: false
                            ),
                            using: dependencies
                        )
                    }.toNot(throwError())
                    
                    expect(preparedRequest?.path).to(equal("/user/testUserId/moderator"))
                    expect(preparedRequest?.method.rawValue).to(equal("POST"))
                }
                
                // MARK: ---- does a global update if no room tokens are provided
                it("does a global update if no room tokens are provided") {
                    expect {
                        preparedRequest = try OpenGroupAPI.preparedUserModeratorUpdate(
                            sessionId: "testUserId",
                            moderator: true,
                            admin: nil,
                            visible: true,
                            for: nil,
                            authMethod: Authentication.community(
                                info: LibSession.OpenGroupCapabilityInfo(
                                    roomToken: "",
                                    server: "testserver",
                                    publicKey: TestConstants.publicKey,
                                    capabilities: []
                                ),
                                forceBlinded: false
                            ),
                            using: dependencies
                        )
                    }.toNot(throwError())
                    
                    let requestBody: OpenGroupAPI.UserModeratorRequest? = try? preparedRequest?.body?
                        .decoded(as: OpenGroupAPI.UserModeratorRequest.self, using: dependencies)
                    expect(requestBody?.global).to(beTrue())
                    expect(requestBody?.rooms).to(beNil())
                }
                
                // MARK: ---- does room specific updates if room tokens are provided
                it("does room specific updates if room tokens are provided") {
                    expect {
                        preparedRequest = try OpenGroupAPI.preparedUserModeratorUpdate(
                            sessionId: "testUserId",
                            moderator: true,
                            admin: nil,
                            visible: true,
                            for: ["testRoom"],
                            authMethod: Authentication.community(
                                info: LibSession.OpenGroupCapabilityInfo(
                                    roomToken: "",
                                    server: "testserver",
                                    publicKey: TestConstants.publicKey,
                                    capabilities: []
                                ),
                                forceBlinded: false
                            ),
                            using: dependencies
                        )
                    }.toNot(throwError())
                    
                    let requestBody: OpenGroupAPI.UserModeratorRequest? = try? preparedRequest?.body?
                        .decoded(as: OpenGroupAPI.UserModeratorRequest.self, using: dependencies)
                    expect(requestBody?.global).to(beNil())
                    expect(requestBody?.rooms).to(equal(["testRoom"]))
                }
                
                // MARK: ---- fails if neither moderator or admin are set
                it("fails if neither moderator or admin are set") {
                    expect {
                        preparedRequest = try OpenGroupAPI.preparedUserModeratorUpdate(
                            sessionId: "testUserId",
                            moderator: nil,
                            admin: nil,
                            visible: true,
                            for: nil,
                            authMethod: Authentication.community(
                                info: LibSession.OpenGroupCapabilityInfo(
                                    roomToken: "",
                                    server: "testserver",
                                    publicKey: TestConstants.publicKey,
                                    capabilities: []
                                ),
                                forceBlinded: false
                            ),
                            using: dependencies
                        )
                    }.to(throwError(NetworkError.invalidPreparedRequest))
                    
                    expect(preparedRequest).to(beNil())
                }
            }
            
            // MARK: -- when preparing a ban and delete all request
            context("when preparing a ban and delete all request") {
                @TestState var preparedRequest:  Network.PreparedRequest<Network.BatchResponseMap<OpenGroupAPI.Endpoint>>?
                
                // MARK: ---- generates the request correctly
                it("generates the request correctly") {
                    expect {
                        preparedRequest = try OpenGroupAPI.preparedUserBanAndDeleteAllMessages(
                            sessionId: "testUserId",
                            roomToken: "testRoom",
                            authMethod: Authentication.community(
                                info: LibSession.OpenGroupCapabilityInfo(
                                    roomToken: "",
                                    server: "testserver",
                                    publicKey: TestConstants.publicKey,
                                    capabilities: []
                                ),
                                forceBlinded: false
                            ),
                            using: dependencies
                        )
                    }.toNot(throwError())
                    
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
                @TestState var preparedRequest: Network.PreparedRequest<[OpenGroupAPI.Room]>?
                
                // MARK: ---- fails when there is no ed25519SecretKey
                it("fails when there is no ed25519SecretKey") {
                    try await mockGeneralCache.when { $0.ed25519SecretKey }.thenReturn([])
                    
                    expect {
                        preparedRequest = try OpenGroupAPI.preparedRooms(
                            authMethod: Authentication.community(
                                info: LibSession.OpenGroupCapabilityInfo(
                                    roomToken: "",
                                    server: "testserver",
                                    publicKey: TestConstants.publicKey,
                                    capabilities: []
                                ),
                                forceBlinded: false
                            ),
                            using: dependencies
                        )
                    }.to(throwError(OpenGroupAPIError.signingFailed))
                    
                    expect(preparedRequest).to(beNil())
                }
                
                // MARK: ---- when unblinded
                context("when unblinded") {
                    // MARK: ------ signs correctly
                    it("signs correctly") {
                        expect {
                            preparedRequest = try OpenGroupAPI.preparedRooms(
                                authMethod: Authentication.community(
                                    info: LibSession.OpenGroupCapabilityInfo(
                                        roomToken: "",
                                        server: "testserver",
                                        publicKey: TestConstants.publicKey,
                                        capabilities: [.sogs]
                                    ),
                                    forceBlinded: false
                                ),
                                using: dependencies
                            )
                        }.toNot(throwError())
                        
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
                        try await mockCrypto
                            .when { $0.generate(.signature(message: .any, ed25519SecretKey: .any)) }
                            .thenThrow(CryptoError.failedToGenerateOutput)
                        
                        expect {
                            preparedRequest = try OpenGroupAPI.preparedRooms(
                                authMethod: Authentication.community(
                                    info: LibSession.OpenGroupCapabilityInfo(
                                        roomToken: "",
                                        server: "testserver",
                                        publicKey: TestConstants.publicKey,
                                        capabilities: [.sogs]
                                    ),
                                    forceBlinded: false
                                ),
                                using: dependencies
                            )
                        }.to(throwError(OpenGroupAPIError.signingFailed))
                        
                        expect(preparedRequest).to(beNil())
                    }
                }
                
                // MARK: ---- when blinded
                context("when blinded") {
                    // MARK: ------ signs correctly
                    it("signs correctly") {
                        expect {
                            preparedRequest = try OpenGroupAPI.preparedRooms(
                                authMethod: Authentication.community(
                                    info: LibSession.OpenGroupCapabilityInfo(
                                        roomToken: "",
                                        server: "testserver",
                                        publicKey: TestConstants.publicKey,
                                        capabilities: [.sogs, .blind]
                                    ),
                                    forceBlinded: false
                                ),
                                using: dependencies
                            )
                        }.toNot(throwError())
                        
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
                        try await mockCrypto
                            .when { $0.generate(.blinded15KeyPair(serverPublicKey: .any, ed25519SecretKey: .any)) }
                            .thenReturn(nil)
                        
                        expect {
                            preparedRequest = try OpenGroupAPI.preparedRooms(
                                authMethod: Authentication.community(
                                    info: LibSession.OpenGroupCapabilityInfo(
                                        roomToken: "",
                                        server: "testserver",
                                        publicKey: TestConstants.publicKey,
                                        capabilities: [.sogs, .blind]
                                    ),
                                    forceBlinded: false
                                ),
                                using: dependencies
                            )
                        }.to(throwError(OpenGroupAPIError.signingFailed))
                        
                        expect(preparedRequest).to(beNil())
                    }
                    
                    // MARK: ------ fails when the sogsSignature is not generated
                    it("fails when the sogsSignature is not generated") {
                        try await mockCrypto
                            .when { $0.generate(.blinded15KeyPair(serverPublicKey: .any, ed25519SecretKey: .any)) }
                            .thenReturn(nil)
                        
                        expect {
                            preparedRequest = try OpenGroupAPI.preparedRooms(
                                authMethod: Authentication.community(
                                    info: LibSession.OpenGroupCapabilityInfo(
                                        roomToken: "",
                                        server: "testserver",
                                        publicKey: TestConstants.publicKey,
                                        capabilities: [.sogs, .blind]
                                    ),
                                    forceBlinded: false
                                ),
                                using: dependencies
                            )
                        }.to(throwError(OpenGroupAPIError.signingFailed))
                        
                        expect(preparedRequest).to(beNil())
                    }
                }
            }
            
            // MARK: -- when sending
            context("when sending") {
                @TestState var preparedRequest: Network.PreparedRequest<[OpenGroupAPI.Room]>?
                
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
                        .thenReturn(MockNetwork.response(type: [OpenGroupAPI.Room].self))
                }
                
                // MARK: ---- triggers sending correctly
                it("triggers sending correctly") {
                    var response: (info: ResponseInfoType, data: [OpenGroupAPI.Room])?
                    
                    expect {
                        preparedRequest = try OpenGroupAPI.preparedRooms(
                            authMethod: Authentication.community(
                                info: LibSession.OpenGroupCapabilityInfo(
                                    roomToken: "",
                                    server: "testserver",
                                    publicKey: TestConstants.publicKey,
                                    capabilities: []
                                ),
                                forceBlinded: false
                            ),
                            using: dependencies
                        )
                    }.toNot(throwError())
                    
                    preparedRequest?
                        .send(using: dependencies)
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
            case .randomSnode(let swarmPublicKey): return swarmPublicKey
            case .server(let info), .serverDownload(let info), .serverUpload(let info, _): return info.x25519PublicKey
        }
    }
    
    var testHeaders: [HTTPHeader: String]? {
        switch self {
            case .cached, .snode, .randomSnode: return nil
            case .server(let info), .serverDownload(let info), .serverUpload(let info, _): return info.headers
        }
    }
}
