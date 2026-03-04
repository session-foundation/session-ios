// Copyright © 2026 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtil
import SessionUtilitiesKit
import TestUtilities

import Quick
import Nimble

@testable import SessionNetworkingKit
@testable import SessionMessagingKit

class LibSessionGroupMembersSpec: AsyncSpec {
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
        }
        
        // MARK: - LibSessionGroupMembers
        describe("LibSessionGroupMembers") {
            // MARK: -- when handling a GROUP_MEMBERS update
            context("when handling a GROUP_MEMBERS update") {
                @TestState var latestGroup: ClosedGroup?
                
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
                    }
                    try await mockLibSessionCache.when { $0.configNeedsDump(.any) }.thenReturn(true)
                    createGroupOutput.groupState[.groupMembers]?.conf.map {
                        var cMemberId: [CChar] = "05\(TestConstants.publicKey)".cString(using: .utf8)!
                        var member: config_group_member = config_group_member()
                        expect(groups_members_get_or_construct($0, &member, &cMemberId)).to(beTrue())
                        
                        member.admin = true
                        member.invited = 0
                        member.promoted = 0
                        groups_members_set($0, &member)
                    }
                }
                
                // MARK: ---- does nothing if there are no changes
                it("does nothing if there are no changes") {
                    try await mockLibSessionCache.when { $0.configNeedsDump(.any) }.thenReturn(false)
                    
                    try await mockStorage.write { db in
                        try mockLibSessionCache.handleGroupMembersUpdate(
                            db,
                            in: createGroupOutput.groupState[.groupMembers],
                            groupSessionId: SessionId(.group, hex: createGroupOutput.group.threadId),
                            serverTimestampMs: 1234567891000
                        )
                    }
                    
                    latestGroup = try await mockStorage.read { db in
                        try ClosedGroup.fetchOne(db, id: createGroupOutput.group.threadId)
                    }
                    expect(createGroupOutput.groupState[.groupMembers]).toNot(beNil())
                    expect(createGroupOutput.group).to(equal(latestGroup))
                }
                
                // MARK: ---- throws if the config is invalid
                it("throws if the config is invalid") {
                    await expect {
                        try await mockStorage.write { db in
                            try mockLibSessionCache.handleGroupMembersUpdate(
                                db,
                                in: createGroupOutput.groupState[.groupInfo]!,
                                groupSessionId: createGroupOutput.groupSessionId,
                                serverTimestampMs: 1234567891000
                            )
                        }
                    }
                    .to(throwError())
                }
                
                // MARK: ---- updates a standard member entry to an accepted admin
                it("updates a standard member entry to an accepted admin") {
                    try await mockStorage.write { db in
                        try GroupMember(
                            groupId: createGroupOutput.groupSessionId.hexString,
                            profileId: "05\(TestConstants.publicKey)",
                            role: .standard,
                            roleStatus: .accepted,
                            isHidden: false
                        ).upsert(db)
                    }

                    try await mockStorage.write { db in
                        try mockLibSessionCache.handleGroupMembersUpdate(
                            db,
                            in: createGroupOutput.groupState[.groupMembers],
                            groupSessionId: createGroupOutput.groupSessionId,
                            serverTimestampMs: 1234567891000
                        )
                    }

                    let members: [GroupMember] = try await mockStorage.read { db in try GroupMember.fetchAll(db) }
                    expect(members.count).to(equal(1))
                    expect(members.first?.role).to(equal(.admin))
                    expect(members.first?.roleStatus).to(equal(.accepted))
                }

                // MARK: ---- updates a failed admin entry to an accepted admin
                it("updates a failed admin entry to an accepted admin") {
                    try await mockStorage.write { db in
                        try GroupMember(
                            groupId: createGroupOutput.groupSessionId.hexString,
                            profileId: "05\(TestConstants.publicKey)",
                            role: .admin,
                            roleStatus: .failed,
                            isHidden: false
                        ).upsert(db)
                    }

                    try await mockStorage.write { db in
                        try mockLibSessionCache.handleGroupMembersUpdate(
                            db,
                            in: createGroupOutput.groupState[.groupMembers],
                            groupSessionId: createGroupOutput.groupSessionId,
                            serverTimestampMs: 1234567891000
                        )
                    }

                    let members: [GroupMember] = try await mockStorage.read { db in try GroupMember.fetchAll(db) }
                    expect(members.count).to(equal(1))
                    expect(members.first?.role).to(equal(.admin))
                    expect(members.first?.roleStatus).to(equal(.accepted))
                }

                // MARK: ---- updates a pending admin entry to an accepted admin
                it("updates a pending admin entry to an accepted admin") {
                    try await mockStorage.write { db in
                        try GroupMember(
                            groupId: createGroupOutput.groupSessionId.hexString,
                            profileId: "05\(TestConstants.publicKey)",
                            role: .admin,
                            roleStatus: .pending,
                            isHidden: false
                        ).upsert(db)
                    }

                    try await mockStorage.write { db in
                        try mockLibSessionCache.handleGroupMembersUpdate(
                            db,
                            in: createGroupOutput.groupState[.groupMembers],
                            groupSessionId: createGroupOutput.groupSessionId,
                            serverTimestampMs: 1234567891000
                        )
                    }

                    let members: [GroupMember] = try await mockStorage.read { db in try GroupMember.fetchAll(db) }
                    expect(members.count).to(equal(1))
                    expect(members.first?.role).to(equal(.admin))
                    expect(members.first?.roleStatus).to(equal(.accepted))
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
