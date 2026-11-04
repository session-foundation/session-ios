// Copyright © 2026 Session Technology Foundation. All rights reserved.

import Foundation
import GRDB
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

            // MARK: -- when migrating
            context("when migrating") {
                @TestState var storage: Storage!

                beforeEach {
                    storage = try Storage.createForTesting(using: dependencies)
                    _ = await storage.state.first(where: { $0 == .pendingMigrations })
                }

                // MARK: ---- refuses to migrate while suspended
                ///
                /// Migrating would write to the database in the background, and moving out of `suspended` would leave nothing
                /// to resume it, so a startup waiting for the resume would never finish
                it("refuses to migrate while suspended") {
                    await storage.suspendDatabaseAccess()

                    await expect { try await storage.perform(migrations: [StorageSpecMigration.self]) }
                        .to(throwError { error in
                            switch error {
                                case StorageError.databaseSuspended: break
                                default: fail("Expected databaseSuspended, got \(error)")
                            }
                        })
                    await expect { await storage.state.first() }.to(equal(.suspended))
                }

                // MARK: ---- migrates once resumed
                it("migrates once resumed") {
                    await storage.suspendDatabaseAccess()
                    _ = try? await storage.perform(migrations: [StorageSpecMigration.self])
                    await storage.resumeDatabaseAccess()

                    await expect { await storage.state.first() }.to(equal(.pendingMigrations))
                    try await storage.perform(migrations: [StorageSpecMigration.self])
                    await expect { await storage.state.first() }.to(equal(.readyForUse))
                }

                // MARK: ---- marks a migration which aborts as failed rather than suspended
                ///
                /// Nothing resumes a database which wasn't suspended by `suspendDatabaseAccess`, so reporting this as a
                /// suspension would leave startup waiting forever
                it("marks a migration which aborts as failed rather than suspended") {
                    await expect { try await storage.perform(migrations: [StorageSpecAbortingMigration.self]) }
                        .to(throwError())
                    await expect { await storage.state.first() }.to(equal(.migrationsFailed))
                }

                // MARK: ---- resumes ready for use when a migration finishes while suspended
                ///
                /// A migration between statements can't be interrupted, so it can finish after the suspension; resuming into
                /// `pendingMigrations` would then leave everything waiting for `readyForUse` (like the `JobRunner`) waiting forever
                it("resumes ready for use when a migration finishes while suspended") {
                    let migrating: Task<Void, Error> = Task {
                        try await storage.perform(migrations: [StorageSpecBlockingMigration.self])
                    }
                    await Task.detached { StorageSpecBlockingMigration.started.wait() }.value
                    let suspending: Task<Void, Never> = Task { await storage.suspendDatabaseAccess() }
                    _ = await storage.state.first(where: { $0 == .suspended })
                    StorageSpecBlockingMigration.finish.signal()
                    try await migrating.value
                    await suspending.value
                    await storage.resumeDatabaseAccess()

                    await expect { await storage.state.first() }.to(equal(.readyForUse))
                }
            }

            // MARK: -- when a startup read is interrupted
            ///
            /// The failed-startup alert decides from these errors whether clearing the device is offered straight away, so
            /// they have to stay the ones it recognises as transient
            context("when a startup read is interrupted") {
                @TestState var storage: Storage!

                beforeEach {
                    storage = try Storage.createForTesting(using: dependencies)
                    try await storage.perform(migrations: [])
                }

                // MARK: ---- fails with databaseSuspended if the database was suspended first
                it("fails with databaseSuspended if the database was suspended first") {
                    await storage.suspendDatabaseAccess()

                    await expect { try await storage.read { db in try Int.fetchOne(db, sql: "SELECT 1") } }
                        .to(throwError { error in
                            switch error {
                                case StorageError.databaseSuspended: break
                                default: fail("Expected databaseSuspended, got \(error)")
                            }
                        })
                }

                // MARK: ---- fails with a CancellationError if the database is suspended during it
                it("fails with a CancellationError if the database is suspended during it") {
                    dependencies[feature: .forceSlowDatabaseQueries] = true
                    let read: Task<Int?, Error> = Task {
                        try await storage.read { db in try Int.fetchOne(db, sql: "SELECT 1") }
                    }
                    try await Task.sleep(for: .milliseconds(200))
                    await storage.suspendDatabaseAccess()

                    await expect { try await read.value }.to(throwError(errorType: CancellationError.self))
                }

                // MARK: ---- fails with a CancellationError if its task is cancelled
                it("fails with a CancellationError if its task is cancelled") {
                    dependencies[feature: .forceSlowDatabaseQueries] = true
                    let read: Task<Int?, Error> = Task {
                        try await storage.read { db in try Int.fetchOne(db, sql: "SELECT 1") }
                    }
                    try await Task.sleep(for: .milliseconds(200))
                    read.cancel()

                    await expect { try await read.value }.to(throwError(errorType: CancellationError.self))
                }
            }
        }
    }
}

// MARK: - Test Types

private enum StorageSpecMigration: Migration {
    static let identifier: String = "StorageSpecMigration"
    static let minExpectedRunDuration: TimeInterval = 0
    static let createdTables: [(TableRecord & FetchableRecord).Type] = []

    static func migrate(_ db: ObservingDatabase, using dependencies: Dependencies) throws {
        try db.execute(sql: "CREATE TABLE storageSpecTable (id INTEGER PRIMARY KEY)")
    }
}

private enum StorageSpecAbortingMigration: Migration {
    static let identifier: String = "StorageSpecAbortingMigration"
    static let minExpectedRunDuration: TimeInterval = 0
    static let createdTables: [(TableRecord & FetchableRecord).Type] = []

    static func migrate(_ db: ObservingDatabase, using dependencies: Dependencies) throws {
        throw DatabaseError(resultCode: .SQLITE_ABORT)
    }
}

private enum StorageSpecBlockingMigration: Migration {
    static let identifier: String = "StorageSpecBlockingMigration"
    static let minExpectedRunDuration: TimeInterval = 0
    static let createdTables: [(TableRecord & FetchableRecord).Type] = []
    static let started: DispatchSemaphore = DispatchSemaphore(value: 0)
    static let finish: DispatchSemaphore = DispatchSemaphore(value: 0)

    static func migrate(_ db: ObservingDatabase, using dependencies: Dependencies) throws {
        started.signal()
        finish.wait()
        try db.execute(sql: "CREATE TABLE storageSpecBlockingTable (id INTEGER PRIMARY KEY)")
    }
}
