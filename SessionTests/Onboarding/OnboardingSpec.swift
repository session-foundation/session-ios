// Copyright © 2026 Rangeproof Pty Ltd. All rights reserved.

import Combine
import GRDB
import Quick
import Nimble
import SessionUtil
import SessionUIKit
import SessionUtilitiesKit
import TestUtilities

@testable import Session
@testable import SessionNetworkingKit
@testable import SessionMessagingKit

class OnboardingSpec: AsyncSpec {
    override class func spec() {
        // MARK: Configuration
        
        @TestState var dependencies: TestDependencies! = TestDependencies { dependencies in
            dependencies.forceSynchronous = true
            dependencies[singleton: .scheduler] = .immediate
            dependencies.uuid = .mock
            dependencies.dateNow = Date(timeIntervalSince1970: 1234567890)
        }
        @TestState var mockStorage: Storage! = try! Storage.createForTesting(using: dependencies)
        @TestState var mockCrypto: MockCrypto! = .create(using: dependencies)
        @TestState var mockLibSessionCache: MockLibSessionCache! = .create(using: dependencies)
        @TestState var mockUserDefaults: MockUserDefaults! = .create(using: dependencies)
        @TestState var mockGeneralCache: MockGeneralCache! = .create(using: dependencies)
        @TestState var mockNetwork: MockNetwork! = .create(using: dependencies)
        @TestState var mockExtensionHelper: MockExtensionHelper! = .create(using: dependencies)
        @TestState var mockJobRunner: MockJobRunner! = .create(using: dependencies)
        @TestState var manager: Onboarding.Manager!
        
        beforeEach {
            dependencies.set(cache: .general, to: mockGeneralCache)
            try await mockGeneralCache.defaultInitialSetup()
            
            dependencies.set(cache: .libSession, to: mockLibSessionCache)
            try await mockLibSessionCache.defaultInitialSetup()
            try await mockLibSessionCache
                .when {
                    $0.profile(
                        contactId: .any,
                        threadId: .any,
                        threadVariant: .any,
                        visibleMessage: .any
                    )
                }
                .thenReturn(nil)
            
            dependencies.set(singleton: .storage, to: mockStorage)
            try await mockStorage.perform(migrations: SNMessagingKit.migrations)
            
            dependencies.set(singleton: .crypto, to: mockCrypto)
            try await mockCrypto
                .when { $0.generate(.x25519(ed25519Pubkey: .any)) }
                .thenReturn(Array(Data(hex: TestConstants.publicKey)))
            try await mockCrypto
                .when { $0.generate(.x25519(ed25519Seckey: .any)) }
                .thenReturn(Array(Data(hex: TestConstants.privateKey)))
            try await mockCrypto
                .when { $0.generate(.randomBytes(.any)) }
                .thenReturn(Data([1, 2, 3, 4, 5, 6, 7, 8, 1, 2, 3, 4, 5, 6, 7, 8]))
            try await mockCrypto
                .when { $0.generate(.ed25519Seed(ed25519SecretKey: Array<UInt8>.any)) }
                .thenReturn(Data([
                    1, 2, 3, 4, 5, 6, 7, 8, 9, 0,
                    1, 2, 3, 4, 5, 6, 7, 8, 9, 0,
                    1, 2, 3, 4, 5, 6, 7, 8, 9, 0,
                    1, 2
                ]))
            try await mockCrypto
                .when { $0.generate(.ed25519KeyPair(seed: Array<UInt8>.any)) }
                .thenReturn(
                    KeyPair(
                        publicKey: Array(Data(hex: TestConstants.edPublicKey)),
                        secretKey: Array(Data(hex: TestConstants.edSecretKey))
                    )
                )
            try await mockCrypto
                .when { $0.generate(.signature(message: .any, ed25519SecretKey: .any)) }
                .thenReturn(Authentication.Signature.standard(signature: "TestSignature".bytes))
            
            dependencies.set(singleton: .network, to: mockNetwork)
            let pendingPushes: LibSession.PendingPushes? = {
                let cache: LibSession.Cache = LibSession.Cache(
                    userSessionId: SessionId(.standard, hex: TestConstants.publicKey),
                    using: dependencies
                )
                cache.loadDefaultStateFor(
                    variant: .userProfile,
                    sessionId: cache.userSessionId,
                    userEd25519SecretKey: Array(Data(hex: TestConstants.edSecretKey)),
                    groupEd25519SecretKey: nil
                )
                try? cache.updateProfile(displayName: "TestPolledName")
                
                return try? cache.pendingPushes(swarmPublicKey: cache.userSessionId.hexString)
            }()
            
            try await mockNetwork.defaultInitialSetup(using: dependencies)
            await mockNetwork.removeRequestMocks()
            await mockNetwork.removeMocksFor { try await $0.getSwarm(for: .any, ignoreStrikeCount: .any) }
            try await mockNetwork
                .when { try await $0.getSwarm(for: .any, ignoreStrikeCount: .any) }
                .thenReturn([
                    LibSession.Snode(
                        ed25519PubkeyHex: "1234",
                        ip: "1.2.3.4",
                        httpsPort: 1233,
                        quicPort: 1234,
                        version: "2.11.0",
                        swarmId: 1
                    )
                ])
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
                .thenReturn(MockNetwork.batchResponseData(
                    with: [
                        (
                            Network.StorageServer.Endpoint.getMessages,
                            Network.StorageServer.GetMessagesResponse(
                                messages: (pendingPushes?
                                    .pushData
                                    .first { $0.variant == .userProfile }?
                                    .data
                                    .enumerated()
                                    .map { index, data in
                                        Network.StorageServer.GetMessagesResponse.RawMessage(
                                            base64EncodedDataString: data.base64EncodedString(),
                                            expirationMs: nil,
                                            hash: "\(index)",
                                            timestampMs: 1234567890
                                        )
                                    } ?? []),
                                more: false,
                                hardForkVersion: [2, 2],
                                timeOffset: 0
                                
                            ).batchSubResponse()
                        )
                    ]
                ))
            
            dependencies.set(defaults: .standard, to: mockUserDefaults)
            try await mockUserDefaults.defaultInitialSetup()
            try await mockUserDefaults
                .when { $0.bool(forKey: UserDefaults.BoolKey.isMainAppActive.rawValue) }
                .thenReturn(true)
            try await mockUserDefaults
                .when { $0.bool(forKey: UserDefaults.BoolKey.isUsingFullAPNs.rawValue) }
                .thenReturn(false)
            try await mockUserDefaults.when { $0.integer(forKey: .any) }.thenReturn(2)
            
            dependencies.set(singleton: .extensionHelper, to: mockExtensionHelper)
            try await mockExtensionHelper
                .when { $0.lastUpdatedTimestamp(for: .any, variant: .any) }
                .thenReturn(0)
            try await mockExtensionHelper
                .when { $0.replicate(dump: .any, replaceExisting: .any) }
                .thenReturn(())
            try await mockExtensionHelper
                .when {
                    try $0.saveUserMetadata(
                        sessionId: .any,
                        ed25519SecretKey: .any,
                        unreadCount: .any
                    )
                }
                .thenReturn(())
            try await mockExtensionHelper.when { $0.userMetadataExists() }.thenReturn(false)
            try await mockExtensionHelper.when { $0.loadUserMetadata() }.thenReturn(nil)
            
            dependencies.set(singleton: .jobRunner, to: mockJobRunner)
            try await mockJobRunner
                .when { $0.add(.any, job: .any, initialDependencies: .any) }
                .thenReturn(nil)
            try await mockJobRunner
                .when { await $0.jobsMatching(filters: .any) }
                .thenReturn([:])
        }
        
        // MARK: - an Onboarding Cache - Initialization
        describe("an Onboarding Cache when initialising") {
            beforeEach {
                try await mockLibSessionCache
                    .when { $0.profile(contactId: .any, threadId: .any, threadVariant: .any, visibleMessage: .any) }
                    .thenReturn(nil)
            }
            
            justBeforeEach {
                manager = Onboarding.Manager(
                    flow: .restore,
                    using: dependencies
                )
                try await manager.loadInitialState()
            }
            
            // MARK: -- stores the initialFlow
            it("stores the initialFlow") {
                for flow in Onboarding.Flow.allCases {
                    manager = Onboarding.Manager(
                        flow: flow,
                        using: dependencies
                    )
                    await expect { await manager.initialFlow }.to(equal(flow))
                }
            }
            
            // MARK: -- without a stored secret key
            context("without a stored secret key") {
                beforeEach {
                    try await mockGeneralCache.when { $0.ed25519SecretKey }.thenReturn([])
                    try await mockCrypto
                        .when { $0.generate(.ed25519KeyPair(seed: Array<UInt8>.any)) }
                        .thenReturn(KeyPair(publicKey: [1, 2, 3], secretKey: [4, 5, 6]))
                    try await mockCrypto
                        .when { $0.generate(.x25519(ed25519Pubkey: .any)) }
                        .thenReturn([3, 2, 1])
                    try await mockCrypto
                        .when { $0.generate(.x25519(ed25519Seckey: .any)) }
                        .thenReturn([6, 5, 4])
                }
                
                // MARK: ---- generates new key pairs
                it("generates new key pairs") {
                    await expect { await manager.ed25519KeyPair.publicKey.toHexString() }
                        .toEventually(equal("010203"))
                    await expect { await manager.ed25519KeyPair.secretKey.toHexString() }
                        .toEventually(equal("040506"))
                    await expect { await manager.x25519KeyPair.publicKey.toHexString() }
                        .toEventually(equal("030201"))
                    await expect { await manager.x25519KeyPair.secretKey.toHexString() }
                        .toEventually(equal("060504"))
                    await expect { await manager.userSessionId }
                        .toEventually(equal(SessionId(.standard, hex: "030201")))
                }
            }
            
            // MARK: -- with a stored secret key
            context("with a stored secret key") {
                beforeEach {
                    try await mockGeneralCache
                        .when { $0.ed25519SecretKey }
                        .thenReturn(Array(Data(hex: TestConstants.edSecretKey)))
                    try await mockCrypto
                        .when { $0.generate(.ed25519KeyPair(seed: Array<UInt8>.any)) }
                        .thenReturn(
                            KeyPair(
                                publicKey: Array(Data(hex: TestConstants.edPublicKey)),
                                secretKey: Array(Data(hex: TestConstants.edSecretKey))
                            )
                        )
                }
                
                // MARK: ---- does not generate a seed
                it("does not generate a seed") {
                    await expect { await manager.seed.isEmpty }.to(beTrue())
                }
                
                // MARK: ---- loads the ed25519 key pair from the database
                it("loads the ed25519 key pair from the database") {
                    await expect { await manager.ed25519KeyPair.publicKey.toHexString() }
                        .to(equal(TestConstants.edPublicKey))
                    await expect { await manager.ed25519KeyPair.secretKey.toHexString() }
                        .to(equal(TestConstants.edSecretKey))
                }
                
                // MARK: ---- generates the x25519KeyPair from the loaded ed25519 key pair
                it("generates the x25519KeyPair from the loaded ed25519 key pair") {
                    await mockCrypto
                        .verify { $0.generate(.x25519(ed25519Pubkey: Array(Data(hex: TestConstants.edPublicKey)))) }
                        .wasCalled(exactly: 1)
                    await mockCrypto
                        .verify { $0.generate(.x25519(ed25519Seckey: Array(Data(hex: TestConstants.edSecretKey)))) }
                        .wasCalled(exactly: 1)
                    
                    await expect { await manager.x25519KeyPair.publicKey.toHexString() }
                        .to(equal(TestConstants.publicKey))
                    await expect { await manager.x25519KeyPair.secretKey.toHexString() }
                        .to(equal(TestConstants.privateKey))
                }
                
                // MARK: ---- generates the sessionId from the generated x25519PublicKey
                it("generates the sessionId from the generated x25519PublicKey") {
                    await expect { await manager.userSessionId }
                        .to(equal(SessionId(.standard, hex: TestConstants.publicKey)))
                }
                
                // MARK: ---- and failing to generate an x25519KeyPair
                context("and failing to generate an x25519KeyPair") {
                    beforeEach {
                        await mockCrypto.removeMocksFor {
                            $0.generate(.ed25519KeyPair(seed: Array<UInt8>.any))
                        }
                        await mockCrypto.removeMocksFor {
                            $0.generate(.ed25519Seed(ed25519SecretKey: Array<UInt8>.any))
                        }
                        try await mockCrypto
                            .when {
                                try $0.tryGenerate(
                                    .ed25519Seed(
                                        ed25519SecretKey: Array(Data(hex: TestConstants.edSecretKey))
                                    )
                                )
                            }
                            .thenReturn(Data([9, 8, 7]))
                        try await mockCrypto
                            .when { $0.generate(.ed25519KeyPair(seed: [9, 8, 7])) }
                            .thenReturn(KeyPair(publicKey: [9, 8, 7, 6], secretKey: [5, 4, 3, 2]))
                        try await mockCrypto
                            .when {
                                $0.generate(.ed25519KeyPair(seed: [
                                    1, 2, 3, 4, 5, 6, 7, 8, 1, 2, 3, 4, 5, 6, 7, 8,
                                    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
                                ]))
                            }
                            .thenReturn(KeyPair(publicKey: [1, 2, 3], secretKey: [4, 5, 6]))
                        try await mockCrypto
                            .when { $0.generate(.x25519(ed25519Pubkey: [1, 2, 3])) }
                            .thenReturn([4, 3, 2, 1])
                        try await mockCrypto
                            .when { $0.generate(.x25519(ed25519Seckey: [4, 5, 6])) }
                            .thenReturn([7, 6, 5, 4])
                        try await mockCrypto
                            .when { $0.generate(.x25519(ed25519Pubkey: [9, 8, 7, 6])) }
                            .thenReturn(nil)
                    }
                    
                    // MARK: ------ generates new credentials
                    it("generates new credentials") {
                        await expect { await manager.state.first() }.to(equal(.noUserInvalidKeyPair))
                        await expect { await manager.seed }
                            .to(equal(Data([1, 2, 3, 4, 5, 6, 7, 8, 1, 2, 3, 4, 5, 6, 7, 8])))
                        await expect { await manager.ed25519KeyPair.publicKey.toHexString() }.to(equal("010203"))
                        await expect { await manager.ed25519KeyPair.secretKey.toHexString() }.to(equal("040506"))
                        await expect { await manager.x25519KeyPair.publicKey.toHexString() }.to(equal("04030201"))
                        await expect { await manager.x25519KeyPair.secretKey.toHexString() }.to(equal("07060504"))
                        await expect { await manager.userSessionId }.to(equal(SessionId(.standard, hex: "04030201")))
                    }
                    
                    // MARK: ------ goes into an invalid state when generating a seed fails
                    it("goes into an invalid state when generating a seed fails") {
                        /// Need to set `mockLibSessionCache` again as it would have been cleared by the first creation
                        /// of the `Onboarding.Manager`
                        dependencies.set(cache: .libSession, to: mockLibSessionCache)
                        try await mockCrypto
                            .when { $0.generate(.randomBytes(.any)) }
                            .thenReturn(nil as Data?)
                        
                        manager = Onboarding.Manager(
                            flow: .restore,
                            using: dependencies
                        )
                        try await manager.loadInitialState()
                        await expect{ await manager.state.first() }.to(equal(.noUserInvalidSeedGeneration))
                    }
                    
                    // MARK: ------ does not load the useAPNs flag from user defaults
                    it("does not load the useAPNs flag from user defaults") {
                        await mockUserDefaults.verify { $0.bool(forKey: .any) }.wasNotCalled()
                    }
                }
                
                // MARK: ---- and an existing display name
                context("and an existing display name") {
                    beforeEach {
                        try await mockUserDefaults
                            .when { $0.bool(forKey: UserDefaults.BoolKey.isUsingFullAPNs.rawValue) }
                            .thenReturn(true)
                        try await mockLibSessionCache
                            .when {
                                $0.profile(
                                    contactId: .any,
                                    threadId: .any,
                                    threadVariant: .any,
                                    visibleMessage: .any
                                )
                            }
                            .thenReturn(
                                Profile(
                                    id: "TestProfileId",
                                    name: "TestProfileName",
                                    nickname: nil,
                                    displayPictureUrl: nil,
                                    displayPictureEncryptionKey: nil,
                                    profileLastUpdated: nil,
                                    blocksCommunityMessageRequests: nil,
                                    proFeatures: .none,
                                    proExpiryUnixTimestampSeconds: 0,
                                    proRevocationTagHex: nil
                                )
                            )
                    }
                    
                    // MARK: ------ loads from libSession
                    it("loads from libSession") {
                        await mockLibSessionCache
                            .verify {
                                $0.profile(
                                    contactId: "05\(TestConstants.publicKey)",
                                    threadId: nil,
                                    threadVariant: nil,
                                    visibleMessage: nil
                                )
                            }
                            .wasCalled(exactly: 1)
                    }
                    
                    // MARK: ------ stores the loaded displayName
                    it("stores the loaded displayName") {
                        await expect { await manager.displayName.first() }
                            .toEventually(equal("TestProfileName"), timeout: .milliseconds(100))
                    }
                    
                    // MARK: ------ loads the useAPNs setting from user defaults
                    it("loads the useAPNs setting from user defaults") {
                        await mockUserDefaults.verify { $0.bool(forKey: .any) }.wasCalled()
                        await expect{ await manager.useAPNS }.to(beTrue())
                    }
                    
                    // MARK: ------ after generating new credentials
                    context("after generating new credentials") {
                        beforeEach {
                            await mockCrypto.removeMocksFor {
                                $0.generate(.ed25519KeyPair(seed: Array<UInt8>.any))
                            }
                            await mockCrypto.removeMocksFor {
                                $0.generate(.ed25519Seed(ed25519SecretKey: Array<UInt8>.any))
                            }
                            try await mockCrypto
                                .when { try $0.tryGenerate(.ed25519Seed(ed25519SecretKey: Array<UInt8>.any)) }
                                .thenThrow(MockError.mock)
                            try await mockCrypto
                                .when {
                                    $0.generate(.ed25519KeyPair(
                                        seed: Array(Data(hex: TestConstants.edSecretKey))
                                    ))
                                }
                                .thenReturn(KeyPair(publicKey: [1, 2, 3], secretKey: [9, 8, 7]))
                            try await mockCrypto
                                .when {
                                    $0.generate(.ed25519KeyPair(seed: [
                                        1, 2, 3, 4, 5, 6, 7, 8, 1, 2, 3, 4, 5, 6, 7, 8,
                                        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
                                    ]))
                                }
                                .thenReturn(KeyPair(publicKey: [1, 2, 3], secretKey: [4, 5, 6]))
                            try await mockCrypto
                                .when { $0.generate(.x25519(ed25519Pubkey: [1, 2, 3])) }
                                .thenReturn([4, 3, 2, 1])
                            try await mockCrypto
                                .when { $0.generate(.x25519(ed25519Seckey: [4, 5, 6])) }
                                .thenReturn([7, 6, 5, 4])
                            try await mockCrypto
                                .when { $0.generate(.x25519(ed25519Pubkey: [9, 8, 7])) }
                                .thenReturn(nil)
                        }
                        
                        // MARK: -------- has no display name
                        it("has no display name") {
                            await expect { await manager.displayName.first() }.to(beNil())
                        }
                    }
                }
                
                // MARK: ---- and a missing display name
                context("and a missing display name") {
                    beforeEach {
                        try await mockUserDefaults
                            .when { $0.bool(forKey: UserDefaults.BoolKey.isUsingFullAPNs.rawValue) }
                            .thenReturn(true)
                    }
                    
                    // MARK: ------ has an empty display name
                    it("has an empty display name") {
                        await expect { await manager.displayName.first() }.to(equal(""))
                    }
                    
                    // MARK: ------ loads the useAPNs setting from user defaults
                    it("loads the useAPNs setting from user defaults") {
                        await mockUserDefaults.verify { $0.bool(forKey: .any) }.wasCalled()
                        await expect { await manager.useAPNS }.to(beTrue())
                    }
                }
            }
        }
        
        // MARK: - an Onboarding Cache - Seed Data
        describe("an Onboarding Cache when setting seed data") {
            beforeEach {
                try await mockCrypto
                    .when { $0.generate(.ed25519KeyPair(seed: Array<UInt8>.any)) }
                    .thenReturn(
                        KeyPair(
                            publicKey: Array(Data(hex: TestConstants.edPublicKey)),
                            secretKey: Array(Data(hex: TestConstants.edSecretKey))
                        )
                    )
            }
            
            justBeforeEach {
                manager = Onboarding.Manager(
                    flow: .register,
                    using: dependencies
                )
                try await manager.loadInitialState()
                try await manager.setSeedData(Data(hex: TestConstants.edKeySeed).prefix(upTo: 16))
            }
            
            // MARK: -- throws if the seed is the wrong length
            it("throws if the seed is the wrong length") {
                await expect { try await manager.setSeedData(Data([1, 2, 3])) }
                    .toEventually(throwError(CryptoError.invalidSeed))
            }
            
            // MARK: -- stores the seed
            it("stores the seed") {
                await expect { await manager.seed }
                    .toEventually(equal(Data(hex: TestConstants.edKeySeed).prefix(upTo: 16)))
            }
            
            // MARK: -- stores the generated identity
            it("stores the generated identity") {
                await expect { await manager.ed25519KeyPair.publicKey.toHexString() }
                    .toEventually(equal(TestConstants.edPublicKey))
                await expect { await manager.ed25519KeyPair.secretKey.toHexString() }
                    .toEventually(equal(TestConstants.edSecretKey))
                await expect { await manager.x25519KeyPair.publicKey.toHexString() }
                    .toEventually(equal(TestConstants.publicKey))
                await expect { await manager.x25519KeyPair.secretKey.toHexString() }
                    .toEventually(equal(TestConstants.privateKey))
                await expect { await manager.userSessionId }
                    .toEventually(equal(SessionId(.standard, hex: TestConstants.publicKey)))
            }
            
            // MARK: -- polls for the userProfile config
            it("polls for the userProfile config") {
                await mockNetwork
                    .verify {
                        try await $0.send(
                            endpoint: Network.StorageServer.Endpoint.batch,
                            destination: Network.Destination.snode(
                                LibSession.Snode(
                                    ed25519PubkeyHex: "1234",
                                    ip: "1.2.3.4",
                                    httpsPort: 1233,
                                    quicPort: 1234,
                                    version: "2.11.0",
                                    swarmId: 1
                                ),
                                swarmPublicKey: "0588672ccb97f40bb57238989226cf429b575ba355443f47bc76c5ab144a96c65b"
                            ),
                            body: try JSONEncoder(using: dependencies).encode(
                                Network.BatchRequest(
                                    target: .storageServer,
                                    requests: [
                                        try Network.StorageServer.preparedGetMessages(
                                            namespace: .configUserProfile,
                                            snode: LibSession.Snode(
                                                ed25519PubkeyHex: "1234",
                                                ip: "1.2.3.4",
                                                httpsPort: 1233,
                                                quicPort: 1234,
                                                version: "2.11.0",
                                                swarmId: 1
                                            ),
                                            lastHash: nil,
                                            maxSize: -1,
                                            authMethod: Authentication.standard(
                                                sessionId: SessionId(.standard, hex: TestConstants.publicKey),
                                                ed25519PublicKey: Array(Data(hex: TestConstants.edPublicKey)),
                                                ed25519SecretKey: Array(Data(hex: TestConstants.edSecretKey))
                                            ),
                                            using: dependencies
                                        )
                                    ]
                                )
                            ),
                            category: .standard,
                            requestTimeout: 10,
                            overallTimeout: nil
                        )
                    }
                    .wasCalled(exactly: 1, timeout: .milliseconds(100))
            }
            
            // MARK: -- the display name stream to output the correct value
            it("the display name stream to output the correct value") {
                await expect { await manager.displayName.first() }.toEventually(equal("TestPolledName"))
            }
        }
        
        // MARK: - an Onboarding Cache - Setting values
        describe("an Onboarding Cache when setting values") {
            justBeforeEach {
                manager = Onboarding.Manager(
                    flow: .register,
                    using: dependencies
                )
                try await manager.loadInitialState()
            }
            
            // MARK: -- stores the useAPNs setting
            it("stores the useAPNs setting") {
                await expect { await manager.useAPNS }.toEventually(beFalse())
                await manager.setUseAPNS(true)
                await expect { await manager.useAPNS }.toEventually(beTrue())
            }
            
            // MARK: -- stores the display name
            it("stores the display name") {
                await expect { await manager.displayName.first() }.toEventually(equal(""))
                await manager.setDisplayName("TestName")
                await expect { await manager.displayName.first() }.toEventually(equal("TestName"))
            }
        }
        
        // MARK: - an Onboarding Cache - Complete Registration
        describe("an Onboarding Cache when completing registration") {
            justBeforeEach {
                try await mockGeneralCache.when { $0.ed25519SecretKey }.thenReturn([])
                
                /// The `profile_updated` timestamp in `libSession` is set to now so we need to set the value to some
                /// distant future value to force the update logic to trigger
                dependencies.dateNow = Date(timeIntervalSince1970: 9876543210)
                
                manager = Onboarding.Manager(
                    flow: .register,
                    using: dependencies
                )
                try await manager.loadInitialState()
                await manager.setDisplayName("TestCompleteName")
                
                await mockGeneralCache.removeMocksFor { $0.ed25519SecretKey }
                try await mockGeneralCache
                    .when { $0.ed25519SecretKey }
                    .thenReturn(Array(Data(hex: TestConstants.edSecretKey)))
                
                try await manager.completeRegistration()
            }
            
            // MARK: -- stores the ed25519 secret key in the general cache
            it("stores the ed25519 secret key in the general cache") {
                await mockGeneralCache
                    .verify { $0.setSecretKey(ed25519SecretKey: Array(Data(hex: TestConstants.edSecretKey))) }
                    .wasCalled(exactly: 1)
            }
            
            // MARK: -- stores a new libSession cache instance
            it("stores a new libSession cache instance") {
                expect(dependencies[cache: .libSession]).toNot(beAKindOf(MockLibSessionCache.self))
            }
            
            // MARK: -- saves the identity data to the database
            it("saves the identity data to the database") {
                await expect {
                    try await mockStorage.read { db in
                        try Identity.fetchAll(db)
                    }
                }
                .toEventually(equal([
                    Identity(variant: .ed25519SecretKey, data: Data(hex: TestConstants.edSecretKey)),
                    Identity(variant: .ed25519PublicKey, data: Data(hex: TestConstants.edPublicKey)),
                    Identity(variant: .x25519PrivateKey, data: Data(hex: TestConstants.privateKey)),
                    Identity(variant: .x25519PublicKey, data: Data(hex: TestConstants.publicKey))
                ]))
            }
            
            // MARK: -- creates a contact record for the current user
            it("creates a contact record for the current user") {
                await expect {
                    try await mockStorage.read { db in
                        try Contact.fetchAll(db)
                    }
                }.toEventually(equal([
                    Contact(
                        id: "0588672ccb97f40bb57238989226cf429b575ba355443f47bc76c5ab144a96c65b",
                        isTrusted: true,
                        isApproved: true,
                        isBlocked: false,
                        lastKnownClientVersion: nil,
                        didApproveMe: true,
                        hasBeenBlocked: false,
                        currentUserSessionId: SessionId(.standard, hex: TestConstants.publicKey)
                    )
                ]))
            }
            
            // MARK: -- creates a profile record for the current user
            it("creates a profile record for the current user") {
                let profile: Profile = try await require {
                    try await mockStorage.read { db in
                        try Profile.fetchAll(db).first
                    }
                }.toEventuallyNot(beNil(), timeout: .milliseconds(100))
                expect(profile.id)
                    .to(equal("0588672ccb97f40bb57238989226cf429b575ba355443f47bc76c5ab144a96c65b"))
                expect(profile.name).to(equal("TestCompleteName"))
                expect(profile.nickname).to(beNil())
                expect(profile.displayPictureUrl).to(beNil())
                expect(profile.displayPictureEncryptionKey).to(beNil())
                expect(profile.blocksCommunityMessageRequests).to(beTrue())
                expect(profile.proFeatures).to(equal(SessionPro.ProfileFeatures.none))
                expect(profile.proExpiryUnixTimestampSeconds).to(equal(0))
                expect(profile.proRevocationTagHex).to(beNil())
                
                /// This value will come out of a proper libSession instance (since the display name isn't getting changed) so we
                /// can't match an exact value as it will be "now")
                expect(profile.profileLastUpdated).toNot(beNil())
            }
            
            // MARK: -- creates a thread for Note to Self
            it("creates a thread for Note to Self") {
                await expect {
                    try await mockStorage.read { db in
                        try SessionThread.fetchAll(db)
                    }
                }.toEventually(equal([
                    SessionThread(
                        id: "0588672ccb97f40bb57238989226cf429b575ba355443f47bc76c5ab144a96c65b",
                        variant: .contact,
                        creationDateTimestamp: 9876543210,
                        shouldBeVisible: false,
                        messageDraft: nil,
                        notificationSound: nil,
                        mutedUntilTimestamp: nil,
                        onlyNotifyForMentions: false,
                        markedAsUnread: false,
                        pinnedPriority: 0,
                        isDraft: false
                    )
                ]))
            }
            
            // MARK: -- has the correct profile in libSession
            it("has the correct profile in libSession") {
                await expect {
                    dependencies.mutate(cache: .libSession) { $0.profile }.with(
                        profileLastUpdated: .set(to: 1234567890)
                    )
                }
                .toEventually(equal(
                    Profile(
                        id: "0588672ccb97f40bb57238989226cf429b575ba355443f47bc76c5ab144a96c65b",
                        name: "TestCompleteName",
                        nickname: nil,
                        displayPictureUrl: nil,
                        displayPictureEncryptionKey: nil,
                        profileLastUpdated: 1234567890,
                        blocksCommunityMessageRequests: true,
                        proFeatures: .none,
                        proExpiryUnixTimestampSeconds: 0,
                        proRevocationTagHex: nil
                    )
                ))
            }
            
            // MARK: -- saves a config dump to the database
            it("saves a config dump to the database") {
                let result: [ConfigDump] = try await require {
                    try await mockStorage.read { db in
                        try ConfigDump.fetchAll(db)
                    }
                }
                .toEventually(haveCount(1))
                let userProfileDump: ConfigDump = try await require { () -> ConfigDump? in
                    result.first(where: { $0.variant == .userProfile })
                }
                .toNot(beNil())
                expect(userProfileDump.variant).to(equal(.userProfile))
                expect(userProfileDump.sessionId).to(equal(SessionId(.standard, hex: TestConstants.publicKey)))
                expect(userProfileDump.timestampMs).to(equal(9876543210000))
                
                /// The data now contains a `now` timestamp so won't be an exact match anymore, but we _can_ check to ensure
                /// the rest of the data matches and that the timestamps are close enough to `now`
                ///
                /// **Note:** The data contains non-ASCII content so we can't do a straight conversion unfortunately
                let resultData: Data = userProfileDump.data
                let prefixData: Data = "d1:!i1e1:$124:d1:#i1e1:&d1:+i-1e1:n16:TestCompleteName1:ti"
                    .data(using: .ascii)!
                let infixData: Data = "ee1:<lli0e32:".data(using: .ascii)!
                let suffixData: Data = "edeee1:=d1:+0:1:n0:1:t0:ee1:(le1:)le1:*de1:+dee".data(using: .ascii)!
                
                guard
                    let prefixRange: Range<Data.Index> = resultData.range(of: prefixData),
                    let infixRange: Range<Data.Index> = resultData
                        .range(of: infixData, in: prefixRange.upperBound..<resultData.endIndex),
                    let suffixRange: Range<Data.Index> = resultData
                        .range(of: suffixData, in: infixRange.upperBound..<resultData.endIndex)
                else { return fail("The structure of the binary data is incorrect.") }
                
                /// Extract the timestamp and ensure it matches
                let timestampRange: Range<Data.Index> = prefixRange.upperBound..<infixRange.lowerBound
                let timestampData: Data = resultData.subdata(in: timestampRange)
                
                guard let timestampString: String = String(data: timestampData, encoding: .ascii) else {
                    return fail("Failed to decode the isolated timestamp data into strings.")
                }
                
                /// Ensure the timestamp is within 5s of now
                guard let timestampValue = TimeInterval(timestampString) else {
                    return fail("Could not convert the captured timestamp '\(timestampString)' to a TimeInterval.")
                }
                expect(timestampValue).to(beCloseTo(Date().timeIntervalSince1970, within: 5.0))

                /// Just for completeness we also want to ensure the end  of the data (which contains non-ASCII characters) matches
                /// the content
                let expectedNonAsciiPart: String = "6hc7V77KivGMNRmnu/acPnoF0cBJ+pVYNB2Ou0iwyQ=="
                
                guard let expectedNonAsciiPartData: Data = Data(base64Encoded: expectedNonAsciiPart) else {
                    return fail("Failed to convert expected end part to Data.")
                }
                
                expect(resultData.subdata(in: infixRange.upperBound..<suffixRange.lowerBound)).to(
                    equal(expectedNonAsciiPartData),
                    description: "The data does not end with the expected static suffix."
                )
            }
            
            // MARK: -- updates the onboarding state to 'completed'
            it("updates the onboarding state to 'completed'") {
                await expect { await manager.state.first() }.to(equal(.completed))
            }
            
            // MARK: -- updates the hasViewedSeed value only when restoring
            it("updates the hasViewedSeed value only when restoring") {
                // Check for the `register` case first
                await expect(dependencies[cache: .libSession]?.get(.hasViewedSeed)).toEventually(beFalse())
                
                /// Need to set `mockLibSessionCache` again as it would have been cleared by the first creation
                /// of the `Onboarding.Manager`
                dependencies.set(cache: .libSession, to: mockLibSessionCache)
                
                // Then the `restore` case
                manager = Onboarding.Manager(
                    flow: .restore,
                    using: dependencies
                )
                try await manager.loadInitialState()
                await manager.setDisplayName("TestCompleteName")
                try await manager.completeRegistration()
                
                await expect(dependencies[cache: .libSession]?.get(.hasViewedSeed))
                    .toEventually(beTrue())
            }
            
            // MARK: -- replicates the user metadata
            it("replicates the user metadata") {
                await mockExtensionHelper
                    .verify {
                        try $0.saveUserMetadata(
                            sessionId: SessionId(.standard, hex: TestConstants.publicKey),
                            ed25519SecretKey: Array(Data(hex: TestConstants.edSecretKey)),
                            unreadCount: 0
                        )
                    }
                    .wasCalled(exactly: 1)
            }
            
            // MARK: -- stores the desired useAPNs value in the user defaults
            it("stores the desired useAPNs value in the user defaults") {
                await mockUserDefaults
                    .verify { $0.set(false, forKey: UserDefaults.BoolKey.isUsingFullAPNs.rawValue) }
                    .wasCalled(exactly: 1)
            }
            
            // MARK: -- emits the complete status
            it("emits the complete status") {
                /// The fixture has already registered, and a second registration into a populated database is refused,
                /// so put the database back into the state a real registration starts from
                try await mockStorage.write { db in
                    _ = try Identity.deleteAll(db)
                    _ = try SessionThread.deleteAll(db)
                }
                
                /// Need to set `mockLibSessionCache` again as it would have been cleared by the first creation
                /// of the `Onboarding.Manager`
                dependencies.set(cache: .libSession, to: mockLibSessionCache)
                
                manager = Onboarding.Manager(
                    flow: .register,
                    using: dependencies
                )
                try await manager.loadInitialState()
                await expect { await manager.state.first() }.toEventuallyNot(equal(.completed))
                await manager.setDisplayName("TestCompleteName")
                try await manager.completeRegistration()
                
                await expect { await manager.state.first() }.toEventually(equal(.completed))
            }
        }
        
        // MARK: - an Onboarding Cache - Registering over an existing account
        describe("an Onboarding Cache when registering into a database which holds an account") {
            justBeforeEach {
                try await mockGeneralCache.when { $0.ed25519SecretKey }.thenReturn([])
                
                /// The `profile_updated` timestamp in `libSession` is set to now so we need to set the value to some
                /// distant future value to force the update logic to trigger
                dependencies.dateNow = Date(timeIntervalSince1970: 9876543210)
            }
            
            // MARK: -- refuses to register when the identity rows are present
            it("refuses to register when the identity rows are present") {
                let existingSecretKey: Data = Data([1, 2, 3, 4])
                try await mockStorage.write { db in
                    try Identity(variant: .ed25519SecretKey, data: existingSecretKey).insert(db)
                }
                
                manager = Onboarding.Manager(flow: .register, using: dependencies)
                try await manager.loadInitialState()
                await manager.setDisplayName("TestCompleteName")
                
                await expect { try await manager.completeRegistration() }
                    .to(throwError { error in
                        switch error {
                            case Onboarding.RegistrationError.userDataAlreadyPresent: break
                            default: fail("Expected userDataAlreadyPresent, got \(error)")
                        }
                    })
                
                /// Overwriting this row is the data loss the refusal exists to prevent, so assert on the row itself
                /// rather than only on the thrown error
                let storedSecretKey: Data? = try await mockStorage.read { db in
                    try Identity.fetchOne(db, id: .ed25519SecretKey)?.data
                }
                expect(storedSecretKey).to(equal(existingSecretKey))
                
                await mockGeneralCache
                    .verify { $0.setSecretKey(ed25519SecretKey: .any) }
                    .wasNotCalled()
            }
            
            // MARK: -- refuses to register when the identity is gone but the conversations remain
            ///
            /// The reported failure leaves everything except a readable identity, so this is the state a second
            /// registration actually finds - and an identity-only check would pass it straight through
            it("refuses to register when the identity is gone but the conversations remain") {
                manager = Onboarding.Manager(flow: .register, using: dependencies)
                try await manager.loadInitialState()
                await manager.setDisplayName("TestCompleteName")
                try await manager.completeRegistration()
                
                try await mockStorage.write { db in
                    _ = try Identity.deleteAll(db)
                }
                await expect {
                    try await mockStorage.read { db in try SessionThread.fetchCount(db) }
                }
                .to(beGreaterThan(0))
                
                /// Need to set `mockLibSessionCache` again as it would have been cleared by the first creation
                /// of the `Onboarding.Manager`
                dependencies.set(cache: .libSession, to: mockLibSessionCache)
                
                manager = Onboarding.Manager(flow: .register, using: dependencies)
                try await manager.loadInitialState()
                await manager.setDisplayName("TestCompleteName")
                
                await expect { try await manager.completeRegistration() }
                    .to(throwError { error in
                        switch error {
                            case Onboarding.RegistrationError.userDataAlreadyPresent: break
                            default: fail("Expected userDataAlreadyPresent, got \(error)")
                        }
                    })
            }
            
            // MARK: -- treats a freshly migrated database as containing no user data
            ///
            /// The refusal is only safe while a database with the migrations run and nobody registered holds no user
            /// data. If default content is ever seeded before registration - by a migration or otherwise - this fails
            /// here rather than by refusing every new registration in the field.
            ///
            /// It does not catch everything: `_027_SessionUtilChanges` skips its `thread` insert when
            /// `XCTestConfigurationFilePath` is set, so a future migration copying that pattern would seed content in
            /// the field and still pass here
            it("treats a freshly migrated database as containing no user data") {
                let containsUserData: Bool = try await mockStorage.read { db in
                    try Onboarding.databaseContainsUserData(db)
                }
                
                expect(containsUserData).to(beFalse())
            }
            
            // MARK: -- still registers into an empty database
            it("still registers into an empty database") {
                manager = Onboarding.Manager(flow: .register, using: dependencies)
                try await manager.loadInitialState()
                await manager.setDisplayName("TestCompleteName")
                
                await expect { try await manager.completeRegistration() }.toNot(throwError())
                await expect { await manager.state.first() }.toEventually(equal(.completed))
            }
            
            // MARK: -- does not refuse a restore
            ///
            /// A restore into a populated database is the user asking for exactly that; it is registration that can
            /// only get there by mistake
            it("does not refuse a restore") {
                try await mockStorage.write { db in
                    try Identity(variant: .ed25519SecretKey, data: Data([1, 2, 3, 4])).insert(db)
                }
                
                manager = Onboarding.Manager(flow: .restore, using: dependencies)
                try await manager.loadInitialState()
                await manager.setDisplayName("TestCompleteName")
                
                await expect { try await manager.completeRegistration() }.toNot(throwError())
            }
        }
        
        // MARK: - an Onboarding Cache - Complete Restoration
        describe("an Onboarding Cache when completing an account restoration") {
            @TestState var testCacheProfile: Profile!
            
            justBeforeEach {
                /// The `profile_updated` timestamp in `libSession` is set to now so we need to set the value to some
                /// distant future value to force the update logic to trigger
                dependencies.dateNow = Date(timeIntervalSince1970: 9876543210)
                
                manager = Onboarding.Manager(
                    flow: .restore,
                    using: dependencies
                )
                try await manager.loadInitialState()
                await expect { await manager.state.first() }.toEventuallyNot(equal(.completed))
                try await manager.completeRegistration()
                try await manager.setSeedData(Data(hex: TestConstants.edKeySeed).prefix(upTo: 16))
                await expect { await manager.displayName.first() }.toEventually(equal("TestPolledName"))
                try await manager.completeRegistration()
            }
            
            beforeEach {
                let cache: LibSession.Cache = LibSession.Cache(
                    userSessionId: SessionId(.standard, hex: TestConstants.publicKey),
                    using: dependencies
                )
                cache.loadDefaultStateFor(
                    variant: .userProfile,
                    sessionId: cache.userSessionId,
                    userEd25519SecretKey: Array(Data(hex: TestConstants.edSecretKey)),
                    groupEd25519SecretKey: nil
                )
                try? cache.updateProfile(
                    displayName: .set(to: "TestPolledName"),
                    displayPictureUrl: .set(to: "http://filev2.getsession.org/file/1234"),
                    displayPictureEncryptionKey: .set(to: Data([1, 2, 3])),
                    proProfileFeatures: .set(to: .none),
                    isReuploadProfilePicture: false
                )
                testCacheProfile = cache.profile
                let pendingPushes: LibSession.PendingPushes? = try? cache.pendingPushes(
                    swarmPublicKey: cache.userSessionId.hexString
                )
                
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
                    .thenReturn(MockNetwork.batchResponseData(
                        with: [
                            (
                                Network.StorageServer.Endpoint.getMessages,
                                Network.StorageServer.GetMessagesResponse(
                                    messages: (pendingPushes?
                                        .pushData
                                        .first { $0.variant == .userProfile }?
                                        .data
                                        .enumerated()
                                        .map { index, data in
                                            Network.StorageServer.GetMessagesResponse.RawMessage(
                                                base64EncodedDataString: data.base64EncodedString(),
                                                expirationMs: nil,
                                                hash: "\(index)",
                                                timestampMs: 1234567890
                                            )
                                        } ?? []),
                                    more: false,
                                    hardForkVersion: [2, 2],
                                    timeOffset: 0
                                    
                                ).batchSubResponse()
                            )
                        ]
                    ))
            }
            
            // MARK: -- starts a download job if there was a display picture
            it("starts a download job if there was a display picture") {
                /// Since the `timestamp` is stored in `details` which gets encoded into raw data we can't mock it
                await mockJobRunner
                    .verify {
                        $0.add(
                            .any,
                            job: Job(
                                variant: .displayPictureDownload,
                                threadId: nil,
                                interactionId: nil,
                                uniqueKey: DisplayPictureDownloadJob.generateUniqueKey(
                                    id: "05\(TestConstants.publicKey)",
                                    url: "http://filev2.getsession.org/file/1234"
                                ),
                                details: DisplayPictureDownloadJob.Details(
                                    target: .profile(
                                        id: "05\(TestConstants.publicKey)",
                                        url: "http://filev2.getsession.org/file/1234",
                                        encryptionKey: Data([
                                            1, 2, 3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                                            0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
                                        ])
                                    ),
                                    timestamp: testCacheProfile.profileLastUpdated
                                )
                            ),
                            initialDependencies: []
                        )
                    }
                    .wasCalled(exactly: 1, timeout: .milliseconds(100))
            }
        }
        
        // MARK: - Recovery diagnostics
        describe("Onboarding when gathering recovery diagnostics") {
            @TestState var mockFileManager: MockFileManager! = .create(using: dependencies)
            
            let testMetadata: ExtensionHelper.UserMetadata = ExtensionHelper.UserMetadata(
                sessionId: SessionId(.standard, hex: TestConstants.publicKey),
                ed25519SecretKey: Array(Data(hex: TestConstants.edSecretKey)),
                unreadCount: 0
            )
            
            beforeEach {
                /// Recreate the state these diagnostics exist for: an account whose identity rows are gone while its
                /// conversations and config remain
                try await mockGeneralCache.when { $0.ed25519SecretKey }.thenReturn([])
                manager = Onboarding.Manager(flow: .register, using: dependencies)
                try await manager.loadInitialState()
                await manager.setDisplayName("TestCompleteName")
                try await manager.completeRegistration()
                try await mockStorage.write { db in
                    _ = try Identity.deleteAll(db)
                }
                
                dependencies.set(singleton: .fileManager, to: mockFileManager)
                try await mockFileManager.defaultInitialSetup()
                try await mockFileManager.when { $0.fileExists(atPath: .any) }.thenReturn(true)
                try await mockFileManager
                    .when {
                        $0.enumerator(
                            at: .any,
                            includingPropertiesForKeys: .any,
                            options: [],
                            errorHandler: nil
                        )
                    }
                    .thenReturn(nil)
                try await mockExtensionHelper.when { $0.userMetadataExists() }.thenReturn(true)
                try await mockExtensionHelper.when { $0.loadUserMetadata() }.thenReturn(testMetadata)
            }
            
            // MARK: -- reports a key which belongs to the data on disk
            it("reports a key which belongs to the data on disk") {
                let diagnostics: String? = await Onboarding.recoveryDiagnostics(using: dependencies)
                
                expect(diagnostics).to(contain("database: 1024 bytes, wal: 1024 bytes"))
                expect(diagnostics).to(contain("identity rows: 0"))
                expect(diagnostics).to(contain("threads: 1"))
                expect(diagnostics).to(contain("accounts in user config dumps: 1"))
                expect(diagnostics).to(contain("extension metadata exists: yes"))
                expect(diagnostics).to(contain("decrypts: yes"))
                expect(diagnostics).to(contain("has key: yes"))
                expect(diagnostics).to(contain("key matches metadata Session ID: yes"))
                expect(diagnostics).to(contain("key matches user config dumps: yes"))
                expect(diagnostics).to(contain("key has Note to Self: yes"))
            }
            
            // MARK: -- reports a key which belongs to another account
            it("reports a key which belongs to another account") {
                try await mockCrypto
                    .when { $0.generate(.x25519(ed25519Pubkey: .any)) }
                    .thenReturn(Array(Array(Data(hex: TestConstants.publicKey)).reversed()))
                
                let diagnostics: String? = await Onboarding.recoveryDiagnostics(using: dependencies)
                
                expect(diagnostics).to(contain("has key: yes"))
                expect(diagnostics).to(contain("key matches metadata Session ID: no"))
                expect(diagnostics).to(contain("key matches user config dumps: no"))
                expect(diagnostics).to(contain("key has Note to Self: no"))
            }
            
            // MARK: -- reports a key which has already been lost
            ///
            /// Before the badge update stopped writing without a user, the first launch without an identity replaced the
            /// key with an empty one - which is what an affected user's log shows
            it("reports a key which has already been lost") {
                try await mockExtensionHelper
                    .when { $0.loadUserMetadata() }
                    .thenReturn(ExtensionHelper.UserMetadata(sessionId: .invalid, ed25519SecretKey: [], unreadCount: 0))
                
                let diagnostics: String? = await Onboarding.recoveryDiagnostics(using: dependencies)
                
                expect(diagnostics).to(contain("decrypts: yes"))
                expect(diagnostics).to(contain("has key: no"))
                expect(diagnostics).to(contain("key matches metadata Session ID: n/a"))
                expect(diagnostics).to(contain("key matches user config dumps: n/a"))
            }
            
            // MARK: -- reports metadata which cannot be read
            it("reports metadata which cannot be read") {
                try await mockExtensionHelper.when { $0.loadUserMetadata() }.thenReturn(nil)
                
                let diagnostics: String? = await Onboarding.recoveryDiagnostics(using: dependencies)
                
                expect(diagnostics).to(contain("extension metadata exists: yes"))
                expect(diagnostics).to(contain("decrypts: no"))
                expect(diagnostics).to(contain("has key: n/a"))
            }
            
            // MARK: -- reports missing metadata
            it("reports missing metadata") {
                try await mockExtensionHelper.when { $0.userMetadataExists() }.thenReturn(false)
                
                let diagnostics: String? = await Onboarding.recoveryDiagnostics(using: dependencies)
                
                expect(diagnostics).to(contain("extension metadata exists: no"))
                expect(diagnostics).to(contain("decrypts: n/a"))
                await mockExtensionHelper.verify { $0.loadUserMetadata() }.wasNotCalled()
            }
            
            // MARK: -- contains no key material or Session IDs
            it("contains no key material or Session IDs") {
                let diagnostics: String? = await Onboarding.recoveryDiagnostics(using: dependencies)
                
                expect(diagnostics).toNot(beNil())
                [TestConstants.publicKey, TestConstants.edPublicKey, TestConstants.edSecretKey].forEach { value in
                    expect(diagnostics).toNot(contain(String(value.prefix(8))))
                    expect(diagnostics).toNot(contain(String(value.suffix(8))))
                }
            }
            
            // MARK: -- does nothing without a database file
            it("does nothing without a database file") {
                try await mockFileManager.when { $0.fileExists(atPath: .any) }.thenReturn(false)
                
                let diagnostics: String? = await Onboarding.recoveryDiagnostics(using: dependencies)
                
                expect(diagnostics).to(beNil())
            }
            
            // MARK: -- are only gathered by the manager created at launch
            ///
            /// The flows started from the landing screen run the same path, so without the gate they would repeat the line on
            /// every tap. The launch manager runs last so its call proves the detached work had time to happen at all
            it("are only gathered by the manager created at launch") {
                manager = Onboarding.Manager(flow: .restore, using: dependencies)
                try await manager.loadInitialState()
                manager = Onboarding.Manager(flow: .register, using: dependencies)
                try await manager.loadInitialState()
                manager = Onboarding.Manager(flow: .none, using: dependencies)
                try await manager.loadInitialState()
                
                await mockExtensionHelper
                    .verify { $0.userMetadataExists() }
                    .wasCalled(atLeast: 1, timeout: .milliseconds(500))
                try await Task.sleep(nanoseconds: 100_000_000)
                await mockExtensionHelper
                    .verify { $0.userMetadataExists() }
                    .wasCalled(exactly: 1)
            }
        }
        
        // MARK: - Unread badge update
        describe("the unread badge update") {
            // MARK: -- with no user
            context("with no user") {
                beforeEach {
                    try await mockGeneralCache.when { $0.userExists }.thenReturn(false)
                    try await mockGeneralCache.when { $0.sessionId }.thenReturn(.invalid)
                    try await mockGeneralCache.when { $0.ed25519SecretKey }.thenReturn([])
                }
                
                // MARK: ---- does not replace the key held for the extensions
                ///
                /// This runs on every activation, including while onboarding is showing - which is when the extensions' copy
                /// is the only key left to recover a lost account with
                it("does not replace the key held for the extensions") {
                    await AppDelegate.updateUnreadBadgeCount(using: dependencies)
                    
                    await mockExtensionHelper
                        .verify {
                            try $0.saveUserMetadata(sessionId: .any, ed25519SecretKey: .any, unreadCount: .any)
                        }
                        .wasNotCalled()
                }
            }
            
            // MARK: -- with a user
            context("with a user") {
                // MARK: ---- saves the user metadata for the extensions
                it("saves the user metadata for the extensions") {
                    await AppDelegate.updateUnreadBadgeCount(using: dependencies)
                    
                    await mockExtensionHelper
                        .verify {
                            try $0.saveUserMetadata(
                                sessionId: SessionId(.standard, hex: TestConstants.publicKey),
                                ed25519SecretKey: Array(Data(hex: TestConstants.edSecretKey)),
                                unreadCount: 0
                            )
                        }
                        .wasCalled(exactly: 1)
                }
            }
        }
        
        // MARK: - an Onboarding Cache - Failing to store the identity
        describe("an Onboarding Cache when storing the identity fails") {
            // MARK: -- during a restore
            context("during a restore") {
                beforeEach {
                    try await mockGeneralCache.when { $0.ed25519SecretKey }.thenReturn([])
                    manager = Onboarding.Manager(flow: .restore, using: dependencies)
                    try await manager.loadInitialState()
                    await manager.setDisplayName("TestCompleteName")
                    
                    /// The likeliest real cause: the app is backgrounded while the restore is finishing
                    await mockStorage.suspendDatabaseAccess()
                }
                
                // MARK: ---- throws instead of completing
                ///
                /// Completing would run the session on an account which exists only in memory, and everything written
                /// afterwards would sit in the database with no identity for the next launch to find
                it("throws instead of completing") {
                    await expect { try await manager.completeRegistration() }
                        .to(throwError { error in
                            switch error {
                                case StorageError.databaseSuspended: break
                                default: fail("Expected databaseSuspended, got \(error)")
                            }
                        })
                    await expect { await manager.state.first() }.toNot(equal(.completed))
                }
                
                // MARK: ---- clears the account from memory
                it("clears the account from memory") {
                    _ = try? await manager.completeRegistration()
                    
                    await mockGeneralCache
                        .verify { $0.setSecretKey(ed25519SecretKey: []) }
                        .wasCalled(exactly: 1)
                }
                
                // MARK: ---- does not save the key for the extensions
                it("does not save the key for the extensions") {
                    _ = try? await manager.completeRegistration()
                    
                    await mockExtensionHelper
                        .verify {
                            try $0.saveUserMetadata(sessionId: .any, ed25519SecretKey: .any, unreadCount: .any)
                        }
                        .wasNotCalled()
                }
            }
            
            // MARK: -- for an account which is already loaded
            context("for an account which is already loaded") {
                // MARK: ---- still completes
                ///
                /// These flows reuse the identity already in memory, so clearing it on failure would take that account away
                it("still completes") {
                    manager = Onboarding.Manager(flow: .none, using: dependencies)
                    try await manager.loadInitialState()
                    await mockStorage.suspendDatabaseAccess()
                    
                    await expect { try await manager.completeRegistration() }.toNot(throwError())
                    await expect { await manager.state.first() }.toEventually(equal(.completed))
                    await mockGeneralCache
                        .verify { $0.setSecretKey(ed25519SecretKey: []) }
                        .wasNotCalled()
                }
            }
        }
        
        // MARK: - Automatic identity recovery
        describe("automatic identity recovery") {
            @TestState var mockAppContext: MockAppContext! = .create(using: dependencies)
            
            let testMetadata: ExtensionHelper.UserMetadata = ExtensionHelper.UserMetadata(
                sessionId: SessionId(.standard, hex: TestConstants.publicKey),
                ed25519SecretKey: Array(Data(hex: TestConstants.edSecretKey)),
                unreadCount: 0
            )
            
            // MARK: -- decides
            context("decides") {
                // MARK: ---- to recover only when every check passes
                it("to recover only when every check passes") {
                    let keySessionId: SessionId = SessionId(.standard, hex: TestConstants.publicKey)
                    let otherSessionId: SessionId = SessionId(.standard, hex: String(TestConstants.publicKey.reversed()))
                    let dumpCases: [Set<String>] = [
                        [],
                        [keySessionId.hexString],
                        [otherSessionId.hexString],
                        [keySessionId.hexString, otherSessionId.hexString]
                    ]
                    
                    for identityRowCount in [0, 1, 4] {
                        for metadataSessionId in [keySessionId, otherSessionId, .invalid] {
                            for userConfigSessionIds in dumpCases {
                                let expected: Bool = (
                                    identityRowCount == 0 &&
                                    metadataSessionId == keySessionId &&
                                    userConfigSessionIds == [keySessionId.hexString]
                                )
                                
                                expect(
                                    AppSetup.canRecoverIdentity(
                                        identityRowCount: identityRowCount,
                                        metadataSessionId: metadataSessionId,
                                        keySessionId: keySessionId,
                                        userConfigSessionIds: userConfigSessionIds
                                    )
                                ).to(
                                    equal(expected),
                                    description: "rows: \(identityRowCount), metadata matches: \(metadataSessionId == keySessionId), dumps: \(userConfigSessionIds.count)"
                                )
                            }
                        }
                    }
                }
            }
            
            // MARK: -- for a database which lost its identity
            context("for a database which lost its identity") {
                beforeEach {
                    /// Recreate the state recovery exists for: an account whose identity rows are gone while its
                    /// conversations and config remain
                    try await mockGeneralCache.when { $0.ed25519SecretKey }.thenReturn([])
                    manager = Onboarding.Manager(flow: .register, using: dependencies)
                    try await manager.loadInitialState()
                    await manager.setDisplayName("TestCompleteName")
                    try await manager.completeRegistration()
                    try await mockStorage.write { db in
                        _ = try Identity.deleteAll(db)
                    }
                    
                    dependencies.set(singleton: .appContext, to: mockAppContext)
                    try await mockAppContext.when { $0.isMainApp }.thenReturn(true)
                    try await mockExtensionHelper.when { $0.userMetadataExists() }.thenReturn(true)
                    try await mockExtensionHelper.when { $0.loadUserMetadata() }.thenReturn(testMetadata)
                }
                
                // MARK: ---- restores the identity from the extension metadata
                it("restores the identity from the extension metadata") {
                    let didRecover: Bool = await AppSetup.recoverIdentityIfPossible(using: dependencies)
                    let keyPair: KeyPair? = try await mockStorage.read { db in
                        try Identity.fetchUserEd25519KeyPair(db)
                    }
                    
                    expect(didRecover).to(beTrue())
                    expect(keyPair?.secretKey).to(equal(Array(Data(hex: TestConstants.edSecretKey))))
                    expect(keyPair?.publicKey).to(equal(Array(Data(hex: TestConstants.edPublicKey))))
                    await expect {
                        try await mockStorage.read { db in try Identity.fetchCount(db) }
                    }.to(equal(4))
                }
                
                // MARK: ---- does nothing in an extension
                it("does nothing in an extension") {
                    try await mockAppContext.when { $0.isMainApp }.thenReturn(false)
                    
                    let didRecover: Bool = await AppSetup.recoverIdentityIfPossible(using: dependencies)
                    
                    expect(didRecover).to(beFalse())
                    await mockExtensionHelper.verify { $0.loadUserMetadata() }.wasNotCalled()
                }
                
                // MARK: ---- does nothing when any identity row remains
                it("does nothing when any identity row remains") {
                    let existingPublicKey: Data = Data([1, 2, 3, 4])
                    try await mockStorage.write { db in
                        try Identity(variant: .x25519PublicKey, data: existingPublicKey).insert(db)
                    }
                    
                    let didRecover: Bool = await AppSetup.recoverIdentityIfPossible(using: dependencies)
                    let storedRows: [Identity] = try await mockStorage.read { db in try Identity.fetchAll(db) }
                    
                    expect(didRecover).to(beFalse())
                    expect(storedRows.map(\.data)).to(equal([existingPublicKey]))
                }
                
                // MARK: ---- does nothing when the key belongs to another account
                it("does nothing when the key belongs to another account") {
                    try await mockCrypto
                        .when { $0.generate(.x25519(ed25519Pubkey: .any)) }
                        .thenReturn(Array(Array(Data(hex: TestConstants.publicKey)).reversed()))
                    try await mockExtensionHelper
                        .when { $0.loadUserMetadata() }
                        .thenReturn(
                            ExtensionHelper.UserMetadata(
                                sessionId: SessionId(.standard, publicKey: Array(Array(Data(hex: TestConstants.publicKey)).reversed())),
                                ed25519SecretKey: Array(Data(hex: TestConstants.edSecretKey)),
                                unreadCount: 0
                            )
                        )
                    
                    let didRecover: Bool = await AppSetup.recoverIdentityIfPossible(using: dependencies)
                    
                    expect(didRecover).to(beFalse())
                    await expect {
                        try await mockStorage.read { db in try Identity.fetchCount(db) }
                    }.to(equal(0))
                }
                
                // MARK: ---- does nothing when the metadata's key was already lost
                it("does nothing when the metadata's key was already lost") {
                    try await mockExtensionHelper
                        .when { $0.loadUserMetadata() }
                        .thenReturn(ExtensionHelper.UserMetadata(sessionId: .invalid, ed25519SecretKey: [], unreadCount: 0))
                    
                    let didRecover: Bool = await AppSetup.recoverIdentityIfPossible(using: dependencies)
                    
                    expect(didRecover).to(beFalse())
                }
                
                // MARK: ---- does not read the metadata when there is no file
                it("does not read the metadata when there is no file") {
                    try await mockExtensionHelper.when { $0.userMetadataExists() }.thenReturn(false)
                    
                    let didRecover: Bool = await AppSetup.recoverIdentityIfPossible(using: dependencies)
                    
                    expect(didRecover).to(beFalse())
                    await mockExtensionHelper.verify { $0.loadUserMetadata() }.wasNotCalled()
                }
                
                // MARK: ---- returns rather than throwing when the write fails
                it("returns rather than throwing when the write fails") {
                    await mockStorage.suspendDatabaseAccess()
                    
                    let didRecover: Bool = await AppSetup.recoverIdentityIfPossible(using: dependencies)
                    
                    expect(didRecover).to(beFalse())
                }
            }
            
            // MARK: -- for a database with no account data
            context("for a database with no account data") {
                // MARK: ---- does nothing
                ///
                /// What "Clear Device and Restore" used to leave behind: a recreated database, but the extension's copy of the key
                it("does nothing") {
                    dependencies.set(singleton: .appContext, to: mockAppContext)
                    try await mockAppContext.when { $0.isMainApp }.thenReturn(true)
                    try await mockExtensionHelper.when { $0.userMetadataExists() }.thenReturn(true)
                    try await mockExtensionHelper.when { $0.loadUserMetadata() }.thenReturn(testMetadata)
                    
                    let didRecover: Bool = await AppSetup.recoverIdentityIfPossible(using: dependencies)
                    
                    expect(didRecover).to(beFalse())
                    await expect {
                        try await mockStorage.read { db in try Identity.fetchCount(db) }
                    }.to(equal(0))
                }
            }
        }
    }
}
