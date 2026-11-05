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
        let value: Data = Data([0xDE, 0xAD, 0xBE, 0xEF])
        let otherValue: Data = Data([0x01, 0x02, 0x03, 0x04])

        @TestState var dependencies: TestDependencies! = TestDependencies()
        @TestState var storage: KeychainStorage! = KeychainStorage(using: dependencies)

        /// The keychain outlives the test process, so anything written here has to be cleaned up explicitly or it
        /// leaks into every later run on the same device or simulator
        func cleanUp() {
            try? storage.remove(key: dataKey)
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
                /// group lands in the app's first access group - here the team-prefixed `keychain-access-groups`
                /// entry - so a
                /// read scoped to the app group must not see it. Were scoping unenforced, a migration that
                /// silently did nothing would still verify as successful.
                /// **Written through the Security framework directly, not `KeychainStorage`.** The unscoped setter
                /// mirrors into the app group by design, so going through it would put the item in both groups and
                /// this could never fail. The property under test belongs to iOS rather than to our wrapper, so the
                /// spec asserts it against iOS
                it("does not return an item written to the default group") {
                    let status: OSStatus = SecItemAdd(
                        [
                            kSecClass: kSecClassGenericPassword,
                            kSecAttrAccount: dataKey.rawValue,
                            kSecValueData: otherValue,
                            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                        ] as CFDictionary,
                        nil
                    )
                    expect(status).to(equal(errSecSuccess))

                    expect { try storage.data(forKey: dataKey, accessGroup: storage.appGroupAccessGroup) }
                        .to(throwError())
                }

                // MARK: ------ accepts a write when the same key already exists in the default group
                ///
                /// **This is the only sequence that runs on a device**, and every other spec here starts from an
                /// empty keychain, so nothing else reaches it. `migrate` reads the existing default-group item and
                /// then writes the same account into the app group — if the access group were not part of the
                /// uniqueness tuple for a generic password, that write would fail with `errSecDuplicateItem` and
                /// the migration would fail for every existing user while the rest of this file stayed green
                it("accepts a write when the same key already exists in the default group") {
                    try storage.set(data: otherValue, forKey: dataKey)

                    expect {
                        try storage.set(data: value, forKey: dataKey, accessGroup: storage.appGroupAccessGroup)
                    }.toNot(throwError())
                    expect(try storage.data(forKey: dataKey, accessGroup: storage.appGroupAccessGroup))
                        .to(equal(value))
                }

                // MARK: ------ is removed by an unscoped delete
                ///
                /// Whether an unscoped `SecItemDelete` spans every access group decides that "Clear all data" really
                /// removes the app-group copy. Apple documents that the search, update and delete calls default to
                /// every access group the app belongs to; this asserts it rather than inheriting it
                it("is removed by an unscoped delete") {
                    try storage.set(data: value, forKey: dataKey, accessGroup: storage.appGroupAccessGroup)
                    try storage.remove(key: dataKey)

                    expect { try storage.data(forKey: dataKey, accessGroup: storage.appGroupAccessGroup) }
                        .to(throwError())
                }
            }

            // MARK: -- never removes an item while overwriting it
            ///
            /// Removing it first would leave no item at all if the add then failed (eg. while the keychain is locked) or
            /// the process was killed in between, and anything reading it meanwhile would be told it doesn't exist.
            /// **The reader goes to the Security framework directly** so it can't mask a gap by reading again
            it("never removes an item while overwriting it") {
                try storage.set(data: value, forKey: dataKey)

                let reader: Task<Int, Never> = Task.detached {
                    var notFoundCount: Int = 0

                    while !Task.isCancelled {
                        let status: OSStatus = SecItemCopyMatching(
                            [
                                kSecClass: kSecClassGenericPassword,
                                kSecAttrAccount: dataKey.rawValue,
                                kSecMatchLimit: kSecMatchLimitOne,
                                kSecReturnData: true
                            ] as CFDictionary,
                            nil
                        )

                        if status == errSecItemNotFound { notFoundCount += 1 }
                    }

                    return notFoundCount
                }

                for index in 0..<300 {
                    try storage.set(data: (index.isMultiple(of: 2) ? value : otherValue), forKey: dataKey)
                }
                reader.cancel()
                let notFoundCount: Int = await reader.value

                expect(notFoundCount).to(equal(0))
                expect(try storage.data(forKey: dataKey)).to(equal(otherValue))
            }

            // MARK: -- with a stubbed Security framework
            context("with a stubbed Security framework") {
                @TestState var security: SecurityStub! = SecurityStub()
                @TestState var mockAppContext: MockAppContext! = .create(using: dependencies)
                @TestState var mockCrypto: MockCrypto! = .create(using: dependencies)
                @TestState var stubbedStorage: KeychainStorage! = KeychainStorage(
                    using: dependencies,
                    security: security.functions
                )

                beforeEach {
                    dependencies.set(singleton: .appContext, to: mockAppContext)
                    try await mockAppContext.when { $0.isMainApp }.thenReturn(true)
                    try await mockAppContext.when { $0.isInBackground }.thenReturn(false)
                    try await mockAppContext.when { $0.reportedApplicationState }.thenReturn(.active)
                    dependencies.set(singleton: .crypto, to: mockCrypto)
                    try await mockCrypto
                        .when { try $0.tryGenerate(.randomBytes(.any)) }
                        .thenReturn(Data(repeating: 1, count: 48))
                }

                // MARK: ---- reports an item as not found only once a second read agrees
                ///
                /// A "not found" leads `getOrGenerateEncryptionKey` to replace the key, so a wrong one destroys a key
                /// which exists
                it("reports an item as not found only once a second read agrees") {
                    security.copyResults = [(errSecItemNotFound, nil), (errSecSuccess, value)]

                    expect(try stubbedStorage.data(forKey: dataKey)).to(equal(value))
                }

                // MARK: ---- does not replace a key when the second read fails differently
                it("does not replace a key when the second read fails differently") {
                    security.copyResults = [(errSecItemNotFound, nil), (errSecInteractionNotAllowed, nil)]

                    expect {
                        try stubbedStorage.getOrGenerateEncryptionKey(forKey: dataKey, length: 48, cat: .keychain)
                    }.to(throwError { error in
                        switch error {
                            case KeychainStorageError.keySpecInaccessible: break
                            default: fail("Expected keySpecInaccessible, got \(error)")
                        }
                    })
                    expect(security.addCount).to(equal(0))
                    expect(security.updateCount).to(equal(0))
                    expect(security.deleteCount).to(equal(0))
                }

                // MARK: ---- replaces a key only when two reads report it as not found
                it("replaces a key only when two reads report it as not found") {
                    security.copyResults = [(errSecItemNotFound, nil), (errSecItemNotFound, nil)]

                    expect {
                        try stubbedStorage.getOrGenerateEncryptionKey(forKey: dataKey, length: 48, cat: .keychain)
                    }.to(equal(Data(repeating: 1, count: 48)))
                    expect(security.copyCount).to(equal(2))
                    expect(security.addCount).to(beGreaterThan(0))
                }

                // MARK: ---- keeps the existing item when an overwrite fails
                it("keeps the existing item when an overwrite fails") {
                    security.updateStatus = errSecInteractionNotAllowed

                    expect { try stubbedStorage.set(data: value, forKey: dataKey) }
                        .to(throwError { error in
                            expect((error as? KeychainStorageError)?.code).to(equal(errSecInteractionNotAllowed))
                        })
                    expect(security.deleteCount).to(equal(0))
                    expect(security.addCount).to(equal(0))
                }
            }
        }
    }
}

// MARK: - SecurityStub

/// Answers `KeychainStorage`'s Security framework calls from a script, and counts them
private final class SecurityStub {
    var copyResults: [(status: OSStatus, data: Data?)] = []
    var updateStatus: OSStatus = errSecItemNotFound
    var addStatus: OSStatus = errSecSuccess
    private(set) var copyCount: Int = 0
    private(set) var addCount: Int = 0
    private(set) var updateCount: Int = 0
    private(set) var deleteCount: Int = 0

    var functions: KeychainStorage.SecurityFunctions {
        KeychainStorage.SecurityFunctions(
            copyData: { [self] _ in
                copyCount += 1

                return (copyResults.isEmpty ? (errSecItemNotFound, nil) : copyResults.removeFirst())
            },
            add: { [self] _ in
                addCount += 1
                return addStatus
            },
            update: { [self] _, _ in
                updateCount += 1
                return updateStatus
            },
            delete: { [self] _ in
                deleteCount += 1
                return errSecSuccess
            }
        )
    }
}
