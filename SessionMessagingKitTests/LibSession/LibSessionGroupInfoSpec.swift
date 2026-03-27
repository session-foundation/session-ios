// Copyright © 2026 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtil
import SessionUtilitiesKit
import SessionNetworkingKit
import TestUtilities

import Quick
import Nimble

@testable import SessionNetworkingKit
@testable import SessionMessagingKit

class LibSessionGroupInfoSpec: AsyncSpec {
    override class func spec() {
        // MARK: Configuration
        
        @TestState var dependencies: TestDependencies! = TestDependencies { dependencies in
            dependencies.dateNow = Date(timeIntervalSince1970: 1234567890)
            dependencies.forceSynchronous = true
        }
        @TestState var mockGeneralCache: MockGeneralCache! = .create(using: dependencies)
        @TestState var mockStorage: Storage! = try! Storage.createForTesting(using: dependencies)
        @TestState var mockNetwork: MockNetwork! = .create(using: dependencies)
        @TestState var mockJobRunner: MockJobRunner! = .create(using: dependencies)
        @TestState var createGroupOutput: LibSession.CreatedGroupInfo!
        @TestState var mockLibSessionCache: MockLibSessionCache! = .create(using: dependencies)
        @TestState var mockCrypto: MockCrypto! = .create(using: dependencies)
        
        beforeEach {
            dependencies.set(cache: .general, to: mockGeneralCache)
            try await mockGeneralCache.defaultInitialSetup()
            
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
                .thenReturn(MockNetwork.response(data: Data([1, 2, 3])))
            
            dependencies.set(singleton: .storage, to: mockStorage)
            try await mockStorage.perform(migrations: SNMessagingKit.migrations)
            try await mockStorage.write { db in
                try Identity(variant: .x25519PublicKey, data: Data(hex: TestConstants.publicKey)).insert(db)
                try Identity(variant: .x25519PrivateKey, data: Data(hex: TestConstants.privateKey)).insert(db)
                try Identity(variant: .ed25519PublicKey, data: Data(hex: TestConstants.edPublicKey)).insert(db)
                try Identity(variant: .ed25519SecretKey, data: Data(hex: TestConstants.edSecretKey)).insert(db)
                
                createGroupOutput = try LibSession.createGroup(
                    db,
                    name: "TestGroup",
                    description: nil,
                    displayPictureUrl: nil,
                    displayPictureEncryptionKey: nil,
                    members: [],
                    using: dependencies
                 )
            }
            
            dependencies.set(singleton: .jobRunner, to: mockJobRunner)
            try await mockJobRunner
                .when { $0.add(.any, job: .any, initialDependencies: .any) }
                .thenReturn(nil)
            try await mockJobRunner
                .when { await $0.jobsMatching(filters: .any) }
                .thenReturn([:])
            
            dependencies.set(cache: .libSession, to: mockLibSessionCache)
            var conf: UnsafeMutablePointer<config_object>!
            var secretKey: [UInt8] = Array(Data(hex: TestConstants.edSecretKey))
            _ = user_groups_init(&conf, &secretKey, nil, 0, nil)
            
            try await mockLibSessionCache.defaultInitialSetup(
                configs: [
                    .userGroups: .userGroups(conf),
                    .groupInfo: createGroupOutput.groupState[.groupInfo],
                    .groupMembers: createGroupOutput.groupState[.groupMembers],
                    .groupKeys: createGroupOutput.groupState[.groupKeys]
                ]
            )
            try await mockLibSessionCache.when { $0.configNeedsDump(.any) }.thenReturn(true)
            
            dependencies.set(singleton: .crypto, to: mockCrypto)
            try await mockCrypto
                .when { $0.generate(.hash(message: .any, length: .any)) }
                .thenReturn("TestHash".bytes)
            try await mockCrypto
                .when { $0.generate(.signature(message: .any, ed25519SecretKey: .any)) }
                .thenReturn(Authentication.Signature.standard(signature: "TestSignature".bytes))
        }
        
        // MARK: - LibSessionGroupInfo
        describe("LibSessionGroupInfo") {
            // MARK: -- when handling a GROUP_INFO update
            context("when handling a GROUP_INFO update") {
                @TestState var latestGroup: ClosedGroup?
                @TestState var initialDisappearingConfig: DisappearingMessagesConfiguration?
                @TestState var latestDisappearingConfig: DisappearingMessagesConfiguration?
                
                beforeEach {
                    try await mockStorage.write { db in
                        try SessionThread.upsert(
                            db,
                            id: createGroupOutput.group.threadId,
                            variant: .group,
                            values: SessionThread.TargetValues(
                                creationDateTimestamp: .setTo(1234567890),
                                shouldBeVisible: .setTo(true)
                            ),
                            using: dependencies
                        )
                        try createGroupOutput.group.insert(db)
                        try createGroupOutput.members.forEach { try $0.insert(db) }
                        initialDisappearingConfig = try DisappearingMessagesConfiguration
                            .fetchOne(db, id: createGroupOutput.group.threadId)
                            .defaulting(
                                to: DisappearingMessagesConfiguration.defaultWith(createGroupOutput.group.threadId)
                            )
                    }
                }
                
                // MARK: ---- does nothing if there are no changes
                it("does nothing if there are no changes") {
                    try await mockLibSessionCache.when { $0.configNeedsDump(.any) }.thenReturn(false)
                    
                    try await mockStorage.write { db in
                        try mockLibSessionCache.handleGroupInfoUpdate(
                            db,
                            in: createGroupOutput.groupState[.groupInfo],
                            groupSessionId: SessionId(.group, hex: createGroupOutput.group.threadId)
                        )
                    }
                    
                    latestGroup = try await mockStorage.read { db in
                        try ClosedGroup.fetchOne(db, id: createGroupOutput.group.threadId)
                    }
                    expect(createGroupOutput.groupState[.groupInfo]).toNot(beNil())
                    expect(createGroupOutput.group).to(equal(latestGroup))
                }
                
                // MARK: ---- throws if the config is invalid
                it("throws if the config is invalid") {
                    await expect {
                        try await mockStorage.write { db in
                            try mockLibSessionCache.handleGroupInfoUpdate(
                                db,
                                in: createGroupOutput.groupState[.groupMembers]!,
                                groupSessionId: SessionId(.group, hex: createGroupOutput.group.threadId)
                            )
                        }
                    }
                    .to(throwError())
                }
                
                // MARK: ---- removes group data if the group is destroyed
                it("removes group data if the group is destroyed") {
                    createGroupOutput.groupState[.groupInfo]?.conf.map { groups_info_destroy_group($0) }
                    
                    try await mockStorage.write { db in
                        try mockLibSessionCache.handleGroupInfoUpdate(
                            db,
                            in: createGroupOutput.groupState[.groupInfo],
                            groupSessionId: SessionId(.group, hex: createGroupOutput.group.threadId)
                        )
                    }
                    
                    latestGroup = try await mockStorage.read { db in
                        try ClosedGroup.fetchOne(db, id: createGroupOutput.group.threadId)
                    }
                    expect(latestGroup?.authData).to(beNil())
                    expect(latestGroup?.groupIdentityPrivateKey).to(beNil())
                }
                
                // MARK: ---- updates the name if it changed
                it("updates the name if it changed") {
                    createGroupOutput.groupState[.groupInfo]?.conf.map {
                        var updatedName: [CChar] = "UpdatedName".cString(using: .utf8)!
                        groups_info_set_name($0, &updatedName)
                    }
                    
                    try await mockStorage.write { db in
                        try mockLibSessionCache.handleGroupInfoUpdate(
                            db,
                            in: createGroupOutput.groupState[.groupInfo],
                            groupSessionId: SessionId(.group, hex: createGroupOutput.group.threadId)
                        )
                    }
                    
                    latestGroup = try await mockStorage.read { db in
                        try ClosedGroup.fetchOne(db, id: createGroupOutput.group.threadId)
                    }
                    expect(createGroupOutput.group.name).to(equal("TestGroup"))
                    expect(latestGroup?.name).to(equal("UpdatedName"))
                }
                
                // MARK: ---- updates the description if it changed
                it("updates the description if it changed") {
                    createGroupOutput.groupState[.groupInfo]?.conf.map {
                        var updatedDesc: [CChar] = "UpdatedDesc".cString(using: .utf8)!
                        groups_info_set_description($0, &updatedDesc)
                    }
                    
                    try await mockStorage.write { db in
                        try mockLibSessionCache.handleGroupInfoUpdate(
                            db,
                            in: createGroupOutput.groupState[.groupInfo],
                            groupSessionId: SessionId(.group, hex: createGroupOutput.group.threadId)
                        )
                    }
                    
                    latestGroup = try await mockStorage.read { db in
                        try ClosedGroup.fetchOne(db, id: createGroupOutput.group.threadId)
                    }
                    expect(createGroupOutput.group.groupDescription).to(beNil())
                    expect(latestGroup?.groupDescription).to(equal("UpdatedDesc"))
                }
                
                // MARK: ---- updates the formation timestamp if it is later than the current value
                it("updates the formation timestamp if it is later than the current value") {
                    /// **Note:** the `formationTimestamp` stores the "joinedAt" date so we only update it if it's later than
                    /// the current value (as we don't want to replace the record of when the current user joined the group with
                    /// when the group was originally created)
                    try await mockStorage.write { db in
                        try ClosedGroup.updateAll(
                            db,
                            ClosedGroup.Columns.formationTimestamp.set(to: 50000)
                        )
                    }
                    createGroupOutput.groupState[.groupInfo]?.conf.map { groups_info_set_created($0, 54321) }
                    let originalGroup: ClosedGroup? = try await mockStorage.read { db in
                        try ClosedGroup.fetchOne(db, id: createGroupOutput.group.threadId)
                    }
                    
                    try await mockStorage.write { db in
                        try mockLibSessionCache.handleGroupInfoUpdate(
                            db,
                            in: createGroupOutput.groupState[.groupInfo],
                            groupSessionId: SessionId(.group, hex: createGroupOutput.group.threadId)
                        )
                    }
                    
                    latestGroup = try await mockStorage.read { db in
                        try ClosedGroup.fetchOne(db, id: createGroupOutput.group.threadId)
                    }
                    expect(originalGroup?.formationTimestamp).to(equal(50000))
                    expect(latestGroup?.formationTimestamp).to(equal(54321))
                }
                
                // MARK: ---- and the display picture was changed
                context("and the display picture was changed") {
                    // MARK: ------ removes the display picture
                    it("removes the display picture") {
                        try await mockStorage.write { db in
                            try ClosedGroup
                                .updateAll(
                                    db,
                                    ClosedGroup.Columns.displayPictureUrl.set(to: "TestUrl"),
                                    ClosedGroup.Columns.displayPictureEncryptionKey.set(to: Data([1, 2, 3]))
                                )
                        }
                        
                        try await mockStorage.write { db in
                            try mockLibSessionCache.handleGroupInfoUpdate(
                                db,
                                in: createGroupOutput.groupState[.groupInfo],
                                groupSessionId: SessionId(.group, hex: createGroupOutput.group.threadId)
                            )
                        }
                        
                        latestGroup = try await mockStorage.read { db in
                            try ClosedGroup.fetchOne(db, id: createGroupOutput.group.threadId)
                        }
                        expect(latestGroup?.displayPictureUrl).to(beNil())
                        expect(latestGroup?.displayPictureEncryptionKey).to(beNil())
                    }
                    
                    // MARK: ------ schedules a display picture download job if there is a new one
                    it("schedules a display picture download job if there is a new one") {
                        createGroupOutput.groupState[.groupInfo]?.conf.map {
                            var displayPic: user_profile_pic = user_profile_pic()
                            displayPic.set(\.url, to: "https://www.oxen.io/file/1234")
                            displayPic.set(\.key, to: Data(repeating: 1, count: DisplayPictureManager.encryptionKeySize))
                            groups_info_set_pic($0, displayPic)
                        }
                        
                        try await mockStorage.write { db in
                            try mockLibSessionCache.handleGroupInfoUpdate(
                                db,
                                in: createGroupOutput.groupState[.groupInfo],
                                groupSessionId: SessionId(.group, hex: createGroupOutput.group.threadId)
                            )
                        }
                        
                        await mockJobRunner
                            .verify {
                                $0.add(
                                    .any,
                                    job: Job(
                                        variant: .displayPictureDownload,
                                        uniqueKey: DisplayPictureDownloadJob.generateUniqueKey(
                                            id: createGroupOutput.group.threadId,
                                            url: "https://www.oxen.io/file/1234"
                                        ),
                                        details: DisplayPictureDownloadJob.Details(
                                            target: .group(
                                                id: createGroupOutput.group.threadId,
                                                url: "https://www.oxen.io/file/1234",
                                                encryptionKey: Data(
                                                    repeating: 1,
                                                    count: DisplayPictureManager.encryptionKeySize
                                                )
                                            ),
                                            timestamp: 1234567890
                                        )
                                    ),
                                    initialDependencies: []
                                )
                            }
                            .wasCalled(exactly: 1, timeout: .milliseconds(100))
                    }
                }
                
                // MARK: ---- updates the disappearing messages config
                it("updates the disappearing messages config") {
                    createGroupOutput.groupState[.groupInfo]?.conf.map { groups_info_set_expiry_timer($0, 10) }
                    
                    try await mockStorage.write { db in
                        try mockLibSessionCache.handleGroupInfoUpdate(
                            db,
                            in: createGroupOutput.groupState[.groupInfo],
                            groupSessionId: SessionId(.group, hex: createGroupOutput.group.threadId)
                        )
                    }
                    
                    latestDisappearingConfig = try await mockStorage.read { db in
                        try DisappearingMessagesConfiguration.fetchOne(db, id: createGroupOutput.group.threadId)
                    }
                    expect(initialDisappearingConfig?.isEnabled).to(beFalse())
                    expect(initialDisappearingConfig?.durationSeconds).to(equal(0))
                    expect(latestDisappearingConfig?.isEnabled).to(beTrue())
                    expect(latestDisappearingConfig?.durationSeconds).to(equal(10))
                }
                
                // MARK: ---- containing a deleteBefore timestamp
                context("containing a deleteBefore timestamp") {
                    @TestState var numInteractions: Int!
                    
                    // MARK: ------ deletes messages before the timestamp
                    it("deletes messages before the timestamp") {
                        try await mockStorage.write { db in
                            try SessionThread.upsert(
                                db,
                                id: createGroupOutput.group.threadId,
                                variant: .contact,
                                values: SessionThread.TargetValues(
                                    creationDateTimestamp: .setTo(1234567890),
                                    shouldBeVisible: .setTo(true)
                                ),
                                using: dependencies
                            )
                            _ = try Interaction(
                                serverHash: "1234",
                                messageUuid: nil,
                                threadId: createGroupOutput.group.threadId,
                                authorId: "4321",
                                variant: .standardIncoming,
                                body: nil,
                                timestampMs: 100000000,
                                receivedAtTimestampMs: 1234567890,
                                wasRead: false,
                                hasMention: false,
                                expiresInSeconds: nil,
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
                        
                        createGroupOutput.groupState[.groupInfo]?.conf.map { groups_info_set_delete_before($0, 123456) }
                        
                        try await mockStorage.write { db in
                            try mockLibSessionCache.handleGroupInfoUpdate(
                                db,
                                in: createGroupOutput.groupState[.groupInfo],
                                groupSessionId: SessionId(.group, hex: createGroupOutput.group.threadId)
                            )
                        }
                        
                        let result: [Interaction] = try await mockStorage.read { db in
                            try Interaction.fetchAll(db)
                        }
                        expect(result.count).to(equal(1))
                        expect(result.map { $0.variant }).to(equal([.standardIncomingDeleted]))
                    }
                    
                    // MARK: ------ does not delete messages after the timestamp
                    it("does not delete messages after the timestamp") {
                        try await mockStorage.write { db in
                            try SessionThread.upsert(
                                db,
                                id: createGroupOutput.group.threadId,
                                variant: .contact,
                                values: SessionThread.TargetValues(
                                    creationDateTimestamp: .setTo(1234567890),
                                    shouldBeVisible: .setTo(true)
                                ),
                                using: dependencies
                            )
                            _ = try Interaction(
                                serverHash: "1234",
                                messageUuid: nil,
                                threadId: createGroupOutput.group.threadId,
                                authorId: "4321",
                                variant: .standardIncoming,
                                body: nil,
                                timestampMs: 100000000,
                                receivedAtTimestampMs: 1234567890,
                                wasRead: false,
                                hasMention: false,
                                expiresInSeconds: nil,
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
                                serverHash: "1235",
                                messageUuid: nil,
                                threadId: createGroupOutput.group.threadId,
                                authorId: "4322",
                                variant: .standardIncoming,
                                body: nil,
                                timestampMs: 200000000,
                                receivedAtTimestampMs: 2234567890,
                                wasRead: false,
                                hasMention: false,
                                expiresInSeconds: nil,
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
                        
                        createGroupOutput.groupState[.groupInfo]?.conf.map { groups_info_set_delete_before($0, 123456) }
                        
                        try await mockStorage.write { db in
                            try mockLibSessionCache.handleGroupInfoUpdate(
                                db,
                                in: createGroupOutput.groupState[.groupInfo],
                                groupSessionId: SessionId(.group, hex: createGroupOutput.group.threadId)
                            )
                        }
                        
                        let result: [Interaction] = try await mockStorage.read { db in
                            try Interaction.fetchAll(db)
                        }
                        expect(result.count).to(equal(2))
                        expect(result.map { $0.variant }).to(equal([.standardIncomingDeleted, .standardIncoming]))
                    }
                }
                
                // MARK: ---- containing a deleteAttachmentsBefore timestamp
                context("containing a deleteAttachmentsBefore timestamp") {
                    @TestState var numInteractions: Int!
                    
                    // MARK: ------ deletes messages with attachments before the timestamp
                    it("deletes messages with attachments before the timestamp") {
                        try await mockStorage.write { db in
                            try SessionThread.upsert(
                                db,
                                id: createGroupOutput.group.threadId,
                                variant: .contact,
                                values: SessionThread.TargetValues(
                                    creationDateTimestamp: .setTo(1234567890),
                                    shouldBeVisible: .setTo(true)
                                ),
                                using: dependencies
                            )
                            let interaction: Interaction = try Interaction(
                                serverHash: "1234",
                                messageUuid: nil,
                                threadId: createGroupOutput.group.threadId,
                                authorId: "4321",
                                variant: .standardIncoming,
                                body: nil,
                                timestampMs: 100000000,
                                receivedAtTimestampMs: 1234567890,
                                wasRead: false,
                                hasMention: false,
                                expiresInSeconds: nil,
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
                            _ = try Attachment(
                                id: "AttachmentId",
                                variant: .standard,
                                contentType: "Test",
                                byteCount: 1234
                            ).inserted(db)
                            _ = try InteractionAttachment(
                                albumIndex: 1,
                                interactionId: interaction.id!,
                                attachmentId: "AttachmentId"
                            ).inserted(db)
                        }
                        
                        createGroupOutput.groupState[.groupInfo]?.conf.map {
                            groups_info_set_attach_delete_before($0, 123456)
                        }
                        
                        try await mockStorage.write { db in
                            try mockLibSessionCache.handleGroupInfoUpdate(
                                db,
                                in: createGroupOutput.groupState[.groupInfo],
                                groupSessionId: SessionId(.group, hex: createGroupOutput.group.threadId)
                            )
                        }
                        
                        let result: [Interaction] = try await mockStorage.read { db in
                            try Interaction.fetchAll(db)
                        }
                        expect(result.count).to(equal(1))
                        expect(result.map { $0.variant }).to(equal([.standardIncomingDeleted]))
                    }
                    
                    // MARK: ------ schedules a garbage collection job to clean up the attachments
                    it("schedules a garbage collection job to clean up the attachments") {
                        try await mockStorage.write { db in
                            try SessionThread.upsert(
                                db,
                                id: createGroupOutput.group.threadId,
                                variant: .contact,
                                values: SessionThread.TargetValues(
                                    creationDateTimestamp: .setTo(1234567890),
                                    shouldBeVisible: .setTo(true)
                                ),
                                using: dependencies
                            )
                            let interaction: Interaction = try Interaction(
                                serverHash: "1234",
                                messageUuid: nil,
                                threadId: createGroupOutput.group.threadId,
                                authorId: "4321",
                                variant: .standardIncoming,
                                body: nil,
                                timestampMs: 100000000,
                                receivedAtTimestampMs: 1234567890,
                                wasRead: false,
                                hasMention: false,
                                expiresInSeconds: nil,
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
                            _ = try Attachment(
                                id: "AttachmentId",
                                variant: .standard,
                                contentType: "Test",
                                byteCount: 1234
                            ).inserted(db)
                            _ = try InteractionAttachment(
                                albumIndex: 1,
                                interactionId: interaction.id!,
                                attachmentId: "AttachmentId"
                            ).inserted(db)
                        }
                        
                        createGroupOutput.groupState[.groupInfo]?.conf.map {
                            groups_info_set_attach_delete_before($0, 123456)
                        }
                        
                        try await mockStorage.write { db in
                            try mockLibSessionCache.handleGroupInfoUpdate(
                                db,
                                in: createGroupOutput.groupState[.groupInfo],
                                groupSessionId: SessionId(.group, hex: createGroupOutput.group.threadId)
                            )
                        }
                        
                        await mockJobRunner
                            .verify {
                                $0.add(
                                    .any,
                                    job: Job(
                                        variant: .garbageCollection,
                                        details: GarbageCollectionJob.Details(
                                            typesToCollect: [.orphanedAttachments, .orphanedAttachmentFiles],
                                            manuallyTriggered: true
                                        )
                                    ),
                                    initialDependencies: []
                                )
                            }
                            .wasCalled(exactly: 1, timeout: .milliseconds(100))
                    }
                    
                    // MARK: ------ does not delete messages with attachments after the timestamp
                    it("does not delete messages with attachments after the timestamp") {
                        try await mockStorage.write { db in
                            try SessionThread.upsert(
                                db,
                                id: createGroupOutput.group.threadId,
                                variant: .contact,
                                values: SessionThread.TargetValues(
                                    creationDateTimestamp: .setTo(1234567890),
                                    shouldBeVisible: .setTo(true)
                                ),
                                using: dependencies
                            )
                            let interaction1: Interaction = try Interaction(
                                serverHash: "1234",
                                messageUuid: nil,
                                threadId: createGroupOutput.group.threadId,
                                authorId: "4321",
                                variant: .standardIncoming,
                                body: nil,
                                timestampMs: 100000000,
                                receivedAtTimestampMs: 1234567890,
                                wasRead: false,
                                hasMention: false,
                                expiresInSeconds: nil,
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
                            let interaction2: Interaction = try Interaction(
                                serverHash: "1235",
                                messageUuid: nil,
                                threadId: createGroupOutput.group.threadId,
                                authorId: "4321",
                                variant: .standardIncoming,
                                body: nil,
                                timestampMs: 200000000,
                                receivedAtTimestampMs: 2234567890,
                                wasRead: false,
                                hasMention: false,
                                expiresInSeconds: nil,
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
                            _ = try Attachment(
                                id: "AttachmentId",
                                variant: .standard,
                                contentType: "Test",
                                byteCount: 1234
                            ).inserted(db)
                            _ = try Attachment(
                                id: "AttachmentId2",
                                variant: .standard,
                                contentType: "Test",
                                byteCount: 1234
                            ).inserted(db)
                            _ = try InteractionAttachment(
                                albumIndex: 1,
                                interactionId: interaction1.id!,
                                attachmentId: "AttachmentId"
                            ).inserted(db)
                            _ = try InteractionAttachment(
                                albumIndex: 1,
                                interactionId: interaction2.id!,
                                attachmentId: "AttachmentId2"
                            ).inserted(db)
                        }
                        
                        createGroupOutput.groupState[.groupInfo]?.conf.map {
                            groups_info_set_attach_delete_before($0, 123456)
                        }
                        
                        try await mockStorage.write { db in
                            try mockLibSessionCache.handleGroupInfoUpdate(
                                db,
                                in: createGroupOutput.groupState[.groupInfo],
                                groupSessionId: SessionId(.group, hex: createGroupOutput.group.threadId)
                            )
                        }
                        
                        let result: [Interaction] = try await mockStorage.read { db in
                            try Interaction.fetchAll(db)
                        }
                        expect(result.count).to(equal(2))
                        expect(result.map { $0.variant }).to(equal([.standardIncomingDeleted, .standardIncoming]))
                    }
                    
                    // MARK: ------ does not delete messages before the timestamp that have no attachments
                    it("does not delete messages before the timestamp that have no attachments") {
                        try await mockStorage.write { db in
                            try SessionThread.upsert(
                                db,
                                id: createGroupOutput.group.threadId,
                                variant: .contact,
                                values: SessionThread.TargetValues(
                                    creationDateTimestamp: .setTo(1234567890),
                                    shouldBeVisible: .setTo(true)
                                ),
                                using: dependencies
                            )
                            let interaction1: Interaction = try Interaction(
                                serverHash: "1234",
                                messageUuid: nil,
                                threadId: createGroupOutput.group.threadId,
                                authorId: "4321",
                                variant: .standardIncoming,
                                body: nil,
                                timestampMs: 100000000,
                                receivedAtTimestampMs: 1234567890,
                                wasRead: false,
                                hasMention: false,
                                expiresInSeconds: nil,
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
                                serverHash: "1235",
                                messageUuid: nil,
                                threadId: createGroupOutput.group.threadId,
                                authorId: "4321",
                                variant: .standardIncoming,
                                body: nil,
                                timestampMs: 200000000,
                                receivedAtTimestampMs: 2234567890,
                                wasRead: false,
                                hasMention: false,
                                expiresInSeconds: nil,
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
                            _ = try Attachment(
                                id: "AttachmentId",
                                variant: .standard,
                                contentType: "Test",
                                byteCount: 1234
                            ).inserted(db)
                            _ = try InteractionAttachment(
                                albumIndex: 1,
                                interactionId: interaction1.id!,
                                attachmentId: "AttachmentId"
                            ).inserted(db)
                        }
                        
                        createGroupOutput.groupState[.groupInfo]?.conf.map {
                            groups_info_set_attach_delete_before($0, 123456)
                        }
                        
                        try await mockStorage.write { db in
                            try mockLibSessionCache.handleGroupInfoUpdate(
                                db,
                                in: createGroupOutput.groupState[.groupInfo],
                                groupSessionId: SessionId(.group, hex: createGroupOutput.group.threadId)
                            )
                        }
                        
                        let result: [Interaction] = try await mockStorage.read { db in
                            try Interaction.fetchAll(db)
                        }
                        expect(result.count).to(equal(2))
                        expect(result.map { $0.variant }).to(equal([.standardIncomingDeleted, .standardIncoming]))
                    }
                }
                
                // MARK: ---- deletes from the server after deleting messages before a given timestamp
                it("deletes from the server after deleting messages before a given timestamp") {
                    try await mockLibSessionCache
                        .when { $0.authData(groupSessionId: .any) }
                        .thenReturn(
                            GroupAuthData(
                                groupIdentityPrivateKey: Data(createGroupOutput.identityKeyPair.secretKey),
                                authData: nil
                            )
                        )
                    try await mockStorage.write { db in
                        try SessionThread.upsert(
                            db,
                            id: createGroupOutput.group.threadId,
                            variant: .contact,
                            values: SessionThread.TargetValues(
                                creationDateTimestamp: .setTo(1234567890),
                                shouldBeVisible: .setTo(true)
                            ),
                            using: dependencies
                        )
                        _ = try Interaction(
                            serverHash: "1234",
                            messageUuid: nil,
                            threadId: createGroupOutput.group.threadId,
                            authorId: "4321",
                            variant: .standardIncoming,
                            body: nil,
                            timestampMs: 100000000,
                            receivedAtTimestampMs: 1234567890,
                            wasRead: false,
                            hasMention: false,
                            expiresInSeconds: nil,
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
                    try await mockLibSessionCache
                        .when { $0.isAdmin(groupSessionId: .any) }
                        .thenReturn(true)
                    try await mockLibSessionCache
                        .when { $0.authData(groupSessionId: .any) }
                        .thenReturn(GroupAuthData(groupIdentityPrivateKey: Data([1, 2, 3]), authData: nil))
                    
                    createGroupOutput.groupState[.groupInfo]?.conf.map { groups_info_set_delete_before($0, 123456) }
                    
                    try await mockStorage.write { db in
                        try mockLibSessionCache.handleGroupInfoUpdate(
                            db,
                            in: createGroupOutput.groupState[.groupInfo],
                            groupSessionId: SessionId(.group, hex: createGroupOutput.group.threadId)
                        )
                    }
                    
                    await mockNetwork
                        .verify {
                            try await $0.send(
                                endpoint: Network.StorageServer.Endpoint.deleteMessages,
                                destination: .randomSnode(
                                    swarmPublicKey: createGroupOutput.groupSessionId.hexString
                                ),
                                body: try! JSONEncoder(using: dependencies).encode(
                                    Network.StorageServer.DeleteMessagesRequest(
                                        messageHashes: ["1234"],
                                        requireSuccessfulDeletion: false,
                                        authMethod: Authentication.groupAdmin(
                                            groupSessionId: createGroupOutput.groupSessionId,
                                            ed25519SecretKey: createGroupOutput.identityKeyPair.secretKey
                                        )
                                    )
                                ),
                                category: .standardSmall,
                                requestTimeout: Network.defaultTimeout,
                                overallTimeout: nil
                            )
                        }
                        .wasCalled(exactly: 1, timeout: .milliseconds(100))
                }
                
                // MARK: ---- does not delete from the server if there is no server hash
                it("does not delete from the server if there is no server hash") {
                    try await mockStorage.write { db in
                        try SessionThread.upsert(
                            db,
                            id: createGroupOutput.group.threadId,
                            variant: .contact,
                            values: SessionThread.TargetValues(
                                creationDateTimestamp: .setTo(1234567890),
                                shouldBeVisible: .setTo(true)
                            ),
                            using: dependencies
                        )
                        _ = try Interaction(
                            serverHash: nil,
                            messageUuid: nil,
                            threadId: createGroupOutput.group.threadId,
                            authorId: "4321",
                            variant: .standardIncoming,
                            body: nil,
                            timestampMs: 100000000,
                            receivedAtTimestampMs: 1234567890,
                            wasRead: false,
                            hasMention: false,
                            expiresInSeconds: nil,
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
                    
                    createGroupOutput.groupState[.groupInfo]?.conf.map { groups_info_set_delete_before($0, 123456) }
                    
                    try await mockStorage.write { db in
                        try mockLibSessionCache.handleGroupInfoUpdate(
                            db,
                            in: createGroupOutput.groupState[.groupInfo],
                            groupSessionId: SessionId(.group, hex: createGroupOutput.group.threadId)
                        )
                    }
                    
                    let result: [Interaction] = try await mockStorage.read { db in
                        try Interaction.fetchAll(db)
                    }
                    expect(result.count).to(equal(1))
                    expect(result.map { $0.variant }).to(equal([.standardIncomingDeleted]))
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
}
