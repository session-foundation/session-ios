// Copyright © 2026 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import Quick
import Nimble
import SessionUtil
import SessionUtilitiesKit
import SessionUIKit
import TestUtilities

@testable import SessionNetworkingKit
@testable import SessionMessagingKit

class MessageReceiverGroupsSpec: AsyncSpec {
    override class func spec() {
        @TestState var fixture: MessageReceiverGroupsTestFixture!
        
        beforeEach {
            fixture = try await MessageReceiverGroupsTestFixture.create()
        }
        
        // MARK: - a MessageReceiver dealing with Groups
        describe("a MessageReceiver dealing with Groups") {
            // MARK: -- when receiving a group invitation
            context("when receiving a group invitation") {
                // MARK: ---- throws if the admin signature fails to verify
                it("throws if the admin signature fails to verify") {
                    await fixture.mockCrypto.removeMocksFor {
                        $0.verify(.signature(message: .any, publicKey: .any, signature: .any))
                    }
                    try await fixture.mockCrypto
                        .when { $0.verify(.signature(message: .any, publicKey: .any, signature: .any)) }
                        .thenReturn(false)
                    
                    await expect {
                        try await fixture.mockStorage.write { db in
                            try MessageReceiver.handleGroupUpdateMessage(
                                db,
                                threadId: fixture.groupId.hexString,
                                threadVariant: .group,
                                message: fixture.inviteMessage,
                                decodedMessage: fixture.decodedMessage,
                                serverExpirationTimestamp: 1234567890,
                                suppressNotifications: false,
                                currentUserSessionIds: [],
                                using: fixture.dependencies
                            )
                        }
                    }.to(throwError(MessageError.invalidMessage("Unable to validate group invite")))
                }
                
                // MARK: ---- with profile information
                context("with profile information") {
                    // MARK: ------ updates the profile name
                    it("updates the profile name") {
                        fixture.inviteMessage.profile = VisibleMessage.VMProfile(displayName: "TestName")
                        
                        try await fixture.mockStorage.write { db in
                            try MessageReceiver.handleGroupUpdateMessage(
                                db,
                                threadId: fixture.groupId.hexString,
                                threadVariant: .group,
                                message: fixture.inviteMessage,
                                decodedMessage: fixture.decodedMessage,
                                serverExpirationTimestamp: 1234567890,
                                suppressNotifications: false,
                                currentUserSessionIds: [],
                                using: fixture.dependencies
                            )
                        }
                        
                        let profiles: [Profile] = try await fixture.mockStorage.read { db in try Profile.fetchAll(db) }
                        expect(profiles.map { $0.name }.sorted()).to(equal(["TestCurrentUser", "TestName"]))
                    }
                    
                    // MARK: ------ with a profile picture
                    context("with a profile picture") {
                        // MARK: ------ schedules and starts a displayPictureDownload job if running the main app
                        it("schedules and starts a displayPictureDownload job if running the main app") {
                            try await fixture.mockAppContext.when { $0.isMainApp }.thenReturn(true)
                            
                            fixture.inviteMessage.profile = VisibleMessage.VMProfile(
                                displayName: "TestName",
                                profileKey: Data((0..<DisplayPictureManager.encryptionKeySize)
                                    .map { _ in 1 }),
                                profilePictureUrl: "https://www.oxen.io/1234"
                            )
                            
                            try await fixture.mockStorage.write { db in
                                try MessageReceiver.handleGroupUpdateMessage(
                                    db,
                                    threadId: fixture.groupId.hexString,
                                    threadVariant: .group,
                                    message: fixture.inviteMessage,
                                    decodedMessage: fixture.decodedMessage,
                                    serverExpirationTimestamp: 1234567890,
                                    suppressNotifications: false,
                                    currentUserSessionIds: [],
                                    using: fixture.dependencies
                                )
                            }
                            
                            await fixture.mockJobRunner
                                .verify {
                                    $0.add(
                                        .any,
                                        job: Job(
                                            variant: .displayPictureDownload,
                                            details: DisplayPictureDownloadJob.Details(
                                                target: .profile(
                                                    id: "TestProfileId",
                                                    url: "https://www.oxen.io/1234",
                                                    encryptionKey: Data((0..<DisplayPictureManager.encryptionKeySize)
                                                        .map { _ in 1 })
                                                ),
                                                timestamp: nil
                                            )
                                        ),
                                        initialDependencies: []
                                    )
                                }
                                .wasCalled(exactly: 1, timeout: .milliseconds(100))
                        }
                        
                        // MARK: ------ schedules but does not start a displayPictureDownload job when not the main app
                        it("schedules but does not start a displayPictureDownload job when not the main app") {
                            fixture.inviteMessage.profile = VisibleMessage.VMProfile(
                                displayName: "TestName",
                                profileKey: Data((0..<DisplayPictureManager.encryptionKeySize)
                                    .map { _ in 1 }),
                                profilePictureUrl: "https://www.oxen.io/1234"
                            )
                            
                            try await fixture.mockStorage.write { db in
                                try MessageReceiver.handleGroupUpdateMessage(
                                    db,
                                    threadId: fixture.groupId.hexString,
                                    threadVariant: .group,
                                    message: fixture.inviteMessage,
                                    decodedMessage: fixture.decodedMessage,
                                    serverExpirationTimestamp: 1234567890,
                                    suppressNotifications: false,
                                    currentUserSessionIds: [],
                                    using: fixture.dependencies
                                )
                            }
                            
                            await fixture.mockJobRunner
                                .verify {
                                    $0.add(
                                        .any,
                                        job: Job(
                                            variant: .displayPictureDownload,
                                            details: DisplayPictureDownloadJob.Details(
                                                target: .profile(
                                                    id: "TestProfileId",
                                                    url: "https://www.oxen.io/1234",
                                                    encryptionKey: Data((0..<DisplayPictureManager.encryptionKeySize)
                                                        .map { _ in 1 })
                                                ),
                                                timestamp: nil
                                            )
                                        ),
                                        initialDependencies: []
                                    )
                                }
                                .wasCalled(exactly: 1, timeout: .milliseconds(100))
                        }
                    }
                }
                
                // MARK: ---- creates the thread
                it("creates the thread") {
                    try await fixture.mockStorage.write { db in
                        try MessageReceiver.handleGroupUpdateMessage(
                            db,
                            threadId: fixture.groupId.hexString,
                            threadVariant: .group,
                            message: fixture.inviteMessage,
                            decodedMessage: fixture.decodedMessage,
                            serverExpirationTimestamp: 1234567890,
                            suppressNotifications: false,
                            currentUserSessionIds: [],
                            using: fixture.dependencies
                        )
                    }
                    
                    let threads: [SessionThread] = try await fixture.mockStorage.read { db in try SessionThread.fetchAll(db) }
                    expect(threads.count).to(equal(1))
                    expect(threads.first?.id).to(equal(fixture.groupId.hexString))
                }
                
                // MARK: ---- creates the group
                it("creates the group") {
                    try await fixture.mockStorage.write { db in
                        try MessageReceiver.handleGroupUpdateMessage(
                            db,
                            threadId: fixture.groupId.hexString,
                            threadVariant: .group,
                            message: fixture.inviteMessage,
                            decodedMessage: fixture.decodedMessage,
                            serverExpirationTimestamp: 1234567890,
                            suppressNotifications: false,
                            currentUserSessionIds: [],
                            using: fixture.dependencies
                        )
                    }
                    
                    let groups: [ClosedGroup] = try await fixture.mockStorage.read { db in try ClosedGroup.fetchAll(db) }
                    expect(groups.count).to(equal(1))
                    expect(groups.first?.id).to(equal(fixture.groupId.hexString))
                    expect(groups.first?.name).to(equal("TestGroup"))
                }
                
                // MARK: ---- adds the group to USER_GROUPS
                it("adds the group to USER_GROUPS") {
                    try await fixture.mockStorage.write { db in
                        try MessageReceiver.handleGroupUpdateMessage(
                            db,
                            threadId: fixture.groupId.hexString,
                            threadVariant: .group,
                            message: fixture.inviteMessage,
                            decodedMessage: fixture.decodedMessage,
                            serverExpirationTimestamp: 1234567890,
                            suppressNotifications: false,
                            currentUserSessionIds: [],
                            using: fixture.dependencies
                        )
                    }
                    
                    expect(user_groups_size(fixture.userGroupsConfig.conf)).to(equal(1))
                }
                
                // MARK: ---- from a sender that is not approved
                context("from a sender that is not approved") {
                    beforeEach {
                        try await fixture.mockLibSessionCache
                            .when { $0.isMessageRequest(threadId: .any, threadVariant: .any) }
                            .thenReturn(true)
                        try await fixture.mockStorage.write { db in
                            try Contact(
                                id: "051111111111111111111111111111111111111111111111111111111111111111",
                                isApproved: false,
                                currentUserSessionId: SessionId(.standard, hex: TestConstants.publicKey)
                            ).insert(db)
                        }
                    }
                    
                    // MARK: ------ adds the group as a pending group invitation
                    it("adds the group as a pending group invitation") {
                        try await fixture.mockStorage.write { db in
                            try MessageReceiver.handleGroupUpdateMessage(
                                db,
                                threadId: fixture.groupId.hexString,
                                threadVariant: .group,
                                message: fixture.inviteMessage,
                                decodedMessage: fixture.decodedMessage,
                                serverExpirationTimestamp: 1234567890,
                                suppressNotifications: false,
                                currentUserSessionIds: [],
                                using: fixture.dependencies
                            )
                        }
                        
                        let groups: [ClosedGroup] = try await fixture.mockStorage.read { db in try ClosedGroup.fetchAll(db) }
                        expect(groups.count).to(equal(1))
                        expect(groups.first?.id).to(equal(fixture.groupId.hexString))
                        expect(groups.first?.invited).to(beTrue())
                    }
                    
                    // MARK: ------ adds the group to USER_GROUPS with the invited flag set to true
                    it("adds the group to USER_GROUPS with the invited flag set to true") {
                        try await fixture.mockStorage.write { db in
                            try MessageReceiver.handleGroupUpdateMessage(
                                db,
                                threadId: fixture.groupId.hexString,
                                threadVariant: .group,
                                message: fixture.inviteMessage,
                                decodedMessage: fixture.decodedMessage,
                                serverExpirationTimestamp: 1234567890,
                                suppressNotifications: false,
                                currentUserSessionIds: [],
                                using: fixture.dependencies
                            )
                        }
                        
                        var cGroupId: [CChar] = fixture.groupId.hexString.cString(using: .utf8)!
                        var userGroup: ugroups_group_info = ugroups_group_info()
                        
                        expect(user_groups_get_group(fixture.userGroupsConfig.conf, &userGroup, &cGroupId)).to(beTrue())
                        expect(userGroup.invited).to(beTrue())
                    }
                    
                    // MARK: ------ does not start the poller
                    it("does not start the poller") {
                        try await fixture.mockStorage.write { db in
                            try MessageReceiver.handleGroupUpdateMessage(
                                db,
                                threadId: fixture.groupId.hexString,
                                threadVariant: .group,
                                message: fixture.inviteMessage,
                                decodedMessage: fixture.decodedMessage,
                                serverExpirationTimestamp: 1234567890,
                                suppressNotifications: false,
                                currentUserSessionIds: [],
                                using: fixture.dependencies
                            )
                        }
                        
                        let groups: [ClosedGroup] = try await fixture.mockStorage.read { db in try ClosedGroup.fetchAll(db) }
                        expect(groups.count).to(equal(1))
                        expect(groups.first?.id).to(equal(fixture.groupId.hexString))
                        expect(groups.first?.shouldPoll).to(beFalse())
                        
                        await fixture.mockPoller
                            .verify { await $0.startIfNeeded() }
                            .wasNotCalled(timeout: .milliseconds(100))
                    }
                    
                    // MARK: ------ sends a local notification about the group invite
                    it("sends a local notification about the group invite") {
                        try await fixture.mockUserDefaults
                            .when { $0.bool(forKey: UserDefaults.BoolKey.isMainAppActive.rawValue) }
                            .thenReturn(true)
                        try await fixture.mockLibSessionCache
                            .when { $0.isMessageRequest(threadId: .any, threadVariant: .any) }
                            .thenReturn(true)
                        
                        try await fixture.mockStorage.write { db in
                            try MessageReceiver.handleGroupUpdateMessage(
                                db,
                                threadId: fixture.groupId.hexString,
                                threadVariant: .group,
                                message: fixture.inviteMessage,
                                decodedMessage: fixture.decodedMessage,
                                serverExpirationTimestamp: 1234567890,
                                suppressNotifications: false,
                                currentUserSessionIds: [],
                                using: fixture.dependencies
                            )
                        }
                        
                        await fixture.mockNotificationsManager
                            .verify {
                                $0.addNotificationRequest(
                                    content: NotificationContent(
                                        threadId: fixture.groupId.hexString,
                                        threadVariant: .group,
                                        identifier: "\(fixture.groupId.hexString)-1",
                                        category: .incomingMessage,
                                        groupingIdentifier: .messageRequest,
                                        title: Constants.app_name,
                                        body: "messageRequestsNew".localized(),
                                        sound: .defaultNotificationSound,
                                        applicationState: .active
                                    ),
                                    notificationSettings: Preferences.NotificationSettings(
                                        previewType: .nameAndPreview,
                                        sound: .defaultNotificationSound,
                                        mentionsOnly: false,
                                        mutedUntil: nil
                                    ),
                                    extensionBaseUnreadCount: nil
                                )
                            }
                            .wasCalled(exactly: 1, timeout: .milliseconds(100))
                    }
                }
                
                // MARK: ---- from a sender that is approved
                context("from a sender that is approved") {
                    beforeEach {
                        try await fixture.mockLibSessionCache
                            .when { $0.isMessageRequest(threadId: .any, threadVariant: .any) }
                            .thenReturn(false)
                        try await fixture.mockStorage.write { db in
                            try Contact(
                                id: "051111111111111111111111111111111111111111111111111111111111111111",
                                isApproved: true,
                                currentUserSessionId: SessionId(.standard, hex: TestConstants.publicKey)
                            ).insert(db)
                        }
                    }
                    
                    // MARK: ------ adds the group as a full group
                    it("adds the group as a full group") {
                        try await fixture.mockStorage.write { db in
                            try MessageReceiver.handleGroupUpdateMessage(
                                db,
                                threadId: fixture.groupId.hexString,
                                threadVariant: .group,
                                message: fixture.inviteMessage,
                                decodedMessage: fixture.decodedMessage,
                                serverExpirationTimestamp: 1234567890,
                                suppressNotifications: false,
                                currentUserSessionIds: [],
                                using: fixture.dependencies
                            )
                        }
                        
                        let groups: [ClosedGroup] = try await fixture.mockStorage.read { db in try ClosedGroup.fetchAll(db) }
                        expect(groups.count).to(equal(1))
                        expect(groups.first?.id).to(equal(fixture.groupId.hexString))
                        expect(groups.first?.invited).to(beFalse())
                    }
                    
                    // MARK: ------ creates the group state
                    it("creates the group state") {
                        try await fixture.mockLibSessionCache
                            .when { $0.hasConfig(for: .any, sessionId: .any) }
                            .thenReturn(false)
                        try await fixture.mockStorage.write { db in
                            try MessageReceiver.handleGroupUpdateMessage(
                                db,
                                threadId: fixture.groupId.hexString,
                                threadVariant: .group,
                                message: fixture.inviteMessage,
                                decodedMessage: fixture.decodedMessage,
                                serverExpirationTimestamp: 1234567890,
                                suppressNotifications: false,
                                currentUserSessionIds: [],
                                using: fixture.dependencies
                            )
                        }
                        
                        await fixture.mockLibSessionCache
                            .verify { $0.setConfig(for: .groupInfo, sessionId: fixture.groupId, to: .any) }
                            .wasCalled(exactly: 1, timeout: .milliseconds(100))
                        await fixture.mockLibSessionCache
                            .verify { $0.setConfig(for: .groupMembers, sessionId: fixture.groupId, to: .any) }
                            .wasCalled(exactly: 1, timeout: .milliseconds(100))
                        await fixture.mockLibSessionCache
                            .verify { $0.setConfig(for: .groupKeys, sessionId: fixture.groupId, to: .any) }
                            .wasCalled(exactly: 1, timeout: .milliseconds(100))
                    }
                    
                    // MARK: ------ adds the group to USER_GROUPS with the invited flag set to false
                    it("adds the group to USER_GROUPS with the invited flag set to false") {
                        try await fixture.mockStorage.write { db in
                            try MessageReceiver.handleGroupUpdateMessage(
                                db,
                                threadId: fixture.groupId.hexString,
                                threadVariant: .group,
                                message: fixture.inviteMessage,
                                decodedMessage: fixture.decodedMessage,
                                serverExpirationTimestamp: 1234567890,
                                suppressNotifications: false,
                                currentUserSessionIds: [],
                                using: fixture.dependencies
                            )
                        }
                        
                        var cGroupId: [CChar] = fixture.groupId.hexString.cString(using: .utf8)!
                        var userGroup: ugroups_group_info = ugroups_group_info()
                        
                        expect(user_groups_get_group(fixture.userGroupsConfig.conf, &userGroup, &cGroupId)).to(beTrue())
                        expect(userGroup.invited).to(beFalse())
                    }
                    
                    // MARK: ------ starts the poller
                    it("starts the poller") {
                        try await fixture.mockStorage.write { db in
                            try MessageReceiver.handleGroupUpdateMessage(
                                db,
                                threadId: fixture.groupId.hexString,
                                threadVariant: .group,
                                message: fixture.inviteMessage,
                                decodedMessage: fixture.decodedMessage,
                                serverExpirationTimestamp: 1234567890,
                                suppressNotifications: false,
                                currentUserSessionIds: [],
                                using: fixture.dependencies
                            )
                        }
                        
                        let groups: [ClosedGroup] = try await fixture.mockStorage.read { db in try ClosedGroup.fetchAll(db) }
                        expect(groups.count).to(equal(1))
                        expect(groups.first?.id).to(equal(fixture.groupId.hexString))
                        expect(groups.first?.shouldPoll).to(beTrue())
                        
                        await fixture.mockGroupPollerManager
                            .verify { await $0.getOrCreatePoller(for: fixture.groupId.hexString) }
                            .wasCalled(exactly: 1, timeout: .milliseconds(100))
                        await fixture.mockPoller
                            .verify { await $0.startIfNeeded() }
                            .wasCalled(exactly: 1, timeout: .milliseconds(100))
                    }
                    
                    // MARK: ------ sends a local notification about the group invite
                    it("sends a local notification about the group invite") {
                        try await fixture.mockStorage.write { db in
                            try MessageReceiver.handleGroupUpdateMessage(
                                db,
                                threadId: fixture.groupId.hexString,
                                threadVariant: .group,
                                message: fixture.inviteMessage,
                                decodedMessage: fixture.decodedMessage,
                                serverExpirationTimestamp: 1234567890,
                                suppressNotifications: false,
                                currentUserSessionIds: [],
                                using: fixture.dependencies
                            )
                        }
                        
                        await fixture.mockNotificationsManager
                            .verify {
                                $0.addNotificationRequest(
                                    content: NotificationContent(
                                        threadId: fixture.groupId.hexString,
                                        threadVariant: .group,
                                        identifier: "\(fixture.groupId.hexString)-1",
                                        category: .incomingMessage,
                                        groupingIdentifier: .threadId(fixture.groupId.hexString),
                                        title: "notificationsIosGroup"
                                            .put(key: "name", value: "0511...1111")
                                            .put(key: "conversation_name", value: "TestGroupName")
                                            .localized(),
                                        body: "messageRequestGroupInvite"
                                            .put(key: "name", value: "0511...1111")
                                            .put(key: "group_name", value: "TestGroup")
                                            .localized()
                                            .deformatted(),
                                        sound: .defaultNotificationSound,
                                        applicationState: .active
                                    ),
                                    notificationSettings: Preferences.NotificationSettings(
                                        previewType: .nameAndPreview,
                                        sound: .defaultNotificationSound,
                                        mentionsOnly: false,
                                        mutedUntil: nil
                                    ),
                                    extensionBaseUnreadCount: nil
                                )
                            }
                            .wasCalled(exactly: 1, timeout: .milliseconds(100))
                    }
                    
                    // MARK: ------ and push notifications are disabled
                    context("and push notifications are disabled") {
                        beforeEach {
                            try await fixture.mockUserDefaults
                                .when { $0.string(forKey: UserDefaults.StringKey.deviceToken.rawValue) }
                                .thenReturn(nil)
                            try await fixture.mockUserDefaults
                                .when { $0.bool(forKey: UserDefaults.BoolKey.isUsingFullAPNs.rawValue) }
                                .thenReturn(false)
                        }
                        
                        // MARK: -------- does not subscribe for push notifications
                        it("does not subscribe for push notifications") {
                            // Need to set `isUsingFullAPNs` to true to generate the `expectedRequest`
                            try await fixture.mockUserDefaults
                                .when { $0.bool(forKey: UserDefaults.BoolKey.isUsingFullAPNs.rawValue) }
                                .thenReturn(true)
                            try await fixture.mockStorage.write { db in
                                _ = try SessionThread.upsert(
                                    db,
                                    id: fixture.groupId.hexString,
                                    variant: .group,
                                    values: SessionThread.TargetValues(
                                        creationDateTimestamp: .setTo(0),
                                        shouldBeVisible: .useExisting
                                    ),
                                    using: fixture.dependencies
                                )
                                try ClosedGroup(
                                    threadId: fixture.groupId.hexString,
                                    name: "Test",
                                    formationTimestamp: 0,
                                    shouldPoll: nil,
                                    groupIdentityPrivateKey: fixture.groupSecretKey,
                                    invited: nil
                                ).upsert(db)
                                
                                // Remove the debug group so it can be created during the actual test
                                try ClosedGroup.filter(id: fixture.groupId.hexString).deleteAll(db)
                                try SessionThread.filter(id: fixture.groupId.hexString).deleteAll(db)
                            }
                            try await fixture.mockUserDefaults
                                .when { $0.bool(forKey: UserDefaults.BoolKey.isUsingFullAPNs.rawValue) }
                                .thenReturn(false)
                            
                            try await fixture.mockStorage.write { db in
                                try MessageReceiver.handleGroupUpdateMessage(
                                    db,
                                    threadId: fixture.groupId.hexString,
                                    threadVariant: .group,
                                    message: fixture.inviteMessage,
                                    decodedMessage: fixture.decodedMessage,
                                    serverExpirationTimestamp: 1234567890,
                                    suppressNotifications: false,
                                    currentUserSessionIds: [],
                                    using: fixture.dependencies
                                )
                            }
                            
                            await fixture.mockNetwork
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
                                        body: try! JSONEncoder(using: fixture.dependencies).encode(
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
                                                            swarmPublicKey: fixture.groupId.hexString,
                                                            using: fixture.dependencies
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
                                .wasNotCalled(timeout: .milliseconds(100))
                        }
                    }
                    
                    // MARK: ------ and push notifications are enabled
                    context("and push notifications are enabled") {
                        beforeEach {
                            try await fixture.mockUserDefaults
                                .when { $0.string(forKey: UserDefaults.StringKey.deviceToken.rawValue) }
                                .thenReturn(Data([5, 4, 3, 2, 1]).toHexString())
                            try await fixture.mockUserDefaults
                                .when { $0.bool(forKey: UserDefaults.BoolKey.isUsingFullAPNs.rawValue) }
                                .thenReturn(true)
                        }
                        
                        // MARK: -------- subscribes for push notifications
                        it("subscribes for push notifications") {
                            try await fixture.mockStorage.write { db in
                                _ = try SessionThread.upsert(
                                    db,
                                    id: fixture.groupId.hexString,
                                    variant: .group,
                                    values: SessionThread.TargetValues(
                                        creationDateTimestamp: .setTo(0),
                                        shouldBeVisible: .useExisting
                                    ),
                                    using: fixture.dependencies
                                )
                                try ClosedGroup(
                                    threadId: fixture.groupId.hexString,
                                    name: "Test",
                                    formationTimestamp: 0,
                                    shouldPoll: nil,
                                    authData: fixture.inviteMessage.memberAuthData,
                                    invited: nil
                                ).upsert(db)
                                
                                // Remove the debug group so it can be created during the actual test
                                try ClosedGroup.filter(id: fixture.groupId.hexString).deleteAll(db)
                                try SessionThread.filter(id: fixture.groupId.hexString).deleteAll(db)
                            }
                            
                            try await fixture.mockStorage.write { db in
                                try MessageReceiver.handleGroupUpdateMessage(
                                    db,
                                    threadId: fixture.groupId.hexString,
                                    threadVariant: .group,
                                    message: fixture.inviteMessage,
                                    decodedMessage: fixture.decodedMessage,
                                    serverExpirationTimestamp: 1234567890,
                                    suppressNotifications: false,
                                    currentUserSessionIds: [],
                                    using: fixture.dependencies
                                )
                            }
                            
                            await fixture.mockNetwork
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
                                        body: try! JSONEncoder(using: fixture.dependencies).encode(
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
                                                            swarmPublicKey: fixture.groupId.hexString,
                                                            using: fixture.dependencies
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
                    }
                }
                
                // MARK: ---- adds the invited control message if the thread does not exist
                it("adds the invited control message if the thread does not exist") {
                    try await fixture.mockStorage.write { db in
                        try MessageReceiver.handleGroupUpdateMessage(
                            db,
                            threadId: fixture.groupId.hexString,
                            threadVariant: .group,
                            message: fixture.inviteMessage,
                            decodedMessage: fixture.decodedMessage,
                            serverExpirationTimestamp: 1234567890,
                            suppressNotifications: false,
                            currentUserSessionIds: [],
                            using: fixture.dependencies
                        )
                    }
                    
                    let interactions: [Interaction] = try await fixture.mockStorage.read { db in try Interaction.fetchAll(db) }
                    expect(interactions.count).to(equal(1))
                    expect(interactions.first?.body)
                        .to(equal("{\"invited\":{\"_0\":\"0511...1111\",\"_1\":\"TestGroup\"}}"))
                }
                
                // MARK: ---- does not add the invited control message if the thread already exists
                it("does not add the invited control message if the thread already exists") {
                    try await fixture.mockStorage.write { db in
                        try SessionThread.upsert(
                            db,
                            id: fixture.groupId.hexString,
                            variant: .group,
                            values: SessionThread.TargetValues(
                                creationDateTimestamp: .setTo(1234567890),
                                shouldBeVisible: .setTo(true)
                            ),
                            using: fixture.dependencies
                        )
                    }
                    
                    try await fixture.mockStorage.write { db in
                        try MessageReceiver.handleGroupUpdateMessage(
                            db,
                            threadId: fixture.groupId.hexString,
                            threadVariant: .group,
                            message: fixture.inviteMessage,
                            decodedMessage: fixture.decodedMessage,
                            serverExpirationTimestamp: 1234567890,
                            suppressNotifications: false,
                            currentUserSessionIds: [],
                            using: fixture.dependencies
                        )
                    }
                    
                    let interactions: [Interaction] = try await fixture.mockStorage.read { db in try Interaction.fetchAll(db) }
                    expect(interactions).to(beEmpty())
                }
            }
            
            // MARK: -- when receiving a group promotion
            context("when receiving a group promotion") {
                beforeEach {
                    var cMemberId: [CChar] = "05\(TestConstants.publicKey)".cString(using: .utf8)!
                    var member: config_group_member = config_group_member()
                    _ = groups_members_get_or_construct(fixture.groupMembersConfig.conf, &member, &cMemberId)
                    member.set(\.name, to: "TestName")
                    groups_members_set(fixture.groupMembersConfig.conf, &member)
                    
                    try await fixture.mockStorage.write { db in
                        try Contact(
                            id: "051111111111111111111111111111111111111111111111111111111111111111",
                            isTrusted: true,
                            isApproved: true,
                            isBlocked: false,
                            lastKnownClientVersion: nil,
                            didApproveMe: true,
                            hasBeenBlocked: false,
                            currentUserSessionId: SessionId(.standard, hex: TestConstants.publicKey)
                        ).insert(db)
                        try SessionThread.upsert(
                            db,
                            id: fixture.groupId.hexString,
                            variant: .group,
                            values: SessionThread.TargetValues(
                                creationDateTimestamp: .setTo(1234567890),
                                shouldBeVisible: .setTo(true)
                            ),
                            using: fixture.dependencies
                        )
                        
                        try ClosedGroup(
                            threadId: fixture.groupId.hexString,
                            name: "TestGroup",
                            formationTimestamp: 1234567890,
                            shouldPoll: true,
                            groupIdentityPrivateKey: nil,
                            authData: Data([1, 2, 3]),
                            invited: false
                        ).upsert(db)
                    }
                }
                
                // MARK: ---- fails if it cannot convert the group seed to a groupIdentityKeyPair
                it("fails if it cannot convert the group seed to a groupIdentityKeyPair") {
                    try await fixture.mockCrypto
                        .when { try $0.tryGenerate(.ed25519KeyPair(seed: Array<UInt8>.any)) }
                        .thenThrow(MockError.mock)
                    
                    await expect {
                        try await fixture.mockStorage.write { db in
                            try MessageReceiver.handleGroupUpdateMessage(
                                db,
                                threadId: fixture.groupId.hexString,
                                threadVariant: .group,
                                message: fixture.promoteMessage,
                                decodedMessage: fixture.decodedMessage,
                                serverExpirationTimestamp: 1234567890,
                                suppressNotifications: false,
                                currentUserSessionIds: [],
                                using: fixture.dependencies
                            )
                        }
                    }.to(throwError(MockError.mock))
                }
                
                // MARK: ---- updates the GROUP_KEYS state correctly
                it("updates the GROUP_KEYS state correctly") {
                    try await fixture.mockCrypto
                        .when { $0.generate(.ed25519KeyPair(seed: Array<UInt8>.any)) }
                        .thenReturn(KeyPair(publicKey: [1, 2, 3], secretKey: [4, 5, 6]))
                    
                    try await fixture.mockStorage.write { db in
                        try MessageReceiver.handleGroupUpdateMessage(
                            db,
                            threadId: fixture.groupId.hexString,
                            threadVariant: .group,
                            message: fixture.promoteMessage,
                            decodedMessage: fixture.decodedMessage,
                            serverExpirationTimestamp: 1234567890,
                            suppressNotifications: false,
                            currentUserSessionIds: [],
                            using: fixture.dependencies
                        )
                    }
                    await fixture.mockLibSessionCache
                        .verify {
                            try $0.loadAdminKey(
                                groupIdentitySeed: fixture.groupSeed,
                                groupSessionId: SessionId(.group, publicKey: [1, 2, 3])
                            )
                        }
                        .wasCalled(exactly: 1, timeout: .milliseconds(100))
                }
                
                // MARK: ---- replaces the memberAuthData with the admin key in the database
                it("replaces the memberAuthData with the admin key in the database") {
                    try await fixture.mockStorage.write { db in
                        try ClosedGroup(
                            threadId: fixture.groupId.hexString,
                            name: "TestGroup",
                            formationTimestamp: 1234567890,
                            shouldPoll: true,
                            groupIdentityPrivateKey: nil,
                            authData: Data([1, 2, 3]),
                            invited: false
                        ).upsert(db)
                    }
                    
                    try await fixture.mockStorage.write { db in
                        try MessageReceiver.handleGroupUpdateMessage(
                            db,
                            threadId: fixture.groupId.hexString,
                            threadVariant: .group,
                            message: fixture.promoteMessage,
                            decodedMessage: fixture.decodedMessage,
                            serverExpirationTimestamp: 1234567890,
                            suppressNotifications: false,
                            currentUserSessionIds: [],
                            using: fixture.dependencies
                        )
                    }
                    
                    let groups: [ClosedGroup] = try await fixture.mockStorage.read { db in try ClosedGroup.fetchAll(db) }
                    expect(groups.count).to(equal(1))
                    expect(groups.first?.groupIdentityPrivateKey).to(equal(Data(fixture.groupKeyPair.secretKey)))
                    expect(groups.first?.authData).to(beNil())
                }
            }
            
            // MARK: -- when receiving an info changed message
            context("when receiving an info changed message") {
                beforeEach {
                    _ = try await fixture.mockStorage.write { db in
                        try SessionThread.upsert(
                            db,
                            id: fixture.groupId.hexString,
                            variant: .group,
                            values: SessionThread.TargetValues(
                                creationDateTimestamp: .setTo(1234567890),
                                shouldBeVisible: .setTo(true)
                            ),
                            using: fixture.dependencies
                        )
                    }
                }
                
                // MARK: ---- throws if the admin signature fails to verify
                it("throws if the admin signature fails to verify") {
                    try await fixture.mockCrypto
                        .when { $0.verify(.signature(message: .any, publicKey: .any, signature: .any)) }
                        .thenReturn(false)
                    
                    await expect {
                        try await fixture.mockStorage.write { db in
                            try MessageReceiver.handleGroupUpdateMessage(
                                db,
                                threadId: fixture.groupId.hexString,
                                threadVariant: .group,
                                message: fixture.infoChangedMessage,
                                decodedMessage: fixture.decodedMessage,
                                serverExpirationTimestamp: 1234567890,
                                suppressNotifications: false,
                                currentUserSessionIds: [],
                                using: fixture.dependencies
                            )
                        }
                    }.to(throwError(MessageError.invalidMessage("Test")))
                }
                
                // MARK: ---- for a name change
                context("for a name change") {
                    // MARK: ------ creates the correct control message
                    it("creates the correct control message") {
                        try await fixture.mockStorage.write { db in
                            try MessageReceiver.handleGroupUpdateMessage(
                                db,
                                threadId: fixture.groupId.hexString,
                                threadVariant: .group,
                                message: fixture.infoChangedMessage,
                                decodedMessage: fixture.decodedMessage,
                                serverExpirationTimestamp: 1234567890,
                                suppressNotifications: false,
                                currentUserSessionIds: [],
                                using: fixture.dependencies
                            )
                        }
                        
                        let interaction: Interaction? = try await fixture.mockStorage.read { db in try Interaction.fetchOne(db) }
                        expect(interaction?.timestampMs).to(equal(1234567800000))
                        expect(interaction?.body).to(equal(
                            ClosedGroup.MessageInfo
                                .updatedName("TestGroup Rename")
                                .infoString(using: fixture.dependencies)
                        ))
                    }
                }
                
                // MARK: ---- for a display picture change
                context("for a display picture change") {
                    beforeEach {
                        fixture.infoChangedMessage = GroupUpdateInfoChangeMessage(
                            changeType: .avatar,
                            updatedName: nil,
                            updatedExpiration: nil,
                            adminSignature: .standard(signature: "TestSignature".bytes)
                        )
                        fixture.infoChangedMessage.sender = "051111111111111111111111111111111111111111111111111111111111111111"
                        fixture.infoChangedMessage.sentTimestampMs = 1234567890000
                    }
                    
                    // MARK: ------ creates the correct control message
                    it("creates the correct control message") {
                        try await fixture.mockStorage.write { db in
                            try MessageReceiver.handleGroupUpdateMessage(
                                db,
                                threadId: fixture.groupId.hexString,
                                threadVariant: .group,
                                message: fixture.infoChangedMessage,
                                decodedMessage: fixture.decodedMessage,
                                serverExpirationTimestamp: 1234567890,
                                suppressNotifications: false,
                                currentUserSessionIds: [],
                                using: fixture.dependencies
                            )
                        }
                        
                        let interaction: Interaction? = try await fixture.mockStorage.read { db in try Interaction.fetchOne(db) }
                        expect(interaction?.timestampMs).to(equal(1234567800000))
                        expect(interaction?.body).to(equal(
                            ClosedGroup.MessageInfo
                                .updatedDisplayPicture
                                .infoString(using: fixture.dependencies)
                        ))
                    }
                }
                
                // MARK: ---- for a disappearing message setting change
                context("for a disappearing message setting change") {
                    beforeEach {
                        fixture.infoChangedMessage = GroupUpdateInfoChangeMessage(
                            changeType: .disappearingMessages,
                            updatedName: nil,
                            updatedExpiration: 3600,
                            adminSignature: .standard(signature: "TestSignature".bytes)
                        )
                        fixture.infoChangedMessage.sender = "051111111111111111111111111111111111111111111111111111111111111111"
                        fixture.infoChangedMessage.sentTimestampMs = 1234567890000
                    }
                    
                    // MARK: ------ creates the correct control message
                    it("creates the correct control message") {
                        try await fixture.mockStorage.write { db in
                            try MessageReceiver.handleGroupUpdateMessage(
                                db,
                                threadId: fixture.groupId.hexString,
                                threadVariant: .group,
                                message: fixture.infoChangedMessage,
                                decodedMessage: fixture.decodedMessage,
                                serverExpirationTimestamp: 1234567890,
                                suppressNotifications: false,
                                currentUserSessionIds: [],
                                using: fixture.dependencies
                            )
                        }
                        
                        let interaction: Interaction? = try await fixture.mockStorage.read { db in try Interaction.fetchOne(db) }
                        expect(interaction?.timestampMs).to(equal(1234567800000))
                        expect(interaction?.body).to(equal(
                            DisappearingMessagesConfiguration(
                                threadId: fixture.groupId.hexString,
                                isEnabled: true,
                                durationSeconds: 3600,
                                type: .disappearAfterSend
                            ).messageInfoString(
                                threadVariant: .group,
                                senderName: fixture.infoChangedMessage.sender,
                                using: fixture.dependencies
                            )
                        ))
                        expect(interaction?.expiresInSeconds).to(beNil())
                    }
                }
            }
            
            // MARK: -- when receiving a member changed message
            context("when receiving a member changed message") {
                beforeEach {
                    _ = try await fixture.mockStorage.write { db in
                        try SessionThread.upsert(
                            db,
                            id: fixture.groupId.hexString,
                            variant: .group,
                            values: SessionThread.TargetValues(
                                creationDateTimestamp: .setTo(1234567890),
                                shouldBeVisible: .setTo(true)
                            ),
                            using: fixture.dependencies
                        )
                    }
                }
                
                // MARK: ---- throws if the admin signature fails to verify
                it("throws if the admin signature fails to verify") {
                    try await fixture.mockCrypto
                        .when { $0.verify(.signature(message: .any, publicKey: .any, signature: .any)) }
                        .thenReturn(false)
                    
                    await expect {
                        try await fixture.mockStorage.write { db in
                            try MessageReceiver.handleGroupUpdateMessage(
                                db,
                                threadId: fixture.groupId.hexString,
                                threadVariant: .group,
                                message: fixture.memberChangedMessage,
                                decodedMessage: fixture.decodedMessage,
                                serverExpirationTimestamp: 1234567890,
                                suppressNotifications: false,
                                currentUserSessionIds: [],
                                using: fixture.dependencies
                            )
                        }
                    }.to(throwError(MessageError.invalidMessage("Test")))
                }
                
                // MARK: ---- correctly retrieves the member name if present
                it("correctly retrieves the member name if present") {
                    try await fixture.mockStorage.write { db in
                        try Profile(
                            id: "051111111111111111111111111111111111111111111111111111111111111112",
                            name: "TestOtherProfile",
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
                    
                    try await fixture.mockStorage.write { db in
                        try MessageReceiver.handleGroupUpdateMessage(
                            db,
                            threadId: fixture.groupId.hexString,
                            threadVariant: .group,
                            message: fixture.memberChangedMessage,
                            decodedMessage: fixture.decodedMessage,
                            serverExpirationTimestamp: 1234567890,
                            suppressNotifications: false,
                            currentUserSessionIds: [],
                            using: fixture.dependencies
                        )
                    }
                    
                    let interaction: Interaction? = try await fixture.mockStorage.read { db in try Interaction.fetchOne(db) }
                    expect(interaction?.timestampMs).to(equal(1234567800000))
                    expect(interaction?.body).to(equal(
                        ClosedGroup.MessageInfo
                            .addedUsers(hasCurrentUser: false, names: ["TestOtherProfile"], historyShared: false)
                            .infoString(using: fixture.dependencies)
                    ))
                }
                
                // MARK: ---- for adding members
                context("for adding members") {
                    // MARK: ------ creates the correct control message for a single member
                    it("creates the correct control message for a single member") {
                        fixture.memberChangedMessage = GroupUpdateMemberChangeMessage(
                            changeType: .added,
                            memberSessionIds: [
                                "051111111111111111111111111111111111111111111111111111111111111112"
                            ],
                            historyShared: false,
                            adminSignature: .standard(signature: "TestSignature".bytes)
                        )
                        fixture.memberChangedMessage.sender = "051111111111111111111111111111111111111111111111111111111111111111"
                        fixture.memberChangedMessage.sentTimestampMs = 1234567890000
                        
                        try await fixture.mockStorage.write { db in
                            try MessageReceiver.handleGroupUpdateMessage(
                                db,
                                threadId: fixture.groupId.hexString,
                                threadVariant: .group,
                                message: fixture.memberChangedMessage,
                                decodedMessage: fixture.decodedMessage,
                                serverExpirationTimestamp: 1234567890,
                                suppressNotifications: false,
                                currentUserSessionIds: [],
                                using: fixture.dependencies
                            )
                        }
                        
                        let interaction: Interaction? = try await fixture.mockStorage.read { db in try Interaction.fetchOne(db) }
                        expect(interaction?.timestampMs).to(equal(1234567800000))
                        expect(interaction?.body).to(equal(
                            ClosedGroup.MessageInfo
                                .addedUsers(
                                    hasCurrentUser: false,
                                    names: ["0511...1112"],
                                    historyShared: false
                                )
                                .infoString(using: fixture.dependencies)
                        ))
                    }
                    
                    // MARK: ------ creates the correct control message for two members
                    it("creates the correct control message for two members") {
                        fixture.memberChangedMessage = GroupUpdateMemberChangeMessage(
                            changeType: .added,
                            memberSessionIds: [
                                "051111111111111111111111111111111111111111111111111111111111111112",
                                "051111111111111111111111111111111111111111111111111111111111111113"
                            ],
                            historyShared: false,
                            adminSignature: .standard(signature: "TestSignature".bytes)
                        )
                        fixture.memberChangedMessage.sender = "051111111111111111111111111111111111111111111111111111111111111111"
                        fixture.memberChangedMessage.sentTimestampMs = 1234567800000
                        
                        try await fixture.mockStorage.write { db in
                            try MessageReceiver.handleGroupUpdateMessage(
                                db,
                                threadId: fixture.groupId.hexString,
                                threadVariant: .group,
                                message: fixture.memberChangedMessage,
                                decodedMessage: fixture.decodedMessage,
                                serverExpirationTimestamp: 1234567890,
                                suppressNotifications: false,
                                currentUserSessionIds: [],
                                using: fixture.dependencies
                            )
                        }
                        
                        let interaction: Interaction? = try await fixture.mockStorage.read { db in try Interaction.fetchOne(db) }
                        expect(interaction?.timestampMs).to(equal(1234567800000))
                        expect(interaction?.body).to(equal(
                            ClosedGroup.MessageInfo
                                .addedUsers(
                                    hasCurrentUser: false,
                                    names: ["0511...1112", "0511...1113"],
                                    historyShared: false
                                )
                                .infoString(using: fixture.dependencies)
                        ))
                    }
                    
                    // MARK: ------ creates the correct control message for many members
                    it("creates the correct control message for many members") {
                        fixture.memberChangedMessage = GroupUpdateMemberChangeMessage(
                            changeType: .added,
                            memberSessionIds: [
                                "051111111111111111111111111111111111111111111111111111111111111112",
                                "051111111111111111111111111111111111111111111111111111111111111113",
                                "051111111111111111111111111111111111111111111111111111111111111114"
                            ],
                            historyShared: false,
                            adminSignature: .standard(signature: "TestSignature".bytes)
                        )
                        fixture.memberChangedMessage.sender = "051111111111111111111111111111111111111111111111111111111111111111"
                        fixture.memberChangedMessage.sentTimestampMs = 1234567890000
                        
                        try await fixture.mockStorage.write { db in
                            try MessageReceiver.handleGroupUpdateMessage(
                                db,
                                threadId: fixture.groupId.hexString,
                                threadVariant: .group,
                                message: fixture.memberChangedMessage,
                                decodedMessage: fixture.decodedMessage,
                                serverExpirationTimestamp: 1234567890,
                                suppressNotifications: false,
                                currentUserSessionIds: [],
                                using: fixture.dependencies
                            )
                        }
                        
                        let interaction: Interaction? = try await fixture.mockStorage.read { db in try Interaction.fetchOne(db) }
                        expect(interaction?.timestampMs).to(equal(1234567800000))
                        expect(interaction?.body).to(equal(
                            ClosedGroup.MessageInfo
                                .addedUsers(
                                    hasCurrentUser: false,
                                    names: ["0511...1112", "0511...1113", "0511...1114"],
                                    historyShared: false
                                )
                                .infoString(using: fixture.dependencies)
                        ))
                    }
                }
                
                // MARK: ---- for removing members
                context("for removing members") {
                    // MARK: ------ creates the correct control message for a single member
                    it("creates the correct control message for a single member") {
                        fixture.memberChangedMessage = GroupUpdateMemberChangeMessage(
                            changeType: .removed,
                            memberSessionIds: [
                                "051111111111111111111111111111111111111111111111111111111111111112"
                            ],
                            historyShared: false,
                            adminSignature: .standard(signature: "TestSignature".bytes)
                        )
                        fixture.memberChangedMessage.sender = "051111111111111111111111111111111111111111111111111111111111111111"
                        fixture.memberChangedMessage.sentTimestampMs = 1234567800000
                        
                        try await fixture.mockStorage.write { db in
                            try MessageReceiver.handleGroupUpdateMessage(
                                db,
                                threadId: fixture.groupId.hexString,
                                threadVariant: .group,
                                message: fixture.memberChangedMessage,
                                decodedMessage: fixture.decodedMessage,
                                serverExpirationTimestamp: 1234567890,
                                suppressNotifications: false,
                                currentUserSessionIds: [],
                                using: fixture.dependencies
                            )
                        }
                        
                        let interaction: Interaction? = try await fixture.mockStorage.read { db in try Interaction.fetchOne(db) }
                        expect(interaction?.timestampMs).to(equal(1234567800000))
                        expect(interaction?.body).to(equal(
                            ClosedGroup.MessageInfo
                                .removedUsers(hasCurrentUser: false, names: ["0511...1112"])
                                .infoString(using: fixture.dependencies)
                        ))
                    }
                    
                    // MARK: ------ creates the correct control message for two members
                    it("creates the correct control message for two members") {
                        fixture.memberChangedMessage = GroupUpdateMemberChangeMessage(
                            changeType: .removed,
                            memberSessionIds: [
                                "051111111111111111111111111111111111111111111111111111111111111112",
                                "051111111111111111111111111111111111111111111111111111111111111113"
                            ],
                            historyShared: false,
                            adminSignature: .standard(signature: "TestSignature".bytes)
                        )
                        fixture.memberChangedMessage.sender = "051111111111111111111111111111111111111111111111111111111111111111"
                        fixture.memberChangedMessage.sentTimestampMs = 1234567890000
                        
                        try await fixture.mockStorage.write { db in
                            try MessageReceiver.handleGroupUpdateMessage(
                                db,
                                threadId: fixture.groupId.hexString,
                                threadVariant: .group,
                                message: fixture.memberChangedMessage,
                                decodedMessage: fixture.decodedMessage,
                                serverExpirationTimestamp: 1234567890,
                                suppressNotifications: false,
                                currentUserSessionIds: [],
                                using: fixture.dependencies
                            )
                        }
                        
                        let interaction: Interaction? = try await fixture.mockStorage.read { db in try Interaction.fetchOne(db) }
                        expect(interaction?.timestampMs).to(equal(1234567800000))
                        expect(interaction?.body).to(equal(
                            ClosedGroup.MessageInfo
                                .removedUsers(hasCurrentUser: false, names: ["0511...1112", "0511...1113"])
                                .infoString(using: fixture.dependencies)
                        ))
                    }
                    
                    // MARK: ------ creates the correct control message for many members
                    it("creates the correct control message for many members") {
                        fixture.memberChangedMessage = GroupUpdateMemberChangeMessage(
                            changeType: .removed,
                            memberSessionIds: [
                                "051111111111111111111111111111111111111111111111111111111111111112",
                                "051111111111111111111111111111111111111111111111111111111111111113",
                                "051111111111111111111111111111111111111111111111111111111111111114"
                            ],
                            historyShared: false,
                            adminSignature: .standard(signature: "TestSignature".bytes)
                        )
                        fixture.memberChangedMessage.sender = "051111111111111111111111111111111111111111111111111111111111111111"
                        fixture.memberChangedMessage.sentTimestampMs = 1234567800000
                        
                        try await fixture.mockStorage.write { db in
                            try MessageReceiver.handleGroupUpdateMessage(
                                db,
                                threadId: fixture.groupId.hexString,
                                threadVariant: .group,
                                message: fixture.memberChangedMessage,
                                decodedMessage: fixture.decodedMessage,
                                serverExpirationTimestamp: 1234567890,
                                suppressNotifications: false,
                                currentUserSessionIds: [],
                                using: fixture.dependencies
                            )
                        }
                        
                        let interaction: Interaction? = try await fixture.mockStorage.read { db in try Interaction.fetchOne(db) }
                        expect(interaction?.timestampMs).to(equal(1234567800000))
                        expect(interaction?.body).to(equal(
                            ClosedGroup.MessageInfo
                                .removedUsers(hasCurrentUser: false, names: ["0511...1112", "0511...1113", "0511...1114"])
                                .infoString(using: fixture.dependencies)
                        ))
                    }
                }
                
                // MARK: ---- for promoting members
                context("for promoting members") {
                    // MARK: ------ creates the correct control message for a single member
                    it("creates the correct control message for a single member") {
                        fixture.memberChangedMessage = GroupUpdateMemberChangeMessage(
                            changeType: .promoted,
                            memberSessionIds: [
                                "051111111111111111111111111111111111111111111111111111111111111112"
                            ],
                            historyShared: false,
                            adminSignature: .standard(signature: "TestSignature".bytes)
                        )
                        fixture.memberChangedMessage.sender = "051111111111111111111111111111111111111111111111111111111111111111"
                        fixture.memberChangedMessage.sentTimestampMs = 1234567890000
                        
                        try await fixture.mockStorage.write { db in
                            try MessageReceiver.handleGroupUpdateMessage(
                                db,
                                threadId: fixture.groupId.hexString,
                                threadVariant: .group,
                                message: fixture.memberChangedMessage,
                                decodedMessage: fixture.decodedMessage,
                                serverExpirationTimestamp: 1234567890,
                                suppressNotifications: false,
                                currentUserSessionIds: [],
                                using: fixture.dependencies
                            )
                        }
                        
                        let interaction: Interaction? = try await fixture.mockStorage.read { db in try Interaction.fetchOne(db) }
                        expect(interaction?.timestampMs).to(equal(1234567800000))
                        expect(interaction?.body).to(equal(
                            ClosedGroup.MessageInfo
                                .promotedUsers(hasCurrentUser: false, names: ["0511...1112"])
                                .infoString(using: fixture.dependencies)
                        ))
                    }
                    
                    // MARK: ------ creates the correct control message for two members
                    it("creates the correct control message for two members") {
                        fixture.memberChangedMessage = GroupUpdateMemberChangeMessage(
                            changeType: .promoted,
                            memberSessionIds: [
                                "051111111111111111111111111111111111111111111111111111111111111112",
                                "051111111111111111111111111111111111111111111111111111111111111113"
                            ],
                            historyShared: false,
                            adminSignature: .standard(signature: "TestSignature".bytes)
                        )
                        fixture.memberChangedMessage.sender = "051111111111111111111111111111111111111111111111111111111111111111"
                        fixture.memberChangedMessage.sentTimestampMs = 1234567800000
                        
                        try await fixture.mockStorage.write { db in
                            try MessageReceiver.handleGroupUpdateMessage(
                                db,
                                threadId: fixture.groupId.hexString,
                                threadVariant: .group,
                                message: fixture.memberChangedMessage,
                                decodedMessage: fixture.decodedMessage,
                                serverExpirationTimestamp: 1234567890,
                                suppressNotifications: false,
                                currentUserSessionIds: [],
                                using: fixture.dependencies
                            )
                        }
                        
                        let interaction: Interaction? = try await fixture.mockStorage.read { db in try Interaction.fetchOne(db) }
                        expect(interaction?.timestampMs).to(equal(1234567800000))
                        expect(interaction?.body).to(equal(
                            ClosedGroup.MessageInfo
                                .promotedUsers(hasCurrentUser: false, names: ["0511...1112", "0511...1113"])
                                .infoString(using: fixture.dependencies)
                        ))
                    }
                    
                    // MARK: ------ creates the correct control message for many members
                    it("creates the correct control message for many members") {
                        fixture.memberChangedMessage = GroupUpdateMemberChangeMessage(
                            changeType: .promoted,
                            memberSessionIds: [
                                "051111111111111111111111111111111111111111111111111111111111111112",
                                "051111111111111111111111111111111111111111111111111111111111111113",
                                "051111111111111111111111111111111111111111111111111111111111111114"
                            ],
                            historyShared: false,
                            adminSignature: .standard(signature: "TestSignature".bytes)
                        )
                        fixture.memberChangedMessage.sender = "051111111111111111111111111111111111111111111111111111111111111111"
                        fixture.memberChangedMessage.sentTimestampMs = 1234567890000
                        
                        try await fixture.mockStorage.write { db in
                            try MessageReceiver.handleGroupUpdateMessage(
                                db,
                                threadId: fixture.groupId.hexString,
                                threadVariant: .group,
                                message: fixture.memberChangedMessage,
                                decodedMessage: fixture.decodedMessage,
                                serverExpirationTimestamp: 1234567890,
                                suppressNotifications: false,
                                currentUserSessionIds: [],
                                using: fixture.dependencies
                            )
                        }
                        
                        let interaction: Interaction? = try await fixture.mockStorage.read { db in try Interaction.fetchOne(db) }
                        expect(interaction?.timestampMs).to(equal(1234567800000))
                        expect(interaction?.body).to(equal(
                            ClosedGroup.MessageInfo
                                .promotedUsers(hasCurrentUser: false, names: ["0511...1112", "0511...1113", "0511...1114"])
                                .infoString(using: fixture.dependencies)
                        ))
                    }
                }
            }
            
            // MARK: -- when receiving a member left message
            context("when receiving a member left message") {
                beforeEach {
                    _ = try await fixture.mockStorage.write { db in
                        try SessionThread.upsert(
                            db,
                            id: fixture.groupId.hexString,
                            variant: .group,
                            values: SessionThread.TargetValues(
                                creationDateTimestamp: .setTo(1234567890),
                                shouldBeVisible: .setTo(true)
                            ),
                            using: fixture.dependencies
                        )
                    }
                }
                
                // MARK: ---- does not create a control message
                it("does not create a control message") {
                    try await fixture.mockStorage.write { db in
                        try MessageReceiver.handleGroupUpdateMessage(
                            db,
                            threadId: fixture.groupId.hexString,
                            threadVariant: .group,
                            message: fixture.memberLeftMessage,
                            decodedMessage: fixture.decodedMessage,
                            serverExpirationTimestamp: 1234567890,
                            suppressNotifications: false,
                            currentUserSessionIds: [],
                            using: fixture.dependencies
                        )
                    }
                    
                    let interactions: [Interaction] = try await fixture.mockStorage.read { db in try Interaction.fetchAll(db) }
                    expect(interactions).to(beEmpty())
                }
                
                // MARK: ---- throws if the current user is not an admin
                it("throws if the current user is not an admin") {
                    try await fixture.mockLibSessionCache
                        .when { $0.isAdmin(groupSessionId: .any) }
                        .thenReturn(false)
                    
                    await expect {
                        try await fixture.mockStorage.write { db in
                            try MessageReceiver.handleGroupUpdateMessage(
                                db,
                                threadId: fixture.groupId.hexString,
                                threadVariant: .group,
                                message: fixture.memberLeftMessage,
                                decodedMessage: fixture.decodedMessage,
                                serverExpirationTimestamp: 1234567890,
                                suppressNotifications: false,
                                currentUserSessionIds: [],
                                using: fixture.dependencies
                            )
                        }
                    }.to(throwError(MessageError.ignorableMessage))
                }
                
                // MARK: ---- when the current user is a group admin
                context("when the current user is a group admin") {
                    beforeEach {
                        // Only update members if they already exist in the group
                        var cMemberId: [CChar] = "051111111111111111111111111111111111111111111111111111111111111112".cString(using: .utf8)!
                        var groupMember: config_group_member = config_group_member()
                        _ = groups_members_get_or_construct(fixture.groupMembersConfig.conf, &groupMember, &cMemberId)
                        groupMember.set(\.name, to: "TestOtherName")
                        groups_members_set(fixture.groupMembersConfig.conf, &groupMember)
                        
                        fixture.decodedMessage = DecodedMessage(
                            content: Data(
                                base64Encoded: "CAESvwEKABIAGrYBCAYSACjQiOyP9yM4AUKmAfjX/WXVFs+QE5Eh54Esw9/N" +
                                "lYza3k8MOvcRAI7y8k0JzLsm/KpXxKP7Zx7+5YyII9sCRXzFK2U4/X9SSMN088YEr/5wKoDfL5q" +
                                "PQbN70aa59WS8YE+yWcniQO0KXfAzr6Acn40fsa9BMr9tnQLfvxY8vD7qBz9iEOV9jTxPzxUoD+" +
                                "JelIbsv2qlkOl9vs166NC/Y772NZmUAR5u1ewL4SYEWkqX5R4gAA=="
                            )!,
                            sender: SessionId(.standard, hex: "1111111111111111111111111111111111111111111111111111111111111112"),
                            decodedEnvelope: nil,
                            sentTimestampMs: 1234567800000
                        )
                        
                        try await fixture.mockStorage.write { db in
                            try ClosedGroup(
                                threadId: fixture.groupId.hexString,
                                name: "TestGroup",
                                formationTimestamp: 1234567890,
                                shouldPoll: true,
                                groupIdentityPrivateKey: fixture.groupSecretKey,
                                authData: nil,
                                invited: false
                            ).upsert(db)
                            
                            try GroupMember(
                                groupId: fixture.groupId.hexString,
                                profileId: "051111111111111111111111111111111111111111111111111111111111111112",
                                role: .standard,
                                roleStatus: .accepted,
                                isHidden: false
                            ).upsert(db)
                        }
                    }
                    
                    // MARK: ------ flags the member for removal keeping their messages
                    it("flags the member for removal keeping their messages") {
                        try await fixture.mockStorage.write { db in
                            try MessageReceiver.handleGroupUpdateMessage(
                                db,
                                threadId: fixture.groupId.hexString,
                                threadVariant: .group,
                                message: fixture.memberLeftMessage,
                                decodedMessage: fixture.decodedMessage,
                                serverExpirationTimestamp: 1234567890,
                                suppressNotifications: false,
                                currentUserSessionIds: [],
                                using: fixture.dependencies
                            )
                        }
                        
                        var cMemberId: [CChar] = "051111111111111111111111111111111111111111111111111111111111111112".cString(using: .utf8)!
                        var groupMember: config_group_member = config_group_member()
                        
                        await expect { () -> Int32? in
                            guard groups_members_get(fixture.groupMembersConfig.conf, &groupMember, &cMemberId) else {
                                return nil
                            }
                            
                            return groupMember.removed
                        }.toEventually(equal(1), timeout: .milliseconds(100))
                    }
                    
                    // MARK: ------ flags the GroupMember as pending removal
                    it("flags the GroupMember as pending removal") {
                        try await fixture.mockStorage.write { db in
                            try MessageReceiver.handleGroupUpdateMessage(
                                db,
                                threadId: fixture.groupId.hexString,
                                threadVariant: .group,
                                message: fixture.memberLeftMessage,
                                decodedMessage: fixture.decodedMessage,
                                serverExpirationTimestamp: 1234567890,
                                suppressNotifications: false,
                                currentUserSessionIds: [],
                                using: fixture.dependencies
                            )
                        }
                        
                        await expect {
                            try await fixture.mockStorage.read { db in
                                try GroupMember.fetchAll(db).map(\.roleStatus)
                            }
                        }.toEventually(equal([.pendingRemoval]), timeout: .milliseconds(100))
                    }
                    
                    // MARK: ------ schedules a job to process the pending removal
                    it("schedules a job to process the pending removal") {
                        try await fixture.mockStorage.write { db in
                            try MessageReceiver.handleGroupUpdateMessage(
                                db,
                                threadId: fixture.groupId.hexString,
                                threadVariant: .group,
                                message: fixture.memberLeftMessage,
                                decodedMessage: fixture.decodedMessage,
                                serverExpirationTimestamp: 1234567890,
                                suppressNotifications: false,
                                currentUserSessionIds: [],
                                using: fixture.dependencies
                            )
                        }
                        
                        await fixture.mockJobRunner
                            .verify {
                                $0.add(
                                    .any,
                                    job: Job(
                                        variant: .processPendingGroupMemberRemovals,
                                        threadId: fixture.groupId.hexString,
                                        details: ProcessPendingGroupMemberRemovalsJob.Details(
                                            changeTimestampMs: 1234567800000
                                        )
                                    ),
                                    initialDependencies: []
                                )
                            }
                            .wasCalled(exactly: 1, timeout: .milliseconds(100))
                    }
                    
                    // MARK: ------ does not schedule a member change control message to be sent
                    it("does not schedule a member change control message to be sent") {
                        try await fixture.mockStorage.write { db in
                            try MessageReceiver.handleGroupUpdateMessage(
                                db,
                                threadId: fixture.groupId.hexString,
                                threadVariant: .group,
                                message: fixture.memberLeftMessage,
                                decodedMessage: fixture.decodedMessage,
                                serverExpirationTimestamp: 1234567890,
                                suppressNotifications: false,
                                currentUserSessionIds: [],
                                using: fixture.dependencies
                            )
                        }
                        
                        await fixture.mockJobRunner
                            .verify {
                                $0.add(
                                    .any,
                                    job: Job(
                                        variant: .messageSend,
                                        threadId: fixture.groupId.hexString,
                                        interactionId: nil,
                                        details: MessageSendJob.Details(
                                            destination: .group(publicKey: fixture.groupId.hexString),
                                            message: try! GroupUpdateMemberChangeMessage(
                                                changeType: .removed,
                                                memberSessionIds: [
                                                    "051111111111111111111111111111111111111111111111111111111111111112"
                                                ],
                                                historyShared: false,
                                                sentTimestampMs: 1234567800000,
                                                authMethod: Authentication.groupAdmin(
                                                    groupSessionId: fixture.groupId,
                                                    ed25519SecretKey: Array(fixture.groupSecretKey)
                                                ),
                                                using: fixture.dependencies
                                            ),
                                            ignorePermanentFailure: false
                                        )
                                    ),
                                    initialDependencies: []
                                )
                            }
                            .wasNotCalled(timeout: .milliseconds(100))
                    }
                }
            }
            
            // MARK: -- when receiving a member left notification message
            context("when receiving a member left notification message") {
                beforeEach {
                    fixture.decodedMessage = DecodedMessage(
                        content: Data(
                            base64Encoded: "CAESvwEKABIAGrYBCAYSACjQiOyP9yM4AUKmAfjX/WXVFs+QE5Eh54Esw9/N" +
                            "lYza3k8MOvcRAI7y8k0JzLsm/KpXxKP7Zx7+5YyII9sCRXzFK2U4/X9SSMN088YEr/5wKoDfL5q" +
                            "PQbN70aa59WS8YE+yWcniQO0KXfAzr6Acn40fsa9BMr9tnQLfvxY8vD7qBz9iEOV9jTxPzxUoD+" +
                            "JelIbsv2qlkOl9vs166NC/Y772NZmUAR5u1ewL4SYEWkqX5R4gAA=="
                        )!,
                        sender: SessionId(.standard, hex: "1111111111111111111111111111111111111111111111111111111111111112"),
                        decodedEnvelope: nil,
                        sentTimestampMs: 1234567800000
                    )
                    
                    _ = try await fixture.mockStorage.write { db in
                        try SessionThread.upsert(
                            db,
                            id: fixture.groupId.hexString,
                            variant: .group,
                            values: SessionThread.TargetValues(
                                creationDateTimestamp: .setTo(1234567890),
                                shouldBeVisible: .setTo(true)
                            ),
                            using: fixture.dependencies
                        )
                    }
                }
                
                // MARK: ---- creates the correct control message
                it("creates the correct control message") {
                    try await fixture.mockStorage.write { db in
                        try MessageReceiver.handleGroupUpdateMessage(
                            db,
                            threadId: fixture.groupId.hexString,
                            threadVariant: .group,
                            message: fixture.memberLeftNotificationMessage,
                            decodedMessage: fixture.decodedMessage,
                            serverExpirationTimestamp: 1234567890,
                            suppressNotifications: false,
                            currentUserSessionIds: [],
                            using: fixture.dependencies
                        )
                    }
                    
                    let interaction: Interaction? = try await fixture.mockStorage.read { db in try Interaction.fetchOne(db) }
                    expect(interaction?.timestampMs).to(equal(1234567800000))
                    expect(interaction?.body).to(equal(
                        ClosedGroup.MessageInfo
                            .memberLeft(wasCurrentUser: false, name: "0511...1112")
                            .infoString(using: fixture.dependencies)
                    ))
                }
                
                // MARK: ---- correctly retrieves the member name if present
                it("correctly retrieves the member name if present") {
                    try await fixture.mockStorage.write { db in
                        try Profile(
                            id: "051111111111111111111111111111111111111111111111111111111111111112",
                            name: "TestOtherProfile",
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
                    
                    try await fixture.mockStorage.write { db in
                        try MessageReceiver.handleGroupUpdateMessage(
                            db,
                            threadId: fixture.groupId.hexString,
                            threadVariant: .group,
                            message: fixture.memberLeftNotificationMessage,
                            decodedMessage: fixture.decodedMessage,
                            serverExpirationTimestamp: 1234567890,
                            suppressNotifications: false,
                            currentUserSessionIds: [],
                            using: fixture.dependencies
                        )
                    }
                    
                    let interaction: Interaction? = try await fixture.mockStorage.read { db in try Interaction.fetchOne(db) }
                    expect(interaction?.timestampMs).to(equal(1234567800000))
                    expect(interaction?.body).to(equal(
                        ClosedGroup.MessageInfo
                            .memberLeft(wasCurrentUser: false, name: "TestOtherProfile")
                            .infoString(using: fixture.dependencies)
                    ))
                }
            }
            
            // MARK: -- when receiving an invite response message
            context("when receiving an invite response message") {
                beforeEach {
                    _ = try await fixture.mockStorage.write { db in
                        try SessionThread.upsert(
                            db,
                            id: fixture.groupId.hexString,
                            variant: .group,
                            values: SessionThread.TargetValues(
                                creationDateTimestamp: .setTo(1234567890),
                                shouldBeVisible: .setTo(true)
                            ),
                            using: fixture.dependencies
                        )
                    }
                }
                
                // MARK: ---- throws if the message isn't an approval
                it("throws if the message isn't an approval") {
                    fixture.inviteResponseMessage.isApproved = false

                    await expect {
                        try await fixture.mockStorage.write { db in
                            try MessageReceiver.handleGroupUpdateMessage(
                                db,
                                threadId: fixture.groupId.hexString,
                                threadVariant: .group,
                                message: fixture.inviteResponseMessage,
                                decodedMessage: fixture.decodedMessage,
                                serverExpirationTimestamp: 1234567890,
                                suppressNotifications: false,
                                currentUserSessionIds: [],
                                using: fixture.dependencies
                            )
                        }
                    }.to(throwError(MessageError.ignorableMessage))
                }
                
                // MARK: ---- updates the profile information in the database if provided
                it("updates the profile information in the database if provided") {
                    try await fixture.mockStorage.write { db in
                        try MessageReceiver.handleGroupUpdateMessage(
                            db,
                            threadId: fixture.groupId.hexString,
                            threadVariant: .group,
                            message: fixture.inviteResponseMessage,
                            decodedMessage: fixture.decodedMessage,
                            serverExpirationTimestamp: 1234567890,
                            suppressNotifications: false,
                            currentUserSessionIds: [],
                            using: fixture.dependencies
                        )
                    }
                    
                    await expect {
                        try await fixture.mockStorage.read { db in
                            try Profile.fetchAll(db)
                                .reduce(into: [:]) { result, next in
                                    result[next.id] = next.name
                                }
                        }
                    }.toEventually(
                        equal([
                            "05\(TestConstants.publicKey)": "TestCurrentUser",
                            "TestProfileId": "TestOtherMember"
                        ]),
                        timeout: .milliseconds(100)
                    )
                }
                
                // MARK: ---- and the current user is a group admin
                context("and the current user is a group admin") {
                    beforeEach {
                        // Only update members if they already exist in the group
                        var cMemberId: [CChar] = "051111111111111111111111111111111111111111111111111111111111111112".cString(using: .utf8)!
                        var groupMember: config_group_member = config_group_member()
                        _ = groups_members_get_or_construct(fixture.groupMembersConfig.conf, &groupMember, &cMemberId)
                        groupMember.set(\.name, to: "TestOtherMember")
                        groupMember.invited = 1
                        groups_members_set(fixture.groupMembersConfig.conf, &groupMember)
                        
                        fixture.decodedMessage = DecodedMessage(
                            content: Data(
                                base64Encoded: "CAESvwEKABIAGrYBCAYSACjQiOyP9yM4AUKmAfjX/WXVFs+QE5Eh54Esw9/N" +
                                "lYza3k8MOvcRAI7y8k0JzLsm/KpXxKP7Zx7+5YyII9sCRXzFK2U4/X9SSMN088YEr/5wKoDfL5q" +
                                "PQbN70aa59WS8YE+yWcniQO0KXfAzr6Acn40fsa9BMr9tnQLfvxY8vD7qBz9iEOV9jTxPzxUoD+" +
                                "JelIbsv2qlkOl9vs166NC/Y772NZmUAR5u1ewL4SYEWkqX5R4gAA=="
                            )!,
                            sender: SessionId(.standard, hex: "1111111111111111111111111111111111111111111111111111111111111112"),
                            decodedEnvelope: nil,
                            sentTimestampMs: 1234567800000
                        )
                        
                        try await fixture.mockStorage.write { db in
                            try ClosedGroup(
                                threadId: fixture.groupId.hexString,
                                name: "TestGroup",
                                formationTimestamp: 1234567890,
                                shouldPoll: true,
                                groupIdentityPrivateKey: fixture.groupSecretKey,
                                authData: nil,
                                invited: false
                            ).upsert(db)
                        }
                    }
                    
                    // MARK: ------ updates a pending member entry to an accepted member
                    it("updates a pending member entry to an accepted member") {
                        try await fixture.mockStorage.write { db in
                            try GroupMember(
                                groupId: fixture.groupId.hexString,
                                profileId: "051111111111111111111111111111111111111111111111111111111111111112",
                                role: .standard,
                                roleStatus: .pending,
                                isHidden: false
                            ).upsert(db)
                        }
                        
                        try await fixture.mockStorage.write { db in
                            try MessageReceiver.handleGroupUpdateMessage(
                                db,
                                threadId: fixture.groupId.hexString,
                                threadVariant: .group,
                                message: fixture.inviteResponseMessage,
                                decodedMessage: fixture.decodedMessage,
                                serverExpirationTimestamp: 1234567890,
                                suppressNotifications: false,
                                currentUserSessionIds: [],
                                using: fixture.dependencies
                            )
                        }
                        
                        let members: [GroupMember] = try await fixture.mockStorage.read { db in try GroupMember.fetchAll(db) }
                        expect(members.count).to(equal(1))
                        expect(members.first?.profileId).to(equal(
                            "051111111111111111111111111111111111111111111111111111111111111112"
                        ))
                        expect(members.first?.role).to(equal(.standard))
                        expect(members.first?.roleStatus).to(equal(.accepted))
                        
                        var cMemberId: [CChar] = "051111111111111111111111111111111111111111111111111111111111111112".cString(using: .utf8)!
                        var groupMember: config_group_member = config_group_member()
                        expect(groups_members_get(fixture.groupMembersConfig.conf, &groupMember, &cMemberId)).to(beTrue())
                        expect(groupMember.invited).to(equal(0))
                    }
                    
                    // MARK: ------ updates a failed member entry to an accepted member
                    it("updates a failed member entry to an accepted member") {
                        var cMemberId1: [CChar] = "051111111111111111111111111111111111111111111111111111111111111112".cString(using: .utf8)!
                        var groupMember1: config_group_member = config_group_member()
                        _ = groups_members_get(fixture.groupMembersConfig.conf, &groupMember1, &cMemberId1)
                        groupMember1.invited = 2
                        groups_members_set(fixture.groupMembersConfig.conf, &groupMember1)
                        
                        try await fixture.mockStorage.write { db in
                            try GroupMember(
                                groupId: fixture.groupId.hexString,
                                profileId: "051111111111111111111111111111111111111111111111111111111111111112",
                                role: .standard,
                                roleStatus: .failed,
                                isHidden: false
                            ).upsert(db)
                        }
                        
                        try await fixture.mockStorage.write { db in
                            try MessageReceiver.handleGroupUpdateMessage(
                                db,
                                threadId: fixture.groupId.hexString,
                                threadVariant: .group,
                                message: fixture.inviteResponseMessage,
                                decodedMessage: fixture.decodedMessage,
                                serverExpirationTimestamp: 1234567890,
                                suppressNotifications: false,
                                currentUserSessionIds: [],
                                using: fixture.dependencies
                            )
                        }
                        
                        let members: [GroupMember] = try await fixture.mockStorage.read { db in try GroupMember.fetchAll(db) }
                        expect(members.count).to(equal(1))
                        expect(members.first?.profileId).to(equal(
                            "051111111111111111111111111111111111111111111111111111111111111112"
                        ))
                        expect(members.first?.role).to(equal(.standard))
                        expect(members.first?.roleStatus).to(equal(.accepted))
                        
                        var cMemberId: [CChar] = "051111111111111111111111111111111111111111111111111111111111111112".cString(using: .utf8)!
                        var groupMember: config_group_member = config_group_member()
                        expect(groups_members_get(fixture.groupMembersConfig.conf, &groupMember, &cMemberId)).to(beTrue())
                        expect(groupMember.invited).to(equal(0))
                    }
                    
                    // MARK: ------ updates the entry in libSession directly if there is no database value
                    it("updates the entry in libSession directly if there is no database value") {
                        try await fixture.mockStorage.write { db in
                            _ = try GroupMember.deleteAll(db)
                        }
                        
                        try await fixture.mockStorage.write { db in
                            try MessageReceiver.handleGroupUpdateMessage(
                                db,
                                threadId: fixture.groupId.hexString,
                                threadVariant: .group,
                                message: fixture.inviteResponseMessage,
                                decodedMessage: fixture.decodedMessage,
                                serverExpirationTimestamp: 1234567890,
                                suppressNotifications: false,
                                currentUserSessionIds: [],
                                using: fixture.dependencies
                            )
                        }
                        
                        var cMemberId: [CChar] = "051111111111111111111111111111111111111111111111111111111111111112".cString(using: .utf8)!
                        var groupMember: config_group_member = config_group_member()
                        expect(groups_members_get(fixture.groupMembersConfig.conf, &groupMember, &cMemberId)).to(beTrue())
                        expect(groupMember.invited).to(equal(0))
                    }
                    
                    // MARK: ---- updates the config member entry with profile information if provided
                    it("updates the config member entry with profile information if provided") {
                        try await fixture.mockStorage.write { db in
                            _ = try GroupMember.deleteAll(db)
                        }
                        
                        try await fixture.mockStorage.write { db in
                            try MessageReceiver.handleGroupUpdateMessage(
                                db,
                                threadId: fixture.groupId.hexString,
                                threadVariant: .group,
                                message: fixture.inviteResponseMessage,
                                decodedMessage: fixture.decodedMessage,
                                serverExpirationTimestamp: 1234567890,
                                suppressNotifications: false,
                                currentUserSessionIds: [],
                                using: fixture.dependencies
                            )
                        }
                        
                        var cMemberId: [CChar] = "051111111111111111111111111111111111111111111111111111111111111112".cString(using: .utf8)!
                        var groupMember: config_group_member = config_group_member()
                        expect(groups_members_get(fixture.groupMembersConfig.conf, &groupMember, &cMemberId)).to(beTrue())
                        expect(groupMember.get(\.name)).to(equal("TestOtherMember"))
                    }
                }
            }
            
            // MARK: -- when receiving a delete content message
            context("when receiving a delete content message") {
                beforeEach {
                    try await fixture.mockStorage.write { db in
                        try SessionThread.upsert(
                            db,
                            id: fixture.groupId.hexString,
                            variant: .group,
                            values: SessionThread.TargetValues(
                                creationDateTimestamp: .setTo(1234567890),
                                shouldBeVisible: .setTo(true)
                            ),
                            using: fixture.dependencies
                        )
                        
                        _ = try Interaction(
                            id: 1,
                            serverHash: "TestMessageHash1",
                            messageUuid: nil,
                            threadId: fixture.groupId.hexString,
                            authorId: "051111111111111111111111111111111111111111111111111111111111111111",
                            variant: .standardIncoming,
                            body: "Test1",
                            timestampMs: 1234560000001,
                            receivedAtTimestampMs: 1234560000001,
                            wasRead: false,
                            hasMention: false,
                            expiresInSeconds: 0,
                            expiresStartedAtMs: nil,
                            linkPreviewUrl: nil,
                            openGroupServerMessageId: nil,
                            openGroupWhisper: false,
                            openGroupWhisperMods: false,
                            openGroupWhisperTo: nil,
                            state: .sent,
                            recipientReadTimestampMs: nil,
                            mostRecentFailureText: nil,
                            proMessageFeatures: .none,
                            proProfileFeatures: .none
                        ).inserted(db)
                        
                        _ = try Interaction(
                            id: 2,
                            serverHash: "TestMessageHash2",
                            messageUuid: nil,
                            threadId: fixture.groupId.hexString,
                            authorId: "051111111111111111111111111111111111111111111111111111111111111111",
                            variant: .standardIncoming,
                            body: "Test2",
                            timestampMs: 1234567890002,
                            receivedAtTimestampMs: 1234567890002,
                            wasRead: false,
                            hasMention: false,
                            expiresInSeconds: 0,
                            expiresStartedAtMs: nil,
                            linkPreviewUrl: nil,
                            openGroupServerMessageId: nil,
                            openGroupWhisper: false,
                            openGroupWhisperMods: false,
                            openGroupWhisperTo: nil,
                            state: .sent,
                            recipientReadTimestampMs: nil,
                            mostRecentFailureText: nil,
                            proMessageFeatures: .none,
                            proProfileFeatures: .none
                        ).inserted(db)
                        
                        _ = try Interaction(
                            id: 3,
                            serverHash: "TestMessageHash3",
                            messageUuid: nil,
                            threadId: fixture.groupId.hexString,
                            authorId: "051111111111111111111111111111111111111111111111111111111111111112",
                            variant: .standardIncoming,
                            body: "Test3",
                            timestampMs: 1234560000003,
                            receivedAtTimestampMs: 1234560000003,
                            wasRead: false,
                            hasMention: false,
                            expiresInSeconds: 0,
                            expiresStartedAtMs: nil,
                            linkPreviewUrl: nil,
                            openGroupServerMessageId: nil,
                            openGroupWhisper: false,
                            openGroupWhisperMods: false,
                            openGroupWhisperTo: nil,
                            state: .sent,
                            recipientReadTimestampMs: nil,
                            mostRecentFailureText: nil,
                            proMessageFeatures: .none,
                            proProfileFeatures: .none
                        ).inserted(db)
                        
                        _ = try Interaction(
                            id: 4,
                            serverHash: "TestMessageHash4",
                            messageUuid: nil,
                            threadId: fixture.groupId.hexString,
                            authorId: "051111111111111111111111111111111111111111111111111111111111111112",
                            variant: .standardIncoming,
                            body: "Test4",
                            timestampMs: 1234567890004,
                            receivedAtTimestampMs: 1234567890004,
                            wasRead: false,
                            hasMention: false,
                            expiresInSeconds: 0,
                            expiresStartedAtMs: nil,
                            linkPreviewUrl: nil,
                            openGroupServerMessageId: nil,
                            openGroupWhisper: false,
                            openGroupWhisperMods: false,
                            openGroupWhisperTo: nil,
                            state: .sent,
                            recipientReadTimestampMs: nil,
                            mostRecentFailureText: nil,
                            proMessageFeatures: .none,
                            proProfileFeatures: .none
                        ).inserted(db)
                    }
                }
                
                // MARK: ---- throws if the admin signature fails to verify
                it("throws if the admin signature fails to verify") {
                    try await fixture.mockCrypto
                        .when { $0.verify(.signature(message: .any, publicKey: .any, signature: .any)) }
                        .thenReturn(false)
                    
                    await expect {
                        try await fixture.mockStorage.write { db in
                            try MessageReceiver.handleGroupUpdateMessage(
                                db,
                                threadId: fixture.groupId.hexString,
                                threadVariant: .group,
                                message: fixture.deleteContentMessage,
                                decodedMessage: fixture.decodedMessage,
                                serverExpirationTimestamp: 1234567890,
                                suppressNotifications: false,
                                currentUserSessionIds: [],
                                using: fixture.dependencies
                            )
                        }
                    }.to(throwError(MessageError.invalidMessage("Test")))
                }
                
                // MARK: ---- and there is no admin signature
                context("and there is no admin signature") {
                    // MARK: ------ removes content for specific messages from the database
                    it("removes content for specific messages from the database") {
                        fixture.deleteContentMessage = GroupUpdateDeleteMemberContentMessage(
                            memberSessionIds: [],
                            messageHashes: ["TestMessageHash3"],
                            adminSignature: nil
                        )
                        fixture.deleteContentMessage.sender = "051111111111111111111111111111111111111111111111111111111111111112"
                        fixture.deleteContentMessage.sentTimestampMs = 1234567890000
                        fixture.decodedMessage = DecodedMessage(
                            content: Data(
                                base64Encoded: "CAESvwEKABIAGrYBCAYSACjQiOyP9yM4AUKmAfjX/WXVFs+QE5Eh54Esw9/N" +
                                "lYza3k8MOvcRAI7y8k0JzLsm/KpXxKP7Zx7+5YyII9sCRXzFK2U4/X9SSMN088YEr/5wKoDfL5q" +
                                "PQbN70aa59WS8YE+yWcniQO0KXfAzr6Acn40fsa9BMr9tnQLfvxY8vD7qBz9iEOV9jTxPzxUoD+" +
                                "JelIbsv2qlkOl9vs166NC/Y772NZmUAR5u1ewL4SYEWkqX5R4gAA=="
                            )!,
                            sender: SessionId(.standard, hex: "1111111111111111111111111111111111111111111111111111111111111112"),
                            decodedEnvelope: nil,
                            sentTimestampMs: 1234567800000
                        )
                        
                        try await fixture.mockStorage.write { db in
                            try MessageReceiver.handleGroupUpdateMessage(
                                db,
                                threadId: fixture.groupId.hexString,
                                threadVariant: .group,
                                message: fixture.deleteContentMessage,
                                decodedMessage: fixture.decodedMessage,
                                serverExpirationTimestamp: 1234567890,
                                suppressNotifications: false,
                                currentUserSessionIds: [],
                                using: fixture.dependencies
                            )
                        }
                        
                        let interactions: [Interaction] = try await fixture.mockStorage.read { db in
                            try Interaction.fetchAll(db)
                        }
                        expect(interactions.count).to(equal(4))    /// Message isn't deleted, just content
                        expect(interactions.map { $0.body }).toNot(contain("Test3"))
                    }
                    
                    // MARK: ------ removes content for all messages from the sender from the database
                    it("removes content for all messages from the sender from the database") {
                        fixture.deleteContentMessage = GroupUpdateDeleteMemberContentMessage(
                            memberSessionIds: [
                                "051111111111111111111111111111111111111111111111111111111111111112"
                            ],
                            messageHashes: [],
                            adminSignature: nil
                        )
                        fixture.deleteContentMessage.sender = "051111111111111111111111111111111111111111111111111111111111111112"
                        fixture.deleteContentMessage.sentTimestampMs = 1234567800000
                        fixture.decodedMessage = DecodedMessage(
                            content: Data(
                                base64Encoded: "CAESvwEKABIAGrYBCAYSACjQiOyP9yM4AUKmAfjX/WXVFs+QE5Eh54Esw9/N" +
                                "lYza3k8MOvcRAI7y8k0JzLsm/KpXxKP7Zx7+5YyII9sCRXzFK2U4/X9SSMN088YEr/5wKoDfL5q" +
                                "PQbN70aa59WS8YE+yWcniQO0KXfAzr6Acn40fsa9BMr9tnQLfvxY8vD7qBz9iEOV9jTxPzxUoD+" +
                                "JelIbsv2qlkOl9vs166NC/Y772NZmUAR5u1ewL4SYEWkqX5R4gAA=="
                            )!,
                            sender: SessionId(.standard, hex: "1111111111111111111111111111111111111111111111111111111111111112"),
                            decodedEnvelope: nil,
                            sentTimestampMs: 1234567800000
                        )
                        
                        try await fixture.mockStorage.write { db in
                            try MessageReceiver.handleGroupUpdateMessage(
                                db,
                                threadId: fixture.groupId.hexString,
                                threadVariant: .group,
                                message: fixture.deleteContentMessage,
                                decodedMessage: fixture.decodedMessage,
                                serverExpirationTimestamp: 1234567890,
                                suppressNotifications: false,
                                currentUserSessionIds: [],
                                using: fixture.dependencies
                            )
                        }
                        
                        let interactions: [Interaction] = try await fixture.mockStorage.read { db in
                            try Interaction.fetchAll(db)
                        }
                        expect(interactions.count).to(equal(4))    /// Message isn't deleted, just content
                        expect(interactions.map { $0.body }).toNot(contain("Test3"))
                    }
                    
                    // MARK: ------ ignores messages not sent by the sender
                    it("ignores messages not sent by the sender") {
                        fixture.deleteContentMessage = GroupUpdateDeleteMemberContentMessage(
                            memberSessionIds: [],
                            messageHashes: ["TestMessageHash1", "TestMessageHash3"],
                            adminSignature: nil
                        )
                        fixture.deleteContentMessage.sender = "051111111111111111111111111111111111111111111111111111111111111112"
                        fixture.deleteContentMessage.sentTimestampMs = 1234567890000
                        fixture.decodedMessage = DecodedMessage(
                            content: Data(
                                base64Encoded: "CAESvwEKABIAGrYBCAYSACjQiOyP9yM4AUKmAfjX/WXVFs+QE5Eh54Esw9/N" +
                                "lYza3k8MOvcRAI7y8k0JzLsm/KpXxKP7Zx7+5YyII9sCRXzFK2U4/X9SSMN088YEr/5wKoDfL5q" +
                                "PQbN70aa59WS8YE+yWcniQO0KXfAzr6Acn40fsa9BMr9tnQLfvxY8vD7qBz9iEOV9jTxPzxUoD+" +
                                "JelIbsv2qlkOl9vs166NC/Y772NZmUAR5u1ewL4SYEWkqX5R4gAA=="
                            )!,
                            sender: SessionId(.standard, hex: "1111111111111111111111111111111111111111111111111111111111111112"),
                            decodedEnvelope: nil,
                            sentTimestampMs: 1234567800000
                        )
                        
                        try await fixture.mockStorage.write { db in
                            try MessageReceiver.handleGroupUpdateMessage(
                                db,
                                threadId: fixture.groupId.hexString,
                                threadVariant: .group,
                                message: fixture.deleteContentMessage,
                                decodedMessage: fixture.decodedMessage,
                                serverExpirationTimestamp: 1234567890,
                                suppressNotifications: false,
                                currentUserSessionIds: [],
                                using: fixture.dependencies
                            )
                        }
                        
                        let interactions: [Interaction] = try await fixture.mockStorage.read { db in
                            try Interaction.fetchAll(db)
                        }
                        expect(interactions.count).to(equal(4))
                        expect(interactions.map { $0.serverHash }).to(equal([
                            "TestMessageHash1", "TestMessageHash2",
                            "TestMessageHash3", "TestMessageHash4"
                        ]))
                        expect(interactions.map { $0.body }).to(equal([
                            "Test1",
                            "Test2",
                            nil,
                            "Test4"
                        ]))
                        expect(interactions.map { $0.authorId }).to(equal([
                            "051111111111111111111111111111111111111111111111111111111111111111",
                            "051111111111111111111111111111111111111111111111111111111111111111",
                            "051111111111111111111111111111111111111111111111111111111111111112",
                            "051111111111111111111111111111111111111111111111111111111111111112"
                        ]))
                        expect(interactions.map { $0.timestampMs }).to(equal([
                            1234560000001,
                            1234567890002,
                            1234560000003,
                            1234567890004
                        ]))
                    }
                    
                    // MARK: ------ ignores messages sent after the delete content message was sent
                    it("ignores messages sent after the delete content message was sent") {
                        fixture.deleteContentMessage = GroupUpdateDeleteMemberContentMessage(
                            memberSessionIds: [],
                            messageHashes: ["TestMessageHash3", "TestMessageHash4"],
                            adminSignature: nil
                        )
                        fixture.deleteContentMessage.sender = "051111111111111111111111111111111111111111111111111111111111111112"
                        fixture.deleteContentMessage.sentTimestampMs = 1234567800000
                        fixture.decodedMessage = DecodedMessage(
                            content: Data(
                                base64Encoded: "CAESvwEKABIAGrYBCAYSACjQiOyP9yM4AUKmAfjX/WXVFs+QE5Eh54Esw9/N" +
                                "lYza3k8MOvcRAI7y8k0JzLsm/KpXxKP7Zx7+5YyII9sCRXzFK2U4/X9SSMN088YEr/5wKoDfL5q" +
                                "PQbN70aa59WS8YE+yWcniQO0KXfAzr6Acn40fsa9BMr9tnQLfvxY8vD7qBz9iEOV9jTxPzxUoD+" +
                                "JelIbsv2qlkOl9vs166NC/Y772NZmUAR5u1ewL4SYEWkqX5R4gAA=="
                            )!,
                            sender: SessionId(.standard, hex: "1111111111111111111111111111111111111111111111111111111111111112"),
                            decodedEnvelope: nil,
                            sentTimestampMs: 1234567800000
                        )
                        
                        try await fixture.mockStorage.write { db in
                            try MessageReceiver.handleGroupUpdateMessage(
                                db,
                                threadId: fixture.groupId.hexString,
                                threadVariant: .group,
                                message: fixture.deleteContentMessage,
                                decodedMessage: fixture.decodedMessage,
                                serverExpirationTimestamp: 1234567890,
                                suppressNotifications: false,
                                currentUserSessionIds: [],
                                using: fixture.dependencies
                            )
                        }
                        
                        let interactions: [Interaction] = try await fixture.mockStorage.read { db in
                            try Interaction.fetchAll(db)
                        }
                        expect(interactions.count).to(equal(4))
                        expect(interactions.map { $0.serverHash }).to(equal([
                            "TestMessageHash1", "TestMessageHash2",
                            "TestMessageHash3", "TestMessageHash4"
                        ]))
                        expect(interactions.map { $0.body }).to(equal([
                            "Test1",
                            "Test2",
                            nil,
                            "Test4"
                        ]))
                        expect(interactions.map { $0.authorId }).to(equal([
                            "051111111111111111111111111111111111111111111111111111111111111111",
                            "051111111111111111111111111111111111111111111111111111111111111111",
                            "051111111111111111111111111111111111111111111111111111111111111112",
                            "051111111111111111111111111111111111111111111111111111111111111112"
                        ]))
                        expect(interactions.map { $0.timestampMs }).to(equal([
                            1234560000001,
                            1234567890002,
                            1234560000003,
                            1234567890004
                        ]))
                    }
                }
                
                // MARK: ---- and there is no admin signature
                context("and there is no admin signature") {
                    // MARK: ------ removes content for specific messages from the database
                    it("removes content for specific messages from the database") {
                        fixture.deleteContentMessage = GroupUpdateDeleteMemberContentMessage(
                            memberSessionIds: [],
                            messageHashes: ["TestMessageHash3"],
                            adminSignature: .standard(signature: "TestSignature".bytes)
                        )
                        fixture.deleteContentMessage.sender = "051111111111111111111111111111111111111111111111111111111111111112"
                        fixture.deleteContentMessage.sentTimestampMs = 1234567890000
                        fixture.decodedMessage = DecodedMessage(
                            content: Data(
                                base64Encoded: "CAESvwEKABIAGrYBCAYSACjQiOyP9yM4AUKmAfjX/WXVFs+QE5Eh54Esw9/N" +
                                "lYza3k8MOvcRAI7y8k0JzLsm/KpXxKP7Zx7+5YyII9sCRXzFK2U4/X9SSMN088YEr/5wKoDfL5q" +
                                "PQbN70aa59WS8YE+yWcniQO0KXfAzr6Acn40fsa9BMr9tnQLfvxY8vD7qBz9iEOV9jTxPzxUoD+" +
                                "JelIbsv2qlkOl9vs166NC/Y772NZmUAR5u1ewL4SYEWkqX5R4gAA=="
                            )!,
                            sender: SessionId(.standard, hex: "1111111111111111111111111111111111111111111111111111111111111112"),
                            decodedEnvelope: nil,
                            sentTimestampMs: 1234567800000
                        )
                        
                        try await fixture.mockStorage.write { db in
                            try MessageReceiver.handleGroupUpdateMessage(
                                db,
                                threadId: fixture.groupId.hexString,
                                threadVariant: .group,
                                message: fixture.deleteContentMessage,
                                decodedMessage: fixture.decodedMessage,
                                serverExpirationTimestamp: 1234567890,
                                suppressNotifications: false,
                                currentUserSessionIds: [],
                                using: fixture.dependencies
                            )
                        }
                        
                        let interactions: [Interaction] = try await fixture.mockStorage.read { db in
                            try Interaction.fetchAll(db)
                        }
                        expect(interactions.count).to(equal(4))
                        expect(interactions.map { $0.body }).toNot(contain("Test3"))
                    }
                    
                    // MARK: ------ removes content for all messages for a given id from the database
                    it("removes content for all messages for a given id from the database") {
                        fixture.deleteContentMessage = GroupUpdateDeleteMemberContentMessage(
                            memberSessionIds: [
                                "051111111111111111111111111111111111111111111111111111111111111112"
                            ],
                            messageHashes: [],
                            adminSignature: .standard(signature: "TestSignature".bytes)
                        )
                        fixture.deleteContentMessage.sender = "051111111111111111111111111111111111111111111111111111111111111112"
                        fixture.deleteContentMessage.sentTimestampMs = 1234567800000
                        fixture.decodedMessage = DecodedMessage(
                            content: Data(
                                base64Encoded: "CAESvwEKABIAGrYBCAYSACjQiOyP9yM4AUKmAfjX/WXVFs+QE5Eh54Esw9/N" +
                                "lYza3k8MOvcRAI7y8k0JzLsm/KpXxKP7Zx7+5YyII9sCRXzFK2U4/X9SSMN088YEr/5wKoDfL5q" +
                                "PQbN70aa59WS8YE+yWcniQO0KXfAzr6Acn40fsa9BMr9tnQLfvxY8vD7qBz9iEOV9jTxPzxUoD+" +
                                "JelIbsv2qlkOl9vs166NC/Y772NZmUAR5u1ewL4SYEWkqX5R4gAA=="
                            )!,
                            sender: SessionId(.standard, hex: "1111111111111111111111111111111111111111111111111111111111111112"),
                            decodedEnvelope: nil,
                            sentTimestampMs: 1234567800000
                        )
                        
                        try await fixture.mockStorage.write { db in
                            try MessageReceiver.handleGroupUpdateMessage(
                                db,
                                threadId: fixture.groupId.hexString,
                                threadVariant: .group,
                                message: fixture.deleteContentMessage,
                                decodedMessage: fixture.decodedMessage,
                                serverExpirationTimestamp: 1234567890,
                                suppressNotifications: false,
                                currentUserSessionIds: [],
                                using: fixture.dependencies
                            )
                        }
                        
                        let interactions: [Interaction] = try await fixture.mockStorage.read { db in
                            try Interaction.fetchAll(db)
                        }
                        expect(interactions.count).to(equal(4))
                        expect(interactions.map { $0.body }).toNot(contain("Test3"))
                    }
                    
                    // MARK: ------ removes content for specific messages sent from a user that is not the sender from the database
                    it("removes content for specific messages sent from a user that is not the sender from the database") {
                        fixture.deleteContentMessage = GroupUpdateDeleteMemberContentMessage(
                            memberSessionIds: [],
                            messageHashes: ["TestMessageHash3"],
                            adminSignature: .standard(signature: "TestSignature".bytes)
                        )
                        fixture.deleteContentMessage.sender = "051111111111111111111111111111111111111111111111111111111111111111"
                        fixture.deleteContentMessage.sentTimestampMs = 1234567890000
                        
                        try await fixture.mockStorage.write { db in
                            try MessageReceiver.handleGroupUpdateMessage(
                                db,
                                threadId: fixture.groupId.hexString,
                                threadVariant: .group,
                                message: fixture.deleteContentMessage,
                                decodedMessage: fixture.decodedMessage,
                                serverExpirationTimestamp: 1234567890,
                                suppressNotifications: false,
                                currentUserSessionIds: [],
                                using: fixture.dependencies
                            )
                        }
                        
                        let interactions: [Interaction] = try await fixture.mockStorage.read { db in
                            try Interaction.fetchAll(db)
                        }
                        expect(interactions.count).to(equal(4))
                        expect(interactions.map { $0.body }).toNot(contain("Test3"))
                    }
                    
                    // MARK: ------ removes content for all messages for a given id that is not the sender from the database
                    it("removes content for all messages for a given id that is not the sender from the database") {
                        fixture.deleteContentMessage = GroupUpdateDeleteMemberContentMessage(
                            memberSessionIds: [
                                "051111111111111111111111111111111111111111111111111111111111111112"
                            ],
                            messageHashes: [],
                            adminSignature: .standard(signature: "TestSignature".bytes)
                        )
                        fixture.deleteContentMessage.sender = "051111111111111111111111111111111111111111111111111111111111111111"
                        fixture.deleteContentMessage.sentTimestampMs = 1234567800000
                        
                        try await fixture.mockStorage.write { db in
                            try MessageReceiver.handleGroupUpdateMessage(
                                db,
                                threadId: fixture.groupId.hexString,
                                threadVariant: .group,
                                message: fixture.deleteContentMessage,
                                decodedMessage: fixture.decodedMessage,
                                serverExpirationTimestamp: 1234567890,
                                suppressNotifications: false,
                                currentUserSessionIds: [],
                                using: fixture.dependencies
                            )
                        }
                        
                        let interactions: [Interaction] = try await fixture.mockStorage.read { db in
                            try Interaction.fetchAll(db)
                        }
                        expect(interactions.count).to(equal(4))
                        expect(interactions.map { $0.body }).toNot(contain("Test3"))
                    }
                    
                    // MARK: ------ ignores messages sent after the delete content message was sent
                    it("ignores messages sent after the delete content message was sent") {
                        fixture.deleteContentMessage = GroupUpdateDeleteMemberContentMessage(
                            memberSessionIds: [
                                "051111111111111111111111111111111111111111111111111111111111111111",
                                "051111111111111111111111111111111111111111111111111111111111111112"
                            ],
                            messageHashes: [],
                            adminSignature: .standard(signature: "TestSignature".bytes)
                        )
                        fixture.deleteContentMessage.sender = "051111111111111111111111111111111111111111111111111111111111111111"
                        fixture.deleteContentMessage.sentTimestampMs = 1234567890000
                        
                        try await fixture.mockStorage.write { db in
                            try MessageReceiver.handleGroupUpdateMessage(
                                db,
                                threadId: fixture.groupId.hexString,
                                threadVariant: .group,
                                message: fixture.deleteContentMessage,
                                decodedMessage: fixture.decodedMessage,
                                serverExpirationTimestamp: 1234567890,
                                suppressNotifications: false,
                                currentUserSessionIds: [],
                                using: fixture.dependencies
                            )
                        }
                        
                        let interactions: [Interaction] = try await fixture.mockStorage.read { db in
                            try Interaction.fetchAll(db)
                        }
                        expect(interactions.count).to(equal(4))
                        expect(interactions.map { $0.serverHash }).to(equal([
                            "TestMessageHash1", "TestMessageHash2",
                            "TestMessageHash3", "TestMessageHash4"
                        ]))
                        expect(interactions.map { $0.body }).to(equal([
                            nil,
                            "Test2",
                            nil,
                            "Test4"
                        ]))
                        expect(interactions.map { $0.authorId }).to(equal([
                            "051111111111111111111111111111111111111111111111111111111111111111",
                            "051111111111111111111111111111111111111111111111111111111111111111",
                            "051111111111111111111111111111111111111111111111111111111111111112",
                            "051111111111111111111111111111111111111111111111111111111111111112"
                        ]))
                        expect(interactions.map { $0.timestampMs }).to(equal([
                            1234560000001,
                            1234567890002,
                            1234560000003,
                            1234567890004
                        ]))
                    }
                }
                
                // MARK: ---- and the current user is an admin
                context("and the current user is an admin") {
                    beforeEach {
                        try await fixture.mockStorage.write { db in
                            try ClosedGroup(
                                threadId: fixture.groupId.hexString,
                                name: "TestGroup",
                                formationTimestamp: 1234567890,
                                shouldPoll: true,
                                groupIdentityPrivateKey: fixture.groupSecretKey,
                                authData: nil,
                                invited: false
                            ).upsert(db)
                        }
                    }
                    
                    // MARK: ------ deletes the messages from the swarm
                    it("deletes the messages from the swarm") {
                        fixture.deleteContentMessage = GroupUpdateDeleteMemberContentMessage(
                            memberSessionIds: [],
                            messageHashes: ["TestMessageHash3"],
                            adminSignature: nil
                        )
                        fixture.deleteContentMessage.sender = "051111111111111111111111111111111111111111111111111111111111111112"
                        fixture.deleteContentMessage.sentTimestampMs = 1234567800000
                        fixture.decodedMessage = DecodedMessage(
                            content: Data(
                                base64Encoded: "CAESvwEKABIAGrYBCAYSACjQiOyP9yM4AUKmAfjX/WXVFs+QE5Eh54Esw9/N" +
                                "lYza3k8MOvcRAI7y8k0JzLsm/KpXxKP7Zx7+5YyII9sCRXzFK2U4/X9SSMN088YEr/5wKoDfL5q" +
                                "PQbN70aa59WS8YE+yWcniQO0KXfAzr6Acn40fsa9BMr9tnQLfvxY8vD7qBz9iEOV9jTxPzxUoD+" +
                                "JelIbsv2qlkOl9vs166NC/Y772NZmUAR5u1ewL4SYEWkqX5R4gAA=="
                            )!,
                            sender: SessionId(.standard, hex: "1111111111111111111111111111111111111111111111111111111111111112"),
                            decodedEnvelope: nil,
                            sentTimestampMs: 1234567800000
                        )
                        
                        try await fixture.mockStorage.write { db in
                            try MessageReceiver.handleGroupUpdateMessage(
                                db,
                                threadId: fixture.groupId.hexString,
                                threadVariant: .group,
                                message: fixture.deleteContentMessage,
                                decodedMessage: fixture.decodedMessage,
                                serverExpirationTimestamp: 1234567890,
                                suppressNotifications: false,
                                currentUserSessionIds: [],
                                using: fixture.dependencies
                            )
                        }
                        
                        await fixture.mockNetwork
                            .verify {
                                try await $0.send(
                                    endpoint: Network.StorageServer.Endpoint.deleteMessages,
                                    destination: .randomSnode(
                                        swarmPublicKey: fixture.groupId.hexString
                                    ),
                                    body: try! JSONEncoder(using: fixture.dependencies).encode(
                                        Network.StorageServer.DeleteMessagesRequest(
                                            messageHashes: ["TestMessageHash3"],
                                            requireSuccessfulDeletion: false,
                                            authMethod: Authentication.groupAdmin(
                                                groupSessionId: fixture.groupId,
                                                ed25519SecretKey: Array(fixture.groupSecretKey)
                                            )
                                        )
                                    ),
                                    category: .standardSmall,
                                    requestTimeout: Network.defaultTimeout,
                                    overallTimeout: nil
                                )
                            }
                            .wasCalled(exactly: 1, timeout: .milliseconds(250))
                    }
                }
                
                // MARK: ---- and the current user is not an admin
                context("and the current user is not an admin") {
                    beforeEach {
                        try await fixture.mockLibSessionCache
                            .when { $0.isAdmin(groupSessionId: .any) }
                            .thenReturn(false)
                    }
                    
                    // MARK: ------ does not delete the messages from the swarm
                    it("does not delete the messages from the swarm") {
                        fixture.deleteContentMessage = GroupUpdateDeleteMemberContentMessage(
                            memberSessionIds: [],
                            messageHashes: ["TestMessageHash3"],
                            adminSignature: nil
                        )
                        fixture.deleteContentMessage.sender = "051111111111111111111111111111111111111111111111111111111111111112"
                        fixture.deleteContentMessage.sentTimestampMs = 1234567890000
                        fixture.decodedMessage = DecodedMessage(
                            content: Data(
                                base64Encoded: "CAESvwEKABIAGrYBCAYSACjQiOyP9yM4AUKmAfjX/WXVFs+QE5Eh54Esw9/N" +
                                "lYza3k8MOvcRAI7y8k0JzLsm/KpXxKP7Zx7+5YyII9sCRXzFK2U4/X9SSMN088YEr/5wKoDfL5q" +
                                "PQbN70aa59WS8YE+yWcniQO0KXfAzr6Acn40fsa9BMr9tnQLfvxY8vD7qBz9iEOV9jTxPzxUoD+" +
                                "JelIbsv2qlkOl9vs166NC/Y772NZmUAR5u1ewL4SYEWkqX5R4gAA=="
                            )!,
                            sender: SessionId(.standard, hex: "1111111111111111111111111111111111111111111111111111111111111112"),
                            decodedEnvelope: nil,
                            sentTimestampMs: 1234567800000
                        )
                        
                        try await fixture.mockStorage.write { db in
                            try MessageReceiver.handleGroupUpdateMessage(
                                db,
                                threadId: fixture.groupId.hexString,
                                threadVariant: .group,
                                message: fixture.deleteContentMessage,
                                decodedMessage: fixture.decodedMessage,
                                serverExpirationTimestamp: 1234567890,
                                suppressNotifications: false,
                                currentUserSessionIds: [],
                                using: fixture.dependencies
                            )
                        }
                        
                        await fixture.mockNetwork
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
            
            // MARK: -- when receiving a delete message
            context("when receiving a delete message") {
                beforeEach {
                    var cGroupId: [CChar] = fixture.groupId.hexString.cString(using: .utf8)!
                    var userGroup: ugroups_group_info = ugroups_group_info()
                    user_groups_get_or_construct_group(fixture.userGroupsConfig.conf, &userGroup, &cGroupId)
                    userGroup.set(\.name, to: "TestName")
                    user_groups_set_group(fixture.userGroupsConfig.conf, &userGroup)
                    
                    // Rekey a couple of times to increase the key generation to 1
                    var fakeHash1: [CChar] = "fakehash1".cString(using: .utf8)!
                    var fakeHash2: [CChar] = "fakehash2".cString(using: .utf8)!
                    var pushResult: UnsafePointer<UInt8>? = nil
                    var pushResultLen: Int = 0
                    _ = groups_keys_rekey(fixture.groupKeysConfig.keysConf, fixture.groupInfoConfig.conf, fixture.groupMembersConfig.conf, &pushResult, &pushResultLen)
                    _ = groups_keys_load_message(fixture.groupKeysConfig.keysConf, &fakeHash1, pushResult, pushResultLen, 1234567890, fixture.groupInfoConfig.conf, fixture.groupMembersConfig.conf)
                    _ = groups_keys_rekey(fixture.groupKeysConfig.keysConf, fixture.groupInfoConfig.conf, fixture.groupMembersConfig.conf, &pushResult, &pushResultLen)
                    _ = groups_keys_load_message(fixture.groupKeysConfig.keysConf, &fakeHash2, pushResult, pushResultLen, 1234567890, fixture.groupInfoConfig.conf, fixture.groupMembersConfig.conf)
                    
                    try await fixture.mockStorage.write { db in
                        try SessionThread.upsert(
                            db,
                            id: fixture.groupId.hexString,
                            variant: .group,
                            values: SessionThread.TargetValues(
                                creationDateTimestamp: .setTo(1234567890),
                                shouldBeVisible: .setTo(true)
                            ),
                            using: fixture.dependencies
                        )
                        
                        try ClosedGroup(
                            threadId: fixture.groupId.hexString,
                            name: "TestGroup",
                            formationTimestamp: 1234567890,
                            shouldPoll: true,
                            groupIdentityPrivateKey: nil,
                            authData: Data([1, 2, 3]),
                            invited: false
                        ).upsert(db)
                        
                        try GroupMember(
                            groupId: fixture.groupId.hexString,
                            profileId: "05\(TestConstants.publicKey)",
                            role: .standard,
                            roleStatus: .accepted,
                            isHidden: false
                        ).insert(db)
                        
                        _ = try Interaction(
                            id: 1,
                            serverHash: nil,
                            messageUuid: nil,
                            threadId: fixture.groupId.hexString,
                            authorId: "051111111111111111111111111111111111111111111111111111111111111111",
                            variant: .standardIncoming,
                            body: "Test",
                            timestampMs: 1234567890,
                            receivedAtTimestampMs: 1234567890,
                            wasRead: false,
                            hasMention: false,
                            expiresInSeconds: 0,
                            expiresStartedAtMs: nil,
                            linkPreviewUrl: nil,
                            openGroupServerMessageId: nil,
                            openGroupWhisper: false,
                            openGroupWhisperMods: false,
                            openGroupWhisperTo: nil,
                            state: .sent,
                            recipientReadTimestampMs: nil,
                            mostRecentFailureText: nil,
                            proMessageFeatures: .none,
                            proProfileFeatures: .none
                        ).inserted(db)
                        
                        try ConfigDump(
                            variant: .groupKeys,
                            sessionId: fixture.groupId.hexString,
                            data: Data([1, 2, 3]),
                            timestampMs: 1234567890
                        ).insert(db)
                        
                        try ConfigDump(
                            variant: .groupInfo,
                            sessionId: fixture.groupId.hexString,
                            data: Data([1, 2, 3]),
                            timestampMs: 1234567890
                        ).insert(db)
                        
                        try ConfigDump(
                            variant: .groupMembers,
                            sessionId: fixture.groupId.hexString,
                            data: Data([1, 2, 3]),
                            timestampMs: 1234567890
                        ).insert(db)
                    }
                }
                    
                // MARK: ---- deletes any interactions from the conversation
                it("deletes any interactions from the conversation") {
                    try await fixture.mockStorage.write { db in
                        try MessageReceiver.handleGroupDelete(
                            db,
                            groupSessionId: fixture.groupId,
                            plaintext: fixture.deleteMessage,
                            using: fixture.dependencies
                        )
                    }
                    
                    let interactions: [Interaction] = try await fixture.mockStorage.read { db in try Interaction.fetchAll(db) }
                    expect(interactions).to(beEmpty())
                }
                
                // MARK: ---- deletes the group auth data
                it("deletes the group auth data") {
                    try await fixture.mockStorage.write { db in
                        try MessageReceiver.handleGroupDelete(
                            db,
                            groupSessionId: fixture.groupId,
                            plaintext: fixture.deleteMessage,
                            using: fixture.dependencies
                        )
                    }
                    
                    let authData: [Data?] = try await fixture.mockStorage.read { db in
                        try ClosedGroup
                            .select(ClosedGroup.Columns.authData)
                            .asRequest(of: Data?.self)
                            .fetchAll(db)
                    }
                    let privateKeyData: [Data?] = try await fixture.mockStorage.read { db in
                        try ClosedGroup
                            .select(ClosedGroup.Columns.groupIdentityPrivateKey)
                            .asRequest(of: Data?.self)
                            .fetchAll(db)
                    }
                    expect(authData).to(equal([nil]))
                    expect(privateKeyData).to(equal([nil]))
                }
                
                // MARK: ---- deletes the group members
                it("deletes the group members") {
                    try await fixture.mockStorage.write { db in
                        try MessageReceiver.handleGroupDelete(
                            db,
                            groupSessionId: fixture.groupId,
                            plaintext: fixture.deleteMessage,
                            using: fixture.dependencies
                        )
                    }
                    
                    let members: [GroupMember] = try await fixture.mockStorage.read { db in try GroupMember.fetchAll(db) }
                    expect(members).to(beEmpty())
                }
                
                // MARK: ---- removes the group libSession state
                it("removes the group libSession state") {
                    try await fixture.mockStorage.write { db in
                        try MessageReceiver.handleGroupDelete(
                            db,
                            groupSessionId: fixture.groupId,
                            plaintext: fixture.deleteMessage,
                            using: fixture.dependencies
                        )
                    }
                    
                    await fixture.mockLibSessionCache
                        .verify { $0.removeConfigs(for: fixture.groupId) }
                        .wasCalled(exactly: 1, timeout: .milliseconds(100))
                }
                
                // MARK: ---- removes the cached libSession state dumps
                it("removes the cached libSession state dumps") {
                    try await fixture.mockStorage.write { db in
                        try MessageReceiver.handleGroupDelete(
                            db,
                            groupSessionId: fixture.groupId,
                            plaintext: fixture.deleteMessage,
                            using: fixture.dependencies
                        )
                    }
                    
                    await fixture.mockLibSessionCache
                        .verify { $0.removeConfigs(for: fixture.groupId) }
                        .wasCalled(exactly: 1, timeout: .milliseconds(100))
                    
                    let dumps: [ConfigDump] = try await fixture.mockStorage.read { db in
                        try ConfigDump
                            .filter(ConfigDump.Columns.publicKey == fixture.groupId.hexString)
                            .fetchAll(db)
                    }
                    expect(dumps).to(beEmpty())
                }
                
                // MARK: ------ unsubscribes from push notifications
                it("unsubscribes from push notifications") {
                    try await fixture.mockUserDefaults
                        .when { $0.string(forKey: UserDefaults.StringKey.deviceToken.rawValue) }
                        .thenReturn(Data([5, 4, 3, 2, 1]).toHexString())
                    try await fixture.mockUserDefaults
                        .when { $0.bool(forKey: UserDefaults.BoolKey.isUsingFullAPNs.rawValue) }
                        .thenReturn(true)
                    
                    try await fixture.mockStorage.write { db in
                        try MessageReceiver.handleGroupDelete(
                            db,
                            groupSessionId: fixture.groupId,
                            plaintext: fixture.deleteMessage,
                            using: fixture.dependencies
                        )
                    }
                    
                    await fixture.mockNetwork
                        .verify {
                            try await $0.send(
                                endpoint: Network.PushNotification.Endpoint.unsubscribe,
                                destination: .server(
                                    method: .post,
                                    server: Network.PushNotification.server,
                                    queryParameters: [:],
                                    headers: [:],
                                    x25519PublicKey: Network.PushNotification.serverPublicKey
                                ),
                                body: try! JSONEncoder(using: fixture.dependencies).encode(
                                    Network.PushNotification.UnsubscribeRequest(
                                        subscriptions: [
                                            Network.PushNotification.UnsubscribeRequest.Subscription(
                                                serviceInfo: Network.PushNotification.ServiceInfo(
                                                    token: Data([5, 4, 3, 2, 1]).toHexString()
                                                ),
                                                authMethod: try! Authentication.with(
                                                    swarmPublicKey: fixture.groupId.hexString,
                                                    using: fixture.dependencies
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
                
                // MARK: ---- and the group is an invitation
                context("and the group is an invitation") {
                    beforeEach {
                        _ = try await fixture.mockStorage.write { db in
                            try ClosedGroup.updateAll(db, ClosedGroup.Columns.invited.set(to: true))
                        }
                    }
                    
                    // MARK: ------ deletes the thread
                    it("deletes the thread") {
                        try await fixture.mockStorage.write { db in
                            try MessageReceiver.handleGroupDelete(
                                db,
                                groupSessionId: fixture.groupId,
                                plaintext: fixture.deleteMessage,
                                using: fixture.dependencies
                            )
                        }
                        
                        let threads: [SessionThread] = try await fixture.mockStorage.read { db in try SessionThread.fetchAll(db) }
                        expect(threads).to(beEmpty())
                    }
                    
                    // MARK: ------ deletes the group
                    it("deletes the group") {
                        try await fixture.mockStorage.write { db in
                            try MessageReceiver.handleGroupDelete(
                                db,
                                groupSessionId: fixture.groupId,
                                plaintext: fixture.deleteMessage,
                                using: fixture.dependencies
                            )
                        }
                        
                        let groups: [ClosedGroup] = try await fixture.mockStorage.read { db in try ClosedGroup.fetchAll(db) }
                        expect(groups).to(beEmpty())
                    }
                    
                    // MARK: ---- stops the poller
                    it("stops the poller") {
                        try await fixture.mockStorage.write { db in
                            try MessageReceiver.handleGroupDelete(
                                db,
                                groupSessionId: fixture.groupId,
                                plaintext: fixture.deleteMessage,
                                using: fixture.dependencies
                            )
                        }
                        
                        await fixture.mockGroupPollerManager
                            .verify { await $0.stopAndRemovePoller(for: fixture.groupId.hexString) }
                            .wasCalled(exactly: 1, timeout: .milliseconds(100))
                    }
                    
                    // MARK: ------ removes the group from the USER_GROUPS config
                    it("removes the group from the USER_GROUPS config") {
                        try await fixture.mockStorage.write { db in
                            try MessageReceiver.handleGroupDelete(
                                db,
                                groupSessionId: fixture.groupId,
                                plaintext: fixture.deleteMessage,
                                using: fixture.dependencies
                            )
                        }
                        
                        var cGroupId: [CChar] = fixture.groupId.hexString.cString(using: .utf8)!
                        var userGroup: ugroups_group_info = ugroups_group_info()
                        expect(user_groups_get_group(fixture.userGroupsConfig.conf, &userGroup, &cGroupId)).to(beFalse())
                    }
                }
                
                // MARK: ---- and the group is not an invitation
                context("and the group is not an invitation") {
                    beforeEach {
                        _ = try await fixture.mockStorage.write { db in
                            try ClosedGroup.updateAll(db, ClosedGroup.Columns.invited.set(to: false))
                        }
                    }
                    
                    // MARK: ------ does not delete the thread
                    it("does not delete the thread") {
                        try await fixture.mockStorage.write { db in
                            try MessageReceiver.handleGroupDelete(
                                db,
                                groupSessionId: fixture.groupId,
                                plaintext: fixture.deleteMessage,
                                using: fixture.dependencies
                            )
                        }
                        
                        let threads: [SessionThread] = try await fixture.mockStorage.read { db in try SessionThread.fetchAll(db) }
                        expect(threads).toNot(beEmpty())
                    }
                    
                    // MARK: ------ does not remove the group from the USER_GROUPS config
                    it("does not remove the group from the USER_GROUPS config") {
                        try await fixture.mockStorage.write { db in
                            try MessageReceiver.handleGroupDelete(
                                db,
                                groupSessionId: fixture.groupId,
                                plaintext: fixture.deleteMessage,
                                using: fixture.dependencies
                            )
                        }
                        
                        var cGroupId: [CChar] = fixture.groupId.hexString.cString(using: .utf8)!
                        var userGroup: ugroups_group_info = ugroups_group_info()
                        expect(user_groups_get_group(fixture.userGroupsConfig.conf, &userGroup, &cGroupId)).to(beTrue())
                    }
                    
                    // MARK: ---- stops the poller and flags the group to not poll
                    it("stops the poller and flags the group to not poll") {
                        try await fixture.mockStorage.write { db in
                            try MessageReceiver.handleGroupDelete(
                                db,
                                groupSessionId: fixture.groupId,
                                plaintext: fixture.deleteMessage,
                                using: fixture.dependencies
                            )
                        }
                        
                        let shouldPoll: [Bool] = try await fixture.mockStorage.read { db in
                            try ClosedGroup
                                .select(ClosedGroup.Columns.shouldPoll)
                                .asRequest(of: Bool.self)
                                .fetchAll(db)
                        }
                        await fixture.mockGroupPollerManager
                            .verify { await $0.stopAndRemovePoller(for: fixture.groupId.hexString) }
                            .wasCalled(exactly: 1, timeout: .milliseconds(100))
                        expect(shouldPoll).to(equal([false]))
                    }
                    
                    // MARK: ------ marks the group in USER_GROUPS as kicked
                    it("marks the group in USER_GROUPS as kicked") {
                        try await fixture.mockStorage.write { db in
                            try MessageReceiver.handleGroupDelete(
                                db,
                                groupSessionId: fixture.groupId,
                                plaintext: fixture.deleteMessage,
                                using: fixture.dependencies
                            )
                        }
                        
                        await fixture.mockLibSessionCache
                            .verify { try $0.markAsKicked(groupSessionIds: [fixture.groupId.hexString]) }
                            .wasCalled(exactly: 1, timeout: .milliseconds(100))
                    }
                }
                
                // MARK: ---- throws if the data is invalid
                it("throws if the data is invalid") {
                    fixture.deleteMessage = Data([1, 2, 3])
                    
                    await expect {
                        try await fixture.mockStorage.write { db in
                            try MessageReceiver.handleGroupDelete(
                                db,
                                groupSessionId: fixture.groupId,
                                plaintext: fixture.deleteMessage,
                                using: fixture.dependencies
                            )
                        }
                    }.to(throwError(MessageError.invalidMessage("Test")))
                }
                
                // MARK: ---- throws if the included member id does not match the current user
                it("throws if the included member id does not match the current user") {
                    fixture.deleteMessage = try! LibSessionMessage.groupKicked(
                        memberId: "051111111111111111111111111111111111111111111111111111111111111111",
                        groupKeysGen: 1
                    ).1
                    
                    await expect {
                        try await fixture.mockStorage.write { db in
                            try MessageReceiver.handleGroupDelete(
                                db,
                                groupSessionId: fixture.groupId,
                                plaintext: fixture.deleteMessage,
                                using: fixture.dependencies
                            )
                        }
                    }.to(throwError(MessageError.ignorableMessage))
                }
                
                // MARK: ---- throws if the key generation is earlier than the current keys generation
                it("throws if the key generation is earlier than the current keys generation") {
                    fixture.deleteMessage = try! LibSessionMessage.groupKicked(
                        memberId: "05\(TestConstants.publicKey)",
                        groupKeysGen: 0
                    ).1
                    
                    await expect {
                        try await fixture.mockStorage.write { db in
                            try MessageReceiver.handleGroupDelete(
                                db,
                                groupSessionId: fixture.groupId,
                                plaintext: fixture.deleteMessage,
                                using: fixture.dependencies
                            )
                        }
                    }.to(throwError(MessageError.ignorableMessage))
                }
            }
            
            // MARK: -- when receiving a visible message from a member that is not accepted and the current user is a group admin
            context("when receiving a visible message from a member that is not accepted and the current user is a group admin") {
                beforeEach {
                    // Only update members if they already exist in the group
                    var cMemberId: [CChar] = "051111111111111111111111111111111111111111111111111111111111111112".cString(using: .utf8)!
                    var groupMember: config_group_member = config_group_member()
                    _ = groups_members_get_or_construct(fixture.groupMembersConfig.conf, &groupMember, &cMemberId)
                    groupMember.set(\.name, to: "TestOtherMember")
                    groupMember.invited = 1
                    groups_members_set(fixture.groupMembersConfig.conf, &groupMember)
                    
                    fixture.decodedMessage = DecodedMessage(
                        content: Data(
                            base64Encoded: "CAESvwEKABIAGrYBCAYSACjQiOyP9yM4AUKmAfjX/WXVFs+QE5Eh54Esw9/N" +
                            "lYza3k8MOvcRAI7y8k0JzLsm/KpXxKP7Zx7+5YyII9sCRXzFK2U4/X9SSMN088YEr/5wKoDfL5q" +
                            "PQbN70aa59WS8YE+yWcniQO0KXfAzr6Acn40fsa9BMr9tnQLfvxY8vD7qBz9iEOV9jTxPzxUoD+" +
                            "JelIbsv2qlkOl9vs166NC/Y772NZmUAR5u1ewL4SYEWkqX5R4gAA=="
                        )!,
                        sender: SessionId(.standard, hex: "1111111111111111111111111111111111111111111111111111111111111112"),
                        decodedEnvelope: nil,
                        sentTimestampMs: 1234567800000
                    )
                    
                    try await fixture.mockStorage.write { db in
                        try SessionThread.upsert(
                            db,
                            id: fixture.groupId.hexString,
                            variant: .group,
                            values: SessionThread.TargetValues(
                                creationDateTimestamp: .setTo(1234567890),
                                shouldBeVisible: .setTo(true)
                            ),
                            using: fixture.dependencies
                        )
                        
                        try ClosedGroup(
                            threadId: fixture.groupId.hexString,
                            name: "TestGroup",
                            formationTimestamp: 1234567890,
                            shouldPoll: true,
                            groupIdentityPrivateKey: fixture.groupSecretKey,
                            authData: nil,
                            invited: false
                        ).upsert(db)
                    }
                }
                
                // MARK: ---- updates a pending member entry to an accepted member
                it("updates a pending member entry to an accepted member") {
                    try await fixture.mockStorage.write { db in
                        try GroupMember(
                            groupId: fixture.groupId.hexString,
                            profileId: "051111111111111111111111111111111111111111111111111111111111111112",
                            role: .standard,
                            roleStatus: .pending,
                            isHidden: false
                        ).upsert(db)
                    }
                    
                    try await fixture.mockStorage.write { db in
                        try MessageReceiver.handle(
                            db,
                            threadId: fixture.groupId.hexString,
                            threadVariant: .group,
                            message: fixture.visibleMessage,
                            decodedMessage: fixture.decodedMessage,
                            serverExpirationTimestamp: nil,
                            suppressNotifications: false,
                            currentUserSessionIds: [],
                            using: fixture.dependencies
                        )
                    }
                    
                    let members: [GroupMember] = try await fixture.mockStorage.read { db in
                        try GroupMember.fetchAll(db)
                    }
                    expect(members.count).to(equal(1))
                    expect(members.first?.profileId).to(equal(
                        "051111111111111111111111111111111111111111111111111111111111111112"
                    ))
                    expect(members.first?.role).to(equal(.standard))
                    expect(members.first?.roleStatus).to(equal(.accepted))
                    
                    var cMemberId: [CChar] = "051111111111111111111111111111111111111111111111111111111111111112".cString(using: .utf8)!
                    var groupMember: config_group_member = config_group_member()
                    expect(groups_members_get(fixture.groupMembersConfig.conf, &groupMember, &cMemberId)).to(beTrue())
                    expect(groupMember.invited).to(equal(0))
                }
                
                // MARK: ---- updates a failed member entry to an accepted member
                it("updates a failed member entry to an accepted member") {
                    var cMemberId1: [CChar] = "051111111111111111111111111111111111111111111111111111111111111112".cString(using: .utf8)!
                    var groupMember1: config_group_member = config_group_member()
                    _ = groups_members_get(fixture.groupMembersConfig.conf, &groupMember1, &cMemberId1)
                    groupMember1.invited = 2
                    groups_members_set(fixture.groupMembersConfig.conf, &groupMember1)
                    
                    try await fixture.mockStorage.write { db in
                        try GroupMember(
                            groupId: fixture.groupId.hexString,
                            profileId: "051111111111111111111111111111111111111111111111111111111111111112",
                            role: .standard,
                            roleStatus: .failed,
                            isHidden: false
                        ).upsert(db)
                    }
                    
                    try await fixture.mockStorage.write { db in
                        try MessageReceiver.handle(
                            db,
                            threadId: fixture.groupId.hexString,
                            threadVariant: .group,
                            message: fixture.visibleMessage,
                            decodedMessage: fixture.decodedMessage,
                            serverExpirationTimestamp: nil,
                            suppressNotifications: false,
                            currentUserSessionIds: [],
                            using: fixture.dependencies
                        )
                    }
                    
                    let members: [GroupMember] = try await fixture.mockStorage.read { db in
                        try GroupMember.fetchAll(db)
                    }
                    expect(members.count).to(equal(1))
                    expect(members.first?.profileId).to(equal(
                        "051111111111111111111111111111111111111111111111111111111111111112"
                    ))
                    expect(members.first?.role).to(equal(.standard))
                    expect(members.first?.roleStatus).to(equal(.accepted))
                    
                    var cMemberId: [CChar] = "051111111111111111111111111111111111111111111111111111111111111112".cString(using: .utf8)!
                    var groupMember: config_group_member = config_group_member()
                    expect(groups_members_get(fixture.groupMembersConfig.conf, &groupMember, &cMemberId)).to(beTrue())
                    expect(groupMember.invited).to(equal(0))
                }
                
                // MARK: ---- updates the entry in libSession directly if there is no database value
                it("updates the entry in libSession directly if there is no database value") {
                    try await fixture.mockStorage.write { db in
                        _ = try GroupMember.deleteAll(db)
                    }
                    
                    try await fixture.mockStorage.write { db in
                        try MessageReceiver.handle(
                            db,
                            threadId: fixture.groupId.hexString,
                            threadVariant: .group,
                            message: fixture.visibleMessage,
                            decodedMessage: fixture.decodedMessage,
                            serverExpirationTimestamp: nil,
                            suppressNotifications: false,
                            currentUserSessionIds: [],
                            using: fixture.dependencies
                        )
                    }
                    
                    var cMemberId: [CChar] = "051111111111111111111111111111111111111111111111111111111111111112".cString(using: .utf8)!
                    var groupMember: config_group_member = config_group_member()
                    expect(groups_members_get(fixture.groupMembersConfig.conf, &groupMember, &cMemberId)).to(beTrue())
                    expect(groupMember.invited).to(equal(0))
                }
            }
        }
    }
}

// MARK: - Configuration

private class MessageReceiverGroupsTestFixture: FixtureBase {
    var mockStorage: Storage {
        mock(for: .storage) { dependencies in
            try! Storage.createForTesting(using: dependencies)
        }
    }
    var mockNetwork: MockNetwork { mock(for: .network) }
    var mockJobRunner: MockJobRunner { mock(for: .jobRunner) }
    var mockAppContext: MockAppContext { mock(for: .appContext) }
    var mockUserDefaults: MockUserDefaults { mock(defaults: .standard) }
    var mockCrypto: MockCrypto { mock(for: .crypto) }
    var mockKeychain: MockKeychain { mock(for: .keychain) }
    var mockFileManager: MockFileManager { mock(for: .fileManager) }
    var mockExtensionHelper: MockExtensionHelper { mock(for: .extensionHelper) }
    var mockGroupPollerManager: MockGroupPollerManager { mock(for: .groupPollerManager) }
    var mockNotificationsManager: MockNotificationsManager { mock(for: .notificationsManager) }
    var mockGeneralCache: MockGeneralCache { mock(cache: .general) }
    var mockLibSessionCache: MockLibSessionCache { mock(cache: .libSession) }
    var mockPoller: MockPoller<SwarmPoller.PollResponse> { mock() }
    
    let userGroupsConfig: LibSession.Config
    let convoInfoVolatileConfig: LibSession.Config
    let groupInfoConfig: LibSession.Config
    let groupMembersConfig: LibSession.Config
    let groupKeysConfig: LibSession.Config
    
    let groupSeed: Data
    let groupKeyPair: KeyPair
    let groupId: SessionId
    let groupSecretKey: Data
    
    var decodedMessage: DecodedMessage
    let inviteMessage: GroupUpdateInviteMessage
    let promoteMessage: GroupUpdatePromoteMessage
    var infoChangedMessage: GroupUpdateInfoChangeMessage
    var memberChangedMessage: GroupUpdateMemberChangeMessage
    let memberLeftMessage: GroupUpdateMemberLeftMessage
    let memberLeftNotificationMessage: GroupUpdateMemberLeftNotificationMessage
    let inviteResponseMessage: GroupUpdateInviteResponseMessage
    var deleteMessage: Data
    var deleteContentMessage: GroupUpdateDeleteMemberContentMessage
    let visibleMessageProto: SNProtoContent
    let visibleMessage: VisibleMessage
    
    override init() {
        let constants = Self.setupConstants()
        groupSeed = constants.groupSeed
        groupKeyPair = constants.groupKeyPair
        groupId = constants.groupId
        groupSecretKey = constants.groupSecretKey
        
        let configs = Self.setupConfigs(constants: constants)
        userGroupsConfig = configs.userGroupsConfig
        convoInfoVolatileConfig = configs.convoInfoVolatileConfig
        groupInfoConfig = configs.groupInfoConfig
        groupMembersConfig = configs.groupMembersConfig
        groupKeysConfig = configs.groupKeysConfig
        
        let messages = Self.setupMessages(constants: constants)
        decodedMessage = messages.decodedMessage
        inviteMessage = messages.inviteMessage
        promoteMessage = messages.promoteMessage
        infoChangedMessage = messages.infoChangedMessage
        memberChangedMessage = messages.memberChangedMessage
        memberLeftMessage = messages.memberLeftMessage
        memberLeftNotificationMessage = messages.memberLeftNotificationMessage
        inviteResponseMessage = messages.inviteResponseMessage
        deleteMessage = messages.deleteMessage
        deleteContentMessage = messages.deleteContentMessage
        visibleMessageProto = messages.visibleMessageProto
        visibleMessage = messages.visibleMessage
        
        super.init()
    }
    
    static func create() async throws -> MessageReceiverGroupsTestFixture {
        let fixture: MessageReceiverGroupsTestFixture = MessageReceiverGroupsTestFixture()
        try await fixture.applyBaselineStubs()
        
        return fixture
    }
    
    // MARK: - Setup
    
    typealias Constants = (groupSeed: Data, groupId: SessionId, groupKeyPair: KeyPair, groupSecretKey: Data)
    private static func setupConstants() -> Constants {
        let groupSeed: Data = Data(hex: "0123456789abcdef0123456789abcdeffedcba9876543210fedcba9876543210")
        let groupId: SessionId = SessionId(
            .group,
            hex: "03cbd569f56fb13ea95a3f0c05c331cc24139c0090feb412069dc49fab34406ece"
        )
        let groupKeyPair: KeyPair = try! Crypto(using: .any).tryGenerate(.ed25519KeyPair(seed: Array(groupSeed)))
        let groupSecretKey: Data = Data(hex:
            "0123456789abcdef0123456789abcdeffedcba9876543210fedcba9876543210" +
            "cbd569f56fb13ea95a3f0c05c331cc24139c0090feb412069dc49fab34406ece"
        )
        
        return (groupSeed, groupId, groupKeyPair, groupSecretKey)
    }
    
    typealias Configs = (
        userGroupsConfig: LibSession.Config,
        convoInfoVolatileConfig: LibSession.Config,
        groupInfoConfig: LibSession.Config,
        groupMembersConfig: LibSession.Config,
        groupKeysConfig: LibSession.Config
    )
    private static func setupConfigs(constants: Constants) -> Configs {
        var secretKey: [UInt8] = Array(Data(hex: TestConstants.edSecretKey))
        var groupEdPK: [UInt8] = constants.groupKeyPair.publicKey
        var groupEdSK: [UInt8] = constants.groupKeyPair.secretKey
        
        let userGroupsConfig: LibSession.Config = {
            var conf: UnsafeMutablePointer<config_object>!
            _ = user_groups_init(&conf, &secretKey, nil, 0, nil)
            
            return .userGroups(conf)
        }()
        let convoInfoVolatileConfig: LibSession.Config = {
            var conf: UnsafeMutablePointer<config_object>!
            _ = convo_info_volatile_init(&conf, &secretKey, nil, 0, nil)
            
            return .convoInfoVolatile(conf)
        }()
        let groupInfoConf: UnsafeMutablePointer<config_object> = {
            var conf: UnsafeMutablePointer<config_object>!
            _ = groups_info_init(&conf, &groupEdPK, &groupEdSK, nil, 0, nil)
            
            return conf
        }()
        let groupMembersConf: UnsafeMutablePointer<config_object> = {
            var conf: UnsafeMutablePointer<config_object>!
            _ = groups_members_init(&conf, &groupEdPK, &groupEdSK, nil, 0, nil)
            
            return conf
        }()
        let groupKeysConf: UnsafeMutablePointer<config_group_keys> = {
            var conf: UnsafeMutablePointer<config_group_keys>!
            _ = groups_keys_init(&conf, &secretKey, &groupEdPK, &groupEdSK, groupInfoConf, groupMembersConf, nil, 0, nil)
            
            return conf
        }()
        let groupInfoConfig: LibSession.Config = .groupInfo(groupInfoConf)
        let groupMembersConfig: LibSession.Config = .groupMembers(groupMembersConf)
        let groupKeysConfig: LibSession.Config = .groupKeys(
            groupKeysConf,
            info: groupInfoConf,
            members: groupMembersConf
        )
        
        return (userGroupsConfig, convoInfoVolatileConfig, groupInfoConfig, groupMembersConfig, groupKeysConfig)
    }
    
    typealias Messages = (
        decodedMessage: DecodedMessage,
        inviteMessage: GroupUpdateInviteMessage,
        promoteMessage: GroupUpdatePromoteMessage,
        infoChangedMessage: GroupUpdateInfoChangeMessage,
        memberChangedMessage: GroupUpdateMemberChangeMessage,
        memberLeftMessage: GroupUpdateMemberLeftMessage,
        memberLeftNotificationMessage: GroupUpdateMemberLeftNotificationMessage,
        inviteResponseMessage: GroupUpdateInviteResponseMessage,
        deleteMessage: Data,
        deleteContentMessage: GroupUpdateDeleteMemberContentMessage,
        visibleMessageProto: SNProtoContent,
        visibleMessage: VisibleMessage
    )
    private static func setupMessages(constants: Constants) -> Messages {
        let decodedMessage = DecodedMessage(
            content: Data(
                base64Encoded: "CAESvwEKABIAGrYBCAYSACjQiOyP9yM4AUKmAfjX/WXVFs+QE5Eh54Esw9/N" +
                "lYza3k8MOvcRAI7y8k0JzLsm/KpXxKP7Zx7+5YyII9sCRXzFK2U4/X9SSMN088YEr/5wKoDfL5q" +
                "PQbN70aa59WS8YE+yWcniQO0KXfAzr6Acn40fsa9BMr9tnQLfvxY8vD7qBz9iEOV9jTxPzxUoD+" +
                "JelIbsv2qlkOl9vs166NC/Y772NZmUAR5u1ewL4SYEWkqX5R4gAA=="
            )!,
            sender: SessionId(.standard, hex: "1111111111111111111111111111111111111111111111111111111111111111"),
            decodedEnvelope: nil,
            sentTimestampMs: 1234567800000
        )
        let inviteMessage = {
            let result: GroupUpdateInviteMessage = GroupUpdateInviteMessage(
                inviteeSessionIdHexString: "TestId",
                groupSessionId: constants.groupId,
                groupName: "TestGroup",
                memberAuthData: Data([1, 2, 3]),
                profile: nil,
                adminSignature: .standard(signature: "TestSignature".bytes)
            )
            result.sender = "051111111111111111111111111111111111111111111111111111111111111111"
            result.sentTimestampMs = 1234567890000
            
            return result
        }()
        let promoteMessage = {
            let result: GroupUpdatePromoteMessage = GroupUpdatePromoteMessage(
                groupIdentitySeed: constants.groupSeed,
                groupName: "TestGroup",
                sentTimestampMs: 1234567890000
            )
            result.sender = "051111111111111111111111111111111111111111111111111111111111111111"
            
            return result
        }()
        let infoChangedMessage = {
            let result: GroupUpdateInfoChangeMessage = GroupUpdateInfoChangeMessage(
                changeType: .name,
                updatedName: "TestGroup Rename",
                updatedExpiration: nil,
                adminSignature: .standard(signature: "TestSignature".bytes)
            )
            result.sender = "051111111111111111111111111111111111111111111111111111111111111111"
            result.sentTimestampMs = 1234567890000
            
            return result
        }()
        let memberChangedMessage = {
            let result: GroupUpdateMemberChangeMessage = GroupUpdateMemberChangeMessage(
                changeType: .added,
                memberSessionIds: ["051111111111111111111111111111111111111111111111111111111111111112"],
                historyShared: false,
                adminSignature: .standard(signature: "TestSignature".bytes)
            )
            result.sender = "051111111111111111111111111111111111111111111111111111111111111111"
            result.sentTimestampMs = 1234567890000
            
            return result
        }()
        let memberLeftMessage = {
            let result: GroupUpdateMemberLeftMessage = GroupUpdateMemberLeftMessage()
            result.sender = "051111111111111111111111111111111111111111111111111111111111111112"
            result.sentTimestampMs = 1234567890000
            
            return result
        }()
        let memberLeftNotificationMessage = {
            let result: GroupUpdateMemberLeftNotificationMessage = GroupUpdateMemberLeftNotificationMessage()
            result.sender = "051111111111111111111111111111111111111111111111111111111111111112"
            result.sentTimestampMs = 1234567890000
            
            return result
        }()
        let inviteResponseMessage = {
            let result: GroupUpdateInviteResponseMessage = GroupUpdateInviteResponseMessage(
                isApproved: true,
                profile: VisibleMessage.VMProfile(displayName: "TestOtherMember"),
                sentTimestampMs: 1234567890000
            )
            result.sender = "051111111111111111111111111111111111111111111111111111111111111112"
            
            return result
        }()
        let deleteMessage = try! LibSessionMessage.groupKicked(
            memberId: "05\(TestConstants.publicKey)",
            groupKeysGen: 1
        ).1
        let deleteContentMessage = {
            let result: GroupUpdateDeleteMemberContentMessage = GroupUpdateDeleteMemberContentMessage(
                memberSessionIds: ["051111111111111111111111111111111111111111111111111111111111111112"],
                messageHashes: [],
                adminSignature: .standard(signature: "TestSignature".bytes)
            )
            result.sender = "051111111111111111111111111111111111111111111111111111111111111112"
            result.sentTimestampMs = 1234567890000
            
            return result
        }()
        let visibleMessageProto = {
            let proto = SNProtoContent.builder()
            proto.setSigTimestamp((1234568890 - (60 * 10)) * 1000)
            
            let dataMessage = SNProtoDataMessage.builder()
            dataMessage.setBody("Test")
            proto.setDataMessage(try! dataMessage.build())
            return try! proto.build()
        }()
        let visibleMessage = {
            let result = VisibleMessage(
                sender: "051111111111111111111111111111111111111111111111111111111111111112",
                sentTimestampMs: ((1234568890 - (60 * 10)) * 1000),
                text: "Test"
            )
            result.receivedTimestampMs = (1234568890 * 1000)
            return result
        }()
        
        return (
            decodedMessage,
            inviteMessage,
            promoteMessage,
            infoChangedMessage,
            memberChangedMessage,
            memberLeftMessage,
            memberLeftNotificationMessage,
            inviteResponseMessage,
            deleteMessage,
            deleteContentMessage,
            visibleMessageProto,
            visibleMessage
        )
    }
    
    // MARK: - Default State

    private func applyBaselineStubs() async throws {
        try await applyBaselineStorage()
        try await applyBaselineNetwork()
        try await applyBaselineJobRunner()
        try await applyBaselineAppContext()
        try await applyBaselineUserDefaults()
        try await applyBaselineCrypto()
        try await applyBaselineKeychain()
        try await applyBaselineFileManager()
        try await applyBaselineExtensionHelper()
        try await applyBaselineGroupPollerManager()
        try await applyBaselineNotificationsManager()
        try await applyBaselineGeneralCache()
        try await applyBaselineLibSessionCache()
        try await applyBaselinePoller()
    }
    
    private func applyBaselineStorage() async throws {
        try await mockStorage.perform(migrations: SNMessagingKit.migrations)
        try await mockStorage.write { db in
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
    }
    
    private func applyBaselineNetwork() async throws {
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
            .thenReturn(MockNetwork.response(with: FileMetadata(id: "1", size: 1)))
    }
    
    private func applyBaselineJobRunner() async throws {
        try await mockJobRunner
            .when { await $0.jobsMatching(filters: .any) }
            .thenReturn([:])
        try await mockJobRunner
            .when { $0.add(.any, job: .any, initialDependencies: .any) }
            .thenReturn(nil)
        try await mockJobRunner
            .when { await $0.stopAndClearJobs(filters: .any) }
            .thenReturn(())
    }
    
    private func applyBaselineAppContext() async throws {
        try await mockAppContext.when { $0.isMainApp }.thenReturn(false)
    }
    
    private func applyBaselineUserDefaults() async throws {
        try await mockUserDefaults.defaultInitialSetup()
        try await mockUserDefaults.when { $0.string(forKey: .any) }.thenReturn(nil)
        try await mockUserDefaults.when { $0.integer(forKey: .any) }.thenReturn(1)
    }
    
    private func applyBaselineCrypto() async throws {
        try await mockCrypto
            .when { $0.generate(.signature(message: .any, ed25519SecretKey: .any)) }
            .thenReturn(Authentication.Signature.standard(signature: "TestSignature".bytes))
        try await mockCrypto
            .when { $0.generate(.signatureSubaccount(config: .any, verificationBytes: .any, memberAuthData: .any)) }
            .thenReturn(Authentication.Signature.subaccount(
                subaccount: "TestSubAccount".bytes,
                subaccountSig: "TestSubAccountSignature".bytes,
                signature: "TestSignature".bytes
            ))
        try await mockCrypto
            .when { $0.verify(.signature(message: .any, publicKey: .any, signature: .any)) }
            .thenReturn(true)
        try await mockCrypto
            .when { $0.generate(.ed25519KeyPair(seed: Array<UInt8>.any)) }
            .thenReturn(groupKeyPair)
        try await mockCrypto
            .when { $0.verify(.memberAuthData(groupSessionId: .any, ed25519SecretKey: .any, memberAuthData: .any)) }
            .thenReturn(true)
        try await mockCrypto
            .when { $0.generate(.hash(message: .any, key: .any, length: .any)) }
            .thenReturn("TestHash".bytes)
    }
    
    private func applyBaselineKeychain() async throws {
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
    }
    
    private func applyBaselineFileManager() async throws {
        try await mockFileManager.defaultInitialSetup()
    }
    
    private func applyBaselineExtensionHelper() async throws {
        try await mockExtensionHelper
            .when { try $0.removeDedupeRecord(threadId: .any, uniqueIdentifier: .any) }
            .thenReturn(())
        try await mockExtensionHelper
            .when { try $0.upsertLastClearedRecord(threadId: .any) }
            .thenReturn(())
    }
    
    private func applyBaselineGroupPollerManager() async throws {
        try await mockGroupPollerManager.when { await $0.startAllPollers() }.thenReturn(())
        try await mockGroupPollerManager.when { await $0.getOrCreatePoller(for: .any) }.thenReturn(mockPoller)
        try await mockGroupPollerManager.when { await $0.stopAndRemovePoller(for: .any) }.thenReturn(())
        try await mockGroupPollerManager.when { await $0.stopAndRemoveAllPollers() }.thenReturn(())
    }
    
    private func applyBaselineNotificationsManager() async throws {
        try await mockNotificationsManager.defaultInitialSetup()
    }
    
    private func applyBaselineGeneralCache() async throws {
        try await mockGeneralCache
            .when { $0.sessionId }
            .thenReturn(SessionId(.standard, hex: TestConstants.publicKey))
        try await mockGeneralCache
            .when { $0.ed25519SecretKey }
            .thenReturn(Array(Data(hex: TestConstants.edSecretKey)))
    }
    
    private func applyBaselineLibSessionCache() async throws {
        try await mockLibSessionCache.defaultInitialSetup(
            configs: [
                .userGroups: userGroupsConfig,
                .convoInfoVolatile: convoInfoVolatileConfig,
                .groupInfo: groupInfoConfig,
                .groupMembers: groupMembersConfig,
                .groupKeys: groupKeysConfig
            ]
        )
    }
    
    private func applyBaselinePoller() async throws {
        try await mockPoller.when { await $0.startIfNeeded() }.thenReturn(())
        try await mockPoller
            .when { $0.receivedPollResponse }
            .thenReturn(.singleValue(value: SwarmPoller.PollResponse()))
    }
}


// MARK: - Convenience

private extension LibSession.Config {
    var conf: UnsafeMutablePointer<config_object>? {
        switch self {
            case .userProfile(let conf), .contacts(let conf),
                .convoInfoVolatile(let conf), .userGroups(let conf),
                .groupInfo(let conf), .groupMembers(let conf):
                return conf
            default: return nil
        }
    }
    
    var keysConf: UnsafeMutablePointer<config_group_keys>? {
        switch self {
            case .groupKeys(let conf, _, _): return conf
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
