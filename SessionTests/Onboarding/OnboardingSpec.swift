// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Combine
import GRDB
import Quick
import Nimble
import SessionUtil
import SessionUIKit
import SessionUtilitiesKit

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
            migrations: SNMessagingKit.migrations,
            using: dependencies
        )
        @TestState(singleton: .crypto, in: dependencies) var mockCrypto: MockCrypto! = MockCrypto(
            initialSetup: { crypto in
                crypto
                    .when { $0.generate(.x25519(ed25519Pubkey: .any)) }
                    .thenReturn(Array(Data(hex: TestConstants.publicKey)))
                crypto
                    .when { $0.generate(.x25519(ed25519Seckey: .any)) }
                    .thenReturn(Array(Data(hex: TestConstants.privateKey)))
                crypto
                    .when { $0.generate(.randomBytes(.any)) }
                    .thenReturn(Data([1, 2, 3, 4, 5, 6, 7, 8, 1, 2, 3, 4, 5, 6, 7, 8]))
                crypto
                    .when { $0.generate(.ed25519Seed(ed25519SecretKey: Array<UInt8>.any)) }
                    .thenReturn(Data([
                        1, 2, 3, 4, 5, 6, 7, 8, 9, 0,
                        1, 2, 3, 4, 5, 6, 7, 8, 9, 0,
                        1, 2, 3, 4, 5, 6, 7, 8, 9, 0,
                        1, 2
                    ]))
                crypto
                    .when { $0.generate(.ed25519KeyPair(seed: Array<UInt8>.any)) }
                    .thenReturn(
                        KeyPair(
                            publicKey: Array(Data(hex: TestConstants.edPublicKey)),
                            secretKey: Array(Data(hex: TestConstants.edSecretKey))
                        )
                    )
                crypto
                    .when { $0.generate(.signature(message: .any, ed25519SecretKey: .any)) }
                    .thenReturn(Authentication.Signature.standard(signature: "TestSignature".bytes))
                crypto
                    .when { $0.generate(.hash(message: .any)) }
                    .thenReturn([1, 2, 3])
            }
        )
        @TestState(cache: .libSession, in: dependencies) var mockLibSession: MockLibSessionCache! = MockLibSessionCache(
            initialSetup: { cache in
                cache.defaultInitialSetup()
                cache
                    .when {
                        $0.profile(
                            contactId: .any,
                            threadId: .any,
                            threadVariant: .any,
                            visibleMessage: .any
                        )
                    }
                    .thenReturn(nil)
            }
        )
        @TestState(defaults: .standard, in: dependencies) var mockUserDefaults: MockUserDefaults! = MockUserDefaults(
            initialSetup: { defaults in
                defaults.when { $0.bool(forKey: UserDefaults.BoolKey.isMainAppActive.rawValue) }.thenReturn(true)
                defaults.when { $0.bool(forKey: UserDefaults.BoolKey.isUsingFullAPNs.rawValue) }.thenReturn(false)
                defaults.when { $0.integer(forKey: .any) }.thenReturn(2)
                defaults.when { $0.set(true, forKey: .any) }.thenReturn(())
                defaults.when { $0.set(false, forKey: .any) }.thenReturn(())
            }
        )
        @TestState(cache: .general, in: dependencies) var mockGeneralCache: MockGeneralCache! = MockGeneralCache(
            initialSetup: { cache in
                cache.when { $0.userExists }.thenReturn(true)
                cache.when { $0.setSecretKey(ed25519SecretKey: .any) }.thenReturn(())
                cache.when { $0.sessionId }.thenReturn(SessionId(.standard, hex: TestConstants.publicKey))
                cache.when { $0.ed25519SecretKey }.thenReturn(Array(Data(hex: TestConstants.edSecretKey)))
            }
        )
        @TestState(singleton: .network, in: dependencies) var mockNetwork: MockNetwork! = MockNetwork(
            initialSetup: { network in
                network.when { $0.getSwarm(for: .any) }.thenReturn([
                    LibSession.Snode(
                        ip: "1.2.3.4",
                        quicPort: 1234,
                        ed25519PubkeyHex: "1234"
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
                            endpoint: MockEndpoint.any,
                            destination: .any,
                            body: .any,
                            requestTimeout: .any,
                            requestAndPathBuildTimeout: .any
                        )
                    }
                    .thenReturn(MockNetwork.batchResponseData(
                        with: [
                            (
                                Network.SnodeAPI.Endpoint.getMessages,
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
        @TestState(cache: .snodeAPI, in: dependencies) var mockSnodeAPICache: MockSnodeAPICache! = MockSnodeAPICache(
            initialSetup: { $0.defaultInitialSetup() }
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
        @TestState var disposables: [AnyCancellable]! = []
        @TestState var cache: Onboarding.Cache!
        
        // MARK: - an Onboarding Cache - Initialization
        describe("an Onboarding Cache when initialising") {
            beforeEach {
                mockLibSession
                    .when { $0.profile(contactId: .any, threadId: .any, threadVariant: .any, visibleMessage: .any) }
                    .thenReturn(nil)
            }
            
            justBeforeEach {
                cache = Onboarding.Cache(
                    flow: .restore,
                    using: dependencies
                )
            }
            
            // MARK: -- stores the initialFlow
            it("stores the initialFlow") {
                Onboarding.Flow.allCases.forEach { flow in
                    cache = Onboarding.Cache(
                        flow: flow,
                        using: dependencies
                    )
                    expect(cache.initialFlow).to(equal(flow))
                }
            }
            
            // MARK: -- without a stored secret key
            context("without a stored secret key") {
                beforeEach {
                    mockGeneralCache.when { $0.ed25519SecretKey }.thenReturn([])
                    mockCrypto
                        .when { $0.generate(.ed25519KeyPair(seed: Array<UInt8>.any)) }
                        .thenReturn(KeyPair(publicKey: [1, 2, 3], secretKey: [4, 5, 6]))
                    mockCrypto
                        .when { $0.generate(.x25519(ed25519Pubkey: .any)) }
                        .thenReturn([3, 2, 1])
                    mockCrypto
                        .when { $0.generate(.x25519(ed25519Seckey: .any)) }
                        .thenReturn([6, 5, 4])
                }
                
                // MARK: ---- generates new key pairs
                it("generates new key pairs") {
                    expect(cache.ed25519KeyPair.publicKey.toHexString()).to(equal("010203"))
                    expect(cache.ed25519KeyPair.secretKey.toHexString()).to(equal("040506"))
                    expect(cache.x25519KeyPair.publicKey.toHexString()).to(equal("030201"))
                    expect(cache.x25519KeyPair.secretKey.toHexString()).to(equal("060504"))
                    expect(cache.userSessionId).to(equal(SessionId(.standard, hex: "030201")))
                }
            }
            
            // MARK: -- with a stored secret key
            context("with a stored secret key") {
                beforeEach {
                    mockGeneralCache
                        .when { $0.ed25519SecretKey }
                        .thenReturn(Array(Data(hex: TestConstants.edSecretKey)))
                    mockCrypto
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
                    expect(cache.seed.isEmpty).to(beTrue())
                }
                
                // MARK: ---- loads the ed25519 key pair from the database
                it("loads the ed25519 key pair from the database") {
                    expect(cache.ed25519KeyPair.publicKey.toHexString())
                        .to(equal(TestConstants.edPublicKey))
                    expect(cache.ed25519KeyPair.secretKey.toHexString())
                        .to(equal(TestConstants.edSecretKey))
                }
                
                // MARK: ---- generates the x25519KeyPair from the loaded ed25519 key pair
                it("generates the x25519KeyPair from the loaded ed25519 key pair") {
                    expect(mockCrypto).to(call(.exactly(times: 1), matchingParameters: .all) {
                        $0.generate(.x25519(ed25519Pubkey: Array(Data(hex: TestConstants.edPublicKey))))
                    })
                    expect(mockCrypto).to(call(.exactly(times: 1), matchingParameters: .all) {
                        $0.generate(.x25519(ed25519Seckey: Array(Data(hex: TestConstants.edSecretKey))))
                    })
                    
                    expect(cache.x25519KeyPair.publicKey.toHexString())
                        .to(equal(TestConstants.publicKey))
                    expect(cache.x25519KeyPair.secretKey.toHexString())
                        .to(equal(TestConstants.privateKey))
                }
                
                // MARK: ---- generates the sessionId from the generated x25519PublicKey
                it("generates the sessionId from the generated x25519PublicKey") {
                    expect(cache.userSessionId)
                        .to(equal(SessionId(.standard, hex: TestConstants.publicKey)))
                }
                
                // MARK: ---- and failing to generate an x25519KeyPair
                context("and failing to generate an x25519KeyPair") {
                    beforeEach {
                        mockCrypto.removeMocksFor { $0.generate(.ed25519KeyPair(seed: Array<UInt8>.any)) }
                        mockCrypto.removeMocksFor { $0.generate(.ed25519Seed(ed25519SecretKey: Array<UInt8>.any)) }
                        mockCrypto
                            .when { try $0.tryGenerate(.ed25519Seed(ed25519SecretKey: Array<UInt8>.any)) }
                            .thenThrow(MockError.mockedData)
                        mockCrypto
                            .when {
                                $0.generate(.ed25519KeyPair(
                                    seed: Array(Data(hex: TestConstants.edSecretKey))
                                ))
                            }
                            .thenReturn(KeyPair(publicKey: [1, 2, 3], secretKey: [9, 8, 7]))
                        mockCrypto
                            .when {
                                $0.generate(.ed25519KeyPair(
                                    seed: [1, 2, 3, 4, 5, 6, 7, 8, 1, 2, 3, 4, 5, 6, 7, 8]
                                )) }
                            .thenReturn(KeyPair(publicKey: [1, 2, 3], secretKey: [4, 5, 6]))
                        mockCrypto
                            .when { $0.generate(.x25519(ed25519Pubkey: [1, 2, 3])) }
                            .thenReturn([4, 3, 2, 1])
                        mockCrypto
                            .when { $0.generate(.x25519(ed25519Seckey: [4, 5, 6])) }
                            .thenReturn([7, 6, 5, 4])
                        mockCrypto
                            .when { $0.generate(.x25519(ed25519Pubkey: [9, 8, 7])) }
                            .thenReturn(nil)
                    }
                    
                    // MARK: ------ generates new credentials
                    it("generates new credentials") {
                        expect(cache.state).to(equal(.noUserInvalidKeyPair))
                        expect(cache.seed).to(equal(Data([1, 2, 3, 4, 5, 6, 7, 8, 1, 2, 3, 4, 5, 6, 7, 8])))
                        expect(cache.ed25519KeyPair.publicKey.toHexString()).to(equal("010203"))
                        expect(cache.ed25519KeyPair.secretKey.toHexString()).to(equal("040506"))
                        expect(cache.x25519KeyPair.publicKey.toHexString()).to(equal("04030201"))
                        expect(cache.x25519KeyPair.secretKey.toHexString()).to(equal("07060504"))
                        expect(cache.userSessionId).to(equal(SessionId(.standard, hex: "04030201")))
                    }
                    
                    // MARK: ------ goes into an invalid state when generating a seed fails
                    it("goes into an invalid state when generating a seed fails") {
                        mockCrypto.when { $0.generate(.randomBytes(.any)) }.thenReturn(nil as Data?)
                        cache = Onboarding.Cache(
                            flow: .restore,
                            using: dependencies
                        )
                        expect(cache.state).to(equal(.noUserInvalidSeedGeneration))
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
                        expect(cache.displayName).to(equal("TestProfileName"))
                    }
                    
                    // MARK: ------ loads the useAPNs setting from user defaults
                    it("loads the useAPNs setting from user defaults") {
                        expect(mockUserDefaults).to(call { $0.bool(forKey: .any) })
                        expect(cache.useAPNS).to(beTrue())
                    }
                    
                    // MARK: ------ after generating new credentials
                    context("after generating new credentials") {
                        beforeEach {
                            mockCrypto.removeMocksFor { $0.generate(.ed25519KeyPair(seed: Array<UInt8>.any)) }
                            mockCrypto.removeMocksFor { $0.generate(.ed25519Seed(ed25519SecretKey: Array<UInt8>.any)) }
                            mockCrypto
                                .when { try $0.tryGenerate(.ed25519Seed(ed25519SecretKey: Array<UInt8>.any)) }
                                .thenThrow(MockError.mockedData)
                            mockCrypto
                                .when {
                                    $0.generate(.ed25519KeyPair(
                                        seed: Array(Data(hex: TestConstants.edSecretKey))
                                    ))
                                }
                                .thenReturn(KeyPair(publicKey: [1, 2, 3], secretKey: [9, 8, 7]))
                            mockCrypto
                                .when {
                                    $0.generate(.ed25519KeyPair(
                                        seed: [1, 2, 3, 4, 5, 6, 7, 8, 1, 2, 3, 4, 5, 6, 7, 8]
                                    )) }
                                .thenReturn(KeyPair(publicKey: [1, 2, 3], secretKey: [4, 5, 6]))
                            mockCrypto
                                .when { $0.generate(.x25519(ed25519Pubkey: [1, 2, 3])) }
                                .thenReturn([4, 3, 2, 1])
                            mockCrypto
                                .when { $0.generate(.x25519(ed25519Seckey: [4, 5, 6])) }
                                .thenReturn([7, 6, 5, 4])
                            mockCrypto
                                .when { $0.generate(.x25519(ed25519Pubkey: [9, 8, 7])) }
                                .thenReturn(nil)
                        }
                        
                        // MARK: -------- has an empty display name
                        it("has an empty display name") {
                            expect(cache.displayName).to(equal(""))
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
                        expect(cache.displayName).to(equal(""))
                    }
                    
                    // MARK: ------ loads the useAPNs setting from user defaults
                    it("loads the useAPNs setting from user defaults") {
                        expect(mockUserDefaults).to(call { $0.bool(forKey: .any) })
                        expect(cache.useAPNS).to(beTrue())
                    }
                }
            }
        }
        
        // MARK: - an Onboarding Cache - Seed Data
        describe("an Onboarding Cache when setting seed data") {
            beforeEach {
                mockCrypto
                    .when { $0.generate(.ed25519KeyPair(seed: Array<UInt8>.any)) }
                    .thenReturn(
                        KeyPair(
                            publicKey: Array(Data(hex: TestConstants.edPublicKey)),
                            secretKey: Array(Data(hex: TestConstants.edSecretKey))
                        )
                    )
            }
            
            justBeforeEach {
                cache = Onboarding.Cache(
                    flow: .register,
                    using: dependencies
                )
                cache.displayNamePublisher.sinkAndStore(in: &disposables)
                try? cache.setSeedData(Data(hex: TestConstants.edKeySeed).prefix(upTo: 16))
            }
            
            // MARK: -- throws if the seed is the wrong length
            it("throws if the seed is the wrong length") {
                expect { try cache.setSeedData(Data([1, 2, 3])) }
                    .to(throwError(CryptoError.invalidSeed))
            }
            
            // MARK: -- stores the seed
            it("stores the seed") {
                expect(cache.seed).to(equal(Data(hex: TestConstants.edKeySeed).prefix(upTo: 16)))
            }
            
            // MARK: -- stores the generated identity
            it("stores the generated identity") {
                expect(cache.ed25519KeyPair.publicKey.toHexString())
                    .to(equal(TestConstants.edPublicKey))
                expect(cache.ed25519KeyPair.secretKey.toHexString())
                    .to(equal(TestConstants.edSecretKey))
                expect(cache.x25519KeyPair.publicKey.toHexString())
                    .to(equal(TestConstants.publicKey))
                expect(cache.x25519KeyPair.secretKey.toHexString())
                    .to(equal(TestConstants.privateKey))
                expect(cache.userSessionId)
                    .to(equal(SessionId(.standard, hex: TestConstants.publicKey)))
            }
            
            // MARK: -- polls for the userProfile config
            it("polls for the userProfile config") {
                let base64EncodedDataString: String = "eyJtZXRob2QiOiJiYXRjaCIsInBhcmFtcyI6eyJyZXF1ZXN0cyI6W3sibWV0aG9kIjoicmV0cmlldmUiLCJwYXJhbXMiOnsibGFzdF9oYXNoIjoiIiwibWF4X3NpemUiOi0xLCJuYW1lc3BhY2UiOjIsInB1YmtleSI6IjA1ODg2NzJjY2I5N2Y0MGJiNTcyMzg5ODkyMjZjZjQyOWI1NzViYTM1NTQ0M2Y0N2JjNzZjNWFiMTQ0YTk2YzY1YiIsInB1YmtleV9lZDI1NTE5IjoiYmFjNmU3MWVmZDdkZmE0YTgzYzk4ZWQyNGYyNTRhYjJjMjY3ZjljY2RiMTcyYTUyODBhMDQ0NGFkMjRlODljYyIsInNpZ25hdHVyZSI6IlZHVnpkRk5wWjI1aGRIVnlaUT09IiwidGltZXN0YW1wIjoxMjM0NTY3ODkwMDAwfX1dfX0="
                
                await expect(mockNetwork)
                    .toEventually(call(.exactly(times: 1), matchingParameters: .atLeast(3)) {
                        $0.send(
                            endpoint: Network.SnodeAPI.Endpoint.batch,
                            destination: Network.Destination.snode(
                                LibSession.Snode(
                                    ip: "1.2.3.4",
                                    quicPort: 1234,
                                    ed25519PubkeyHex: ""
                                ),
                                swarmPublicKey: "0588672ccb97f40bb57238989226cf429b575ba355443f47bc76c5ab144a96c65b"
                            ),
                            body: Data(base64Encoded: base64EncodedDataString),
                            requestTimeout: 10,
                            requestAndPathBuildTimeout: nil
                        )
                    })
            }
            
            // MARK: -- the display name to be set to the successful result
            it("the display name to be set to the successful result") {
                await expect(cache.displayName).toEventually(equal("TestPolledName"))
            }
            
            // MARK: -- the publisher to emit the display name
            it("the publisher to emit the display name") {
                var value: String?
                cache
                    .displayNamePublisher
                    .sink(
                        receiveCompletion: { _ in },
                        receiveValue: { value = $0 }
                    )
                    .store(in: &disposables)
                await expect(value).toEventually(equal("TestPolledName"))
            }
        }
        
        // MARK: - an Onboarding Cache - Setting values
        describe("an Onboarding Cache when setting values") {
            justBeforeEach {
                cache = Onboarding.Cache(
                    flow: .register,
                    using: dependencies
                )
            }
            
            // MARK: -- stores the useAPNs setting
            it("stores the useAPNs setting") {
                expect(cache.useAPNS).to(beFalse())
                cache.setUseAPNS(true)
                expect(cache.useAPNS).to(beTrue())
            }
            
            // MARK: -- stores the display name
            it("stores the display name") {
                expect(cache.displayName).to(equal(""))
                cache.setDisplayName("TestName")
                expect(cache.displayName).to(equal("TestName"))
            }
        }
        
        // MARK: - an Onboarding Cache - Complete Registration
        describe("an Onboarding Cache when completing registration") {
            justBeforeEach {
                /// The `profile_updated` timestamp in `libSession` is set to now so we need to set the value to some
                /// distant future value to force the update logic to trigger
                dependencies.dateNow = Date(timeIntervalSince1970: 12345678900)
                
                cache = Onboarding.Cache(
                    flow: .register,
                    using: dependencies
                )
                cache.setDisplayName("TestCompleteName")
                cache.completeRegistration()
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
                        nickname: nil,
                        displayPictureUrl: nil,
                        displayPictureEncryptionKey: nil,
                        profileLastUpdated: 12345678900,
                        blocksCommunityMessageRequests: nil,
                        proFeatures: .none,
                        proExpiryUnixTimestampMs: 0,
                        proGenIndexHashHex: nil
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
                let profile: Profile = dependencies.mutate(cache: .libSession) { $0.profile }
                expect(profile).to(equal(
                    Profile(
                        id: "0588672ccb97f40bb57238989226cf429b575ba355443f47bc76c5ab144a96c65b",
                        name: "TestCompleteName",
                        nickname: nil,
                        displayPictureUrl: nil,
                        displayPictureEncryptionKey: nil,
                        profileLastUpdated: profile.profileLastUpdated,
                        blocksCommunityMessageRequests: nil,
                        proFeatures: .none,
                        proExpiryUnixTimestampMs: 0,
                        proGenIndexHashHex: nil
                    )
                ))
                expect(profile.profileLastUpdated).toNot(beNil())
            }
            
            // MARK: -- saves a config dump to the database
            it("saves a config dump to the database") {
                let result: [ConfigDump]? = mockStorage.read { db in
                    try ConfigDump.fetchAll(db)
                }
                
                try require(result).to(haveCount(1))
                try require(Set((result?.map { $0.variant })!)).to(equal([.userProfile]))
                expect(result![0].variant).to(equal(.userProfile))
                let userProfileDump: ConfigDump = (result?.first(where: { $0.variant == .userProfile }))!
                expect(userProfileDump.variant).to(equal(.userProfile))
                expect(userProfileDump.sessionId).to(equal(SessionId(.standard, hex: TestConstants.publicKey)))
                expect(userProfileDump.timestampMs).to(equal(1234567890000))
                
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
                expect(cache.state).to(equal(.completed))
            }
            
            // MARK: -- updates the hasViewedSeed value only when restoring
            it("updates the hasViewedSeed value only when restoring") {
                // Check for the `register` case first
                await expect(dependencies[cache: .libSession]?.get(.hasViewedSeed)).toEventually(beFalse())
                
                // Then the `restore` case
                cache = Onboarding.Cache(
                    flow: .restore,
                    using: dependencies
                )
                cache.setDisplayName("TestCompleteName")
                cache.completeRegistration()
                
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
            
            // MARK: -- emits an event from the completion publisher
            it("emits an event from the completion publisher") {
                var didEmitInPublisher: Bool = false
                
                cache = Onboarding.Cache(
                    flow: .register,
                    using: dependencies
                )
                cache.setDisplayName("TestCompleteName")
                cache.onboardingCompletePublisher
                    .sink(receiveValue: { _ in didEmitInPublisher = true })
                    .store(in: &disposables)
                cache.completeRegistration()
                
                await expect(didEmitInPublisher).toEventually(beTrue())
            }
            
            // MARK: -- calls the onComplete callback
            it("calls the onComplete callback") {
                var didCallOnComplete: Bool = false
                
                cache = Onboarding.Cache(
                    flow: .register,
                    using: dependencies
                )
                cache.setDisplayName("TestCompleteName")
                cache.completeRegistration { didCallOnComplete = true }
                
                await expect(didCallOnComplete).toEventually(beTrue())
            }
        }
        
        // MARK: - an Onboarding Cache - Complete Restoration
        describe("an Onboarding Cache when completing an account restoration") {
            @TestState var testCacheProfile: Profile!
            
            justBeforeEach {
                /// The `profile_updated` timestamp in `libSession` is set to now so we need to set the value to some
                /// distant future value to force the update logic to trigger
                dependencies.dateNow = Date(timeIntervalSince1970: 12345678900)
                
                cache = Onboarding.Cache(
                    flow: .restore,
                    using: dependencies
                )
                cache.setDisplayName("TestCompleteName")
                cache.displayNamePublisher.sinkAndStore(in: &disposables)
                try? cache.setSeedData(Data(hex: TestConstants.edKeySeed).prefix(upTo: 16))
                cache.completeRegistration()
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
                    .thenReturn(MockNetwork.batchResponseData(
                        with: [
                            (
                                Network.SnodeAPI.Endpoint.getMessages,
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
            
            // MARK: -- starts a download job if there was a display picture
            it("starts a download job if there was a display picture") {
                // FIXME: Update this with the new mocking system to support `.any` timestamp
                /// Since the `timestamp` comes from `libSession` we can't mock it
                expect(mockJobRunner).to(call(matchingParameters: .all) {
                    $0.add(
                        .any,
                        job: Job(
                            variant: .displayPictureDownload,
                            behaviour: .runOnce,
                            shouldBeUnique: true,
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
                        dependantJob: nil,
                        canStartJob: false
                    )
                })
            }
        }
    }
}
