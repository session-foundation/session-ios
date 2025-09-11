// Copyright © 2024 Rangeproof Pty Ltd. All rights reserved.

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
        @TestState(singleton: .storage, in: dependencies) var mockStorage: Storage! = SynchronousStorage(
            customWriter: try! DatabaseQueue(),
            using: dependencies
        )
        @TestState var mockNetwork: MockNetwork! = .create(using: dependencies)
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
        @TestState var createGroupOutput: LibSession.CreatedGroupInfo!
        @TestState var mockLibSessionCache: MockLibSessionCache! = MockLibSessionCache()
        
        beforeEach {
            /// The compiler kept crashing when doing this via `@TestState` so need to do it here instead
            try await mockGeneralCache.defaultInitialSetup()
            dependencies.set(cache: .general, to: mockGeneralCache)
            
            try await mockStorage.perform(migrations: SNMessagingKit.migrations)
            try await mockStorage.writeAsync { db in
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
            
            var conf: UnsafeMutablePointer<config_object>!
            var secretKey: [UInt8] = Array(Data(hex: TestConstants.edSecretKey))
            _ = user_groups_init(&conf, &secretKey, nil, 0, nil)
            
            mockLibSessionCache.defaultInitialSetup(
                configs: [
                    .userGroups: .userGroups(conf),
                    .groupInfo: createGroupOutput.groupState[.groupInfo],
                    .groupMembers: createGroupOutput.groupState[.groupMembers],
                    .groupKeys: createGroupOutput.groupState[.groupKeys]
                ]
            )
            dependencies.set(cache: .libSession, to: mockLibSessionCache)
            
            try await mockNetwork
                .when {
                    $0.send(
                        endpoint: MockEndpoint.any,
                        destination: .any,
                        body: .any,
                        category: .any,
                        requestTimeout: .any,
                        overallTimeout: .any
                    )
                }
                .thenReturn(MockNetwork.response(data: Data([1, 2, 3])))
            dependencies.set(singleton: .network, to: mockNetwork)
        }
        
        // MARK: - LibSessionGroupMembers
        describe("LibSessionGroupMembers") {
            // MARK: -- when handling a GROUP_MEMBERS update
            context("when handling a GROUP_MEMBERS update") {
                @TestState var latestGroup: ClosedGroup?
                
                beforeEach {
                    mockStorage.write { db in
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
                    mockLibSessionCache.when { $0.configNeedsDump(.any) }.thenReturn(true)
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
                    mockLibSessionCache.when { $0.configNeedsDump(.any) }.thenReturn(false)
                    
                    mockStorage.write { db in
                        try mockLibSessionCache.handleGroupMembersUpdate(
                            db,
                            in: createGroupOutput.groupState[.groupMembers],
                            groupSessionId: SessionId(.group, hex: createGroupOutput.group.threadId),
                            serverTimestampMs: 1234567891000
                        )
                    }
                    
                    latestGroup = mockStorage.read { db in
                        try ClosedGroup.fetchOne(db, id: createGroupOutput.group.threadId)
                    }
                    expect(createGroupOutput.groupState[.groupMembers]).toNot(beNil())
                    expect(createGroupOutput.group).to(equal(latestGroup))
                }
                
                // MARK: ---- throws if the config is invalid
                it("throws if the config is invalid") {
                    mockStorage.write { db in
                        expect {
                            try mockLibSessionCache.handleGroupMembersUpdate(
                                db,
                                in: createGroupOutput.groupState[.groupInfo]!,
                                groupSessionId: createGroupOutput.groupSessionId,
                                serverTimestampMs: 1234567891000
                            )
                        }
                        .to(throwError())
                    }
                }
                
                // MARK: ---- updates a standard member entry to an accepted admin
                it("updates a standard member entry to an accepted admin") {
                    mockStorage.write { db in
                        try GroupMember(
                            groupId: createGroupOutput.groupSessionId.hexString,
                            profileId: "05\(TestConstants.publicKey)",
                            role: .standard,
                            roleStatus: .accepted,
                            isHidden: false
                        ).upsert(db)
                    }

                    mockStorage.write { db in
                        try mockLibSessionCache.handleGroupMembersUpdate(
                            db,
                            in: createGroupOutput.groupState[.groupMembers],
                            groupSessionId: createGroupOutput.groupSessionId,
                            serverTimestampMs: 1234567891000
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
                            groupId: createGroupOutput.groupSessionId.hexString,
                            profileId: "05\(TestConstants.publicKey)",
                            role: .admin,
                            roleStatus: .failed,
                            isHidden: false
                        ).upsert(db)
                    }

                    mockStorage.write { db in
                        try mockLibSessionCache.handleGroupMembersUpdate(
                            db,
                            in: createGroupOutput.groupState[.groupMembers],
                            groupSessionId: createGroupOutput.groupSessionId,
                            serverTimestampMs: 1234567891000
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
                            groupId: createGroupOutput.groupSessionId.hexString,
                            profileId: "05\(TestConstants.publicKey)",
                            role: .admin,
                            roleStatus: .pending,
                            isHidden: false
                        ).upsert(db)
                    }

                    mockStorage.write { db in
                        try mockLibSessionCache.handleGroupMembersUpdate(
                            db,
                            in: createGroupOutput.groupState[.groupMembers],
                            groupSessionId: createGroupOutput.groupSessionId,
                            serverTimestampMs: 1234567891000
                        )
                    }

                    let members: [GroupMember]? = mockStorage.read { db in try GroupMember.fetchAll(db) }
                    expect(members?.count).to(equal(1))
                    expect(members?.first?.role).to(equal(.admin))
                    expect(members?.first?.roleStatus).to(equal(.accepted))
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
