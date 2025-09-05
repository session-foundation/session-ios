// Copyright © 2024 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import Combine
import GRDB
import SessionNetworkingKit
import SessionUtilitiesKit

import Quick
import Nimble

@testable import SessionMessagingKit

class CommunityPollerManagerSpec: AsyncSpec {
    override class func spec() {
        @TestState var fixture: CommunityPollerManagerTestFixture!
        
        beforeEach {
            fixture = try await CommunityPollerManagerTestFixture.create()
        }
        
        // MARK: - a CommunityPollerManager
        describe("a CommunityPollerManager") {
            // MARK: -- when starting polling
            context("when starting polling") {
                // MARK: ---- creates pollers for all of the communities
                it("creates pollers for all of the communities") {
                    await fixture.setupForActivePolling()
                    await fixture.manager.startAllPollers()
                    
                    await expect { await fixture.manager.serversBeingPolled }
                        .to(equal(["testserver", "testserver1"]))
                }
                
                // MARK: ---- creates a poll task
                it("creates a poll task") {
                    await fixture.setupForActivePolling()
                    await fixture.manager.startAllPollers()
                    
                    await expect { await fixture.manager.allPollers.count } .to(equal(2))
                    try await require { await fixture.manager.allPollers.count }.to(equal(2))
                    await expect { await fixture.manager.allPollers[0].pollTask }.toNot(beNil())
                    await expect { await fixture.manager.allPollers[1].pollTask }.toNot(beNil())
                }
                
                // MARK: ---- does not create additional pollers if it's already polling
                it("does not create additional pollers if it's already polling") {
                    await fixture.setupForActivePolling()
                    await fixture.manager
                        .getOrCreatePoller(for: CommunityPoller.Info(server: "testserver", pollFailureCount: 0))
                        .startIfNeeded()
                    await fixture.manager
                        .getOrCreatePoller(for: CommunityPoller.Info(server: "testserver1", pollFailureCount: 0))
                        .startIfNeeded()
                    
                    await fixture.manager.startAllPollers()
                    
                    await expect { await fixture.manager.allPollers.count }.to(equal(2))
                }
            }
            
            // MARK: -- when stopping polling
            context("when stopping polling") {
                // MARK: ---- removes all pollers
                it("removes all pollers") {
                    await fixture.manager.startAllPollers()
                    await fixture.manager.stopAndRemoveAllPollers()
                    
                    await expect { await fixture.manager.allPollers.count }.to(equal(0))
                }
                
                // MARK: ---- updates the isPolling flag
                it("updates the isPolling flag") {
                    await fixture.manager.startAllPollers()
                    
                    let poller1 = await fixture.manager.getOrCreatePoller(for: CommunityPoller.Info(server: "testserver", pollFailureCount: 0))
                    let poller2 = await fixture.manager.getOrCreatePoller(for: CommunityPoller.Info(server: "testserver1", pollFailureCount: 0))
                    await fixture.manager.stopAndRemoveAllPollers()
                    
                    await expect { await poller1.pollTask }.to(beNil())
                    await expect { await poller2.pollTask }.to(beNil())
                }
            }
        }
    }
}

// MARK: - Configuration

private class CommunityPollerManagerTestFixture: FixtureBase {
    var mockStorage: Storage {
        mock(for: .storage) { dependencies in
            Storage(
                customWriter: try! DatabaseQueue(),
                using: dependencies
            )
        }
    }
    var mockNetwork: MockNetwork { mock(for: .network) { MockNetwork() } }
    var mockAppContext: MockAppContext { mock(for: .appContext) }
    var mockUserDefaults: MockUserDefaults { mock(for: .standard) { MockUserDefaults() } }
    var mockGeneralCache: MockGeneralCache { mock(cache: .general) { MockGeneralCache() } }
    var mockOGMCache: MockOGMCache { mock(cache: .openGroupManager) { MockOGMCache() } }
    var mockCrypto: MockCrypto { mock(for: .crypto) { MockCrypto() } }
    lazy var manager: CommunityPollerManager = CommunityPollerManager(using: dependencies)
    
