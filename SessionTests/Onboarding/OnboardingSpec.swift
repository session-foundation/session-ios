// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

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
        @TestState(singleton: .storage, in: dependencies) var mockStorage: Storage! = SynchronousStorage(
            customWriter: try! DatabaseQueue(),
            using: dependencies
        )
        @TestState(singleton: .crypto, in: dependencies) var mockCrypto: MockCrypto! = .create()
        @TestState var mockGeneralCache: MockGeneralCache! = MockGeneralCache()
        @TestState var mockLibSession: MockLibSessionCache! = MockLibSessionCache()
        @TestState(defaults: .standard, in: dependencies) var mockUserDefaults: MockUserDefaults! = MockUserDefaults(
            initialSetup: { defaults in
                defaults.when { $0.bool(forKey: UserDefaults.BoolKey.isMainAppActive.rawValue) }.thenReturn(true)
                defaults.when { $0.bool(forKey: UserDefaults.BoolKey.isUsingFullAPNs.rawValue) }.thenReturn(false)
                defaults.when { $0.integer(forKey: .any) }.thenReturn(2)
                defaults.when { $0.set(true, forKey: .any) }.thenReturn(())
                defaults.when { $0.set(false, forKey: .any) }.thenReturn(())
            }
        )
        @TestState(singleton: .network, in: dependencies) var mockNetwork: MockNetwork! = MockNetwork(
            initialSetup: { network in
                network.when { try await $0.getSwarm(for: .any) }.thenReturn([
                    LibSession.Snode(
                        ed25519PubkeyHex: "1234",
                        ip: "1.2.3.4",
                        httpsPort: 1233,
                        quicPort: 1234,
                        version: "2.11.0",
                        swarmId: 1
                    )
                ])
                
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
                let pendingPushes: LibSession.PendingPushes? = try? cache.pendingPushes(
                    swarmPublicKey: cache.userSessionId.hexString
                )
                
                network
                    .when {
                        $0.send(
                            endpoint: MockEndpoint.mock,
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
                                SnodeAPI.Endpoint.getMessages,
                                GetMessagesResponse(
                                    messages: (pendingPushes?
                                        .pushData
                                        .first { $0.variant == .userProfile }?
                                        .data
                                        .enumerated()
                                        .map { index, data in
                                            GetMessagesResponse.RawMessage(
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
        )
        @TestState(singleton: .extensionHelper, in: dependencies) var mockExtensionHelper: MockExtensionHelper! = MockExtensionHelper(
            initialSetup: { helper in
                helper
                    .when { $0.replicate(dump: .any, replaceExisting: .any) }
                    .thenReturn(())
                helper
                    .when {
                        try $0.saveUserMetadata(
                            sessionId: .any,
                            ed25519SecretKey: .any,
                            unreadCount: .any
                        )
                    }
                    .thenReturn(())
            }
        )
        @TestState var mockSnodeAPICache: MockSnodeAPICache! = MockSnodeAPICache()
        @TestState var disposables: [AnyCancellable]! = []
        @TestState var manager: Onboarding.Manager!
        
        beforeEach {
            /// The compiler kept crashing when doing this via `@TestState` so need to do it here instead
            mockGeneralCache.defaultInitialSetup()
            dependencies.set(cache: .general, to: mockGeneralCache)
            
            mockLibSession.defaultInitialSetup()
            mockLibSession
                .when {
                    $0.profile(
                        contactId: .any,
                        threadId: .any,
                        threadVariant: .any,
                        visibleMessage: .any
                    )
                }
                .thenReturn(nil)
            dependencies.set(cache: .libSession, to: mockLibSession)
            
            mockSnodeAPICache.defaultInitialSetup()
            dependencies.set(cache: .snodeAPI, to: mockSnodeAPICache)
            
            try await mockStorage.perform(migrations: SNMessagingKit.migrations)
            
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
                .when { $0.generate(.ed25519Seed(ed25519SecretKey: .any)) }
                .thenReturn(Data([
                    1, 2, 3, 4, 5, 6, 7, 8, 9, 0,
                    1, 2, 3, 4, 5, 6, 7, 8, 9, 0,
                    1, 2, 3, 4, 5, 6, 7, 8, 9, 0,
                    1, 2
                ]))
            try await mockCrypto
                .when { $0.generate(.ed25519KeyPair(seed: .any)) }
                .thenReturn(
                    KeyPair(
                        publicKey: Array(Data(hex: TestConstants.edPublicKey)),
                        secretKey: Array(Data(hex: TestConstants.edSecretKey))
                    )
                )
            try await mockCrypto
                .when { $0.generate(.signature(message: .any, ed25519SecretKey: .any)) }
                .thenReturn(Authentication.Signature.standard(signature: "TestSignature".bytes))
        }
        
        // MARK: - an Onboarding Cache - Initialization
        describe("an Onboarding Cache when initialising") {
            beforeEach {
                mockLibSession
                    .when { $0.profile(contactId: .any, threadId: .any, threadVariant: .any, visibleMessage: .any) }
                    .thenReturn(nil)
            }
            
            justBeforeEach {
                manager = Onboarding.Manager(
                    flow: .restore,
                    using: dependencies
                )
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
                    mockGeneralCache.when { $0.ed25519SecretKey }.thenReturn([])
                    try await mockCrypto
                        .when { $0.generate(.ed25519KeyPair(seed: .any)) }
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
                    await expect { await manager.ed25519KeyPair.publicKey.toHexString() }.to(equal("010203"))
                    await expect { await manager.ed25519KeyPair.secretKey.toHexString() }.to(equal("040506"))
                    await expect { await manager.x25519KeyPair.publicKey.toHexString() }.to(equal("030201"))
                    await expect { await manager.x25519KeyPair.secretKey.toHexString() }.to(equal("060504"))
                    await expect { await manager.userSessionId }.to(equal(SessionId(.standard, hex: "030201")))
                }
            }
            
            // MARK: -- with a stored secret key
            context("with a stored secret key") {
                beforeEach {
                    mockGeneralCache
                        .when { $0.ed25519SecretKey }
                        .thenReturn(Array(Data(hex: TestConstants.edSecretKey)))
                    try await mockCrypto
                        .when { $0.generate(.ed25519KeyPair(seed: .any)) }
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
                        await mockCrypto.removeMocksFor { $0.generate(.ed25519KeyPair(seed: .any)) }
                        await mockCrypto.removeMocksFor { $0.generate(.ed25519Seed(ed25519SecretKey: .any)) }
                        try await mockCrypto
                            .when { try $0.tryGenerate(.ed25519Seed(ed25519SecretKey: .any)) }
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
                                $0.generate(.ed25519KeyPair(
                                    seed: [1, 2, 3, 4, 5, 6, 7, 8, 1, 2, 3, 4, 5, 6, 7, 8]
                                )) }
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
                        try await mockCrypto.when { $0.generate(.randomBytes(.any)) }.thenReturn(nil as Data?)
                        manager = Onboarding.Manager(
                            flow: .restore,
                            using: dependencies
                        )
                        await expect{ await manager.state.first() }.to(equal(.noUserInvalidSeedGeneration))
                    }
                    
                    // MARK: ------ does not load the useAPNs flag from user defaults
                    it("does not load the useAPNs flag from user defaults") {
                        expect(mockUserDefaults).toNot(call { $0.bool(forKey: .any) })
                    }
                }
                
                // MARK: ---- and an existing display name
                context("and an existing display name") {
                    beforeEach {
                        mockUserDefaults
                            .when { $0.bool(forKey: UserDefaults.BoolKey.isUsingFullAPNs.rawValue) }
                            .thenReturn(true)
                        mockLibSession
                            .when {
                                $0.profile(
                                    contactId: .any,
                                    threadId: .any,
                                    threadVariant: .any,
                                    visibleMessage: .any
                                )
                            }
                            .thenReturn(Profile(id: "TestProfileId", name: "TestProfileName"))
                    }
                    
                    // MARK: ------ loads from libSession
                    it("loads from libSession") {
                        expect(mockLibSession).to(call(.exactly(times: 1), matchingParameters: .all) {
                            $0.profile(
                                contactId: "05\(TestConstants.publicKey)",
                                threadId: nil,
                                threadVariant: nil,
                                visibleMessage: nil
                            )
                        })
                    }
                    
                    // MARK: ------ stores the loaded displayName
                    it("stores the loaded displayName") {
                        await expect{ await manager.displayName.first() }.to(equal("TestProfileName"))
                    }
                    
                    // MARK: ------ loads the useAPNs setting from user defaults
                    it("loads the useAPNs setting from user defaults") {
                        expect(mockUserDefaults).to(call { $0.bool(forKey: .any) })
                        await expect{ await manager.useAPNS }.to(beTrue())
                    }
                    
                    // MARK: ------ after generating new credentials
                    context("after generating new credentials") {
                        beforeEach {
                            await mockCrypto.removeMocksFor { $0.generate(.ed25519KeyPair(seed: .any)) }
                            await mockCrypto.removeMocksFor { $0.generate(.ed25519Seed(ed25519SecretKey: .any)) }
                            try await mockCrypto
                                .when { try $0.tryGenerate(.ed25519Seed(ed25519SecretKey: .any)) }
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
                                    $0.generate(.ed25519KeyPair(
                                        seed: [1, 2, 3, 4, 5, 6, 7, 8, 1, 2, 3, 4, 5, 6, 7, 8]
                                    )) }
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
                        
                        // MARK: -------- has an empty display name
                        it("has an empty display name") {
                            await expect { await manager.displayName.first() }.to(equal(""))
                        }
                    }
                }
                
                // MARK: ---- and a missing display name
                context("and a missing display name") {
                    beforeEach {
                        mockUserDefaults
                            .when { $0.bool(forKey: UserDefaults.BoolKey.isUsingFullAPNs.rawValue) }
                            .thenReturn(true)
                    }
                    
                    // MARK: ------ has an empty display name
                    it("has an empty display name") {
                        await expect { await manager.displayName.first() }.to(equal(""))
                    }
                    
                    // MARK: ------ loads the useAPNs setting from user defaults
                    it("loads the useAPNs setting from user defaults") {
                        expect(mockUserDefaults).to(call { $0.bool(forKey: .any) })
                        await expect { await manager.useAPNS }.to(beTrue())
                    }
                }
            }
        }
        
        // MARK: - an Onboarding Cache - Seed Data
        describe("an Onboarding Cache when setting seed data") {
            beforeEach {
                try await mockCrypto
                    .when { $0.generate(.ed25519KeyPair(seed: .any)) }
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
                try? await manager.setSeedData(Data(hex: TestConstants.edKeySeed).prefix(upTo: 16))
            }
            
            // MARK: -- throws if the seed is the wrong length
            it("throws if the seed is the wrong length") {
                expect { try await manager.setSeedData(Data([1, 2, 3])) }
                    .to(throwError(CryptoError.invalidSeed))
            }
            
            // MARK: -- stores the seed
            it("stores the seed") {
                await expect { await manager.seed }.to(equal(Data(hex: TestConstants.edKeySeed).prefix(upTo: 16)))
            }
            
            // MARK: -- stores the generated identity
            it("stores the generated identity") {
                await expect { await manager.ed25519KeyPair.publicKey.toHexString() }
                    .to(equal(TestConstants.edPublicKey))
                await expect { await manager.ed25519KeyPair.secretKey.toHexString() }
                    .to(equal(TestConstants.edSecretKey))
                await expect { await manager.x25519KeyPair.publicKey.toHexString() }
                    .to(equal(TestConstants.publicKey))
                await expect { await manager.x25519KeyPair.secretKey.toHexString() }
                    .to(equal(TestConstants.privateKey))
                await expect { await manager.userSessionId }
                    .to(equal(SessionId(.standard, hex: TestConstants.publicKey)))
            }
            
            // MARK: -- polls for the userProfile config
            it("polls for the userProfile config") {
                let base64EncodedDataString: String = "eyJtZXRob2QiOiJiYXRjaCIsInBhcmFtcyI6eyJyZXF1ZXN0cyI6W3sibWV0aG9kIjoicmV0cmlldmUiLCJwYXJhbXMiOnsibGFzdF9oYXNoIjoiIiwibWF4X3NpemUiOi0xLCJuYW1lc3BhY2UiOjIsInB1YmtleSI6IjA1ODg2NzJjY2I5N2Y0MGJiNTcyMzg5ODkyMjZjZjQyOWI1NzViYTM1NTQ0M2Y0N2JjNzZjNWFiMTQ0YTk2YzY1YiIsInB1YmtleV9lZDI1NTE5IjoiYmFjNmU3MWVmZDdkZmE0YTgzYzk4ZWQyNGYyNTRhYjJjMjY3ZjljY2RiMTcyYTUyODBhMDQ0NGFkMjRlODljYyIsInNpZ25hdHVyZSI6IlZHVnpkRk5wWjI1aGRIVnlaUT09IiwidGltZXN0YW1wIjoxMjM0NTY3ODkwMDAwfX1dfX0="
                
                await expect(mockNetwork)
                    .toEventually(call(.exactly(times: 1), matchingParameters: .atLeast(3)) {
                        $0.send(
                            endpoint: MockEndpoint.mock,
                            destination: Network.Destination.snode(
                                LibSession.Snode(
                                    ed25519PubkeyHex: "",
                                    ip: "1.2.3.4",
                                    httpsPort: 1233,
                                    quicPort: 1234,
                                    version: "2.11.0",
                                    swarmId: 1
                                ),
                                swarmPublicKey: "0588672ccb97f40bb57238989226cf429b575ba355443f47bc76c5ab144a96c65b"
                            ),
                            body: Data(base64Encoded: base64EncodedDataString),
                            category: .standard,
                            requestTimeout: 10,
                            overallTimeout: nil
                        )
                    })
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
            }
            
            // MARK: -- stores the useAPNs setting
            it("stores the useAPNs setting") {
                await expect { await manager.useAPNS }.to(beFalse())
                await manager.setUseAPNS(true)
                await expect { await manager.useAPNS }.to(beTrue())
            }
            
            // MARK: -- stores the display name
            it("stores the display name") {
                await expect { await manager.displayName.first() }.to(equal(""))
                await manager.setDisplayName("TestName")
                await expect { await manager.displayName.first() }.to(equal("TestName"))
            }
        }
        
        // MARK: - an Onboarding Cache - Complete Registration
        describe("an Onboarding Cache when completing registration") {
            justBeforeEach {
                manager = Onboarding.Manager(
                    flow: .register,
                    using: dependencies
                )
                await manager.setDisplayName("TestCompleteName")
                await manager.completeRegistration()
            }
            
            // MARK: -- stores the ed25519 secret key in the general cache
            it("stores the ed25519 secret key in the general cache") {
                expect(mockGeneralCache).to(call(.exactly(times: 1), matchingParameters: .all) {
                    $0.setSecretKey(ed25519SecretKey: Array(Data(hex: TestConstants.edSecretKey)))
                })
            }
            
            // MARK: -- stores a new libSession cache instance
            it("stores a new libSession cache instance") {
                expect(dependencies[cache: .libSession]).toNot(beAKindOf(MockLibSessionCache.self))
            }
            
            // MARK: -- saves the identity data to the database
            it("saves the identity data to the database") {
                let result: [Identity]? = mockStorage.read { db in
                    try Identity.fetchAll(db)
                }
                
                expect(result).to(equal([
                    Identity(variant: .ed25519SecretKey, data: Data(hex: TestConstants.edSecretKey)),
                    Identity(variant: .ed25519PublicKey, data: Data(hex: TestConstants.edPublicKey)),
                    Identity(variant: .x25519PrivateKey, data: Data(hex: TestConstants.privateKey)),
                    Identity(variant: .x25519PublicKey, data: Data(hex: TestConstants.publicKey))
                ]))
            }
            
            // MARK: -- creates a contact record for the current user
            it("creates a contact record for the current user") {
                let result: [Contact]? = mockStorage.read { db in
                    try Contact.fetchAll(db)
                }

                expect(result).to(equal([
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
                let result: [Profile]? = mockStorage.read { db in
                    try Profile.fetchAll(db)
                }
                
                expect(result).to(equal([
                    Profile(
                        id: "0588672ccb97f40bb57238989226cf429b575ba355443f47bc76c5ab144a96c65b",
                        name: "TestCompleteName",
                        lastNameUpdate: 1234567890,
                        nickname: nil,
                        displayPictureUrl: nil,
                        displayPictureEncryptionKey: nil,
                        displayPictureLastUpdated: nil,
                        blocksCommunityMessageRequests: nil,
                        lastBlocksCommunityMessageRequests: nil
                    )
                ]))
            }
            
            // MARK: -- creates a thread for Note to Self
            it("creates a thread for Note to Self") {
                let result: [SessionThread]? = mockStorage.read { db in
                    try SessionThread.fetchAll(db)
                }
                
                expect(result).to(equal([
                    SessionThread(
                        id: "0588672ccb97f40bb57238989226cf429b575ba355443f47bc76c5ab144a96c65b",
                        variant: .contact,
                        creationDateTimestamp: 1234567890,
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
                expect(dependencies.mutate(cache: .libSession) { $0.profile }).to(equal(
                    Profile(
                        id: "0588672ccb97f40bb57238989226cf429b575ba355443f47bc76c5ab144a96c65b",
                        name: "TestCompleteName",
                        lastNameUpdate: nil,
                        nickname: nil,
                        displayPictureUrl: nil,
                        displayPictureEncryptionKey: nil,
                        displayPictureLastUpdated: nil,
                        blocksCommunityMessageRequests: nil,
                        lastBlocksCommunityMessageRequests: nil
                    )
                ))
            }
            
            // MARK: -- saves a config dump to the database
            it("saves a config dump to the database") {
                let result: [ConfigDump]? = mockStorage.read { db in
                    try ConfigDump.fetchAll(db)
                }
                let expectedData: Data? = Data(base64Encoded: "ZDE6IWkxZTE6JDEwNDpkMTojaTFlMTomZDE6K2ktMWUxOm4xNjpUZXN0Q29tcGxldGVOYW1lZTE6PGxsaTBlMzI66hc7V77KivGMNRmnu/acPnoF0cBJ+pVYNB2Ou0iwyWVkZWVlMTo9ZDE6KzA6MTpuMDplZTE6KGxlMTopbGUxOipkZTE6K2RlZQ==")
                
                expect(result).to(equal([
                    ConfigDump(
                        variant: .userProfile,
                        sessionId: "0588672ccb97f40bb57238989226cf429b575ba355443f47bc76c5ab144a96c65b",
                        data: (expectedData ?? Data()),
                        timestampMs: 1234567890000
                    )
                ]))
            }
            
            // MARK: -- updates the onboarding state to 'completed'
            it("updates the onboarding state to 'completed'") {
                await expect { await manager.state.first() }.to(equal(.completed))
            }
            
            // MARK: -- updates the hasViewedSeed value only when restoring
            it("updates the hasViewedSeed value only when restoring") {
                // Check for the `register` case first
                await expect(dependencies[cache: .libSession]?.get(.hasViewedSeed)).toEventually(beFalse())
                
                // Then the `restore` case
                manager = Onboarding.Manager(
                    flow: .restore,
                    using: dependencies
                )
                await manager.setDisplayName("TestCompleteName")
                await manager.completeRegistration()
                
                await expect(dependencies[cache: .libSession]?.get(.hasViewedSeed)).toEventually(beTrue())
            }
            
            // MARK: -- replicates the user metadata
            it("replicates the user metadata") {
                expect(mockExtensionHelper).to(call(.exactly(times: 1), matchingParameters: .all) {
                    try $0.saveUserMetadata(
                        sessionId: SessionId(.standard, hex: TestConstants.publicKey),
                        ed25519SecretKey: Array(Data(hex: TestConstants.edSecretKey)),
                        unreadCount: 0
                    )
                })
            }
            
            // MARK: -- stores the desired useAPNs value in the user defaults
            it("stores the desired useAPNs value in the user defaults") {
                expect(mockUserDefaults).to(call(.exactly(times: 1), matchingParameters: .all) {
                    $0.set(false, forKey: UserDefaults.BoolKey.isUsingFullAPNs.rawValue)
                })
            }
            
            // MARK: -- emits the complete status
            it("emits the complete status") {
                manager = Onboarding.Manager(
                    flow: .register,
                    using: dependencies
                )
                await expect { await manager.state.first() }.toNot(equal(.completed))
                await manager.setDisplayName("TestCompleteName")
                await manager.completeRegistration()
                
                await expect { await manager.state.first() }.to(equal(.completed))
            }
        }
    }
}
