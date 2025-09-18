// Copyright © 2024 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import TestUtilities

import Quick
import Nimble

@testable import SessionNetworkingKit
@testable import SessionMessagingKit
@testable import SessionUtilitiesKit

class RetrieveDefaultOpenGroupRoomsJobSpec: AsyncSpec {
    override class func spec() {
        // MARK: Configuration
        
        @TestState var dependencies: TestDependencies! = TestDependencies { dependencies in
            dependencies.forceSynchronous = true
            dependencies.dateNow = Date(timeIntervalSince1970: 1234567890)
        }
        @TestState var mockStorage: Storage! = SynchronousStorage(
            customWriter: try! DatabaseQueue(),
            using: dependencies
        )
        @TestState var mockUserDefaults: MockUserDefaults! = .create(using: dependencies)
        @TestState var mockNetwork: MockNetwork! = .create(using: dependencies)
        @TestState var mockJobRunner: MockJobRunner! = .create(using: dependencies)
        @TestState var mockOpenGroupManager: MockOpenGroupManager! = .create(using: dependencies)
        @TestState var mockGeneralCache: MockGeneralCache! = .create(using: dependencies)
        @TestState var job: Job! = Job(variant: .retrieveDefaultOpenGroupRooms)
        @TestState var error: Error? = nil
        @TestState var permanentFailure: Bool! = false
        @TestState var wasDeferred: Bool! = false
        
        beforeEach {
            try await mockGeneralCache.defaultInitialSetup()
            dependencies.set(cache: .general, to: mockGeneralCache)
            
            try await mockOpenGroupManager.defaultInitialSetup()
            dependencies.set(singleton: .openGroupManager, to: mockOpenGroupManager)
            
            try await mockStorage.perform(migrations: SNMessagingKit.migrations)
            try await mockStorage.writeAsync { db in
                try Identity(variant: .x25519PublicKey, data: Data(hex: TestConstants.publicKey)).insert(db)
                try Identity(variant: .x25519PrivateKey, data: Data(hex: TestConstants.privateKey)).insert(db)
                try Identity(variant: .ed25519PublicKey, data: Data(hex: TestConstants.edPublicKey)).insert(db)
                try Identity(variant: .ed25519SecretKey, data: Data(hex: TestConstants.edSecretKey)).insert(db)
            }
            dependencies.set(singleton: .storage, to: mockStorage)
            
            try await mockUserDefaults.defaultInitialSetup()
            try await mockUserDefaults.when { $0.bool(forKey: .any) }.thenReturn(true)
            dependencies.set(defaults: .appGroup, to: mockUserDefaults)
            
            try await mockNetwork.defaultInitialSetup(using: dependencies)
            await mockNetwork.removeRequestMocks()
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
                    MockNetwork.batchResponseData(
                        with: [
                            (
                                Network.SOGS.Endpoint.capabilities,
                                Network.SOGS.CapabilitiesResponse(
                                    capabilities: [
                                        Capability.Variant.blind.rawValue,
                                        Capability.Variant.reactions.rawValue
                                    ]
                                ).batchSubResponse()
                            ),
                            (
                                Network.SOGS.Endpoint.rooms,
                                [
                                    Network.SOGS.Room.mock.with(
                                        token: "testRoom",
                                        name: "TestRoomName"
                                    ),
                                    Network.SOGS.Room.mock.with(
                                        token: "testRoom2",
                                        name: "TestRoomName2",
                                        infoUpdates: 12,
                                        imageId: "12"
                                    )
                                ].batchSubResponse()
                            )
                        ]
                    )
                )
            dependencies.set(singleton: .network, to: mockNetwork)
            
            try await mockJobRunner
                .when { $0.add(.any, job: .any, dependantJob: .any, canStartJob: .any) }
                .thenReturn(nil)
            try await mockJobRunner
                .when { $0.upsert(.any, job: .any, canStartJob: .any) }
                .thenReturn(nil)
            try await mockJobRunner
                .when { $0.jobInfoFor(jobs: .any, state: .any, variant: .any) }
                .thenReturn([:])
            dependencies.set(singleton: .jobRunner, to: mockJobRunner)
        }
        