    static func create() async throws -> CommunityPollerManagerTestFixture {
        let fixture: CommunityPollerManagerTestFixture = CommunityPollerManagerTestFixture()
        try await fixture.applyBaselineStubs()
        
        return fixture
    }
    
    // MARK: - Default State

    private func applyBaselineStubs() async throws {
        try await applyBaselineStorage()
        await applyBaselineNetwork()
        await applyBaselineAppContext()
        await applyBaselineUserDefaults()
        await applyBaselineGeneralCache()
        await applyBaselineOGMCache()
        await applyBaselineCrypto()
    }
    
    private func applyBaselineStorage() async throws {
        try await mockStorage.perform(migrations: SNMessagingKit.migrations, onProgressUpdate: nil)
        try await mockStorage.writeAsync { db in
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
                infoUpdates: 0
            ).insert(db)
            try OpenGroup(
                server: "testServer1",
                roomToken: "testRoom1",
                publicKey: TestConstants.publicKey,
                isActive: true,
                name: "Test1",
                roomDescription: nil,
                imageId: nil,
                userCount: 0,
                infoUpdates: 0
            ).insert(db)
            try Capability(openGroupServer: "testServer", variant: .sogs, isMissing: false).insert(db)
        }
    }
    
    private func applyBaselineNetwork() async {
        mockNetwork.when { await $0.isSuspended }.thenReturn(false)
        mockNetwork.when { $0.networkStatus }.thenReturn(.singleValue(value: .connected))
        
        /// Delay for 10 seconds because we don't want the Poller to get stuck in a recursive loop
        mockNetwork
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
                MockNetwork.response(with: FileUploadResponse(id: "1"))
                    .delay(for: .seconds(10), scheduler: DispatchQueue.main)
                    .eraseToAnyPublisher()
            )
    }
    
    private func applyBaselineAppContext() async {
        await mockAppContext.when { await $0.isMainAppAndActive }.thenReturn(false)
    }
    
    private func applyBaselineUserDefaults() async {}
    
    private func applyBaselineGeneralCache() async {
        mockGeneralCache.when { $0.sessionId }.thenReturn(SessionId(.standard, hex: TestConstants.publicKey))
        mockGeneralCache.when { $0.ed25519SecretKey }.thenReturn(Array(Data(hex: TestConstants.edSecretKey)))
        mockGeneralCache
            .when { $0.ed25519Seed }
            .thenReturn(Array(Array(Data(hex: TestConstants.edSecretKey)).prefix(upTo: 32)))
    }
    
    private func applyBaselineOGMCache() async {
        mockOGMCache.when { $0.pendingChanges }.thenReturn([])
        mockOGMCache.when { $0.getLastSuccessfulCommunityPollTimestamp() }.thenReturn(0)
    }
    
    private func applyBaselineCrypto() async {
        mockCrypto
            .when { $0.generate(.hash(message: .any, key: .any, length: .any)) }
            .thenReturn([])
        mockCrypto
            .when { $0.generate(.blinded15KeyPair(serverPublicKey: .any, ed25519SecretKey: .any)) }
            .thenReturn(
                KeyPair(
                    publicKey: Data(hex: TestConstants.publicKey).bytes,
                    secretKey: Data(hex: TestConstants.edSecretKey).bytes
                )
            )
        mockCrypto
            .when { $0.generate(.signatureBlind15(message: .any, serverPublicKey: .any, ed25519SecretKey: .any)) }
            .thenReturn("TestSogsSignature".bytes)
        mockCrypto
            .when { $0.generate(.randomBytes(16)) }
            .thenReturn(Array(Data(base64Encoded: "pK6YRtQApl4NhECGizF0Cg==")!))
        mockCrypto
            .when { $0.generate(.ed25519KeyPair(seed: .any)) }
            .thenReturn(
                KeyPair(
                    publicKey: Array(Data(hex: TestConstants.edPublicKey)),
                    secretKey: Array(Data(hex: TestConstants.edSecretKey))
                )
            )
    }
    
    // MARK: - Test Specific Configurations
    
    @MainActor func setupForActivePolling() async {
        await mockAppContext.when { $0.isMainAppAndActive }.thenReturn(true)
    }
}
