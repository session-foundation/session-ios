// Copyright © 2026 Session Technology Foundation. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit
import TestUtilities

import Quick
import Nimble

@testable import SessionMessagingKit

class LibSessionLoadStateSpec: AsyncSpec {
    override class func spec() {
        // MARK: Configuration

        let userSessionId: SessionId = SessionId(.standard, hex: TestConstants.publicKey)
        let groupSessionId: SessionId = SessionId(.group, hex: TestConstants.publicKey)
        let userEd25519SecretKey: [UInt8] = Array(Data(hex: TestConstants.edSecretKey))
        let unparseableDump: Data = Data([1, 2, 3])

        @TestState var dependencies: TestDependencies! = TestDependencies()
        @TestState var mockStorage: Storage! = try! Storage.createForTesting(using: dependencies)
        @TestState var mockExtensionHelper: MockExtensionHelper! = .create(using: dependencies)
        @TestState var cache: LibSession.Cache! = LibSession.Cache(userSessionId: userSessionId, using: dependencies)

        beforeEach {
            dependencies.set(singleton: .storage, to: mockStorage)
            dependencies.set(singleton: .extensionHelper, to: mockExtensionHelper)
            try await mockExtensionHelper
                .when { $0.lastUpdatedTimestamp(for: .any, variant: .any) }
                .thenReturn(0)
            try await mockStorage.perform(migrations: SNMessagingKit.migrations)
        }

        // MARK: - LibSession.Cache
        describe("LibSession.Cache") {
            // MARK: -- when loading its state
            context("when loading its state") {
                // MARK: ---- loads every user config when no dumps are stored
                ///
                /// A new account has no dumps yet, so this is the state it starts in
                it("loads every user config when no dumps are stored") {
                    try await mockStorage.read { db in
                        try cache.loadState(db, userEd25519SecretKey: userEd25519SecretKey)
                    }

                    ConfigDump.Variant.userVariants.forEach { variant in
                        expect(cache.hasConfig(for: variant, sessionId: userSessionId))
                            .to(beTrue(), description: "\(variant)")
                    }
                }

                // MARK: ---- fails when the dumps can't be read
                ///
                /// Loading the defaults instead would show an account with no name, contacts or groups, and push that state
                it("fails when the dumps can't be read") {
                    try await mockStorage.write { db in
                        try db.execute(sql: "DROP TABLE \(ConfigDump.databaseTableName)")
                    }

                    await expect {
                        try await mockStorage.read { db in
                            try cache.loadState(db, userEd25519SecretKey: userEd25519SecretKey)
                        }
                    }.to(throwError())
                }

                // MARK: ---- loads the default for a user config which can't be loaded
                ///
                /// The failure would repeat on every launch, so failing the load would stop the app starting at all
                it("loads the default for a user config which can't be loaded") {
                    try await mockStorage.write { db in
                        try ConfigDump(
                            variant: .userProfile,
                            sessionId: userSessionId.hexString,
                            data: unparseableDump,
                            timestampMs: 0
                        ).insert(db)
                    }

                    try await mockStorage.read { db in
                        try cache.loadState(db, userEd25519SecretKey: userEd25519SecretKey)
                    }
                    
                    ConfigDump.Variant.userVariants.forEach { variant in
                        expect(cache.hasConfig(for: variant, sessionId: userSessionId))
                            .to(beTrue(), description: "\(variant)")
                    }
                }

                // MARK: ---- skips the whole of a group whose config can't be loaded
                ///
                /// The failure would repeat on every launch, so failing the load would stop the app starting at all
                it("skips the whole of a group whose config can't be loaded") {
                    try await mockStorage.write { db in
                        try SessionThread(
                            id: groupSessionId.hexString,
                            variant: .group,
                            creationDateTimestamp: 0
                        ).insert(db)
                        try ClosedGroup(
                            threadId: groupSessionId.hexString,
                            name: "Test",
                            formationTimestamp: 0,
                            shouldPoll: true,
                            invited: false
                        ).insert(db)
                        try ConfigDump(
                            variant: .groupInfo,
                            sessionId: groupSessionId.hexString,
                            data: unparseableDump,
                            timestampMs: 0
                        ).insert(db)
                    }

                    try await mockStorage.read { db in
                        try cache.loadState(db, userEd25519SecretKey: userEd25519SecretKey)
                    }

                    expect(cache.hasConfig(for: .groupInfo, sessionId: groupSessionId)).to(beFalse())
                    expect(cache.hasConfig(for: .groupMembers, sessionId: groupSessionId)).to(beFalse())
                    expect(cache.hasConfig(for: .groupKeys, sessionId: groupSessionId)).to(beFalse())
                    expect(cache.hasConfig(for: .userProfile, sessionId: userSessionId)).to(beTrue())
                }
            }
        }
    }
}
