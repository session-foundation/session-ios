// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import SessionUtil
import SessionUtilitiesKit

import Quick
import Nimble

@testable import SessionMessagingKit

class MessageSenderGroupsSpec: QuickSpec {
    override class func spec() {
        // MARK: Configuration
        
        @TestState var dependencies: TestDependencies! = TestDependencies { dependencies in
            dependencies.dateNow = Date(timeIntervalSince1970: 1234567890)
            dependencies.forceSynchronous = true
        }
        @TestState(singleton: .storage, in: dependencies) var mockStorage: Storage! = SynchronousStorage(
            customWriter: try! DatabaseQueue(),
            customMigrationTargets: [
                SNUtilitiesKit.self,
                SNMessagingKit.self
            ],
            using: dependencies,
            initialData: { db in
                try Identity(variant: .x25519PublicKey, data: Data(hex: TestConstants.publicKey)).insert(db)
                try Identity(variant: .x25519PrivateKey, data: Data(hex: TestConstants.privateKey)).insert(db)
                try Identity(variant: .ed25519PublicKey, data: Data(hex: TestConstants.edPublicKey)).insert(db)
                try Identity(variant: .ed25519SecretKey, data: Data(hex: TestConstants.edSecretKey)).insert(db)
            }
        )
        @TestState(singleton: .network, in: dependencies) var mockNetwork: MockNetwork! = MockNetwork()
        @TestState(singleton: .crypto, in: dependencies) var mockCrypto: MockCrypto! = MockCrypto(
            initialSetup: { crypto in
                crypto
                    .when { crypto in crypto.generate(.ed25519KeyPair(seed: any(), using: any())) }
                    .thenReturn(
                        KeyPair(
                            publicKey: Data.data(
                                fromHex: "cbd569f56fb13ea95a3f0c05c331cc24139c0090feb412069dc49fab34406ece"
                            )!.bytes,
                            secretKey: Data.data(
                                fromHex: "0123456789abcdef0123456789abcdeffedcba9876543210fedcba9876543210" +
                                "cbd569f56fb13ea95a3f0c05c331cc24139c0090feb412069dc49fab34406ece"
                            )!.bytes
                        )
                    )
            }
        )
        @TestState(cache: .general, in: dependencies) var mockGeneralCache: MockGeneralCache! = MockGeneralCache(
            initialSetup: { cache in
                cache.when { $0.encodedPublicKey }.thenReturn("05\(TestConstants.publicKey)")
            }
        )
        @TestState(cache: .sessionUtil, in: dependencies) var mockSessionUtilCache: MockSessionUtilCache! = MockSessionUtilCache(
            initialSetup: { cache in
                cache
                    .when { $0.setConfig(for: any(), publicKey: any(), to: any()) }
                    .thenReturn(())
            }
        )
        @TestState var disposables: [AnyCancellable]! = []
        @TestState var error: Error?
        @TestState var thread: SessionThread?
        
        // MARK: - a MessageSender dealing with Groups
        describe("a MessageSender dealing with Groups") {
            // MARK: -- when creating a group
            context("when creating a group") {
                beforeEach {
                    var userGroupsConf: UnsafeMutablePointer<config_object>!
                    var secretKey: [UInt8] = Array(Data(hex: TestConstants.edSecretKey))
                    _ = user_groups_init(&userGroupsConf, &secretKey, nil, 0, nil)
                    let userGroupsConfig: SessionUtil.Config = .object(userGroupsConf)
                    
                    mockSessionUtilCache
                        .when { $0.config(for: .userGroups, publicKey: any()) }
                        .thenReturn(Atomic(userGroupsConfig))
                }
                
                // MARK: ---- stores the thread in the db
                it("stores the thread in the db") {
                    MessageSender
                        .createGroup(
                            name: "Test",
                            displayPicture: nil,
                            members: [
                                ("051111111111111111111111111111111111111111111111111111111111111111", nil)
                            ],
                            using: dependencies
                        )
                        .handleEvents(receiveOutput: { result in thread = result })
                        .mapError { error.setting(to: $0) }
                        .sinkAndStore(in: &disposables)
                    
                    expect(error).to(beNil())
                    expect(thread).toNot(beNil())
                    
                    let dbValue: SessionThread? = mockStorage.read { db in try SessionThread.fetchOne(db) }
                    expect(dbValue).to(equal(thread))
                    expect(dbValue?.id)
                        .to(equal("03cbd569f56fb13ea95a3f0c05c331cc24139c0090feb412069dc49fab34406ece"))
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
                    MessageSender
                        .createGroup(
                            name: "TestGroupName",
                            displayPicture: nil,
                            members: [
                                ("051111111111111111111111111111111111111111111111111111111111111111", nil)
                            ],
                            using: dependencies
                        )
                        .handleEvents(receiveOutput: { result in thread = result })
                        .mapError { error.setting(to: $0) }
                        .sinkAndStore(in: &disposables)
                    
                    expect(error).to(beNil())
                    expect(thread).toNot(beNil())
                    
                    let dbValue: ClosedGroup? = mockStorage.read { db in try ClosedGroup.fetchOne(db) }
                    expect(dbValue?.id)
                        .to(equal("03cbd569f56fb13ea95a3f0c05c331cc24139c0090feb412069dc49fab34406ece"))
                    expect(dbValue?.name).to(equal("TestGroupName"))
                    expect(dbValue?.formationTimestamp).to(equal(1234567890))
                    expect(dbValue?.displayPictureUrl).to(beNil())
                    expect(dbValue?.displayPictureFilename).to(beNil())
                    expect(dbValue?.displayPictureEncryptionKey).to(beNil())
                    expect(dbValue?.lastDisplayPictureUpdate).to(equal(1234567890))
                    expect(dbValue?.groupIdentityPrivateKey?.toHexString())
                        .to(equal(
                            "0123456789abcdef0123456789abcdeffedcba9876543210fedcba9876543210" +
                            "cbd569f56fb13ea95a3f0c05c331cc24139c0090feb412069dc49fab34406ece"
                        ))
                    expect(dbValue?.authData).to(beNil())
                    expect(dbValue?.invited).to(beFalse())
                }
                
                // MARK: ---- stores the group members in the db
                it("stores the group members in the db") {
                    MessageSender
                        .createGroup(
                            name: "TestGroupName",
                            displayPicture: nil,
                            members: [
                                ("051111111111111111111111111111111111111111111111111111111111111111", nil)
                            ],
                            using: dependencies
                        )
                        .handleEvents(receiveOutput: { result in thread = result })
                        .mapError { error.setting(to: $0) }
                        .sinkAndStore(in: &disposables)
                    
                    expect(error).to(beNil())
                    expect(thread).toNot(beNil())
                    expect(mockStorage.read { db in try GroupMember.fetchSet(db) })
                        .to(equal([
                            GroupMember(
                                groupId: "03cbd569f56fb13ea95a3f0c05c331cc24139c0090feb412069dc49fab34406ece",
                                profileId: "051111111111111111111111111111111111111111111111111111111111111111",
                                role: .standard,
                                isHidden: false
                            ),
                            GroupMember(
                                groupId: "03cbd569f56fb13ea95a3f0c05c331cc24139c0090feb412069dc49fab34406ece",
                                profileId: "05\(TestConstants.publicKey)",
                                role: .admin,
                                isHidden: false
                            )
                        ]))
                }
            }
        }
    }
}
