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
        @TestState var groupKeyPair: KeyPair! = Crypto().generate(.ed25519KeyPair(seed: groupSeed))
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
                    .when {
                        try $0.tryGenerate(
                            .signatureSubaccount(config: .any, verificationBytes: .any, memberAuthData: .any)
                        )
                    }
                    .thenReturn(Authentication.Signature.subaccount(
                        subaccount: "TestSubAccount".bytes,
                        subaccountSig: "TestSubAccountSignature".bytes,
                        signature: "TestSignature".bytes
                    ))
                crypto
                    .when { $0.verify(.signature(message: .any, publicKey: .any, signature: .any)) }
                    .thenReturn(true)
                crypto
                    .when { $0.generate(.ed25519KeyPair(seed: .any, using: .any)) }
                    .thenReturn(groupKeyPair)
            }
        )
        @TestState(singleton: .keychain, in: dependencies) var mockKeychain: MockKeychain! = MockKeychain(
            initialSetup: { keychain in
                keychain
                    .when { try $0.data(forService: .pushNotificationAPI, key: .pushNotificationEncryptionKey) }
                    .thenReturn(Data((0..<PushNotificationAPI.encryptionKeyLength).map { _ in 1 }))
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
        @TestState(singleton: .notificationsManager, in: dependencies) var mockNotificationsManager: MockNotificationsManager! = MockNotificationsManager(
            initialSetup: { notificationsManager in
                notificationsManager
                    .when { $0.notifyUser(.any, for: .any, in: .any, applicationState: .any, using: .any) }
                    .thenReturn(())
            }
        )
        
        // MARK: -- Messages
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
        @TestState var promoteMessage: GroupUpdatePromoteMessage! = {
            let result: GroupUpdatePromoteMessage = GroupUpdatePromoteMessage(
                groupIdentitySeed: groupSeed,
                sentTimestamp: 1234567890
            )
            result.sender = "051111111111111111111111111111111111111111111111111111111111111111"
            
            return result
        }()
        
        // MARK: - a MessageReceiver dealing with Groups
        describe("a MessageReceiver dealing with Groups") {
            // MARK: -- when receiving a group invitation
            context("when receiving a group invitation") {
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
                
                // MARK: ---- adds the group to USER_GROUPS
                it("adds the group to USER_GROUPS") {
                    mockStorage.write { db in
                        try MessageReceiver.handleGroupUpdateMessage(
                            db,
                            threadId: groupId.hexString,
                            threadVariant: .group,
                            message: inviteMessage,
                            using: dependencies
                        )
                    }
                    
                    expect(user_groups_size(userGroupsConfig.conf)).to(equal(1))
                }
                
                // MARK: ---- from a sender that is not approved
                context("from a sender that is not approved") {
                    beforeEach {
                        mockStorage.write { db in
                            try Contact(
                                id: "051111111111111111111111111111111111111111111111111111111111111111",
                                isApproved: false
                            ).insert(db)
                        }
                    }
                    
                    // MARK: ------ adds the group as a pending group invitation
                    it("adds the group as a pending group invitation") {
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
                        expect(groups?.first?.invited).to(beTrue())
                    }
                    
                    // MARK: ------ adds the group to USER_GROUPS with the invited flag set to true
                    it("adds the group to USER_GROUPS with the invited flag set to true") {
                        mockStorage.write { db in
                            try MessageReceiver.handleGroupUpdateMessage(
                                db,
                                threadId: groupId.hexString,
                                threadVariant: .group,
                                message: inviteMessage,
                                using: dependencies
                            )
                        }
                        
                        var cGroupId: [CChar] = groupId.hexString.cArray.nullTerminated()
                        var userGroup: ugroups_group_info = ugroups_group_info()
                        
                        expect(user_groups_get_group(userGroupsConfig.conf, &userGroup, &cGroupId)).to(beTrue())
                        expect(userGroup.invited).to(beTrue())
                    }
                    
                    // MARK: ------ does not start the poller
                    it("does not start the poller") {
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
                        expect(groups?.first?.shouldPoll).to(beFalse())
                        
                        expect(mockGroupsPoller).toNot(call { $0.startIfNeeded(for: .any, using: .any) })
                    }
                    
                    // MARK: ------ sends a local notification about the group invite
                    it("sends a local notification about the group invite") {
                        mockUserDefaults
                            .when { $0.bool(forKey: UserDefaults.BoolKey.isMainAppActive.rawValue) }
                            .thenReturn(true)
                        
                        mockStorage.write { db in
                            try MessageReceiver.handleGroupUpdateMessage(
                                db,
                                threadId: groupId.hexString,
                                threadVariant: .group,
                                message: inviteMessage,
                                using: dependencies
                            )
                        }
                        
                        expect(mockNotificationsManager)
                            .to(call(.exactly(times: 1), matchingParameters: .all) { notificationsManager in
                                notificationsManager.notifyUser(
                                    .any,
                                    for: Interaction(
                                        id: 1,
                                        serverHash: nil,
                                        messageUuid: nil,
                                        threadId: groupId.hexString,
                                        authorId: "051111111111111111111111111111111" + "111111111111111111111111111111111",
                                        variant: .infoGroupInfoInvited,
                                        body: ClosedGroup.MessageInfo
                                            .invited("0511...1111", "TestGroup")
                                            .infoString(using: dependencies),
                                        timestampMs: 1234567890,
                                        receivedAtTimestampMs: 1234567890,
                                        wasRead: false,
                                        hasMention: false,
                                        expiresInSeconds: 0,
                                        expiresStartedAtMs: nil,
                                        linkPreviewUrl: nil,
                                        openGroupServerMessageId: nil,
                                        openGroupWhisperMods: false,
                                        openGroupWhisperTo: nil
                                    ),
                                    in: SessionThread(
                                        id: groupId.hexString,
                                        variant: .group,
                                        shouldBeVisible: true,
                                        using: dependencies
                                    ),
                                    applicationState: .active,
                                    using: .any
                                )
                            })
                    }
                }
                
                // MARK: ---- from a sender that is approved
                context("from a sender that is approved") {
                    beforeEach {
                        mockStorage.write { db in
                            try Contact(
                                id: "051111111111111111111111111111111111111111111111111111111111111111",
                                isApproved: true
                            ).insert(db)
                        }
                    }
                    
                    // MARK: ------ adds the group as a full group
                    it("adds the group as a full group") {
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
                        expect(groups?.first?.invited).to(beFalse())
                    }
                    
                    // MARK: ------ creates the group state
                    it("creates the group state") {
                        mockStorage.write { db in
                            try MessageReceiver.handleGroupUpdateMessage(
                                db,
                                threadId: groupId.hexString,
                                threadVariant: .group,
                                message: inviteMessage,
                                using: dependencies
                            )
                        }
                        
                        expect(mockSessionUtilCache)
                            .to(call(.exactly(times: 1), matchingParameters: .atLeast(2)) {
                                $0.setConfig(for: .groupInfo, sessionId: groupId, to: .any)
                            })
                        expect(mockSessionUtilCache)
                            .to(call(.exactly(times: 1), matchingParameters: .atLeast(2)) {
                                $0.setConfig(for: .groupMembers, sessionId: groupId, to: .any)
                            })
                        expect(mockSessionUtilCache)
                            .to(call(.exactly(times: 1), matchingParameters: .atLeast(2)) {
                                $0.setConfig(for: .groupKeys, sessionId: groupId, to: .any)
                            })
                    }
                    
                    // MARK: ------ adds the group to USER_GROUPS with the invited flag set to false
                    it("adds the group to USER_GROUPS with the invited flag set to false") {
                        mockStorage.write { db in
                            try MessageReceiver.handleGroupUpdateMessage(
                                db,
                                threadId: groupId.hexString,
                                threadVariant: .group,
                                message: inviteMessage,
                                using: dependencies
                            )
                        }
                        
                        var cGroupId: [CChar] = groupId.hexString.cArray.nullTerminated()
                        var userGroup: ugroups_group_info = ugroups_group_info()
                        
                        expect(user_groups_get_group(userGroupsConfig.conf, &userGroup, &cGroupId)).to(beTrue())
                        expect(userGroup.invited).to(beFalse())
                    }
                    
                    // MARK: ------ starts the poller
                    it("starts the poller") {
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
                        expect(groups?.first?.shouldPoll).to(beTrue())
                        
                        expect(mockGroupsPoller).to(call(.exactly(times: 1), matchingParameters: .all) {
                            $0.startIfNeeded(for: groupId.hexString, using: .any)
                        })
                    }
                    
                    // MARK: ------ does not send a local notification about the group invite
                    it("does not send a local notification about the group invite") {
                        mockStorage.write { db in
                            try MessageReceiver.handleGroupUpdateMessage(
                                db,
                                threadId: groupId.hexString,
                                threadVariant: .group,
                                message: inviteMessage,
                                using: dependencies
                            )
                        }
                        
                        expect(mockNotificationsManager)
                            .toNot(call { notificationsManager in
                                notificationsManager.notifyUser(
                                    .any,
                                    for: .any,
                                    in: .any,
                                    applicationState: .any,
                                    using: .any
                                )
                            })
                    }
                    
                    // MARK: ------ and push notifications are disabled
                    context("and push notifications are disabled") {
                        beforeEach {
                            mockUserDefaults
                                .when { $0.string(forKey: UserDefaults.StringKey.deviceToken.rawValue) }
                                .thenReturn(nil)
                            mockUserDefaults
                                .when { $0.bool(forKey: UserDefaults.BoolKey.isUsingFullAPNs.rawValue) }
                                .thenReturn(false)
                        }
                        
                        // MARK: -------- does not subscribe for push notifications
                        it("does not subscribe for push notifications") {
                            mockStorage.write { db in
                                try MessageReceiver.handleGroupUpdateMessage(
                                    db,
                                    threadId: groupId.hexString,
                                    threadVariant: .group,
                                    message: inviteMessage,
                                    using: dependencies
                                )
                            }
                            
                            expect(mockNetwork)
                                .toNot(call { network in
                                    network.send(
                                        .selectedNetworkRequest(
                                            .any,
                                            to: PushNotificationAPI.server.value(using: dependencies),
                                            with: PushNotificationAPI.serverPublicKey,
                                            timeout: HTTP.defaultTimeout,
                                            using: .any
                                        )
                                    )
                                })
                        }
                    }
                    
                    // MARK: ------ and push notifications are enabled
                    context("and push notifications are enabled") {
                        beforeEach {
                            mockUserDefaults
                                .when { $0.string(forKey: UserDefaults.StringKey.deviceToken.rawValue) }
                                .thenReturn(Data([5, 4, 3, 2, 1]).toHexString())
                            mockUserDefaults
                                .when { $0.bool(forKey: UserDefaults.BoolKey.isUsingFullAPNs.rawValue) }
                                .thenReturn(true)
                        }
                        
                        // MARK: -------- subscribes for push notifications
                        it("subscribes for push notifications") {
                            mockStorage.write { db in
                                try MessageReceiver.handleGroupUpdateMessage(
                                    db,
                                    threadId: groupId.hexString,
                                    threadVariant: .group,
                                    message: inviteMessage,
                                    using: dependencies
                                )
                            }
                            
                            let expectedRequest: URLRequest = mockStorage.read(using: dependencies) { db in
                                try PushNotificationAPI
                                    .preparedSubscribe(
                                        db,
                                        token: Data([5, 4, 3, 2, 1]),
                                        sessionIds: [groupId],
                                        using: dependencies
                                    )
                                    .request
                            }!
                            
                            expect(mockNetwork)
                                .to(call(.exactly(times: 1), matchingParameters: .all) { network in
                                    network.send(
                                        .selectedNetworkRequest(
                                            expectedRequest,
                                            to: PushNotificationAPI.server.value(using: dependencies),
                                            with: PushNotificationAPI.serverPublicKey,
                                            timeout: HTTP.defaultTimeout,
                                            using: .any
                                        )
                                    )
                                })
                        }
                    }
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
            
            // MARK: -- when receiving a group promotion
            context("when receiving a group promotion") {
                @TestState var result: Result<Void, Error>!
                
                beforeEach {
                    var cMemberId: [CChar] = "05\(TestConstants.publicKey)".cArray
                    var member: config_group_member = config_group_member()
                    _ = groups_members_get_or_construct(groupMembersConf, &member, &cMemberId)
                    member.name = "TestName".toLibSession()
                    groups_members_set(groupMembersConf, &member)
                    
                    mockStorage.write(using: dependencies) { db in
                        try SessionThread.fetchOrCreate(
                            db,
                            id: groupId.hexString,
                            variant: .group,
                            shouldBeVisible: true,
                            calledFromConfigHandling: false,
                            using: dependencies
                        )
                        
                        try ClosedGroup(
                            threadId: groupId.hexString,
                            name: "TestGroup",
                            formationTimestamp: 1234567890,
                            shouldPoll: true,
                            groupIdentityPrivateKey: nil,
                            authData: Data([1, 2, 3]),
                            invited: false
                        ).upsert(db)
                    }
                }
                
                // MARK: ---- promotes the user to admin within the group
                it("promotes the user to admin within the group") {
                    mockCrypto
                        .when { $0.generate(.ed25519KeyPair(seed: .any, using: .any)) }
                        .thenReturn(nil)
                    
                    mockStorage.write { db in
                        result = Result(try MessageReceiver.handleGroupUpdateMessage(
                            db,
                            threadId: groupId.hexString,
                            threadVariant: .group,
                            message: promoteMessage,
                            using: dependencies
                        ))
                    }
                    
                    expect(result.failure).to(matchError(MessageReceiverError.invalidMessage))
                }
                
                // MARK: ---- updates the GROUP_KEYS state correctly
                it("updates the GROUP_KEYS state correctly") {
                    mockCrypto
                        .when { $0.generate(.ed25519KeyPair(seed: .any, using: .any)) }
                        .thenReturn(nil)
                    
                    mockStorage.write { db in
                        try MessageReceiver.handleGroupUpdateMessage(
                            db,
                            threadId: groupId.hexString,
                            threadVariant: .group,
                            message: promoteMessage,
                            using: dependencies
                        )
                    }
                    
                    expect(SessionUtil.isAdmin(groupSessionId: groupId, using: dependencies))
                        .to(beTrue())
                }
                
                // MARK: ---- replaces the memberAuthData with the admin key in the database
                it("replaces the memberAuthData with the admin key in the database") {
                    mockStorage.write { db in
                        try ClosedGroup(
                            threadId: groupId.hexString,
                            name: "TestGroup",
                            formationTimestamp: 1234567890,
                            shouldPoll: true,
                            groupIdentityPrivateKey: nil,
                            authData: Data([1, 2, 3]),
                            invited: false
                        ).upsert(db)
                    }
                    
                    mockStorage.write { db in
                        try MessageReceiver.handleGroupUpdateMessage(
                            db,
                            threadId: groupId.hexString,
                            threadVariant: .group,
                            message: promoteMessage,
                            using: dependencies
                        )
                    }
                    
                    let groups: [ClosedGroup]? = mockStorage.read { db in try ClosedGroup.fetchAll(db) }
                    expect(groups?.count).to(equal(1))
                    expect(groups?.first?.groupIdentityPrivateKey).to(equal(Data(groupKeyPair.secretKey)))
                    expect(groups?.first?.authData).to(beNil())
                }
                
                // MARK: ---- updates a standard member entry to an accepted admin
                it("updates a standard member entry to an accepted admin") {
                    mockStorage.write { db in
                        try GroupMember(
                            groupId: groupId.hexString,
                            profileId: "05\(TestConstants.publicKey)",
                            role: .standard,
                            roleStatus: .accepted,
                            isHidden: false
                        ).insert(db)
                    }
                    
                    mockStorage.write { db in
                        try MessageReceiver.handleGroupUpdateMessage(
                            db,
                            threadId: groupId.hexString,
                            threadVariant: .group,
                            message: promoteMessage,
                            using: dependencies
                        )
                    }
                    
                    let members: [GroupMember]? = mockStorage.read { db in try GroupMember.fetchAll(db) }
                    expect(members?.count).to(equal(1))
                    expect(members?.first?.role).to(equal(.admin))
                    expect(members?.first?.roleStatus).to(equal(.accepted))
                }
                
                // MARK: ---- updates a failed admin entry to an accepted admin
                it("updates a failed admin entry to an accepted admin") {
                    mockStorage.write { db in
                        try GroupMember(
                            groupId: groupId.hexString,
                            profileId: "05\(TestConstants.publicKey)",
                            role: .admin,
                            roleStatus: .failed,
                            isHidden: false
                        ).insert(db)
                    }
                    
                    mockStorage.write { db in
                        try MessageReceiver.handleGroupUpdateMessage(
                            db,
                            threadId: groupId.hexString,
                            threadVariant: .group,
                            message: promoteMessage,
                            using: dependencies
                        )
                    }
                    
                    let members: [GroupMember]? = mockStorage.read { db in try GroupMember.fetchAll(db) }
                    expect(members?.count).to(equal(1))
                    expect(members?.first?.role).to(equal(.admin))
                    expect(members?.first?.roleStatus).to(equal(.accepted))
                }
                
                // MARK: ---- updates a pending admin entry to an accepted admin
                it("updates a pending admin entry to an accepted admin") {
                    mockStorage.write { db in
                        try GroupMember(
                            groupId: groupId.hexString,
                            profileId: "05\(TestConstants.publicKey)",
                            role: .admin,
                            roleStatus: .pending,
                            isHidden: false
                        ).insert(db)
                    }
                    
                    mockStorage.write { db in
                        try MessageReceiver.handleGroupUpdateMessage(
                            db,
                            threadId: groupId.hexString,
                            threadVariant: .group,
                            message: promoteMessage,
                            using: dependencies
                        )
                    }
                    
                    let members: [GroupMember]? = mockStorage.read { db in try GroupMember.fetchAll(db) }
                    expect(members?.count).to(equal(1))
                    expect(members?.first?.role).to(equal(.admin))
                    expect(members?.first?.roleStatus).to(equal(.accepted))
                }
                
                // MARK: ---- updates a sending admin entry to an accepted admin
                it("updates a sending admin entry to an accepted admin") {
                    mockStorage.write { db in
                        try GroupMember(
                            groupId: groupId.hexString,
                            profileId: "05\(TestConstants.publicKey)",
                            role: .admin,
                            roleStatus: .sending,
                            isHidden: false
                        ).insert(db)
                    }
                    
                    mockStorage.write { db in
                        try MessageReceiver.handleGroupUpdateMessage(
                            db,
                            threadId: groupId.hexString,
                            threadVariant: .group,
                            message: promoteMessage,
                            using: dependencies
                        )
                    }
                    
                    let members: [GroupMember]? = mockStorage.read { db in try GroupMember.fetchAll(db) }
                    expect(members?.count).to(equal(1))
                    expect(members?.first?.role).to(equal(.admin))
                    expect(members?.first?.roleStatus).to(equal(.accepted))
                }
                
                // MARK: ---- updates the member in GROUP_MEMBERS from a standard member to be an approved admin
                it("updates the member in GROUP_MEMBERS from a standard member to be an approved admin") {
                    mockStorage.write { db in
                        try MessageReceiver.handleGroupUpdateMessage(
                            db,
                            threadId: groupId.hexString,
                            threadVariant: .group,
                            message: promoteMessage,
                            using: dependencies
                        )
                    }
                    
                    var cMemberId: [CChar] = "05\(TestConstants.publicKey)".cArray
                    var groupMember: config_group_member = config_group_member()
                    _ = groups_members_get(groupMembersConf, &groupMember, &cMemberId)
                    expect(groupMember.admin).to(beTrue())
                    expect(groupMember.promoted).to(equal(0))
                }
                
                // MARK: ---- updates the member in GROUP_MEMBERS from a pending admin to be an approved admin
                it("updates the member in GROUP_MEMBERS from a pending admin to be an approved admin") {
                    var cMemberId: [CChar] = "05\(TestConstants.publicKey)".cArray
                    var initialMember: config_group_member = config_group_member()
                    _ = groups_members_get_or_construct(groupMembersConf, &initialMember, &cMemberId)
                    initialMember.promoted = 1
                    groups_members_set(groupMembersConf, &initialMember)
                    
                    mockStorage.write { db in
                        try MessageReceiver.handleGroupUpdateMessage(
                            db,
                            threadId: groupId.hexString,
                            threadVariant: .group,
                            message: promoteMessage,
                            using: dependencies
                        )
                    }
                    
                    var groupMember: config_group_member = config_group_member()
                    _ = groups_members_get(groupMembersConf, &groupMember, &cMemberId)
                    expect(groupMember.admin).to(beTrue())
                    expect(groupMember.promoted).to(equal(0))
                }
            }
        }
    }
}

// MARK: - Convenience

private extension SessionUtil.Config {
    var conf: UnsafeMutablePointer<config_object>? {
        switch self {
            case .object(let conf): return conf
            default: return nil
        }
    }
}

private extension Result {
    var failure: Failure? {
        switch self {
            case .success: return nil
            case .failure(let error): return error
        }
    }
}