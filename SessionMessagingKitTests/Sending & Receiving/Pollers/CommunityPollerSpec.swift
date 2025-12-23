// Copyright © 2024 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import Combine
import GRDB
import SessionNetworkingKit
import SessionUtilitiesKit

import Quick
import Nimble

@testable import SessionMessagingKit

class CommunityPollerSpec: AsyncSpec {
    override class func spec() {
        // MARK: Configuration
        
        @TestState var dependencies: TestDependencies! = TestDependencies { dependencies in
            dependencies.dateNow = Date(timeIntervalSince1970: 1234567890)
            dependencies.forceSynchronous = true
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
        )
        @TestState(singleton: .network, in: dependencies) var mockNetwork: MockNetwork! = MockNetwork(
            initialSetup: { network in
                // Delay for 10 seconds because we don't want the Poller to get stuck in a recursive loop
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
                        MockNetwork.response(with: FileUploadResponse(id: "1", uploaded: nil, expires: nil))
                            .delay(for: .seconds(10), scheduler: DispatchQueue.main)
                            .eraseToAnyPublisher()
                    )
            }
        )
        @TestState(singleton: .appContext, in: dependencies) var mockAppContext: MockAppContext! = MockAppContext(
            initialSetup: { context in
                context.when { @MainActor in $0.isMainAppAndActive }.thenReturn(false)
            }
        )
        @TestState(defaults: .standard, in: dependencies) var mockUserDefaults: MockUserDefaults! = MockUserDefaults()
        @TestState(cache: .general, in: dependencies) var mockGeneralCache: MockGeneralCache! = MockGeneralCache(
            initialSetup: { cache in
                cache.when { $0.sessionId }.thenReturn(SessionId(.standard, hex: TestConstants.publicKey))
                cache.when { $0.ed25519SecretKey }.thenReturn(Array(Data(hex: TestConstants.edSecretKey)))
                cache
                    .when { $0.ed25519Seed }
                    .thenReturn(Array(Array(Data(hex: TestConstants.edSecretKey)).prefix(upTo: 32)))
            }
        )
        @TestState(singleton: .communityManager, in: dependencies) var mockCommunityManager: MockCommunityManager! = MockCommunityManager(
            initialSetup: { manager in
                manager.when { await $0.pendingChanges }.thenReturn([])
                manager.when { await $0.getLastSuccessfulCommunityPollTimestamp() }.thenReturn(0)
            }
        )
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
                    .when { $0.generate(.randomBytes(16)) }
                    .thenReturn(Array(Data(base64Encoded: "pK6YRtQApl4NhECGizF0Cg==")!))
                crypto
                    .when { $0.generate(.ed25519KeyPair(seed: Array<UInt8>.any)) }
                    .thenReturn(
                        KeyPair(
                            publicKey: Array(Data(hex: TestConstants.edPublicKey)),
                            secretKey: Array(Data(hex: TestConstants.edSecretKey))
                        )
                    )
            }
        )
        @TestState var cache: CommunityPoller.Cache! = CommunityPoller.Cache(using: dependencies)
        
        // MARK: - a CommunityPollerCache
        describe("a CommunityPollerCache") {
            // MARK: -- when starting polling
            context("when starting polling") {
                beforeEach {
                    mockAppContext.when { @MainActor in $0.isMainAppAndActive }.thenReturn(true)
                }
                
                // MARK: ---- creates pollers for all of the communities
                it("creates pollers for all of the communities") {
                    cache.startAllPollers()
                    
                    await expect(cache.serversBeingPolled).toEventually(equal(["testserver", "testserver1"]))
                }
                
                // MARK: ---- updates the isPolling flag
                it("updates the isPolling flag") {
                    cache.startAllPollers()
                    
                    await expect(cache.allPollers.count).toEventually(equal(2))
                    try require(cache.allPollers.count).to(equal(2))
                    expect(cache.allPollers[0].isPolling).to(beTrue())
                    expect(cache.allPollers[1].isPolling).to(beTrue())
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
                
                // MARK: ---- updates the isPolling flag
                it("updates the isPolling flag") {
                    let poller1 = cache.getOrCreatePoller(for: CommunityPoller.Info(server: "testserver", pollFailureCount: 0))
                    let poller2 = cache.getOrCreatePoller(for: CommunityPoller.Info(server: "testserver1", pollFailureCount: 0))
                    cache.stopAndRemoveAllPollers()
                    
                    expect(poller1.isPolling).to(beFalse())
                    expect(poller2.isPolling).to(beFalse())
                }
            }
        }
    }
}
