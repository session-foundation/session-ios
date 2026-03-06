// Copyright © 2026 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtil
import TestUtilities

import Quick
import Nimble

@testable import SessionMessagingKit
@testable import SessionNetworkingKit
@testable import SessionUtilitiesKit

class MessageSenderGroupsSpec: AsyncSpec {
    override class func spec() {
        // MARK: Configuration
        
        let groupSeed: Data = Data(hex: "0123456789abcdef0123456789abcdeffedcba9876543210fedcba9876543210")
        let groupKeyPair: KeyPair = Crypto(using: .any).generate(.ed25519KeyPair(seed: Array(groupSeed)))!
        @TestState var groupId: SessionId! = SessionId(.group, hex: "03cbd569f56fb13ea95a3f0c05c331cc24139c0090feb412069dc49fab34406ece")
        @TestState var groupSecretKey: Data! = Data(hex:
            "0123456789abcdef0123456789abcdeffedcba9876543210fedcba9876543210" +
            "cbd569f56fb13ea95a3f0c05c331cc24139c0090feb412069dc49fab34406ece"
        )
        @TestState var dependencies: TestDependencies! = TestDependencies { dependencies in
            dependencies.dateNow = Date(timeIntervalSince1970: 1234567890)
            dependencies.forceSynchronous = true
            
            SNUtilitiesKit.configure(
                networkMaxFileSize: Network.maxFileSize,
                maxValidImageDimention: 123456789,
                using: dependencies
            )
        }
        @TestState var mockStorage: Storage! = SynchronousStorage(
            customWriter: try! DatabaseQueue(),
            using: dependencies
        )
        @TestState var mockUserDefaults: MockUserDefaults! = .create(using: dependencies)
        @TestState var mockJobRunner: MockJobRunner! = .create(using: dependencies)
        @TestState var mockNetwork: MockNetwork! = .create(using: dependencies)
        @TestState var mockCrypto: MockCrypto! = .create(using: dependencies)
        @TestState var mockKeychain: MockKeychain! = .create(using: dependencies)
        @TestState var mockGeneralCache: MockGeneralCache! = .create(using: dependencies)
        @TestState var secretKey: [UInt8]! = Array(Data(hex: TestConstants.edSecretKey))
        @TestState var groupEdPK: [UInt8]! = groupKeyPair.publicKey
        @TestState var groupEdSK: [UInt8]! = groupKeyPair.secretKey
        @TestState var userGroupsConfig: LibSession.Config! = {
            var userGroupsConf: UnsafeMutablePointer<config_object>!
            _ = user_groups_init(&userGroupsConf, &secretKey, nil, 0, nil)
            
            return .userGroups(userGroupsConf)
        }()
        @TestState var groupInfoConf: UnsafeMutablePointer<config_object>! = {
            var groupInfoConf: UnsafeMutablePointer<config_object>!
            _ = groups_info_init(&groupInfoConf, &groupEdPK, &groupEdSK, nil, 0, nil)
            
            return groupInfoConf
        }()
        @TestState var groupMembersConf: UnsafeMutablePointer<config_object>! = {
            var groupMembersConf: UnsafeMutablePointer<config_object>!
            _ = groups_members_init(&groupMembersConf, &groupEdPK, &groupEdSK, nil, 0, nil)
            
            return groupMembersConf
        }()
        @TestState var groupKeysConf: UnsafeMutablePointer<config_group_keys>! = {
            var groupKeysConf: UnsafeMutablePointer<config_group_keys>!
            _ = groups_keys_init(&groupKeysConf, &secretKey, &groupEdPK, &groupEdSK, groupInfoConf, groupMembersConf, nil, 0, nil)
            
            return groupKeysConf
        }()
        @TestState var groupInfoConfig: LibSession.Config! = .groupInfo(groupInfoConf)
        @TestState var groupMembersConfig: LibSession.Config! = .groupMembers(groupMembersConf)
        @TestState var groupKeysConfig: LibSession.Config! = {
            return .groupKeys(groupKeysConf, info: groupInfoConf, members: groupMembersConf)
        }()
        @TestState var mockLibSessionCache: MockLibSessionCache! = .create(using: dependencies)
        @TestState var mockPoller: MockPoller<SwarmPoller.PollResponse>! = .create(using: dependencies)
        @TestState var mockGroupPollerManager: MockGroupPollerManager! = .create(using: dependencies)
        @TestState var mockFileManager: MockFileManager! = .create(using: dependencies)
        @TestState var mockImageDataManager: MockImageDataManager! = .create(using: dependencies)
        @TestState var mockMediaDecoder: MockMediaDecoder! = .create(using: dependencies)
        @TestState var error: Error?
        @TestState var thread: SessionThread?
        
        beforeEach {
            dependencies.set(cache: .general, to: mockGeneralCache)
            try await mockGeneralCache.defaultInitialSetup()
            
            dependencies.set(cache: .libSession, to: mockLibSessionCache)
            try await mockLibSessionCache.defaultInitialSetup(
                configs: [
                    .userGroups: userGroupsConfig,
                    .groupInfo: groupInfoConfig,
                    .groupMembers: groupMembersConfig,
                    .groupKeys: groupKeysConfig
                ]
            )
            try await mockLibSessionCache
                .when { try $0.pendingPushes(swarmPublicKey: .any) }
                .thenReturn(LibSession.PendingPushes(obsoleteHashes: ["testHash"]))
            
            dependencies.set(singleton: .fileManager, to: mockFileManager)
            try await mockFileManager.defaultInitialSetup()
            
            dependencies.set(singleton: .jobRunner, to: mockJobRunner)
            try await mockJobRunner
                .when { await $0.jobsMatching(filters: .any) }
                .thenReturn([:])
            try await mockJobRunner
                .when { $0.add(.any, job: .any, initialDependencies: .any) }
                .thenReturn(.mock)
            try await mockJobRunner
                .when { try await $0.finalResult(forFirstJobMatching: .any) }
                .thenReturn(.mock)
            try await mockJobRunner
                .when { try $0.addJobDependency(.any, .any) }
                .thenReturn(())
            
            dependencies.set(singleton: .network, to: mockNetwork)
            try await mockNetwork.defaultInitialSetup(using: dependencies)
            await mockNetwork.removeRequestMocks()
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
                .thenReturn(Network.BatchResponse.mockConfigSyncResponse)
            
            dependencies.set(singleton: .keychain, to: mockKeychain)
            try await mockKeychain
                .when {
                    try $0.migrateLegacyKeyIfNeeded(
                        legacyKey: .any,
                        legacyService: .any,
                        toKey: .pushNotificationEncryptionKey
                    )
                }
                .thenReturn(())
            try await mockKeychain
                .when {
                    try $0.getOrGenerateEncryptionKey(
                        forKey: .any,
                        length: .any,
                        cat: .any,
                        legacyKey: .any,
                        legacyService: .any
                    )
                }
                .thenReturn(Data([1, 2, 3]))
            try await mockKeychain
                .when { try $0.data(forKey: .pushNotificationEncryptionKey) }
                .thenReturn(Data((0..<Network.PushNotification.encryptionKeyLength).map { _ in 1 }))
            
            try await mockPoller.when { await $0.startIfNeeded() }.thenReturn(())
            
            dependencies.set(singleton: .groupPollerManager, to: mockGroupPollerManager)
            try await mockGroupPollerManager.when { await $0.startAllPollers() }.thenReturn(())
            try await mockGroupPollerManager
                .when { await $0.getOrCreatePoller(for: .any) }
                .thenReturn(mockPoller)
            try await mockGroupPollerManager.when { await $0.stopAndRemovePoller(for: .any) }.thenReturn(())
            try await mockGroupPollerManager.when { await $0.stopAndRemoveAllPollers() }.thenReturn(())
            
            dependencies.set(singleton: .storage, to: mockStorage)
            try await mockStorage.perform(migrations: SNMessagingKit.migrations)
            try await mockStorage.writeAsync { db in
                try Identity(variant: .x25519PublicKey, data: Data(hex: TestConstants.publicKey)).insert(db)
                try Identity(variant: .x25519PrivateKey, data: Data(hex: TestConstants.privateKey)).insert(db)
                try Identity(variant: .ed25519PublicKey, data: Data(hex: TestConstants.edPublicKey)).insert(db)
                try Identity(variant: .ed25519SecretKey, data: Data(hex: TestConstants.edSecretKey)).insert(db)
                
                try Profile(
                    id: "05\(TestConstants.publicKey)",
                    name: "TestCurrentUser",
                    nickname: nil,
                    displayPictureUrl: nil,
                    displayPictureEncryptionKey: nil,
                    profileLastUpdated: nil,
                    blocksCommunityMessageRequests: nil,
                    proFeatures: .none,
                    proExpiryUnixTimestampMs: 0,
                    proGenIndexHashHex: nil
                ).insert(db)
            }
            
            dependencies.set(singleton: .crypto, to: mockCrypto)
            try await mockCrypto
                .when { $0.generate(.ed25519KeyPair()) }
                .thenReturn(
                    KeyPair(
                        publicKey: Data(hex: groupId.hexString).bytes,
                        secretKey: groupSecretKey.bytes
                    )
                )
            try await mockCrypto
                .when { $0.generate(.ed25519KeyPair(seed: Array<UInt8>.any)) }
                .thenReturn(
                    KeyPair(
                        publicKey: Data(hex: groupId.hexString).bytes,
                        secretKey: groupSecretKey.bytes
                    )
                )
            try await mockCrypto
                .when { $0.generate(.x25519(ed25519Pubkey: .any)) }
                .thenReturn(Array(Data(hex: TestConstants.serverPublicKey)))
            try await mockCrypto
                .when { $0.generate(.signature(message: .any, ed25519SecretKey: .any)) }
                .thenReturn(Authentication.Signature.standard(signature: "TestSignature".bytes))
            try await mockCrypto
                .when { $0.generate(.memberAuthData(config: .any, groupSessionId: .any, memberId: .any)) }
                .thenReturn(Authentication.Info.groupMember(
                    groupSessionId: SessionId(.standard, hex: TestConstants.publicKey),
                    authData: "TestAuthData".data(using: .utf8)!
                ))
            try await mockCrypto
                .when { $0.generate(.tokenSubaccount(config: .any, groupSessionId: .any, memberId: .any)) }
                .thenReturn(Array("TestSubAccountToken".data(using: .utf8)!))
            try await mockCrypto
                .when { try $0.tryGenerate(.randomBytes(.any)) }
                .thenReturn(Data((0..<DisplayPictureManager.encryptionKeySize).map { _ in 1 }))
            try await mockCrypto
                .when { $0.generate(.uuid()) }
                .thenReturn(UUID(uuidString: "00000000-0000-0000-0000-000000000000")!)
            try await mockCrypto
                .when { $0.generate(.legacyEncryptedDisplayPictureSize(plaintextSize: .any)) }
                .thenReturn(1024)
            try await mockCrypto
                .when { $0.generate(.legacyEncryptedDisplayPicture(data: .any, key: .any)) }
                .thenReturn(TestConstants.validImageData)
            try await mockCrypto
                .when {
                    try $0.generate(
                        .encodedMessage(
                            plaintext: Array<UInt8>.any,
                            proMessageFeatures: .any,
                            proProfileFeatures: .any,
                            destination: .any,
                            sentTimestampMs: .any
                        )
                    )
                }
                .thenReturn("TestGroupMessageCiphertext".data(using: .utf8)!)
            try await mockCrypto
                .when { $0.generate(.hash(message: .any)) }
                .thenReturn(Array(Data(hex: "01010101010101010101010101010101")))
            
            dependencies.set(defaults: .standard, to: mockUserDefaults)
            try await mockUserDefaults.defaultInitialSetup()
            try await mockUserDefaults.when { $0.string(forKey: .any) }.thenReturn(nil)
            try await mockUserDefaults.when { $0.integer(forKey: .any) }.thenReturn(1)
        }
        
        // MARK: - a MessageSender dealing with Groups
        describe("a MessageSender dealing with Groups") {
            // MARK: -- when creating a group
            context("when creating a group") {
                beforeEach {
                    try await mockLibSessionCache
                        .when { try $0.pendingPushes(swarmPublicKey: .any) }
                        .thenReturn(LibSession.PendingPushes())
                }
                
                // MARK: ---- loads the state into the cache
                it("loads the state into the cache") {
                    _ = try? await MessageSender.createGroup(
                        name: "TestGroupName",
                        description: nil,
                        displayPicture: nil,
                        displayPictureCropRect: nil,
                        members: [
                            ("051111111111111111111111111111111111111111111111111111111111111111", nil)
                        ],
                        using: dependencies
                    )
                    
                    await mockLibSessionCache
                        .verify { $0.setConfig(for: .groupInfo, sessionId: groupId, to: .any) }
                        .wasCalled(exactly: 1, timeout: .milliseconds(100))
                    await mockLibSessionCache
                        .verify { $0.setConfig(for: .groupMembers, sessionId: groupId, to: .any) }
                        .wasCalled(exactly: 1, timeout: .milliseconds(100))
                    await mockLibSessionCache
                        .verify { $0.setConfig(for: .groupKeys, sessionId: groupId, to: .any) }
                        .wasCalled(exactly: 1, timeout: .milliseconds(100))
                }
                
                // MARK: ---- returns the created thread
                it("returns the created thread") {
                    let thread: SessionThread = try await require {
                        try await MessageSender.createGroup(
                            name: "TestGroupName",
                            description: nil,
                            displayPicture: nil,
                            displayPictureCropRect: nil,
                            members: [
                                ("051111111111111111111111111111111111111111111111111111111111111111", nil)
                            ],
                            using: dependencies
                        )
                    }
                    .toNot(beNil())
                    
                    expect(thread.id).to(equal(groupId.hexString))
                    expect(thread.variant).to(equal(.group))
                    expect(thread.creationDateTimestamp).to(equal(1234567890))
                    expect(thread.shouldBeVisible).to(beTrue())
                    expect(thread.messageDraft).to(beNil())
                    expect(thread.markedAsUnread).to(beFalse())
                    expect(thread.pinnedPriority).to(equal(0))
                }
                
                // MARK: ---- stores the thread in the db
                it("stores the thread in the db") {
                    let thread: SessionThread = try await require {
                        try await MessageSender.createGroup(
                            name: "Test",
                            description: nil,
                            displayPicture: nil,
                            displayPictureCropRect: nil,
                            members: [
                                ("051111111111111111111111111111111111111111111111111111111111111111", nil)
                            ],
                            using: dependencies
                        )
                    }
                    .toNot(throwError())
                    
                    let dbValue: SessionThread? = mockStorage.read { db in try SessionThread.fetchOne(db) }
                    expect(dbValue).to(equal(thread))
                    expect(dbValue?.id).to(equal(groupId.hexString))
                    expect(dbValue?.variant).to(equal(.group))
                    expect(dbValue?.creationDateTimestamp).to(equal(1234567890))
                    expect(dbValue?.shouldBeVisible).to(beTrue())
                    expect(dbValue?.notificationSound).to(beNil())
                    expect(dbValue?.mutedUntilTimestamp).to(beNil())
                    expect(dbValue?.onlyNotifyForMentions).to(beFalse())
                    expect(dbValue?.pinnedPriority).to(equal(0))
                }
                
                // MARK: ---- stores the group in the db
                it("stores the group in the db") {
                    await expect {
                        try await MessageSender.createGroup(
                            name: "TestGroupName",
                            description: nil,
                            displayPicture: nil,
                            displayPictureCropRect: nil,
                            members: [
                                ("051111111111111111111111111111111111111111111111111111111111111111", nil)
                            ],
                            using: dependencies
                        )
                    }
                    .toNot(throwError())
                    
                    let dbValue: ClosedGroup? = mockStorage.read { db in try ClosedGroup.fetchOne(db) }
                    expect(dbValue?.id).to(equal(groupId.hexString))
                    expect(dbValue?.name).to(equal("TestGroupName"))
                    expect(dbValue?.formationTimestamp).to(equal(1234567890))
                    expect(dbValue?.displayPictureUrl).to(beNil())
                    expect(dbValue?.displayPictureEncryptionKey).to(beNil())
                    expect(dbValue?.groupIdentityPrivateKey?.toHexString()).to(equal(groupSecretKey.toHexString()))
                    expect(dbValue?.authData).to(beNil())
                    expect(dbValue?.invited).to(beFalse())
                }
                
                // MARK: ---- stores the group members in the db
                it("stores the group members in the db") {
                    await expect {
                        try await MessageSender.createGroup(
                            name: "TestGroupName",
                            description: nil,
                            displayPicture: nil,
                            displayPictureCropRect: nil,
                            members: [
                                ("051111111111111111111111111111111111111111111111111111111111111111", nil)
                            ],
                            using: dependencies
                        )
                    }
                    .toNot(throwError())
                    
                    expect(mockStorage.read { db in try GroupMember.fetchSet(db) })
                        .to(equal([
                            GroupMember(
                                groupId: groupId.hexString,
                                profileId: "051111111111111111111111111111111111111111111111111111111111111111",
                                role: .standard,
                                roleStatus: .pending,
                                isHidden: false
                            ),
                            GroupMember(
                                groupId: groupId.hexString,
                                profileId: "05\(TestConstants.publicKey)",
                                role: .admin,
                                roleStatus: .accepted,
                                isHidden: false
                            )
                        ]))
                }
                
                // MARK: ---- starts the group poller
                it("starts the group poller") {
                    await expect {
                        try await MessageSender.createGroup(
                            name: "TestGroupName",
                            description: nil,
                            displayPicture: nil,
                            displayPictureCropRect: nil,
                            members: [
                                ("051111111111111111111111111111111111111111111111111111111111111111", nil)
                            ],
                            using: dependencies
                        )
                    }
                    .toNot(throwError())
                    
                    await mockPoller
                        .verify { await $0.startIfNeeded() }
                        .wasCalled(exactly: 1, timeout: .milliseconds(100))
                }
                
                // MARK: ---- syncs the group configuration messages
                it("syncs the group configuration messages") {
                    await mockJobRunner.removeMocksFor { $0.add(.any, job: .any, initialDependencies: .any) }
                    try await mockJobRunner
                        .when { $0.add(.any, job: .any, initialDependencies: .any) }
                        .thenReturn(
                            Job(
                                id: 123,
                                failureCount: 0,
                                variant: .configurationSync,
                                threadId: groupId.hexString,
                                interactionId: nil,
                                details: nil,
                                transientData: nil
                            )
                        )
                    try await mockLibSessionCache
                        .when { try $0.pendingPushes(swarmPublicKey: .any) }
                        .thenReturn(
                            LibSession.PendingPushes(
                                pushData: [
                                    LibSession.PendingPushes.PushData(
                                        data: [Data([1, 2, 3])],
                                        seqNo: 2,
                                        variant: .groupInfo
                                    )
                                ]
                            )
                        )
                    try await mockStorage.writeAsync { db in
                        // Need the auth data to exist in the database to prepare the request
                        _ = try SessionThread.upsert(
                            db,
                            id: groupId.hexString,
                            variant: .group,
                            values: SessionThread.TargetValues(
                                creationDateTimestamp: .setTo(0),
                                shouldBeVisible: .useExisting
                            ),
                            using: dependencies
                        )
                        try ClosedGroup(
                            threadId: groupId.hexString,
                            name: "Test",
                            formationTimestamp: 0,
                            shouldPoll: nil,
                            groupIdentityPrivateKey: groupSecretKey,
                            invited: nil
                        ).upsert(db)
                        
                        // Remove the debug group so it can be created during the actual test
                        try ClosedGroup.filter(id: groupId.hexString).deleteAll(db)
                        try SessionThread.filter(id: groupId.hexString).deleteAll(db)
                    }
                    
                    await expect {
                        try await MessageSender.createGroup(
                            name: "TestGroupName",
                            description: nil,
                            displayPicture: nil,
                            displayPictureCropRect: nil,
                            members: [
                                ("051111111111111111111111111111111111111111111111111111111111111111", nil)
                            ],
                            using: dependencies
                        )
                    }.toNot(throwError())
                    
                    await mockJobRunner
                        .verify {
                            $0.add(
                                .any,
                                job: Job(
                                    variant: .configurationSync,
                                    threadId: groupId.hexString,
                                    transientData: ConfigurationSyncJob.AdditionalTransientData(
                                        beforeSequenceRequests: [],
                                        afterSequenceRequests: [],
                                        requireAllBatchResponses: false,
                                        requireAllRequestsSucceed: true,
                                        customAuthMethod: Authentication.groupAdmin(
                                            groupSessionId: groupId,
                                            ed25519SecretKey: groupSecretKey.map { Array($0) }!
                                        )
                                    )
                                ),
                                initialDependencies: []
                            )
                        }
                        .wasCalled(exactly: 1, timeout: .milliseconds(100))
                    
                    /// Ensure it was called with the mock value returned above
                    await mockJobRunner
                        .verify {
                            try await $0.finalResult(
                                for: Job(
                                    id: 123,
                                    failureCount: 0,
                                    variant: .configurationSync,
                                    threadId: groupId.hexString,
                                    interactionId: nil,
                                    details: nil,
                                    transientData: nil
                                )
                            )
                        }
                        .wasCalled(exactly: 1, timeout: .milliseconds(100))
                }
                
                // MARK: ---- and the group configuration sync fails
                context("and the group configuration sync fails") {
                    beforeEach {
                        await mockJobRunner.removeMocksFor {
                            try await $0.finalResult(forFirstJobMatching: .any)
                        }
                        try await mockJobRunner
                            .when { try await $0.finalResult(forFirstJobMatching: .any) }
                            .thenThrow(TestError.mock)
                    }
                    
                    // MARK: ------ throws an error
                    it("throws an error") {
                        await expect {
                            try await MessageSender.createGroup(
                                name: "TestGroupName",
                                description: nil,
                                displayPicture: nil,
                                displayPictureCropRect: nil,
                                members: [
                                    ("051111111111111111111111111111111111111111111111111111111111111111", nil)
                                ],
                                using: dependencies
                            )
                        }.to(throwError(TestError.mock))
                    }
                    
                    // MARK: ------ removes the config state
                    it("removes the config state") {
                        await expect {
                            try await MessageSender.createGroup(
                                name: "TestGroupName",
                                description: nil,
                                displayPicture: nil,
                                displayPictureCropRect: nil,
                                members: [
                                    ("051111111111111111111111111111111111111111111111111111111111111111", nil)
                                ],
                                using: dependencies
                            )
                        }.to(throwError(TestError.mock))
                        
                        await mockLibSessionCache
                            .verify { $0.removeConfigs(for: groupId) }
                            .wasCalled(exactly: 1, timeout: .milliseconds(100))
                    }
                    
                    // MARK: ------ removes the data from the database
                    it("removes the data from the database") {
                        await expect {
                            try await MessageSender.createGroup(
                                name: "TestGroupName",
                                description: nil,
                                displayPicture: nil,
                                displayPictureCropRect: nil,
                                members: [
                                    ("051111111111111111111111111111111111111111111111111111111111111111", nil)
                                ],
                                using: dependencies
                            )
                        }.to(throwError(TestError.mock))
                        
                        await expect { mockStorage.read { db in try SessionThread.fetchAll(db) } }
                            .toEventually(beEmpty())
                        let groups: [ClosedGroup]? = mockStorage.read { db in try ClosedGroup.fetchAll(db) }
                        let members: [GroupMember]? = mockStorage.read { db in try GroupMember.fetchAll(db) }
                        
                        expect(groups).to(beEmpty())
                        expect(members).to(beEmpty())
                    }
                }
                
                // MARK: ------ does not upload an image if none is provided
                it("does not upload an image if none is provided") {
                    _ = try? await MessageSender.createGroup(
                        name: "TestGroupName",
                        description: nil,
                        displayPicture: nil,
                        displayPictureCropRect: nil,
                        members: [
                            ("051111111111111111111111111111111111111111111111111111111111111111", nil)
                        ],
                        using: dependencies
                    )
                    
                    await mockNetwork
                        .verify {
                            try await $0.send(
                                endpoint: Network.FileServer.Endpoint.file,
                                destination: .serverUpload(
                                    server: Network.FileServer.defaultServer,
                                    x25519PublicKey: try Crypto(using: dependencies).tryGenerate(
                                        .x25519(ed25519Pubkey: Array(Data(
                                            hex: Network.FileServer.defaultEdPublicKey
                                        )))
                                    ).toHexString(),
                                    fileName: nil
                                ),
                                body: TestConstants.validImageData,
                                category: .file,
                                requestTimeout: Network.fileUploadTimeout,
                                overallTimeout: nil
                            )
                        }
                        .wasNotCalled(timeout: .milliseconds(100))
                }
                
                // MARK: ------ with an image
                context("with an image") {
                    // MARK: ------ uploads the image
                    it("uploads the image") {
                        /// Prevent the ConfigSyncJob network request (which would fail due to the network response mocking)
                        /// by making the `libSession` cache appear empty
                        try await mockLibSessionCache.when { $0.isEmpty }.thenReturn(true)
                        try await mockNetwork
                            .when {
                                try await $0.upload(
                                    fileURL: .any,
                                    fileName: .any,
                                    stallTimeout: .any,
                                    requestTimeout: .any,
                                    overallTimeout: .any,
                                    desiredPathIndex: .any
                                )
                            }
                            .thenReturn(FileMetadata(id: "1", size: 1))
                        try await mockFileManager
                            .when { try? $0.contents(atPath: .any) }
                            .thenReturn(TestConstants.validImageData)
                        
                        await expect {
                            try await MessageSender.createGroup(
                                name: "TestGroupName",
                                description: nil,
                                displayPicture: .data("Test", TestConstants.validImageData),
                                displayPictureCropRect: nil,
                                members: [
                                    ("051111111111111111111111111111111111111111111111111111111111111111", nil)
                                ],
                                using: dependencies
                            )
                        }.toNot(throwError())
                        
                        await mockNetwork
                            .verify {
                                try await $0.upload(
                                    fileURL: URL(fileURLWithPath: "tmpFile"),
                                    fileName: nil,
                                    stallTimeout: Network.fileUploadTimeout,
                                    requestTimeout: Network.fileUploadTimeout,
                                    overallTimeout: Network.fileUploadTimeout,
                                    desiredPathIndex: nil
                                )
                            }
                            .wasCalled(exactly: 1, timeout: .milliseconds(100))
                    }
                    
                    // MARK: ------ saves the image info to the group
                    it("saves the image info to the group") {
                        /// Prevent the ConfigSyncJob network request (which would fail due to the network response mocking)
                        /// by making the `libSession` cache appear empty
                        try await mockLibSessionCache.when { $0.isEmpty }.thenReturn(true)
                        try await mockNetwork
                            .when {
                                try await $0.upload(
                                    fileURL: .any,
                                    fileName: .any,
                                    stallTimeout: .any,
                                    requestTimeout: .any,
                                    overallTimeout: .any,
                                    desiredPathIndex: .any
                                )
                            }
                            .thenReturn(FileMetadata(id: "1", size: 1))
                        
                        await expect {
                            try await MessageSender.createGroup(
                                name: "TestGroupName",
                                description: nil,
                                displayPicture: .data("Test", TestConstants.validImageData),
                                displayPictureCropRect: nil,
                                members: [
                                    ("051111111111111111111111111111111111111111111111111111111111111111", nil)
                                ],
                                using: dependencies
                            )
                        }.toNot(throwError())
                        
                        let groups: [ClosedGroup]? = mockStorage.read { db in try ClosedGroup.fetchAll(db) }
                        
                        expect(groups?.first?.displayPictureUrl).to(equal("https://getsession.org/file/1234"))
                        expect(groups?.first?.displayPictureEncryptionKey)
                            .to(equal(Data((0..<DisplayPictureManager.encryptionKeySize).map { _ in 1 })))
                    }
                    
                    // MARK: ------ fails if the image fails to upload
                    it("fails if the image fails to upload") {
                        try await mockNetwork
                            .when {
                                try await $0.upload(
                                    fileURL: .any,
                                    fileName: .any,
                                    stallTimeout: .any,
                                    requestTimeout: .any,
                                    overallTimeout: .any,
                                    desiredPathIndex: .any
                                )
                            }
                            .thenThrow(NetworkError.unknown)
                        
                        await expect {
                            try await MessageSender.createGroup(
                                name: "TestGroupName",
                                description: nil,
                                displayPicture: .data("Test", TestConstants.validImageData),
                                displayPictureCropRect: nil,
                                members: [
                                    ("051111111111111111111111111111111111111111111111111111111111111111", nil)
                                ],
                                using: dependencies
                            )
                        }.to(throwError(AttachmentError.uploadFailed))
                    }
                }
                
                // MARK: ---- schedules member invite jobs
                it("schedules member invite jobs") {
                    _ = try? await MessageSender.createGroup(
                        name: "TestGroupName",
                        description: nil,
                        displayPicture: nil,
                        displayPictureCropRect: nil,
                        members: [
                            ("051111111111111111111111111111111111111111111111111111111111111111", nil)
                        ],
                        using: dependencies
                    )
                    
                    await mockJobRunner
                        .verify {
                            $0.add(
                                .any,
                                job: Job(
                                    variant: .groupInviteMember,
                                    threadId: groupId.hexString,
                                    details: try? GroupInviteMemberJob.Details(
                                        memberSessionIdHexString: "051111111111111111111111111111111111111111111111111111111111111111",
                                        authInfo: .groupMember(
                                            groupSessionId: SessionId(.standard, hex: TestConstants.publicKey),
                                            authData: "TestAuthData".data(using: .utf8)!
                                        )
                                    )
                                ),
                                initialDependencies: []
                            )
                        }
                        .wasCalled(exactly: 1, timeout: .milliseconds(100))
                }
                
                // MARK: ------ and trying to subscribe for push notifications
                context("and trying to subscribe for push notifications") {
                    beforeEach {
                        // Need to set `isUsingFullAPNs` to true to generate the `expectedRequest`
                        try await mockUserDefaults
                            .when { $0.string(forKey: UserDefaults.StringKey.deviceToken.rawValue) }
                            .thenReturn(Data([5, 4, 3, 2, 1]).toHexString())
                        try await mockUserDefaults
                            .when { $0.bool(forKey: UserDefaults.BoolKey.isUsingFullAPNs.rawValue) }
                            .thenReturn(true)
                        mockStorage.write { db in
                            _ = try SessionThread.upsert(
                                db,
                                id: groupId.hexString,
                                variant: .group,
                                values: SessionThread.TargetValues(
                                    creationDateTimestamp: .setTo(0),
                                    shouldBeVisible: .useExisting
                                ),
                                using: dependencies
                            )
                            try ClosedGroup(
                                threadId: groupId.hexString,
                                name: "Test",
                                formationTimestamp: 0,
                                shouldPoll: nil,
                                groupIdentityPrivateKey: groupSecretKey,
                                invited: nil
                            ).upsert(db)
                            
                            // Remove the debug group so it can be created during the actual test
                            try ClosedGroup.filter(id: groupId.hexString).deleteAll(db)
                            try SessionThread.filter(id: groupId.hexString).deleteAll(db)
                        }!
                    }
                    
                    // MARK: ---- subscribes when they are enabled
                    it("subscribes when they are enabled") {
                        try await mockUserDefaults
                            .when { $0.string(forKey: UserDefaults.StringKey.deviceToken.rawValue) }
                            .thenReturn(Data([5, 4, 3, 2, 1]).toHexString())
                        try await mockUserDefaults
                            .when { $0.bool(forKey: UserDefaults.BoolKey.isUsingFullAPNs.rawValue) }
                            .thenReturn(true)
                        
                        _ = try? await MessageSender.createGroup(
                            name: "TestGroupName",
                            description: nil,
                            displayPicture: nil,
                            displayPictureCropRect: nil,
                            members: [
                                ("051111111111111111111111111111111111111111111111111111111111111111", nil)
                            ],
                            using: dependencies
                        )
                        
                        await mockNetwork
                            .verify {
                                try await $0.send(
                                    endpoint: Network.PushNotification.Endpoint.subscribe,
                                    destination: .server(
                                        method: .post,
                                        server: Network.PushNotification.server,
                                        queryParameters: [:],
                                        headers: [:],
                                        x25519PublicKey: Network.PushNotification.serverPublicKey
                                    ),
                                    body: try! JSONEncoder(using: dependencies).encode(
                                        Network.PushNotification.SubscribeRequest(
                                            subscriptions: [
                                                Network.PushNotification.SubscribeRequest.Subscription(
                                                    namespaces: [
                                                        .groupMessages,
                                                        .configGroupKeys,
                                                        .configGroupInfo,
                                                        .configGroupMembers,
                                                        .revokedRetrievableGroupMessages
                                                    ],
                                                    includeMessageData: true,
                                                    serviceInfo: Network.PushNotification.ServiceInfo(
                                                        token: Data([5, 4, 3, 2, 1]).toHexString()
                                                    ),
                                                    notificationsEncryptionKey: Data([1, 2, 3]),
                                                    authMethod: try! Authentication.with(
                                                        swarmPublicKey: groupId.hexString,
                                                        using: dependencies
                                                    ),
                                                    timestamp: 1234567890
                                                )
                                            ]
                                        )
                                    ),
                                    category: .standard,
                                    requestTimeout: Network.defaultTimeout,
                                    overallTimeout: nil
                                )
                            }
                            .wasCalled(exactly: 1, timeout: .milliseconds(100))
                    }
                    
                    // MARK: ---- does not subscribe if push notifications are disabled
                    it("does not subscribe if push notifications are disabled") {
                        /// Prevent the ConfigSyncJob network request (which would fail due to the network response mocking)
                        /// by making the `libSession` cache appear empty
                        try await mockLibSessionCache.when { $0.isEmpty }.thenReturn(true)
                        try await mockUserDefaults
                            .when { $0.string(forKey: UserDefaults.StringKey.deviceToken.rawValue) }
                            .thenReturn(Data([5, 4, 3, 2, 1]).toHexString())
                        try await mockUserDefaults
                            .when { $0.bool(forKey: UserDefaults.BoolKey.isUsingFullAPNs.rawValue) }
                            .thenReturn(false)
                        
                        _ = try? await MessageSender.createGroup(
                            name: "TestGroupName",
                            description: nil,
                            displayPicture: nil,
                            displayPictureCropRect: nil,
                            members: [
                                ("051111111111111111111111111111111111111111111111111111111111111111", nil)
                            ],
                            using: dependencies
                        )
                        
                        await mockNetwork
                            .verify {
                                try await $0.send(
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
                    
                    // MARK: ---- does not subscribe if there is no push token
                    it("does not subscribe if there is no push token") {
                        /// Prevent the ConfigSyncJob network request (which would fail due to the network response mocking)
                        /// by making the `libSession` cache appear empty
                        try await mockLibSessionCache.when { $0.isEmpty }.thenReturn(true)
                        try await mockUserDefaults
                            .when { $0.string(forKey: UserDefaults.StringKey.deviceToken.rawValue) }
                            .thenReturn(nil)
                        try await mockUserDefaults
                            .when { $0.bool(forKey: UserDefaults.BoolKey.isUsingFullAPNs.rawValue) }
                            .thenReturn(true)
                        
                        _ = try? await MessageSender.createGroup(
                            name: "TestGroupName",
                            description: nil,
                            displayPicture: nil,
                            displayPictureCropRect: nil,
                            members: [
                                ("051111111111111111111111111111111111111111111111111111111111111111", nil)
                            ],
                            using: dependencies
                        )
                        
                        await mockNetwork
                            .verify {
                                try await $0.send(
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
                }
            }
            
            // MARK: -- when adding members to a group
            context("when adding members to a group") {
                beforeEach {
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
                        .thenReturn(Network.BatchResponse.mockAddMemberConfigSyncResponse)
                    
                    // Rekey a couple of times to increase the key generation to 1
                    var fakeHash1: [CChar] = "fakehash1".cString(using: .utf8)!
                    var fakeHash2: [CChar] = "fakehash2".cString(using: .utf8)!
                    var pushResult: UnsafePointer<UInt8>? = nil
                    var pushResultLen: Int = 0
                    _ = groups_keys_rekey(groupKeysConf, groupInfoConf, groupMembersConf, &pushResult, &pushResultLen)
                    _ = groups_keys_load_message(groupKeysConf, &fakeHash1, pushResult, pushResultLen, 1234567890, groupInfoConf, groupMembersConf)
                    _ = groups_keys_rekey(groupKeysConf, groupInfoConf, groupMembersConf, &pushResult, &pushResultLen)
                    _ = groups_keys_load_message(groupKeysConf, &fakeHash2, pushResult, pushResultLen, 1234567890, groupInfoConf, groupMembersConf)
                    
                    mockStorage.write { db in
                        try SessionThread.upsert(
                            db,
                            id: groupId.hexString,
                            variant: .group,
                            values: SessionThread.TargetValues(
                                creationDateTimestamp: .setTo(1234567890),
                                shouldBeVisible: .setTo(true)
                            ),
                            using: dependencies
                        )
                        
                        try ClosedGroup(
                            threadId: groupId.hexString,
                            name: "TestGroup",
                            formationTimestamp: 1234567890,
                            shouldPoll: true,
                            groupIdentityPrivateKey: groupSecretKey,
                            authData: nil,
                            invited: false
                        ).upsert(db)
                    }
                }
                
                // MARK: ---- throws if the current user is not an admin
                it("throws if the current user is not an admin") {
                    mockStorage.write { db in
                        try ClosedGroup
                            .updateAll(
                                db,
                                ClosedGroup.Columns.groupIdentityPrivateKey.set(to: nil)
                            )
                    }
                    
                    await expect {
                        try await MessageSender.addGroupMembers(
                            groupSessionId: groupId.hexString,
                            members: [
                                ("051111111111111111111111111111111111111111111111111111111111111112", nil)
                            ],
                            allowAccessToHistoricMessages: false,
                            using: dependencies
                        )
                    }.to(throwError(MessageError.requiresGroupIdentityPrivateKey))
                    
                    let members: [GroupMember]? = mockStorage.read { db in try GroupMember.fetchAll(db) }
                    expect(groups_members_size(groupMembersConf)).to(equal(0))
                    expect(members?.count).to(equal(0))
                }
                
                // MARK: ---- adds the member to the database in the sending state
                it("adds the member to the database in the sending state") {
                    await expect {
                        try await MessageSender.addGroupMembers(
                            groupSessionId: groupId.hexString,
                            members: [
                                ("051111111111111111111111111111111111111111111111111111111111111112", nil)
                            ],
                            allowAccessToHistoricMessages: false,
                            using: dependencies
                        )
                    }.toNot(throwError())
                    
                    let members: [GroupMember]? = mockStorage.read { db in try GroupMember.fetchAll(db) }
                    expect(members?.count).to(equal(1))
                    expect(members?.first?.profileId)
                        .to(equal("051111111111111111111111111111111111111111111111111111111111111112"))
                    expect(members?.first?.role).to(equal(.standard))
                    expect(members?.first?.roleStatus).to(equal(.sending))
                }
                
                // MARK: ---- adds the member to GROUP_MEMBERS
                it("adds the member to GROUP_MEMBERS") {
                    await expect {
                        try await MessageSender.addGroupMembers(
                            groupSessionId: groupId.hexString,
                            members: [
                                ("051111111111111111111111111111111111111111111111111111111111111112", nil)
                            ],
                            allowAccessToHistoricMessages: false,
                            using: dependencies
                        )
                    }.toNot(throwError())
                    
                    expect(groups_members_size(groupMembersConf)).to(equal(1))
                    
                    let members: Set<GroupMember>? = try? LibSession.extractMembers(
                        from: groupMembersConf,
                        groupSessionId: groupId
                    )
                    expect(members?.count).to(equal(1))
                    expect(members?.first?.profileId)
                        .to(equal("051111111111111111111111111111111111111111111111111111111111111112"))
                    expect(members?.first?.role).to(equal(.standard))
                    expect(members?.first?.roleStatus).to(equal(.sending))
                }
                
                // MARK: ---- and granting access to historic messages
                context("and granting access to historic messages") {
                    beforeEach {
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
                            .thenReturn(Network.BatchResponse.mockAddMemberHistoricConfigSyncResponse)
                    }
                    
                    // MARK: ---- performs a supplemental key rotation
                    it("performs a supplemental key rotation") {
                        let initialKeyRotation: Int = try LibSession.currentGeneration(
                            groupSessionId: groupId,
                            using: dependencies
                        )
                        
                        await expect {
                            try await MessageSender.addGroupMembers(
                                groupSessionId: groupId.hexString,
                                members: [
                                    ("051111111111111111111111111111111111111111111111111111111111111112", nil)
                                ],
                                allowAccessToHistoricMessages: true,
                                using: dependencies
                            )
                        }.toNot(throwError())
                        
                        // Can't actually detect a supplemental rotation directly but can check that the
                        // keys generation didn't increase
                        let result: Int = try LibSession.currentGeneration(
                            groupSessionId: groupId,
                            using: dependencies
                        )
                        expect(result).to(equal(initialKeyRotation))
                    }
                    
                    // MARK: ---- includes the supplemental key rotation request as a before sequence request in the config sync job
                    it("includes the supplemental key rotation request as a before sequence request in the config sync job") {
                        let requestDataString: String = "ZDE6IzI0OhOKDnbpLN3QJVbKzR8mOmjn6gXmeUFdTDE6K" +
                            "2wxNDA669s6Q2aETGZ5agGXfVVrC8Q9JA4bIoqv5iWyQWjttPhqDK2IZHXGVDZ/Kaz9tEq2Rl" +
                            "r2B9/neDBUFPtH3haJFN/zkIq1dAIwkgQQ4xJK00zWvZt6HejV1Fy6W9eI1oRJJny0++5+hxp" +
                            "LPczVOFKOPs+rrB3aUpMsNUnJHOEhW9g6zi/UPjuCWTnnvpxlMTpHaTFlMTp+NjQ6dKi86jZJ" +
                            "l3oiJEA5h5pBE5oOJHQNvtF8GOcsYwrIFTZKnI7AGkBSu1TxP0xLWwTUzjOGMgmKvlIgkQ6e9" +
                            "r3JBmU="
                        
                        await expect {
                            try await MessageSender.addGroupMembers(
                                groupSessionId: groupId.hexString,
                                members: [
                                    ("051111111111111111111111111111111111111111111111111111111111111112", nil)
                                ],
                                allowAccessToHistoricMessages: true,
                                using: dependencies
                            )
                        }.toNot(throwError())
                        
                        // If there is a pending keys config then merge it to complete the process
                        var pushResult: UnsafePointer<UInt8>? = nil
                        var pushResultLen: Int = 0
                        
                        if groups_keys_pending_config(groupKeysConf, &pushResult, &pushResultLen) {
                            // Rekey a couple of times to increase the key generation to 1
                            var fakeHash3: [CChar] = "fakehash3".cString(using: .utf8)!
                            _ = groups_keys_load_message(groupKeysConf, &fakeHash3, pushResult, pushResultLen, 1234567890, groupInfoConf, groupMembersConf)
                        }
                        
                        await mockJobRunner
                            .verify {
                                $0.add(
                                    .any,
                                    job: Job(
                                        variant: .configurationSync,
                                        threadId: groupId.hexString,
                                        transientData: ConfigurationSyncJob.AdditionalTransientData(
                                            beforeSequenceRequests: [
                                                try Network.StorageServer.preparedUnrevokeSubaccounts(
                                                    subaccountsToUnrevoke: [Array("TestSubAccountToken".data(using: .utf8)!)],
                                                    authMethod: Authentication.groupAdmin(
                                                        groupSessionId: groupId,
                                                        ed25519SecretKey: Array(groupSecretKey)
                                                    ),
                                                    using: dependencies
                                                ),
                                                try Network.StorageServer.preparedSendMessage(
                                                    request: Network.StorageServer.SendMessageRequest(
                                                        recipient: groupId.hexString,
                                                        namespace: .configGroupKeys,
                                                        data: Data(base64Encoded: requestDataString)!,
                                                        ttl: ConfigDump.Variant.groupKeys.ttl,
                                                        timestampMs: UInt64(1234567890000),
                                                        authMethod: Authentication.groupAdmin(
                                                            groupSessionId: groupId,
                                                            ed25519SecretKey: Array(groupSecretKey)
                                                        )
                                                    ),
                                                    using: dependencies
                                                )
                                            ],
                                            afterSequenceRequests: [],
                                            requireAllBatchResponses: true,
                                            requireAllRequestsSucceed: true,
                                            customAuthMethod: nil
                                        )
                                    ),
                                    initialDependencies: []
                                )
                            }
                            .wasCalled(exactly: 1, timeout: .milliseconds(100))
                    }
                    
                    // MARK: ---- schedules member invite jobs
                    it("schedules member invite jobs") {
                        await expect {
                            try await MessageSender.addGroupMembers(
                                groupSessionId: groupId.hexString,
                                members: [
                                    ("051111111111111111111111111111111111111111111111111111111111111112", nil)
                                ],
                                allowAccessToHistoricMessages: true,
                                using: dependencies
                            )
                        }.toNot(throwError())
                        
                        await mockJobRunner
                            .verify {
                                $0.add(
                                    .any,
                                    job: Job(
                                        variant: .groupInviteMember,
                                        threadId: groupId.hexString,
                                        details: try? GroupInviteMemberJob.Details(
                                            memberSessionIdHexString: "051111111111111111111111111111111111111111111111111111111111111112",
                                            authInfo: .groupMember(
                                                groupSessionId: SessionId(.standard, hex: TestConstants.publicKey),
                                                authData: "TestAuthData".data(using: .utf8)!
                                            )
                                        )
                                    ),
                                    initialDependencies: []
                                )
                            }
                            .wasCalled(exactly: 1, timeout: .milliseconds(100))
                    }
                    
                    // MARK: ---- adds a member change control message
                    it("adds a member change control message") {
                        await expect {
                            try await MessageSender.addGroupMembers(
                                groupSessionId: groupId.hexString,
                                members: [
                                    ("051111111111111111111111111111111111111111111111111111111111111112", nil)
                                ],
                                allowAccessToHistoricMessages: true,
                                using: dependencies
                            )
                        }.toNot(throwError())
                        
                        let interactions: [Interaction]? = mockStorage.read { db in try Interaction.fetchAll(db) }
                        expect(interactions?.count).to(equal(1))
                        expect(interactions?.first?.variant).to(equal(.infoGroupMembersUpdated))
                        expect(interactions?.first?.body).to(equal(
                            ClosedGroup.MessageInfo
                                .addedUsers(
                                    hasCurrentUser: false,
                                    names: ["0511...1112"],
                                    historyShared: true
                                )
                                .infoString(using: dependencies)
                        ))
                    }
                    
                    // MARK: ---- schedules the member change info message sending
                    it("schedules the member change info message sending") {
                        await expect {
                            try await MessageSender.addGroupMembers(
                                groupSessionId: groupId.hexString,
                                members: [
                                    ("051111111111111111111111111111111111111111111111111111111111111112", nil)
                                ],
                                allowAccessToHistoricMessages: true,
                                using: dependencies
                            )
                        }.toNot(throwError())
                        
                        await mockJobRunner
                            .verify {
                                $0.add(
                                    .any,
                                    job: Job(
                                        variant: .messageSend,
                                        threadId: groupId.hexString,
                                        details: MessageSendJob.Details(
                                            destination: .group(publicKey: groupId.hexString),
                                            message: try GroupUpdateMemberChangeMessage(
                                                changeType: .added,
                                                memberSessionIds: [
                                                    "051111111111111111111111111111111111111111111111111111111111111112"
                                                ],
                                                historyShared: true,
                                                sentTimestampMs: UInt64(1234567890000),
                                                authMethod: Authentication.groupAdmin(
                                                    groupSessionId: SessionId(.group, hex: groupId.hexString),
                                                    ed25519SecretKey: [1, 2, 3]
                                                ),
                                                using: dependencies
                                            ),
                                            requiredConfigSyncVariant: .groupMembers,
                                            ignorePermanentFailure: true
                                        )
                                    ),
                                    initialDependencies: []
                                )
                            }
                            .wasCalled(exactly: 1, timeout: .milliseconds(100))
                    }
                }
                
                // MARK: ---- and not granting access to historic messages
                context("and not granting access to historic messages") {
                    beforeEach {
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
                            .thenReturn(Network.BatchResponse.mockAddMemberConfigSyncResponse)
                    }
                    
                    // MARK: ---- performs a full key rotation
                    it("performs a full key rotation") {
                        let initialKeyRotation: Int = try LibSession.currentGeneration(
                            groupSessionId: groupId,
                            using: dependencies
                        )
                        
                        await expect {
                            try await MessageSender.addGroupMembers(
                                groupSessionId: groupId.hexString,
                                members: [
                                    ("051111111111111111111111111111111111111111111111111111111111111112", nil)
                                ],
                                allowAccessToHistoricMessages: false,
                                using: dependencies
                            )
                        }.toNot(throwError())
                        
                        // If there is a pending keys config then merge it to complete the process
                        var pushResult: UnsafePointer<UInt8>? = nil
                        var pushResultLen: Int = 0
                        
                        if groups_keys_pending_config(groupKeysConf, &pushResult, &pushResultLen) {
                            // Rekey a couple of times to increase the key generation to 1
                            var fakeHash3: [CChar] = "fakehash3".cString(using: .utf8)!
                            _ = groups_keys_load_message(groupKeysConf, &fakeHash3, pushResult, pushResultLen, 1234567890, groupInfoConf, groupMembersConf)
                        }
                        
                        let result: Int = try LibSession.currentGeneration(
                            groupSessionId: groupId,
                            using: dependencies
                        )
                        expect(result).to(beGreaterThan(initialKeyRotation))
                    }
                }
                
                // MARK: ---- includes the unrevoke subaccounts as a before sequence request in the config sync job
                it("includes the unrevoke subaccounts as a before sequence request in the config sync job") {
                    await expect {
                        try await MessageSender.addGroupMembers(
                            groupSessionId: groupId.hexString,
                            members: [
                                ("051111111111111111111111111111111111111111111111111111111111111112", nil)
                            ],
                            allowAccessToHistoricMessages: false,
                            using: dependencies
                        )
                    }.toNot(throwError())
                    
                    await mockJobRunner
                        .verify {
                            $0.add(
                                .any,
                                job: Job(
                                    variant: .configurationSync,
                                    threadId: groupId.hexString,
                                    transientData: ConfigurationSyncJob.AdditionalTransientData(
                                        beforeSequenceRequests: [
                                            try Network.StorageServer.preparedUnrevokeSubaccounts(
                                                subaccountsToUnrevoke: [Array("TestSubAccountToken".data(using: .utf8)!)],
                                                authMethod: Authentication.groupAdmin(
                                                    groupSessionId: groupId,
                                                    ed25519SecretKey: Array(groupSecretKey)
                                                ),
                                                using: dependencies
                                            )
                                        ],
                                        afterSequenceRequests: [],
                                        requireAllBatchResponses: true,
                                        requireAllRequestsSucceed: true,
                                        customAuthMethod: nil
                                    )
                                ),
                                initialDependencies: []
                            )
                        }
                        .wasCalled(exactly: 1, timeout: .milliseconds(100))
                }
                
                // MARK: ---- schedules member invite jobs
                it("schedules member invite jobs") {
                    await expect {
                        try await MessageSender.addGroupMembers(
                            groupSessionId: groupId.hexString,
                            members: [
                                ("051111111111111111111111111111111111111111111111111111111111111112", nil)
                            ],
                            allowAccessToHistoricMessages: false,
                            using: dependencies
                        )
                    }.toNot(throwError())
                    
                    await mockJobRunner
                        .verify {
                            $0.add(
                                .any,
                                job: Job(
                                    variant: .groupInviteMember,
                                    threadId: groupId.hexString,
                                    details: try? GroupInviteMemberJob.Details(
                                        memberSessionIdHexString: "051111111111111111111111111111111111111111111111111111111111111112",
                                        authInfo: .groupMember(
                                            groupSessionId: SessionId(.standard, hex: TestConstants.publicKey),
                                            authData: "TestAuthData".data(using: .utf8)!
                                        )
                                    )
                                ),
                                initialDependencies: []
                            )
                        }
                        .wasCalled(exactly: 1, timeout: .milliseconds(100))
                }
                
                // MARK: ---- adds a member change control message
                it("adds a member change control message") {
                    await expect {
                        try await MessageSender.addGroupMembers(
                            groupSessionId: groupId.hexString,
                            members: [
                                ("051111111111111111111111111111111111111111111111111111111111111112", nil)
                            ],
                            allowAccessToHistoricMessages: false,
                            using: dependencies
                        )
                    }.toNot(throwError())
                    
                    let interactions: [Interaction]? = mockStorage.read { db in try Interaction.fetchAll(db) }
                    expect(interactions?.count).to(equal(1))
                    expect(interactions?.first?.variant).to(equal(.infoGroupMembersUpdated))
                    expect(interactions?.first?.body).to(equal(
                        ClosedGroup.MessageInfo
                            .addedUsers(
                                hasCurrentUser: false,
                                names: ["0511...1112"],
                                historyShared: false
                            )
                            .infoString(using: dependencies)
                    ))
                }
                
                // MARK: ---- schedules the member change info message sending
                it("schedules the member change info message sending") {
                    await expect {
                        try await MessageSender.addGroupMembers(
                            groupSessionId: groupId.hexString,
                            members: [
                                ("051111111111111111111111111111111111111111111111111111111111111112", nil)
                            ],
                            allowAccessToHistoricMessages: false,
                            using: dependencies
                        )
                    }.toNot(throwError())
                    
                    await mockJobRunner
                        .verify {
                            $0.add(
                                .any,
                                job: Job(
                                    variant: .messageSend,
                                    threadId: groupId.hexString,
                                    details: MessageSendJob.Details(
                                        destination: .group(publicKey: groupId.hexString),
                                        message: try GroupUpdateMemberChangeMessage(
                                            changeType: .added,
                                            memberSessionIds: [
                                                "051111111111111111111111111111111111111111111111111111111111111112"
                                            ],
                                            historyShared: false,
                                            sentTimestampMs: UInt64(1234567890000),
                                            authMethod: Authentication.groupAdmin(
                                                groupSessionId: SessionId(.group, hex: groupId.hexString),
                                                ed25519SecretKey: [1, 2, 3]
                                            ),
                                            using: dependencies
                                        ),
                                        requiredConfigSyncVariant: .groupMembers,
                                        ignorePermanentFailure: true
                                    )
                                ),
                                initialDependencies: []
                            )
                        }
                        .wasCalled(exactly: 1, timeout: .milliseconds(100))
                }
                
                // MARK: ---- sorts the members in the control message deterministically
                it("sorts the members in the control message deterministically") {
                    await expect {
                        try await MessageSender.addGroupMembers(
                            groupSessionId: groupId.hexString,
                            members: [
                                ("051234111111111111111111111111111111111111111111111111111111111112", nil),
                                ("051111111111111111111111111111111111111111111111111111111111111112", nil),
                                ("05\(TestConstants.publicKey)", nil)
                            ],
                            allowAccessToHistoricMessages: false,
                            using: dependencies
                        )
                    }.toNot(throwError())
                    
                    await mockJobRunner
                        .verify {
                            $0.add(
                                .any,
                                job: Job(
                                    variant: .messageSend,
                                    threadId: groupId.hexString,
                                    details: MessageSendJob.Details(
                                        destination: .group(publicKey: groupId.hexString),
                                        message: try GroupUpdateMemberChangeMessage(
                                            changeType: .added,
                                            memberSessionIds: [
                                                "05\(TestConstants.publicKey)",
                                                "051111111111111111111111111111111111111111111111111111111111111112",
                                                "051234111111111111111111111111111111111111111111111111111111111112"
                                            ],
                                            historyShared: false,
                                            sentTimestampMs: UInt64(1234567890000),
                                            authMethod: Authentication.groupAdmin(
                                                groupSessionId: SessionId(.group, hex: groupId.hexString),
                                                ed25519SecretKey: [1, 2, 3]
                                            ),
                                            using: dependencies
                                        ),
                                        requiredConfigSyncVariant: .groupMembers,
                                        ignorePermanentFailure: true
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
}

// MARK: - Mock Types

extension Network.StorageServer.SendMessagesResponse: @retroactive Mocked {
    public static var any: Network.StorageServer.SendMessagesResponse = Network.StorageServer.SendMessagesResponse(
        hash: .any,
        swarm: .any,
        hardFork: .any,
        timeOffset: .any
    )
    public static var mock: Network.StorageServer.SendMessagesResponse = Network.StorageServer.SendMessagesResponse(
        hash: "hash",
        swarm: [:],
        hardFork: [1, 2],
        timeOffset: 0
    )
}

extension Network.StorageServer.UnrevokeSubaccountResponse: @retroactive Mocked {
    public static var any: Network.StorageServer.UnrevokeSubaccountResponse = Network.StorageServer.UnrevokeSubaccountResponse(
        swarm: .any,
        hardFork: .any,
        timeOffset: .any
    )
    public static var mock: Network.StorageServer.UnrevokeSubaccountResponse = Network.StorageServer.UnrevokeSubaccountResponse(
        swarm: [:],
        hardFork: [],
        timeOffset: 0
    )
}

extension Network.StorageServer.DeleteMessagesResponse: @retroactive Mocked {
    public static var any: Network.StorageServer.DeleteMessagesResponse = Network.StorageServer.DeleteMessagesResponse(
        swarm: .any,
        hardFork: .any,
        timeOffset: .any
    )
    public static var mock: Network.StorageServer.DeleteMessagesResponse = Network.StorageServer.DeleteMessagesResponse(
        swarm: [:],
        hardFork: [],
        timeOffset: 0
    )
}

// MARK: - Mock Batch Responses
                        
extension Network.BatchResponse {
    typealias API = Network.StorageServer
    
    // MARK: - Valid Responses
    
    fileprivate static let mockConfigSyncResponse: (ResponseInfoType, Data?) = MockNetwork.batchResponseData(
        with: [
            (API.Endpoint.sendMessage, API.SendMessagesResponse.mockBatchSubResponse()),
            (API.Endpoint.sendMessage, API.SendMessagesResponse.mockBatchSubResponse()),
            (API.Endpoint.sendMessage, API.SendMessagesResponse.mockBatchSubResponse()),
            (API.Endpoint.deleteMessages, API.DeleteMessagesResponse.mockBatchSubResponse())
        ]
    )
    
    fileprivate static let mockAddMemberConfigSyncResponse: (ResponseInfoType, Data?) = MockNetwork.batchResponseData(
        with: [
            (API.Endpoint.unrevokeSubaccount, API.UnrevokeSubaccountResponse.mockBatchSubResponse()),
            (API.Endpoint.deleteMessages, API.DeleteMessagesResponse.mockBatchSubResponse())
        ]
    )
    
    fileprivate static let mockAddMemberHistoricConfigSyncResponse: (ResponseInfoType, Data?) = MockNetwork.batchResponseData(
        with: [
            (API.Endpoint.unrevokeSubaccount, API.UnrevokeSubaccountResponse.mockBatchSubResponse()),
            (API.Endpoint.sendMessage, API.SendMessagesResponse.mockBatchSubResponse()),
            (API.Endpoint.deleteMessages, API.DeleteMessagesResponse.mockBatchSubResponse())
        ]
    )
}
