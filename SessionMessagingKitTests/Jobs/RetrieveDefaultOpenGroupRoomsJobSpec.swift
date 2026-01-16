// Copyright © 2024 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB

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
                    .when {
                        $0.send(
                            endpoint: MockEndpoint.any,
                            destination: .any,
                            body: .any,
                            requestTimeout: .any,
                            requestAndPathBuildTimeout: .any
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
        @TestState(singleton: .communityManager, in: dependencies) var mockCommunityManager: MockCommunityManager! = MockCommunityManager(
            initialSetup: { manager in
                manager
                    .when { await $0.updateRooms(rooms: .any, server: .any, publicKey: .any, areDefaultRooms: .any) }
                    .thenReturn(())
                manager
                    .when { $0.handleCapabilities(.any, capabilities: .any, server: .any, publicKey: .any) }
                    .thenReturn(())
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
            
            // MARK: -- sends the correct request
            it("sends the correct request") {
                let expectedRequest: Network.PreparedRequest<Network.SOGS.CapabilitiesAndRoomsResponse>! = mockStorage.read { db in
                    try Network.SOGS.preparedCapabilitiesAndRooms(
                        authMethod: Authentication.Community(
                            info: LibSession.OpenGroupCapabilityInfo(
                                roomToken: "",
                                server: Network.SOGS.defaultServer,
                                publicKey: Network.SOGS.defaultServerPublicKey,
                                capabilities: []
                            ),
                            forceBlinded: false
                        ),
                        skipAuthentication: true,
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
                
                await expect(mockNetwork)
                    .toEventually(call { network in
                        network.send(
                            endpoint: Network.SOGS.Endpoint.sequence,
                            destination: expectedRequest.destination,
                            body: expectedRequest.body,
                            requestTimeout: expectedRequest.requestTimeout,
                            requestAndPathBuildTimeout: expectedRequest.requestAndPathBuildTimeout
                        )
                    })
                
                expect(expectedRequest?.headers).to(beEmpty())
            }
            
            // MARK: -- sends the updated capabilities to the CommunityManager for storage
            it("sends the updated capabilities to the CommunityManager for storage") {
                RetrieveDefaultOpenGroupRoomsJob.run(
                    job,
                    scheduler: DispatchQueue.main,
                    success: { _, _ in },
                    failure: { _, _, _ in },
                    deferred: { _ in },
                    using: dependencies
                )
                
                await expect(mockCommunityManager).toEventually(call(.exactly(times: 1), matchingParameters: .all) {
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
                })
            }
            
            // MARK: -- stores the returned rooms in the CommunityManager
            it("stores the returned rooms in the CommunityManager") {
                RetrieveDefaultOpenGroupRoomsJob.run(
                    job,
                    scheduler: DispatchQueue.main,
                    success: { _, _ in },
                    failure: { _, _, _ in },
                    deferred: { _ in },
                    using: dependencies
                )
                
                await expect(mockCommunityManager).toEventually(call(.exactly(times: 1), matchingParameters: .all) {
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
                })
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
                
                await expect(mockJobRunner).toEventually(call(matchingParameters: .all) {
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
                    .when {
                        $0.send(
                            endpoint: MockEndpoint.any,
                            destination: .any,
                            body: .any,
                            requestTimeout: .any,
                            requestAndPathBuildTimeout: .any
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
                
                expect(mockCommunityManager)
                    .toNot(call(matchingParameters: .all) {
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
                    })
            }
        }
    }
}
