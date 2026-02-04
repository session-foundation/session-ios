// Copyright © 2026 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import Combine
import GRDB
import SessionNetworkingKit
import SessionUtilitiesKit
import TestUtilities

import Quick
import Nimble

@testable import SessionMessagingKit

class CommunityPollerManagerSpec: AsyncSpec {
    override class func spec() {
        // MARK: Configuration
        
        @TestState var dependencies: TestDependencies! = TestDependencies { dependencies in
            dependencies.dateNow = Date(timeIntervalSince1970: 1234567890)
            dependencies.forceSynchronous = true
        }
        @TestState var mockStorage: Storage! = SynchronousStorage(
            customWriter: try! DatabaseQueue(),
            using: dependencies
        )
        @TestState var mockNetwork: MockNetwork! = .create(using: dependencies)
        @TestState var mockAppContext: MockAppContext! = .create(using: dependencies)
        @TestState var mockUserDefaults: MockUserDefaults! = .create(using: dependencies)
        @TestState var mockGeneralCache: MockGeneralCache! = .create(using: dependencies)
        @TestState var mockCommunityManager: MockCommunityManager! = .create(using: dependencies)
        @TestState var mockCrypto: MockCrypto! = .create(using: dependencies)
        @TestState var cache: CommunityPoller.Cache! = CommunityPoller.Cache(using: dependencies)
        
        beforeEach {
            dependencies.set(singleton: .storage, to: mockStorage)
            await withCheckedContinuation { continuation in
                mockStorage.perform(
                    migrations: SNMessagingKit.migrations,
                    onProgressUpdate: { _, _ in },
                    onComplete: { _ in continuation.resume() }
                )
            }
            try await mockStorage.writeAsync { db in
                try Identity(variant: .x25519PublicKey, data: Data(hex: TestConstants.publicKey)).insert(db)
                try Identity(variant: .x25519PrivateKey, data: Data(hex: TestConstants.privateKey)).insert(db)
                try Identity(variant: .ed25519PublicKey, data: Data(hex: TestConstants.edPublicKey)).insert(db)
                try Identity(variant: .ed25519SecretKey, data: Data(hex: TestConstants.edSecretKey)).insert(db)
                
                try OpenGroup(
                    server: "testServer",
                    roomToken: "testRoom",
                    publicKey: TestConstants.publicKey,
                    shouldPoll: true,
                    name: "Test",
                    roomDescription: nil,
                    imageId: nil,
                    userCount: 0,
                    infoUpdates: 0
                ).insert(db)
                try OpenGroup(
                    server: "testServer1",
                    roomToken: "testRoom1",
                    publicKey: TestConstants.publicKey,
                    shouldPoll: true,
                    name: "Test1",
                    roomDescription: nil,
                    imageId: nil,
                    userCount: 0,
                    infoUpdates: 0
                ).insert(db)
                try Capability(openGroupServer: "testServer", variant: .sogs, isMissing: false).insert(db)
            }
            
            dependencies.set(singleton: .network, to: mockNetwork)
            // Delay for 10 seconds because we don't want the Poller to get stuck in a recursive loop
            try await mockNetwork
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
                    MockNetwork.response(with: FileUploadResponse(id: "1", uploaded: nil, expires: nil))
                        .delay(for: .seconds(10), scheduler: DispatchQueue.main)
                        .eraseToAnyPublisher()
                )
            
            dependencies.set(singleton: .appContext, to: mockAppContext)
            try await mockAppContext.when { @MainActor in $0.isMainAppAndActive }.thenReturn(false)
            
            dependencies.set(cache: .general, to: mockGeneralCache)
            try await mockGeneralCache.defaultInitialSetup()
            
            dependencies.set(singleton: .communityManager, to: mockCommunityManager)
            try await mockCommunityManager.when { await $0.pendingChanges }.thenReturn([])
            try await mockCommunityManager
                .when { await $0.getLastSuccessfulCommunityPollTimestamp() }
                .thenReturn(0)
            
            dependencies.set(singleton: .crypto, to: mockCrypto)
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
                .when { $0.generate(.randomBytes(16)) }
                .thenReturn(Array(Data(base64Encoded: "pK6YRtQApl4NhECGizF0Cg==")!))
            try await mockCrypto
                .when { $0.generate(.ed25519KeyPair(seed: Array<UInt8>.any)) }
                .thenReturn(
                    KeyPair(
                        publicKey: Array(Data(hex: TestConstants.edPublicKey)),
                        secretKey: Array(Data(hex: TestConstants.edSecretKey))
                    )
                )
        }
        
        // MARK: - a CommunityPollerCache
        describe("a CommunityPollerCache") {
            // MARK: -- when starting polling
            context("when starting polling") {
                beforeEach {
                    try await mockAppContext
                        .when { @MainActor in $0.isMainAppAndActive }
                        .thenReturn(true)
                }
                
                // MARK: ---- creates pollers for all of the communities
                it("creates pollers for all of the communities") {
                    cache.startAllPollers()
                    
                    await expect(cache.serversBeingPolled).toEventually(equal(["testserver", "testserver1"]))
                }
                
                // MARK: ---- creates a poll task
                it("creates a poll task") {
                    cache.startAllPollers()
                    
                    await expect(cache.allPollers.count).toEventually(equal(2))
                    try require(cache.allPollers.count).to(equal(2))
                    expect(cache.allPollers[0].pollTask).toNot(beNil())
                    expect(cache.allPollers[1].pollTask).toNot(beNil())
                }
                
                // MARK: ---- does not create additional pollers if it's already polling
                it("does not create additional pollers if it's already polling") {
                    cache
                        .getOrCreatePoller(for: CommunityPoller.Info(server: "testserver", pollFailureCount: 0))
                        .startIfNeeded()
                    cache
                        .getOrCreatePoller(for: CommunityPoller.Info(server: "testserver1", pollFailureCount: 0))
                        .startIfNeeded()
                    
                    cache.startAllPollers()
                    
                    expect(cache.allPollers.count).to(equal(2))
                }
            }
            
            // MARK: -- when stopping polling
            context("when stopping polling") {
                beforeEach {
                    cache.startAllPollers()
                }
                
                // MARK: ---- removes all pollers
                it("removes all pollers") {
                    cache.stopAndRemoveAllPollers()
                    
                    expect(cache.allPollers.count).to(equal(0))
                }
                
                // MARK: ---- removes the pollTask
                it("removes the pollTask") {
                    let poller1 = cache.getOrCreatePoller(for: CommunityPoller.Info(server: "testserver", pollFailureCount: 0))
                    let poller2 = cache.getOrCreatePoller(for: CommunityPoller.Info(server: "testserver1", pollFailureCount: 0))
                    cache.stopAndRemoveAllPollers()
                    
                    expect(poller1.pollTask).to(beNil())
                    expect(poller2.pollTask).to(beNil())
                }
            }
        }
    }
}
