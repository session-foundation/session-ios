// Copyright © 2026 Session Technology Foundation. All rights reserved.

import Foundation
import TestUtilities

import Quick
import Nimble

@testable import SessionUtilitiesKit

/// **These specs exercise the migration's logic against a mocked keychain, not the Security framework.**
///
/// They prove which calls are made and how each outcome is derived; they cannot prove that iOS honours
/// `kSecAttrAccessGroup`, because no real keychain is involved. That half is covered by `KeychainStorageSpec`,
/// which has to live in `SessionTests` because keychain access needs a test target with a host application and
/// this one has none.
class KeychainAccessGroupMigrationSpec: AsyncSpec {
    override class func spec() {
        // MARK: Configuration

        let testAccessGroup: String = "group.com.test.app"
        let keyA: KeychainStorage.DataKey = "TestKeyA"
        let keyB: KeychainStorage.DataKey = "TestKeyB"
        let valueA: Data = Data([1, 2, 3, 4])
        let valueB: Data = Data([5, 6, 7, 8])

        @TestState var dependencies: TestDependencies! = TestDependencies()
        @TestState var mockKeychain: MockKeychain! = .create(using: dependencies)

        beforeEach {
            dependencies.set(singleton: .keychain, to: mockKeychain)

            try await mockKeychain.when { $0.appGroupAccessGroup }.thenReturn(testAccessGroup)
            try await mockKeychain.when { try $0.data(forKey: keyA) }.thenReturn(valueA)
            try await mockKeychain.when { try $0.data(forKey: keyB) }.thenReturn(valueB)
            try await mockKeychain
                .when { try $0.set(data: valueA, forKey: keyA, accessGroup: testAccessGroup) }
                .thenReturn(())
            try await mockKeychain
                .when { try $0.set(data: valueB, forKey: keyB, accessGroup: testAccessGroup) }
                .thenReturn(())
            try await mockKeychain
                .when { try $0.data(forKey: keyA, accessGroup: testAccessGroup) }
                .thenReturn(valueA)
            try await mockKeychain
                .when { try $0.data(forKey: keyB, accessGroup: testAccessGroup) }
                .thenReturn(valueB)
        }

        // MARK: - a Keychain Access Group Migration
        describe("a Keychain Access Group Migration") {
            // MARK: -- writes each key into the app group access group
            it("writes each key into the app group access group") {
                let result = KeychainAccessGroupMigration.run(keys: [keyA, keyB], using: dependencies)

                expect(result.outcomes[keyA]).to(equal(.migrated))
                expect(result.outcomes[keyB]).to(equal(.migrated))
                expect(result.isFullySucceeded).to(beTrue())

                await mockKeychain
                    .verify { try $0.set(data: valueA, forKey: keyA, accessGroup: testAccessGroup) }
                    .wasCalled(exactly: 1)
                await mockKeychain
                    .verify { try $0.set(data: valueB, forKey: keyB, accessGroup: testAccessGroup) }
                    .wasCalled(exactly: 1)
            }

            // MARK: -- verifies each key by reading it back from the app group specifically
            it("verifies each key by reading it back from the app group specifically") {
                KeychainAccessGroupMigration.run(keys: [keyA], using: dependencies)

                /// An unscoped read would search every access group the app belongs to and so could not tell a
                /// migrated item from one left behind in the default group
                await mockKeychain
                    .verify { try $0.data(forKey: keyA, accessGroup: testAccessGroup) }
                    .wasCalled(exactly: 1)
            }

            // MARK: -- copies rather than moves, leaving the original in place
            it("copies rather than moves, leaving the original in place") {
                KeychainAccessGroupMigration.run(keys: [keyA, keyB], using: dependencies)

                await mockKeychain.verify { try $0.remove(key: keyA) }.wasNotCalled()
                await mockKeychain.verify { try $0.remove(key: keyB) }.wasNotCalled()
            }

            // MARK: -- is idempotent
            it("is idempotent") {
                let first = KeychainAccessGroupMigration.run(keys: [keyA], using: dependencies)
                let second = KeychainAccessGroupMigration.run(keys: [keyA], using: dependencies)

                expect(first.outcomes[keyA]).to(equal(.migrated))
                expect(second.outcomes[keyA]).to(equal(.migrated))
            }

            // MARK: -- when a key does not exist
            context("when a key does not exist") {
                beforeEach {
                    try await mockKeychain
                        .when { try $0.data(forKey: keyA) }
                        .thenThrow(
                            KeychainStorageError.failure(
                                code: errSecItemNotFound,
                                logCategory: .keychain,
                                description: "not found"
                            )
                        )
                }

                // MARK: ---- reports it as missing rather than failed
                it("reports it as missing rather than failed") {
                    let result = KeychainAccessGroupMigration.run(keys: [keyA], using: dependencies)

                    expect(result.outcomes[keyA]).to(equal(.sourceMissing))
                    expect(result.isFullySucceeded).to(beTrue())
                }
            }

            // MARK: -- when a key cannot be read
            ///
            /// A read that failed for any other reason - a locked keychain, a missing entitlement - taught us nothing
            /// about that key, and reporting it as the benign lazily-created case would let a run that read nothing at
            /// all describe itself as a success. `dbCipherKeySpec` in particular provably exists by the time the
            /// migration runs, so "missing" for it is always a read failure
            context("when a key cannot be read") {
                beforeEach {
                    try await mockKeychain
                        .when { try $0.data(forKey: keyA) }
                        .thenThrow(KeychainStorageError.keySpecInaccessible)
                }

                // MARK: ---- reports it as failed rather than missing
                it("reports it as failed rather than missing") {
                    let result = KeychainAccessGroupMigration.run(keys: [keyA], using: dependencies)

                    expect(result.failedKeys).to(equal([keyA]))
                    expect(result.isFullySucceeded).to(beFalse())
                }

                // MARK: ---- does not write anything
                it("does not write anything") {
                    KeychainAccessGroupMigration.run(keys: [keyA], using: dependencies)

                    await mockKeychain
                        .verify { try $0.set(data: valueA, forKey: keyA, accessGroup: testAccessGroup) }
                        .wasNotCalled()
                }
            }

            // MARK: -- when the write fails
            context("when the write fails") {
                beforeEach {
                    try await mockKeychain
                        .when { try $0.set(data: valueA, forKey: keyA, accessGroup: testAccessGroup) }
                        .thenThrow(KeychainStorageError.keySpecCreationFailed)
                }

                // MARK: ---- reports the key as failed
                it("reports the key as failed") {
                    let result = KeychainAccessGroupMigration.run(keys: [keyA], using: dependencies)

                    expect(result.failedKeys).to(equal([keyA]))
                    expect(result.isFullySucceeded).to(beFalse())
                }
            }

            // MARK: -- when the item cannot be read back from the app group
            context("when the item cannot be read back from the app group") {
                beforeEach {
                    try await mockKeychain
                        .when { try $0.data(forKey: keyA, accessGroup: testAccessGroup) }
                        .thenThrow(KeychainStorageError.keySpecInaccessible)
                }

                // MARK: ---- reports the key as failed
                ///
                /// This is the case the whole verification step exists for: the write reported success and an
                /// unscoped read would still find the item, so without the scoped read-back this would look
                /// exactly like a successful migration
                it("reports the key as failed") {
                    let result = KeychainAccessGroupMigration.run(keys: [keyA], using: dependencies)

                    expect(result.failedKeys).to(equal([keyA]))
                    expect(result.verifiedKeys).to(beEmpty())
                    expect(result.isFullySucceeded).to(beFalse())
                }
            }

            // MARK: -- when the value read back differs
            context("when the value read back differs") {
                beforeEach {
                    try await mockKeychain
                        .when { try $0.data(forKey: keyA, accessGroup: testAccessGroup) }
                        .thenReturn(Data([9, 9, 9, 9]))
                }

                // MARK: ---- reports the key as failed
                it("reports the key as failed") {
                    let result = KeychainAccessGroupMigration.run(keys: [keyA], using: dependencies)

                    expect(result.failedKeys).to(equal([keyA]))
                    expect(result.isFullySucceeded).to(beFalse())
                }
            }

            // MARK: -- when one key of several fails
            context("when one key of several fails") {
                beforeEach {
                    try await mockKeychain
                        .when { try $0.data(forKey: keyB, accessGroup: testAccessGroup) }
                        .thenThrow(KeychainStorageError.keySpecInaccessible)
                }

                // MARK: ---- still migrates the others but reports overall failure
                it("still migrates the others but reports overall failure") {
                    let result = KeychainAccessGroupMigration.run(keys: [keyA, keyB], using: dependencies)

                    expect(result.outcomes[keyA]).to(equal(.migrated))
                    expect(result.verifiedKeys).to(equal([keyA]))
                    expect(result.failedKeys).to(equal([keyB]))
                    expect(result.isFullySucceeded).to(beFalse())
                }
            }
        }
    }
}