        // MARK: - a RetrieveDefaultOpenGroupRoomsJob
        describe("a RetrieveDefaultOpenGroupRoomsJob") {
            // MARK: -- defers the job if the main app is not running
            it("defers the job if the main app is not running") {
                try await mockUserDefaults
                    .when { $0.bool(forKey: UserDefaults.BoolKey.isMainAppActive.rawValue) }
                    .thenReturn(false)
                
                RetrieveDefaultOpenGroupRoomsJob.run(
                    job,
                    scheduler: DispatchQueue.main,
                    success: { _, _ in  },
                    failure: { _, _, _ in },
                    deferred: { _ in wasDeferred = true },
                    using: dependencies
                )
                
                expect(wasDeferred).to(beTrue())
            }
            
            // MARK: -- does not defer the job when the main app is running
            it("does not defer the job when the main app is running") {
                try await mockUserDefaults
                    .when { $0.bool(forKey: UserDefaults.BoolKey.isMainAppActive.rawValue) }
                    .thenReturn(true)
                
                RetrieveDefaultOpenGroupRoomsJob.run(
                    job,
                    scheduler: DispatchQueue.main,
                    success: { _, _ in  },
                    failure: { _, _, _ in },
                    deferred: { _ in wasDeferred = true },
                    using: dependencies
                )
                
                expect(wasDeferred).to(beFalse())
            }
            
            // MARK: -- defers the job if there is an existing job running
            it("defers the job if there is an existing job running") {
                try await mockJobRunner
                    .when { $0.jobInfoFor(jobs: .any, state: .running, variant: .retrieveDefaultOpenGroupRooms) }
                    .thenReturn([
                        101: JobRunner.JobInfo(
                            variant: .retrieveDefaultOpenGroupRooms,
                            threadId: nil,
                            interactionId: nil,
                            detailsData: nil,
                            uniqueHashValue: nil
                        )
                    ])
                RetrieveDefaultOpenGroupRoomsJob.run(
                    job,
                    scheduler: DispatchQueue.main,
                    success: { _, _ in  },
                    failure: { _, _, _ in },
                    deferred: { _ in wasDeferred = true },
                    using: dependencies
                )
                
                expect(wasDeferred).to(beTrue())
            }
            
            // MARK: -- does not defer the job when there is no existing job
            it("does not defer the job when there is no existing job") {
                try await mockJobRunner
                    .when { $0.jobInfoFor(jobs: .any, state: .running, variant: .retrieveDefaultOpenGroupRooms) }
                    .thenReturn([:])
                
                RetrieveDefaultOpenGroupRoomsJob.run(
                    job,
                    scheduler: DispatchQueue.main,
                    success: { _, _ in  },
                    failure: { _, _, _ in },
                    deferred: { _ in wasDeferred = true },
                    using: dependencies
                )
                
                expect(wasDeferred).to(beFalse())
            }
            
            // MARK: -- creates an inactive entry in the database if one does not exist
            it("creates an inactive entry in the database if one does not exist") {
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
                
                RetrieveDefaultOpenGroupRoomsJob.run(
                    job,
                    scheduler: DispatchQueue.main,
                    success: { _, _ in },
                    failure: { _, _, _ in },
                    deferred: { _ in },
                    using: dependencies
                )
                
                let openGroups: [OpenGroup]? = mockStorage.read { db in try OpenGroup.fetchAll(db) }
                expect(openGroups?.count).to(equal(1))
                expect(openGroups?.map { $0.server }).to(equal([Network.SOGS.defaultServer]))
                expect(openGroups?.map { $0.roomToken }).to(equal([""]))
                expect(openGroups?.map { $0.publicKey }).to(equal([Network.SOGS.defaultServerPublicKey]))
                expect(openGroups?.map { $0.isActive }).to(equal([false]))
                expect(openGroups?.map { $0.name }).to(equal([""]))
            }
            
            // MARK: -- does not create a new entry if one already exists
            it("does not create a new entry if one already exists") {
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
                
                mockStorage.write { db in
                    try OpenGroup(
                        server: Network.SOGS.defaultServer,
                        roomToken: "",
                        publicKey: Network.SOGS.defaultServerPublicKey,
                        isActive: false,
                        name: "TestExisting",
                        userCount: 0,
                        infoUpdates: 0
                    )
                    .insert(db)
                }
                
                RetrieveDefaultOpenGroupRoomsJob.run(
                    job,
                    scheduler: DispatchQueue.main,
                    success: { _, _ in },
                    failure: { _, _, _ in },
                    deferred: { _ in },
                    using: dependencies
                )
                
                let openGroups: [OpenGroup]? = mockStorage.read { db in try OpenGroup.fetchAll(db) }
                expect(openGroups?.count).to(equal(1))
                expect(openGroups?.map { $0.server }).to(equal([Network.SOGS.defaultServer]))
                expect(openGroups?.map { $0.roomToken }).to(equal([""]))
                expect(openGroups?.map { $0.publicKey }).to(equal([Network.SOGS.defaultServerPublicKey]))
                expect(openGroups?.map { $0.isActive }).to(equal([false]))
                expect(openGroups?.map { $0.name }).to(equal(["TestExisting"]))
            }
            
            // MARK: -- sends the correct request
            it("sends the correct request") {
                mockStorage.write { db in
                    try OpenGroup(
                        server: Network.SOGS.defaultServer,
                        roomToken: "",
                        publicKey: Network.SOGS.defaultServerPublicKey,
                        isActive: false,
                        name: "TestExisting",
                        userCount: 0,
                        infoUpdates: 0
                    )
                    .insert(db)
                }
                let expectedRequest: Network.PreparedRequest<Network.SOGS.CapabilitiesAndRoomsResponse>! = mockStorage.read { db in
                    try Network.SOGS.preparedCapabilitiesAndRooms(
                        authMethod: Authentication.community(
                            info: LibSession.OpenGroupCapabilityInfo(
                                roomToken: "",
                                server: Network.SOGS.defaultServer,
                                publicKey: Network.SOGS.defaultServerPublicKey,
                                capabilities: []
                            ),
                            forceBlinded: false
                        ),
                        using: dependencies
                    )
                }
                RetrieveDefaultOpenGroupRoomsJob.run(
                    job,
                    scheduler: DispatchQueue.main,
                    success: { _, _ in },
                    failure: { _, _, _ in },
                    deferred: { _ in },
                    using: dependencies
                )
                
                await mockNetwork
                    .verify {
                        $0.send(
                            endpoint: Network.SOGS.Endpoint.sequence,
                            destination: .server(info: Network.Destination.ServerInfo(
                                method: .post,
                                server: Network.SOGS.defaultServer,
                                queryParameters: [:],
                                headers: .any,
                                x25519PublicKey: Network.SOGS.defaultServerPublicKey
                            )),
                            body: expectedRequest.body,
                            category: .standard,
                            requestTimeout: expectedRequest.requestTimeout,
                            overallTimeout: expectedRequest.overallTimeout
                        )
                    }
                    .wasCalled(exactly: 1, timeout: .milliseconds(100))
            }
            
            // MARK: -- permanently fails if it gets an error
            it("permanently fails if it gets an error") {
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
                    .thenReturn(MockNetwork.nullResponse())
                
                RetrieveDefaultOpenGroupRoomsJob.run(
                    job,
                    scheduler: DispatchQueue.main,
                    success: { _, _ in },
                    failure: { _, error_, permanentFailure_ in
                        error = error_
                        permanentFailure = permanentFailure_
                    },
                    deferred: { _ in },
                    using: dependencies
                )
                
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
                    .wasCalled(exactly: 1, timeout: .milliseconds(100))
                expect(error).to(matchError(NetworkError.parsingFailed))
                expect(permanentFailure).to(beTrue())
            }
            
            // MARK: -- handles the updated capabilities
            it("handles the updated capabilities") {
                RetrieveDefaultOpenGroupRoomsJob.run(
                    job,
                    scheduler: DispatchQueue.main,
                    success: { _, _ in },
                    failure: { _, _, _ in },
                    deferred: { _ in },
                    using: dependencies
                )
                
                await mockOpenGroupManager
                    .verify {
                        $0.handleCapabilities(
                            .any,
                            capabilities: Network.SOGS.CapabilitiesResponse(
                                capabilities: [
                                    Capability.Variant.blind.rawValue,
                                    Capability.Variant.reactions.rawValue
                                ],
                                missing: nil
                            ),
                            on: Network.SOGS.defaultServer
                        )
                    }
                    .wasCalled(exactly: 1, timeout: .milliseconds(100))
            }
            
            // MARK: -- inserts the returned rooms
            it("inserts the returned rooms") {
                RetrieveDefaultOpenGroupRoomsJob.run(
                    job,
                    scheduler: DispatchQueue.main,
                    success: { _, _ in },
                    failure: { _, _, _ in },
                    deferred: { _ in },
                    using: dependencies
                )
                
                let openGroups: [OpenGroup]? = await expect { mockStorage.read { db in try OpenGroup.fetchAll(db) } }
                    .toEventuallyNot(beNil())
                    .retrieveValue()
                expect(openGroups?.count).to(equal(3))  // 1 for the entry used to fetch the default rooms
                expect(openGroups?.map { $0.server })
                    .to(equal([Network.SOGS.defaultServer, Network.SOGS.defaultServer, Network.SOGS.defaultServer]))
                expect(openGroups?.map { $0.roomToken }).to(equal(["", "testRoom", "testRoom2"]))
                expect(openGroups?.map { $0.publicKey })
                    .to(equal([
                        Network.SOGS.defaultServerPublicKey,
                        Network.SOGS.defaultServerPublicKey,
                        Network.SOGS.defaultServerPublicKey
                    ]))
                expect(openGroups?.map { $0.isActive }).to(equal([false, false, false]))
                expect(openGroups?.map { $0.name }).to(equal(["", "TestRoomName", "TestRoomName2"]))
            }
            
            // MARK: -- does not override existing rooms that were returned
            it("does not override existing rooms that were returned") {
                mockStorage.write { db in
                    try OpenGroup(
                        server: Network.SOGS.defaultServer,
                        roomToken: "testRoom",
                        publicKey: Network.SOGS.defaultServerPublicKey,
                        isActive: false,
                        name: "TestExisting",
                        userCount: 0,
                        infoUpdates: 0
                    )
                    .insert(db)
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
                    .thenReturn(
                        MockNetwork.batchResponseData(
                            with: [
                                (Network.SOGS.Endpoint.capabilities, Network.SOGS.CapabilitiesResponse.mockBatchSubResponse()),
                                (
                                    Network.SOGS.Endpoint.rooms,
                                    try! JSONEncoder().with(outputFormatting: .sortedKeys).encode(
                                        Network.BatchSubResponse(
                                            code: 200,
                                            headers: [:],
                                            body: [
                                                Network.SOGS.Room.mock.with(
                                                    token: "testRoom",
                                                    name: "TestReplacementName"
                                                )
                                            ],
                                            failedToParseBody: false
                                        )
                                    )
                                )
                            ]
                        )
                    )
                
                RetrieveDefaultOpenGroupRoomsJob.run(
                    job,
                    scheduler: DispatchQueue.main,
                    success: { _, _ in },
                    failure: { _, _, _ in },
                    deferred: { _ in },
                    using: dependencies
                )
                
                let openGroups: [OpenGroup]? = await expect { mockStorage.read { db in try OpenGroup.fetchAll(db) } }
                    .toEventuallyNot(beNil())
                    .retrieveValue()
                expect(openGroups?.count).to(equal(2))  // 1 for the entry used to fetch the default rooms
                expect(openGroups?.map { $0.server })
                    .to(equal([Network.SOGS.defaultServer, Network.SOGS.defaultServer]))
                expect(openGroups?.map { $0.roomToken }.sorted()).to(equal(["", "testRoom"]))
                expect(openGroups?.map { $0.publicKey })
                    .to(equal([Network.SOGS.defaultServerPublicKey, Network.SOGS.defaultServerPublicKey]))
                expect(openGroups?.map { $0.isActive }).to(equal([false, false]))
                expect(openGroups?.map { $0.name }.sorted()).to(equal(["", "TestExisting"]))
            }
            
            // MARK: -- schedules a display picture download
            it("schedules a display picture download") {
                RetrieveDefaultOpenGroupRoomsJob.run(
                    job,
                    scheduler: DispatchQueue.main,
                    success: { _, _ in },
                    failure: { _, _, _ in },
                    deferred: { _ in },
                    using: dependencies
                )
                
                await mockJobRunner
                    .verify {
                        $0.add(
                            .any,
                            job: Job(
                                variant: .displayPictureDownload,
                                shouldBeUnique: true,
                                details: DisplayPictureDownloadJob.Details(
                                    target: .community(
                                        imageId: "12",
                                        roomToken: "testRoom2",
                                        server: Network.SOGS.defaultServer
                                    ),
                                    timestamp: 1234567890
                                )
                            ),
                            dependantJob: nil,
                            canStartJob: true
                        )
                    }
                    .wasCalled(exactly: 1, timeout: .milliseconds(100))
            }
            
            // MARK: -- schedules a display picture download if the imageId has changed
            it("schedules a display picture download if the imageId has changed") {
                mockStorage.write { db in
                    try OpenGroup(
                        server: Network.SOGS.defaultServer,
                        roomToken: "testRoom2",
                        publicKey: Network.SOGS.defaultServerPublicKey,
                        isActive: false,
                        name: "TestExisting",
                        imageId: "10",
                        userCount: 0,
                        infoUpdates: 10
                    )
                    .insert(db)
                }
                
                RetrieveDefaultOpenGroupRoomsJob.run(
                    job,
                    scheduler: DispatchQueue.main,
                    success: { _, _ in },
                    failure: { _, _, _ in },
                    deferred: { _ in },
                    using: dependencies
                )
                
                await mockJobRunner
                    .verify {
                        $0.add(
                            .any,
                            job: Job(
                                variant: .displayPictureDownload,
                                shouldBeUnique: true,
                                details: DisplayPictureDownloadJob.Details(
                                    target: .community(
                                        imageId: "12",
                                        roomToken: "testRoom2",
                                        server: Network.SOGS.defaultServer
                                    ),
                                    timestamp: 1234567890
                                )
                            ),
                            dependantJob: nil,
                            canStartJob: true
                        )
                    }
                    .wasCalled(exactly: 1, timeout: .milliseconds(100))
            }
            
            // MARK: -- does not schedule a display picture download if there is no imageId
            it("does not schedule a display picture download if there is no imageId") {
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
                        MockNetwork.batchResponseData(
                            with: [
                                (
                                    Network.SOGS.Endpoint.capabilities,
                                    Network.SOGS.CapabilitiesResponse(
                                        capabilities: [
                                            Capability.Variant.blind.rawValue,
                                            Capability.Variant.reactions.rawValue
                                        ]
                                    ).batchSubResponse()
                                ),
                                (
                                    Network.SOGS.Endpoint.rooms,
                                    [
                                        Network.SOGS.Room.mock.with(
                                            token: "testRoom",
                                            name: "TestRoomName"
                                        ),
                                        Network.SOGS.Room.mock.with(
                                            token: "testRoom2",
                                            name: "TestRoomName2"
                                        )
                                    ].batchSubResponse()
                                )
                            ]
                        )
                    )
                
                RetrieveDefaultOpenGroupRoomsJob.run(
                    job,
                    scheduler: DispatchQueue.main,
                    success: { _, _ in },
                    failure: { _, _, _ in },
                    deferred: { _ in },
                    using: dependencies
                )
                
                await mockJobRunner
                    .verify { $0.add(.any, job: .any, dependantJob: .any, canStartJob: .any) }
                    .wasNotCalled()
            }
            
            // MARK: -- does not schedule a display picture download if the imageId matches and the image has already been downloaded
            it("does not schedule a display picture download if the imageId matches and the image has already been downloaded") {
                mockStorage.write { db in
                    try OpenGroup(
                        server: Network.SOGS.defaultServer,
                        roomToken: "testRoom2",
                        publicKey: Network.SOGS.defaultServerPublicKey,
                        isActive: false,
                        name: "TestExisting",
                        imageId: "12",
                        userCount: 0,
                        infoUpdates: 12,
                        displayPictureOriginalUrl: "TestUrl"
                    )
                    .insert(db)
                }
                
                RetrieveDefaultOpenGroupRoomsJob.run(
                    job,
                    scheduler: DispatchQueue.main,
                    success: { _, _ in },
                    failure: { _, _, _ in },
                    deferred: { _ in },
                    using: dependencies
                )
                
                await mockJobRunner
                    .verify { $0.add(.any, job: .any, dependantJob: .any, canStartJob: .any) }
                    .wasNotCalled()
            }
            
            // MARK: -- updates the cache with the default rooms
            it("updates the cache with the default rooms") {
                RetrieveDefaultOpenGroupRoomsJob.run(
                    job,
                    scheduler: DispatchQueue.main,
                    success: { _, _ in },
                    failure: { _, _, _ in },
                    deferred: { _ in },
                    using: dependencies
                )
                
                await mockOpenGroupManager
                    .verify {
                        await $0.setDefaultRoomInfo([
                            (
                                room: Network.SOGS.Room.mock.with(
                                    token: "testRoom",
                                    name: "TestRoomName"
                                ),
                                openGroup: OpenGroup(
                                    server: Network.SOGS.defaultServer,
                                    roomToken: "testRoom",
                                    publicKey: Network.SOGS.defaultServerPublicKey,
                                    isActive: false,
                                    name: "TestRoomName",
                                    userCount: 0,
                                    infoUpdates: 0
                                )
                            ),
                            (
                                room: Network.SOGS.Room.mock.with(
                                    token: "testRoom2",
                                    name: "TestRoomName2",
                                    infoUpdates: 12,
                                    imageId: "12"
                                ),
                                openGroup: OpenGroup(
                                    server: Network.SOGS.defaultServer,
                                    roomToken: "testRoom2",
                                    publicKey: Network.SOGS.defaultServerPublicKey,
                                    isActive: false,
                                    name: "TestRoomName2",
                                    imageId: "12",
                                    userCount: 0,
                                    infoUpdates: 12
                                )
                            )
                        ])
                    }
                    .wasNotCalled()
            }
        }
    }
}
