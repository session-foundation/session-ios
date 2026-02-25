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
        @TestState var mockStorage: Storage! = SynchronousStorage(
            customWriter: try! DatabaseQueue(),
            using: dependencies
        )
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
                                    proExpiryUnixTimestampMs: 0,
                                    proGenIndexHashHex: nil
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
                
                await manager.completeRegistration()
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
                    try await mockStorage.readAsync { db in
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
                    try await mockStorage.readAsync { db in
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
                await expect {
                    try await mockStorage.readAsync { db in
                        try Profile.fetchAll(db)
                    }
                }.toEventually(
                    equal([
                        Profile(
                            id: "0588672ccb97f40bb57238989226cf429b575ba355443f47bc76c5ab144a96c65b",
                            name: "TestCompleteName",
                            nickname: nil,
                            displayPictureUrl: nil,
                            displayPictureEncryptionKey: nil,
                            profileLastUpdated: 9876543210,
                            blocksCommunityMessageRequests: nil,
                            proFeatures: .none,
                            proExpiryUnixTimestampMs: 0,
                            proGenIndexHashHex: nil
                        )
                    ]),
                    timeout: .milliseconds(100)
                )
            }
            
            // MARK: -- creates a thread for Note to Self
            it("creates a thread for Note to Self") {
                await expect {
                    try await mockStorage.readAsync { db in
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
                        proExpiryUnixTimestampMs: 0,
                        proGenIndexHashHex: nil
                    )
                ))
            }
            
            // MARK: -- saves a config dump to the database
            it("saves a config dump to the database") {
                let result: [ConfigDump] = try await require {
                    try await mockStorage.readAsync { db in
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
                await manager.completeRegistration()
                
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
                await manager.completeRegistration()
                
                await expect { await manager.state.first() }.toEventually(equal(.completed))
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
                await manager.completeRegistration()
                try await manager.setSeedData(Data(hex: TestConstants.edKeySeed).prefix(upTo: 16))
                await expect { await manager.displayName.first() }.toEventually(equal("TestPolledName"))
                await manager.completeRegistration()
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
    }
}
