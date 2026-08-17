// Copyright © 2026 Session Technology Foundation. All rights reserved.

import Foundation
import TestUtilities

import Quick
import Nimble

@testable import SessionUtilitiesKit

class StorageSpec: AsyncSpec {
    override class func spec() {
        // MARK: Configuration

        @TestState var dependencies: TestDependencies! = TestDependencies()
        @TestState var mockFileManager: MockFileManager! = .create(using: dependencies)
        @TestState var mockKeychain: MockKeychain! = .create(using: dependencies)

        beforeEach {
            dependencies.set(singleton: .fileManager, to: mockFileManager)
            dependencies.set(singleton: .keychain, to: mockKeychain)
            try await mockFileManager.defaultInitialSetup()
            try await mockKeychain
                .when { try $0.migrateLegacyKeyIfNeeded(legacyKey: .any, legacyService: .any, toKey: .dbCipherKeySpec) }
                .thenReturn(())
        }

        // MARK: - Storage
        describe("Storage") {
            // MARK: -- when a database exists but its encryption key does not
            context("when a database exists but its encryption key does not") {
                beforeEach {
                    try await mockFileManager.when { $0.fileExists(atPath: .any) }.thenReturn(true)
                    try await mockKeychain
                        .when { try $0.data(forKey: .dbCipherKeySpec) }
                        .thenThrow(
                            KeychainStorageError.failure(
                                code: errSecItemNotFound,
                                logCategory: .keychain,
                                description: "not found"
                            )
                        )
                }

                // MARK: ---- fails with databaseKeyMissingWithActiveDatabase
                it("fails with databaseKeyMissingWithActiveDatabase") {
                    let storage: Storage = Storage.create(using: dependencies)

                    await expect { try await storage.perform(migrations: []) }
                        .to(throwError { error in
                            switch error {
                                case StorageError.databaseKeyMissingWithActiveDatabase: break
                                default: fail("Expected databaseKeyMissingWithActiveDatabase, got \(error)")
                            }
                        })
                }

                // MARK: ---- does not generate a replacement key
                ///
                /// Generating one cannot open the existing database and destroys the evidence, after which a lost
                /// key is indistinguishable from a corrupt database
                it("does not generate a replacement key") {
                    let storage: Storage = Storage.create(using: dependencies)
                    _ = try? await storage.perform(migrations: [])

                    await mockKeychain
                        .verify {
                            try $0.getOrGenerateEncryptionKey(
                                forKey: .dbCipherKeySpec,
                                length: .any,
                                cat: .any,
                                legacyKey: .any,
                                legacyService: .any
                            )
                        }
                        .wasNotCalled()
                }
            }

            // MARK: -- when the key exists but is the wrong length
            ///
            /// A key of the wrong length cannot open the database, so it is as unusable as an absent one. Without this
            /// the read succeeds, the guard does not fire, and `getOrGenerateEncryptionKey` replaces the key and
            /// overwrites the evidence - the exact behaviour the guard exists to prevent
            context("when the key exists but is the wrong length") {
                beforeEach {
                    try await mockFileManager.when { $0.fileExists(atPath: .any) }.thenReturn(true)
                    try await mockKeychain
                        .when { try $0.data(forKey: .dbCipherKeySpec) }
                        .thenReturn(Data([1, 2, 3]))
                }

                // MARK: ---- fails with databaseKeyMissingWithActiveDatabase
                it("fails with databaseKeyMissingWithActiveDatabase") {
                    let storage: Storage = Storage.create(using: dependencies)

                    await expect { try await storage.perform(migrations: []) }
                        .to(throwError { error in
                            switch error {
                                case StorageError.databaseKeyMissingWithActiveDatabase: break
                                default: fail("Expected databaseKeyMissingWithActiveDatabase, got \(error)")
                            }
                        })
                }

                // MARK: ---- does not generate a replacement key
                it("does not generate a replacement key") {
                    let storage: Storage = Storage.create(using: dependencies)
                    _ = try? await storage.perform(migrations: [])

                    await mockKeychain
                        .verify {
                            try $0.getOrGenerateEncryptionKey(
                                forKey: .dbCipherKeySpec,
                                length: .any,
                                cat: .any,
                                legacyKey: .any,
                                legacyService: .any
                            )
                        }
                        .wasNotCalled()
                }
            }

            // MARK: -- when the keychain is inaccessible rather than empty
            ///
            /// The keychain cannot be read before the device's first unlock, and the app can be launched in the
            /// background. Treating that as a lost key would offer to destroy the data of a user whose key is fine
            context("when the keychain is inaccessible rather than empty") {
                beforeEach {
                    try await mockFileManager.when { $0.fileExists(atPath: .any) }.thenReturn(true)
                    try await mockKeychain
                        .when { try $0.data(forKey: .dbCipherKeySpec) }
                        .thenThrow(
                            KeychainStorageError.failure(
                                code: errSecInteractionNotAllowed,
                                logCategory: .keychain,
                                description: "locked"
                            )
                        )
                    try await mockKeychain
                        .when {
                            try $0.getOrGenerateEncryptionKey(
                                forKey: .dbCipherKeySpec,
                                length: .any,
                                cat: .any,
                                legacyKey: .any,
                                legacyService: .any
                            )
                        }
                        .thenThrow(KeychainStorageError.keySpecInaccessible)
                }

                // MARK: ---- does not report the key as missing
                it("does not report the key as missing") {
                    let storage: Storage = Storage.create(using: dependencies)

                    await expect { try await storage.perform(migrations: []) }
                        .to(throwError { error in
                            switch error {
                                case StorageError.databaseKeyMissingWithActiveDatabase:
                                    fail("An inaccessible keychain must not be reported as a missing key")

                                default: break
                            }
                        })
                }
            }

            // MARK: -- when there is no database
            context("when there is no database") {
                beforeEach {
                    try await mockFileManager.when { $0.fileExists(atPath: .any) }.thenReturn(false)
                    try await mockKeychain
                        .when { try $0.data(forKey: .dbCipherKeySpec) }
                        .thenThrow(
                            KeychainStorageError.failure(
                                code: errSecItemNotFound,
                                logCategory: .keychain,
                                description: "not found"
                            )
                        )
                    try await mockKeychain
                        .when {
                            try $0.getOrGenerateEncryptionKey(
                                forKey: .dbCipherKeySpec,
                                length: .any,
                                cat: .any,
                                legacyKey: .any,
                                legacyService: .any
                            )
                        }
                        .thenThrow(KeychainStorageError.keySpecCreationFailed)
                }

                // MARK: ---- does not report the key as missing
                ///
                /// An absent key with no database is an ordinary fresh install, not a lost key
                it("does not report the key as missing") {
                    let storage: Storage = Storage.create(using: dependencies)

                    await expect { try await storage.perform(migrations: []) }
                        .to(throwError { error in
                            switch error {
                                case StorageError.databaseKeyMissingWithActiveDatabase:
                                    fail("A fresh install must not be reported as a missing key")

                                default: break
                            }
                        })
                }
            }
        }
    }
}
