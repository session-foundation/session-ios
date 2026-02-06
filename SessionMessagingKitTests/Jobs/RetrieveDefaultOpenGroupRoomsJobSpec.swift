// Copyright © 2026 Rangeproof Pty Ltd. All rights reserved.

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
        @TestState var mockCommunityManager: MockCommunityManager! = .create(using: dependencies)
        @TestState var mockGeneralCache: MockGeneralCache! = .create(using: dependencies)
        @TestState var job: Job! = Job(variant: .retrieveDefaultOpenGroupRooms)
        @TestState var error: Error? = nil
        @TestState var permanentFailure: Bool! = false
        @TestState var wasDeferred: Bool! = false
        
        beforeEach {
            dependencies.set(cache: .general, to: mockGeneralCache)
            try await mockGeneralCache.defaultInitialSetup()
            
            dependencies.set(singleton: .communityManager, to: mockCommunityManager)
            try await mockCommunityManager.defaultInitialSetup()
            
            dependencies.set(singleton: .storage, to: mockStorage)
            try await mockStorage.perform(migrations: SNMessagingKit.migrations)
            try await mockStorage.writeAsync { db in
                try Identity(variant: .x25519PublicKey, data: Data(hex: TestConstants.publicKey)).insert(db)
                try Identity(variant: .x25519PrivateKey, data: Data(hex: TestConstants.privateKey)).insert(db)
                try Identity(variant: .ed25519PublicKey, data: Data(hex: TestConstants.edPublicKey)).insert(db)
                try Identity(variant: .ed25519SecretKey, data: Data(hex: TestConstants.edSecretKey)).insert(db)
            }
            
            dependencies.set(defaults: .appGroup, to: mockUserDefaults)
            try await mockUserDefaults.defaultInitialSetup()
            try await mockUserDefaults.when { $0.bool(forKey: .any) }.thenReturn(true)
            
            dependencies.set(singleton: .network, to: mockNetwork)
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
            
            dependencies.set(singleton: .jobRunner, to: mockJobRunner)
            try await mockJobRunner
                .when { $0.add(.any, job: .any, initialDependencies: .any) }
                .thenReturn(nil)
            try await mockJobRunner
                .when { await $0.jobsMatching(filters: .any) }
                .thenReturn([:])
        }
        
        // MARK: - a RetrieveDefaultOpenGroupRoomsJob
        describe("a RetrieveDefaultOpenGroupRoomsJob") {
            // MARK: -- successfully runs
            it("successfully runs") {
                try await mockUserDefaults
                    .when { $0.bool(forKey: UserDefaults.BoolKey.isMainAppActive.rawValue) }
                    .thenReturn(true)
                
                await expect {
                    try await RetrieveDefaultOpenGroupRoomsJob.run(job, using: dependencies)
                }.to(equal(.success))
            }
            
            // MARK: -- succeeds without a request if the main app is not running
            it("succeeds without a request if the main app is not running") {
                try await mockUserDefaults
                    .when { $0.bool(forKey: UserDefaults.BoolKey.isMainAppActive.rawValue) }
                    .thenReturn(false)
                
                await expect {
                    try await RetrieveDefaultOpenGroupRoomsJob.run(job, using: dependencies)
                }.to(equal(.success))
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
                    .wasNotCalled(timeout: .milliseconds(100))
            }
            
            // MARK: -- does not allow concurrent execution
            it("does not allow concurrent execution") {
                expect(
                    RetrieveDefaultOpenGroupRoomsJob.canRunConcurrentlyWith(
                        runningJobs: [
                            JobState(
                                queueId: JobQueue.JobQueueId(databaseId: 1),
                                job: Job(variant: .retrieveDefaultOpenGroupRooms),
                                jobDependencies: [],
                                executionState: .running(task: Task(operation: {})),
                                resultStream: CurrentValueAsyncStream(nil)
                            )
                        ],
                        jobState: JobState(
                            queueId: JobQueue.JobQueueId(databaseId: 2),
                            job: Job(variant: .retrieveDefaultOpenGroupRooms),
                            jobDependencies: [],
                            executionState: .pending(lastAttempt: nil),
                            resultStream: CurrentValueAsyncStream(nil)
                        ),
                        using: dependencies
                    )
                ).to(beFalse())
            }
            
            // MARK: -- sends the correct request
            it("sends the correct request") {
                _ = try await RetrieveDefaultOpenGroupRoomsJob.run(job, using: dependencies)
                
                await mockNetwork
                    .verify {
                        $0.send(
                            endpoint: Network.SOGS.Endpoint.sequence,
                            destination: .server(
                                method: .post,
                                server: Network.SOGS.defaultServer,
                                queryParameters: [:],
                                headers: [:],
                                x25519PublicKey: Network.SOGS.defaultServerPublicKey
                            ),
                            body: try JSONEncoder(using: dependencies).encode(
                                Network.BatchRequest(requests: [
                                    try Network.PreparedRequest<Network.SOGS.CapabilitiesResponse>(
                                        request: Request<NoBody, Network.SOGS.Endpoint>(
                                            endpoint: .capabilities,
                                            destination: .server(
                                                method: .get,
                                                server: Network.SOGS.defaultServer,
                                                queryParameters: [:],
                                                headers: [:],
                                                x25519PublicKey: Network.SOGS.defaultServerPublicKey
                                            )
                                        ),
                                        responseType: Network.SOGS.CapabilitiesResponse.self,
                                        using: dependencies
                                    ),
                                    try Network.PreparedRequest<[Network.SOGS.Room]>(
                                        request: Request<NoBody, Network.SOGS.Endpoint>(
                                            endpoint: .rooms,
                                            destination: .server(
                                                method: .get,
                                                server: Network.SOGS.defaultServer,
                                                queryParameters: [:],
                                                headers: [:],
                                                x25519PublicKey: Network.SOGS.defaultServerPublicKey
                                            )
                                        ),
                                        responseType: [Network.SOGS.Room].self,
                                        using: dependencies
                                    )
                                ])
                            ),
                            category: .standard,
                            requestTimeout: Network.defaultTimeout,
                            overallTimeout: nil
                        )
                    }
                    .wasCalled(exactly: 1, timeout: .milliseconds(100))
            }
            
            // MARK: -- sends the updated capabilities to the CommunityManager for storage
            it("sends the updated capabilities to the CommunityManager for storage") {
                _ = try await RetrieveDefaultOpenGroupRoomsJob.run(job, using: dependencies)
                
                await mockCommunityManager
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
                            server: Network.SOGS.defaultServer,
                            publicKey: Network.SOGS.defaultServerPublicKey
                        )
                    }
                    .wasCalled(exactly: 1, timeout: .milliseconds(100))
            }
            
            // MARK: -- stores the returned rooms in the CommunityManager
            it("stores the returned rooms in the CommunityManager") {
                _ = try await RetrieveDefaultOpenGroupRoomsJob.run(job, using: dependencies)
                
                await mockCommunityManager
                    .verify {
                        await $0.updateRooms(
                            rooms: [
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
                            ],
                            server: Network.SOGS.defaultServer,
                            publicKey: Network.SOGS.defaultServerPublicKey,
                            areDefaultRooms: true
                        )
                    }
                    .wasCalled(exactly: 1, timeout: .milliseconds(100))
            }
            
            // MARK: -- schedules a display picture download
            it("schedules a display picture download") {
                _ = try await RetrieveDefaultOpenGroupRoomsJob.run(job, using: dependencies)
                
                await mockJobRunner
                    .verify {
                        $0.add(
                            .any,
                            job: Job(
                                variant: .displayPictureDownload,
                                details: DisplayPictureDownloadJob.Details(
                                    target: .community(
                                        imageId: "12",
                                        roomToken: "testRoom2",
                                        server: Network.SOGS.defaultServer,
                                        publicKey: Network.SOGS.defaultServerPublicKey,
                                        skipAuthentication: true
                                    ),
                                    timestamp: 1234567890
                                )
                            ),
                            initialDependencies: []
                        )
                    }
                    .wasCalled(exactly: 1, timeout: .milliseconds(100))
            }
            
            // MARK: -- does not schedule a display picture download if there is no imageId
            it("does not schedule a display picture download if there is no imageId") {
                try await mockNetwork
                    .when {
                        try await $0.send(
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
                
                _ = try await RetrieveDefaultOpenGroupRoomsJob.run(job, using: dependencies)
                
                await mockJobRunner
                    .verify {
                        $0.add(
                            .any,
                            job: .any,
                            initialDependencies: .any
                        )
                    }
                    .wasNotCalled(timeout: .milliseconds(100))
            }
        }
    }
}
