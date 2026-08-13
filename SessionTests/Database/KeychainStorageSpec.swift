// Copyright © 2026 Session Technology Foundation. All rights reserved.

import Foundation
import TestUtilities

import Quick
import Nimble

@testable import SessionUtilitiesKit

/// Exercises the **real** keychain via `KeychainStorage` rather than a mock, so the access group scoping that the
/// app transfer depends on is asserted against the Security framework instead of against our own call shape.
/// `KeychainAccessGroupMigrationSpec` covers the migration's logic; this covers the storage it stands on.
///
/// 🔴 **This spec lives in `SessionTests` specifically, and must stay there.** Keychain access is granted by
/// entitlements, so it needs a test target with a host application. `SessionUtilitiesKitTests` - where
/// `KeychainStorage` itself lives - has no `TEST_HOST` and is a logic-test bundle, which means no entitlements on
/// any platform (every write returns `errSecMissingEntitlement`, `-34018`) and no ability to run on a device at
/// all ("Logic Testing on iOS devices is not supported"). Only `SessionTests` and `SessionUIKitTests` have a host
/// app.
///
/// Given a host app, the simulator applies entitlements and enforces access group scoping just as a device does,
/// so these expectations hold in both environments and nothing here needs to be conditional.
class KeychainStorageSpec: AsyncSpec {
    override class func spec() {
        // MARK: Configuration

        /// Distinctive so a leaked item is obvious, and so these can never collide with a real key
        let dataKey: KeychainStorage.DataKey = "__KeychainStorageSpec_data__"
        let stringKey: KeychainStorage.StringKey = "__KeychainStorageSpec_string__"
        let value: Data = Data([0xDE, 0xAD, 0xBE, 0xEF])
        let otherValue: Data = Data([0x01, 0x02, 0x03, 0x04])

        @TestState var dependencies: TestDependencies! = TestDependencies()
        @TestState var storage: KeychainStorage! = KeychainStorage(using: dependencies)

        /// The keychain outlives the test process, so anything written here has to be cleaned up explicitly or it
        /// leaks into every later run on the same device or simulator
        func cleanUp() {
            try? storage.remove(key: dataKey)
            try? storage.remove(key: stringKey)
        }

        beforeEach { cleanUp() }
        afterEach { cleanUp() }

        // MARK: - Keychain Storage
        describe("Keychain Storage") {
            // MARK: -- exposes the app group as an access group
            it("exposes the app group as an access group") {
                expect(storage.appGroupAccessGroup).to(equal(UserDefaults.applicationGroup))
                expect(storage.appGroupAccessGroup).to(beginWith("group."))
            }

            // MARK: -- round-trips data
            it("round-trips data") {
                expect { try storage.set(data: value, forKey: dataKey) }.toNot(throwError())
                expect(try storage.data(forKey: dataKey)).to(equal(value))
            }

            // MARK: -- round-trips a string
            it("round-trips a string") {
                expect { try storage.set(string: "testValue", forKey: stringKey) }.toNot(throwError())
                expect(try storage.string(forKey: stringKey)).to(equal("testValue"))
            }

            // MARK: -- reports an absent item as not found rather than as another failure
            ///
            /// Asserting the specific code matters: a bare "it throws" would also be satisfied by a missing
            /// entitlement, so it would pass on a host that cannot reach the keychain at all
            it("reports an absent item as not found rather than as another failure") {
                expect { try storage.data(forKey: dataKey) }
                    .to(throwError { error in
                        expect((error as? KeychainStorageError)?.code).to(equal(errSecItemNotFound))
                    })
            }

            // MARK: -- removes an item
            it("removes an item") {
                try storage.set(data: value, forKey: dataKey)
                expect { try storage.remove(key: dataKey) }.toNot(throwError())
                expect { try storage.data(forKey: dataKey) }.to(throwError())
            }

            // MARK: -- the app group access group
            context("the app group access group") {
                // MARK: ---- round-trips data written to it
                it("round-trips data written to it") {
                    expect {
                        try storage.set(data: value, forKey: dataKey, accessGroup: storage.appGroupAccessGroup)
                    }.toNot(throwError())
                    expect(try storage.data(forKey: dataKey, accessGroup: storage.appGroupAccessGroup))
                        .to(equal(value))
                }

                // MARK: ---- is visible to an unscoped read
                ///
                /// Apple documents that an unscoped read searches every access group the app belongs to, and the
                /// migration relies on it: afterwards the app keeps reading keys without naming a group and still
                /// finds them. If this stopped holding the app would lose its keys silently
                it("is visible to an unscoped read") {
                    try storage.set(data: value, forKey: dataKey, accessGroup: storage.appGroupAccessGroup)

                    expect(try storage.data(forKey: dataKey)).to(equal(value))
                }

                // MARK: ---- does not return an item written to the default group
                ///
                /// **This is the assumption the app transfer plan rests on.** An item written without an explicit
                /// group lands in the app's first access group - the team-prefixed application identifier - so a
                /// read scoped to the app group must not see it. Were scoping unenforced, a migration that
                /// silently did nothing would still verify as successful.
                it("does not return an item written to the default group") {
                    try storage.set(data: otherValue, forKey: dataKey)

                    expect { try storage.data(forKey: dataKey, accessGroup: storage.appGroupAccessGroup) }
                        .to(throwError())
                }
            }
        }
    }
}
