// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import Quick
import Nimble
import SessionUtil
import SessionUtilitiesKit
import SessionUIKit

@testable import SessionMessagingKit

class MessageReceiverGroupsSpec: QuickSpec {
    override class func spec() {
        // MARK: Configuration
        
        let groupSeed: Data = Data(hex: "0123456789abcdef0123456789abcdeffedcba9876543210fedcba9876543210")
        let groupKeyPair: KeyPair = Crypto().generate(.ed25519KeyPair(seed: groupSeed))!
        @TestState var groupId: SessionId! = SessionId(.group, hex: "03cbd569f56fb13ea95a3f0c05c331cc24139c0090feb412069dc49fab34406ece")
        @TestState var groupSecretKey: Data! = Data(hex:
            "0123456789abcdef0123456789abcdeffedcba9876543210fedcba9876543210" +
            "cbd569f56fb13ea95a3f0c05c331cc24139c0090feb412069dc49fab34406ece"
        )
        @TestState var dependencies: TestDependencies! = TestDependencies { dependencies in
            dependencies.dateNow = Date(timeIntervalSince1970: 1234567890)
            dependencies.forceSynchronous = true
            dependencies.setMockableValue(JSONEncoder.OutputFormatting.sortedKeys)  // Deterministic ordering
        }
        @TestState(singleton: .storage, in: dependencies) var mockStorage: Storage! = SynchronousStorage(
            customWriter: try! DatabaseQueue(),
            migrationTargets: [
                SNUtilitiesKit.self,
                SNMessagingKit.self,
                SNUIKit.self
            ],
            using: dependencies,
            initialData: { db in
                try Identity(variant: .x25519PublicKey, data: Data(hex: TestConstants.publicKey)).insert(db)
                try Identity(variant: .x25519PrivateKey, data: Data(hex: TestConstants.privateKey)).insert(db)
                try Identity(variant: .ed25519PublicKey, data: Data(hex: TestConstants.edPublicKey)).insert(db)
                try Identity(variant: .ed25519SecretKey, data: Data(hex: TestConstants.edSecretKey)).insert(db)
                
                try Profile(
                    id: "05\(TestConstants.publicKey)",
                    name: "TestCurrentUser"
                ).insert(db)
            }
        )
        @TestState(defaults: .standard, in: dependencies) var mockUserDefaults: MockUserDefaults! = MockUserDefaults(
            initialSetup: { userDefaults in
                userDefaults.when { $0.string(forKey: .any) }.thenReturn(nil)
            }
        )
        @TestState(singleton: .jobRunner, in: dependencies) var mockJobRunner: MockJobRunner! = MockJobRunner(
            initialSetup: { jobRunner in
                jobRunner
                    .when { $0.jobInfoFor(jobs: .any, state: .any, variant: .any) }
                    .thenReturn([:])
                jobRunner
                    .when { $0.add(.any, job: .any, dependantJob: .any, canStartJob: .any, using: .any) }
                    .thenReturn(nil)
            }
        )
        @TestState(singleton: .network, in: dependencies) var mockNetwork: MockNetwork! = MockNetwork(
            initialSetup: { network in
                network
                    .when { $0.send(.selectedNetworkRequest(.any, to: .any, with: .any, timeout: .any, using: .any)) }
                    .thenReturn(MockNetwork.response(with: FileUploadResponse(id: "1")))
            }
        )
        @TestState(singleton: .crypto, in: dependencies) var mockCrypto: MockCrypto! = MockCrypto(
            initialSetup: { crypto in
                crypto
                    .when { try $0.tryGenerate(.signature(message: .any, secretKey: .any)) }
                    .thenReturn(Authentication.Signature.standard(signature: "TestSignature".bytes))
                crypto
                    .when { $0.verify(.signature(message: .any, publicKey: .any, signature: .any)) }
                    .thenReturn(true)
            }
        )
        @TestState(cache: .general, in: dependencies) var mockGeneralCache: MockGeneralCache! = MockGeneralCache(
            initialSetup: { cache in
                cache.when { $0.sessionId }.thenReturn(SessionId(.standard, hex: TestConstants.publicKey))
            }
        )
        @TestState var secretKey: [UInt8]! = Array(Data(hex: TestConstants.edSecretKey))
        @TestState var groupEdPK: [UInt8]! = groupKeyPair.publicKey
        @TestState var groupEdSK: [UInt8]! = groupKeyPair.secretKey
        @TestState var userGroupsConfig: SessionUtil.Config! = {
            var conf: UnsafeMutablePointer<config_object>!
            _ = user_groups_init(&conf, &secretKey, nil, 0, nil)
            
            return .object(conf)
        }()
        @TestState var convoInfoVolatileConfig: SessionUtil.Config! = {
            var conf: UnsafeMutablePointer<config_object>!
            _ = convo_info_volatile_init(&conf, &secretKey, nil, 0, nil)
            
            return .object(conf)
        }()
        @TestState var groupInfoConf: UnsafeMutablePointer<config_object>! = {
            var conf: UnsafeMutablePointer<config_object>!
            _ = groups_info_init(&conf, &groupEdPK, &groupEdSK, nil, 0, nil)
            
            return conf
        }()
        @TestState var groupMembersConf: UnsafeMutablePointer<config_object>! = {
            var conf: UnsafeMutablePointer<config_object>!
            _ = groups_members_init(&conf, &groupEdPK, &groupEdSK, nil, 0, nil)
            
            return conf
        }()
        @TestState var groupInfoConfig: SessionUtil.Config! = .object(groupInfoConf)
        @TestState var groupMembersConfig: SessionUtil.Config! = .object(groupMembersConf)
        @TestState var groupKeysConfig: SessionUtil.Config! = {
            var groupKeysConf: UnsafeMutablePointer<config_group_keys>!
            _ = groups_keys_init(&groupKeysConf, &secretKey, &groupEdPK, &groupEdSK, groupInfoConf, groupMembersConf, nil, 0, nil)
            
            return .groupKeys(groupKeysConf, info: groupInfoConf, members: groupMembersConf)
        }()
        @TestState(cache: .sessionUtil, in: dependencies) var mockSessionUtilCache: MockSessionUtilCache! = MockSessionUtilCache(
            initialSetup: { cache in
                let userSessionId: SessionId = SessionId(.standard, hex: TestConstants.publicKey)
                
                cache
                    .when { $0.setConfig(for: .any, sessionId: .any, to: .any) }
                    .thenReturn(())
                cache
                    .when { $0.config(for: .userGroups, sessionId: userSessionId) }
                    .thenReturn(Atomic(userGroupsConfig))
                cache
                    .when { $0.config(for: .convoInfoVolatile, sessionId: userSessionId) }
                    .thenReturn(Atomic(convoInfoVolatileConfig))
                cache
                    .when { $0.config(for: .groupInfo, sessionId: groupId) }
                    .thenReturn(Atomic(groupInfoConfig))
                cache
                    .when { $0.config(for: .groupMembers, sessionId: groupId) }
                    .thenReturn(Atomic(groupMembersConfig))
                cache
                    .when { $0.config(for: .groupKeys, sessionId: groupId) }
                    .thenReturn(Atomic(groupKeysConfig))
            }
        )
        @TestState(singleton: .groupsPoller, in: dependencies) var mockGroupsPoller: MockPoller! = MockPoller(
            initialSetup: { poller in
                poller
                    .when { $0.startIfNeeded(for: .any, using: .any) }
                    .thenReturn(())
            }
        )
        
        // MARK: - a MessageReceiver dealing with Groups
        describe("a MessageReceiver dealing with Groups") {
            // MARK: -- when receiving a group invigation
            context("when receiving a group invigation") {
                @TestState var inviteMessage: GroupUpdateInviteMessage! = {
                    let result: GroupUpdateInviteMessage? = try? GroupUpdateInviteMessage(
                        inviteeSessionIdHexString: "TestId",
                        groupSessionId: groupId,
                        groupName: "TestGroup",
                        memberAuthData: Data([1, 2, 3]),
                        sentTimestamp: 1234567890,
                        authMethod: Authentication.groupAdmin(
                            groupSessionId: groupId,
                            ed25519SecretKey: []
                        ),
                        using: dependencies
                    )
                    result?.sender = "051111111111111111111111111111111111111111111111111111111111111111"
                    
                    return result
                }()
                
                // MARK: ---- ignores the invitation if the signature is invalid
                it("ignores the invitation if the signature is invalid") {
                    mockCrypto
                        .when { $0.verify(.signature(message: .any, publicKey: .any, signature: .any)) }
                        .thenReturn(false)
                    
                    mockStorage.write { db in
                        try MessageReceiver.handleGroupUpdateMessage(
                            db,
                            threadId: groupId.hexString,
                            threadVariant: .group,
                            message: inviteMessage,
                            using: dependencies
                        )
                    }
                    
                    let threads: [SessionThread]? = mockStorage.read { db in try SessionThread.fetchAll(db) }
                    expect(threads).to(beEmpty())
                }
                
                // MARK: ---- with profile information
                context("with profile information") {
                    // MARK: ------ updates the profile name
                    it("updates the profile name") {
                        inviteMessage.profile = VisibleMessage.VMProfile(displayName: "TestName")
                        
                        mockStorage.write { db in
                            try MessageReceiver.handleGroupUpdateMessage(
                                db,
                                threadId: groupId.hexString,
                                threadVariant: .group,
                                message: inviteMessage,
                                using: dependencies
                            )
                        }
                        
                        let profiles: [Profile]? = mockStorage.read { db in try Profile.fetchAll(db) }
                        expect(profiles?.map { $0.name }.sorted()).to(equal(["TestCurrentUser", "TestName"]))
                    }
                    
                    // MARK: ------ schedules a displayPictureDownload job if there is a profile picture
                    it("schedules a displayPictureDownload job if there is a profile picture") {
                        inviteMessage.profile = VisibleMessage.VMProfile(
                            displayName: "TestName",
                            profileKey: Data((0..<DisplayPictureManager.aes256KeyByteLength)
                                .map { _ in 1 }),
                            profilePictureUrl: "https://www.oxen.io/1234"
                        )
                        
                        mockStorage.write { db in
                            try MessageReceiver.handleGroupUpdateMessage(
                                db,
                                threadId: groupId.hexString,
                                threadVariant: .group,
                                message: inviteMessage,
                                using: dependencies
                            )
                        }
                        
                        expect(mockJobRunner)
                            .to(call(.exactly(times: 1), matchingParameters: .all) {
                                $0.add(
                                    .any,
                                    job: Job(
                                        variant: .displayPictureDownload,
                                        shouldBeUnique: true,
                                        details: DisplayPictureDownloadJob.Details(
                                            target: .profile(
                                                id: "051111111111111111111111111111111" + "111111111111111111111111111111111",
                                                url: "https://www.oxen.io/1234",
                                                encryptionKey: Data((0..<DisplayPictureManager.aes256KeyByteLength)
                                                    .map { _ in 1 })
                                            ),
                                            timestamp: 1234567890
                                        )
                                    ),
                                    canStartJob: true,
                                    using: .any
                                )
                            })
                    }
                }
                
                // MARK: ---- creates the thread
                it("creates the thread") {
                    mockStorage.write { db in
                        try MessageReceiver.handleGroupUpdateMessage(
                            db,
                            threadId: groupId.hexString,
                            threadVariant: .group,
                            message: inviteMessage,
                            using: dependencies
                        )
                    }
                    
                    let threads: [SessionThread]? = mockStorage.read { db in try SessionThread.fetchAll(db) }
                    expect(threads?.count).to(equal(1))
                    expect(threads?.first?.id).to(equal(groupId.hexString))
                }
                
                // MARK: ---- creates the group
                it("creates the group") {
                    mockStorage.write { db in
                        try MessageReceiver.handleGroupUpdateMessage(
                            db,
                            threadId: groupId.hexString,
                            threadVariant: .group,
                            message: inviteMessage,
                            using: dependencies
                        )
                    }
                    
                    let groups: [ClosedGroup]? = mockStorage.read { db in try ClosedGroup.fetchAll(db) }
                    expect(groups?.count).to(equal(1))
                    expect(groups?.first?.id).to(equal(groupId.hexString))
                    expect(groups?.first?.name).to(equal("TestGroup"))
                }
                // MARK: ---- adds the invited control message if the thread does not exist
                it("adds the invited control message if the thread does not exist") {
                    mockStorage.write { db in
                        try MessageReceiver.handleGroupUpdateMessage(
                            db,
                            threadId: groupId.hexString,
                            threadVariant: .group,
                            message: inviteMessage,
                            using: dependencies
                        )
                    }
                    
                    let interactions: [Interaction]? = mockStorage.read { db in try Interaction.fetchAll(db) }
                    expect(interactions?.count).to(equal(1))
                    expect(interactions?.first?.body)
                        .to(equal("{\"invited\":{\"_0\":\"0511...1111\",\"_1\":\"TestGroup\"}}"))
                }
                
                // MARK: ---- does not add the invited control message if the thread already exists
                it("does not add the invited control message if the thread already exists") {
                    mockStorage.write { db in
                        try SessionThread.fetchOrCreate(
                            db,
                            id: groupId.hexString,
                            variant: .group,
                            shouldBeVisible: true,
                            calledFromConfigHandling: false,
                            using: dependencies
                        )
                    }
                    
                    mockStorage.write { db in
                        try MessageReceiver.handleGroupUpdateMessage(
                            db,
                            threadId: groupId.hexString,
                            threadVariant: .group,
                            message: inviteMessage,
                            using: dependencies
                        )
                    }
                    
                    let interactions: [Interaction]? = mockStorage.read { db in try Interaction.fetchAll(db) }
                    expect(interactions?.count).to(equal(0))
                }
            }
        }
    }
}
