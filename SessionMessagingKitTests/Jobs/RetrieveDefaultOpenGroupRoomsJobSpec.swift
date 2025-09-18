// Copyright © 2024 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB

import Quick
import Nimble

@testable import SessionNetworkingKit
@testable import SessionMessagingKit
@testable import SessionUtilitiesKit

class RetrieveDefaultOpenGroupRoomsJobSpec: QuickSpec {
    override class func spec() {
        // MARK: Configuration
        
        @TestState var dependencies: TestDependencies! = TestDependencies { dependencies in
            dependencies.forceSynchronous = true
            dependencies.dateNow = Date(timeIntervalSince1970: 1234567890)
        }
        @TestState(singleton: .storage, in: dependencies) var mockStorage: Storage! = SynchronousStorage(
            customWriter: try! DatabaseQueue(),
            migrations: SNMessagingKit.migrations,
            using: dependencies,
            initialData: { db in
                try Identity(variant: .x25519PublicKey, data: Data(hex: TestConstants.publicKey)).insert(db)
                try Identity(variant: .x25519PrivateKey, data: Data(hex: TestConstants.privateKey)).insert(db)
                try Identity(variant: .ed25519PublicKey, data: Data(hex: TestConstants.edPublicKey)).insert(db)
                try Identity(variant: .ed25519SecretKey, data: Data(hex: TestConstants.edSecretKey)).insert(db)
            }
        )
        @TestState(defaults: .appGroup, in: dependencies) var mockUserDefaults: MockUserDefaults! = MockUserDefaults(
            initialSetup: { defaults in
                defaults.when { $0.bool(forKey: .any) }.thenReturn(true)
            }
        )
        @TestState(singleton: .network, in: dependencies) var mockNetwork: MockNetwork! = MockNetwork(
            initialSetup: { network in
                network
                    .when { $0.send(.any, to: .any, requestTimeout: .any, requestAndPathBuildTimeout: .any) }
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
            }
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
        @TestState(cache: .openGroupManager, in: dependencies) var mockOGMCache: MockOGMCache! = MockOGMCache(
            initialSetup: { cache in
                cache.when { $0.setDefaultRoomInfo(.any) }.thenReturn(())
            }
        )
        @TestState(cache: .general, in: dependencies) var mockGeneralCache: MockGeneralCache! = MockGeneralCache(
            initialSetup: { cache in
                cache.when { $0.sessionId }.thenReturn(SessionId(.standard, hex: TestConstants.publicKey))
                cache.when { $0.ed25519SecretKey }.thenReturn(Array(Data(hex: TestConstants.edSecretKey)))
                cache
                    .when { $0.ed25519Seed }
                    .thenReturn(Array(Array(Data(hex: TestConstants.edSecretKey)).prefix(upTo: 32)))
            }
        )
        @TestState var job: Job! = Job(variant: .retrieveDefaultOpenGroupRooms)
        @TestState var error: Error? = nil
        @TestState var permanentFailure: Bool! = false
        @TestState var wasDeferred: Bool! = false
        
        // MARK: - a RetrieveDefaultOpenGroupRoomsJob
        describe("a RetrieveDefaultOpenGroupRoomsJob") {
            // MARK: -- defers the job if the main app is not running
            it("defers the job if the main app is not running") {
                mockUserDefaults.when { $0.bool(forKey: UserDefaults.BoolKey.isMainAppActive.rawValue) }.thenReturn(false)
                
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
                mockUserDefaults.when { $0.bool(forKey: UserDefaults.BoolKey.isMainAppActive.rawValue) }.thenReturn(true)
                
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
                mockJobRunner
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
                mockJobRunner
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
                mockNetwork
                    .when { $0.send(.any, to: .any, requestTimeout: .any, requestAndPathBuildTimeout: .any) }
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
                mockNetwork
                    .when { $0.send(.any, to: .any, requestTimeout: .any, requestAndPathBuildTimeout: .any) }
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
                
                expect(mockNetwork)
                    .to(call { network in
                        network.send(
                            expectedRequest.body,
                            to: expectedRequest.destination,
                            requestTimeout: expectedRequest.requestTimeout,
                            requestAndPathBuildTimeout: expectedRequest.requestAndPathBuildTimeout
                        )
                    })
            }
            
            // MARK: -- will retry 8 times before it fails
            it("will retry 8 times before it fails") {
                mockNetwork
                    .when { $0.send(.any, to: .any, requestTimeout: .any, requestAndPathBuildTimeout: .any) }
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
                
                expect(error).to(matchError(NetworkError.parsingFailed))
                expect(mockNetwork)   // First attempt + 8 retries
                    .to(call(.exactly(times: 9)) { network in
                        network.send(.any, to: .any, requestTimeout: .any, requestAndPathBuildTimeout: .any)
                    })
            }
            
            // MARK: -- stores the updated capabilities
            it("stores the updated capabilities") {
                RetrieveDefaultOpenGroupRoomsJob.run(
                    job,
                    scheduler: DispatchQueue.main,
                    success: { _, _ in },
                    failure: { _, _, _ in },
                    deferred: { _ in },
                    using: dependencies
                )
                
                let capabilities: [Capability]? = mockStorage.read { db in try Capability.fetchAll(db) }
                expect(capabilities?.count).to(equal(2))
                expect(capabilities?.map { $0.openGroupServer })
                    .to(equal([Network.SOGS.defaultServer, Network.SOGS.defaultServer]))
                expect(capabilities?.map { $0.variant }).to(equal([.blind, .reactions]))
                expect(capabilities?.map { $0.isMissing }).to(equal([false, false]))
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
                
                let openGroups: [OpenGroup]? = mockStorage.read { db in try OpenGroup.fetchAll(db) }
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
                mockNetwork
                    .when { $0.send(.any, to: .any, requestTimeout: .any, requestAndPathBuildTimeout: .any) }
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
                
                let openGroups: [OpenGroup]? = mockStorage.read { db in try OpenGroup.fetchAll(db) }
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
                                        roomToken: "testRoom2",
                                        server: Network.SOGS.defaultServer,
                                        skipAuthentication: true
                                    ),
                                    timestamp: 1234567890
                                )
                            ),
                            dependantJob: nil,
                            canStartJob: true
                        )
                    })
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
                                        roomToken: "testRoom2",
                                        server: Network.SOGS.defaultServer,
                                        skipAuthentication: true
                                    ),
                                    timestamp: 1234567890
                                )
                            ),
                            dependantJob: nil,
                            canStartJob: true
                        )
                    })
            }
            
            // MARK: -- does not schedule a display picture download if there is no imageId
            it("does not schedule a display picture download if there is no imageId") {
                mockNetwork
                    .when { $0.send(.any, to: .any, requestTimeout: .any, requestAndPathBuildTimeout: .any) }
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
                
                expect(mockJobRunner)
                    .toNot(call { $0.add(.any, job: .any, dependantJob: .any, canStartJob: .any) })
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
                
                expect(mockJobRunner)
                    .toNot(call { $0.add(.any, job: .any, dependantJob: .any, canStartJob: .any) })
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
                
                expect(mockOGMCache)
                    .toNot(call(matchingParameters: .all) {
                        $0.setDefaultRoomInfo([
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
                    })
            }
        }
    }
}
