// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import Quick
import Nimble
import SessionUtil
import SessionUIKit
import SessionNetworkingKit

@testable import Session
@testable import SessionMessagingKit
@testable import SessionUtilitiesKit

class DatabaseSpec: QuickSpec {
    fileprivate static let ignoredTables: Set<String> = [
        "sqlite_sequence", "grdb_migrations", "*_fts*"
    ]
    private static var snapshotCache: [String: Result<DatabaseQueue, Error>] = [:]
    
    override class func spec() {
        // MARK: Configuration
        
        @TestState var dependencies: TestDependencies! = TestDependencies()
        @TestState(singleton: .storage, in: dependencies) var mockStorage: Storage! = SynchronousStorage(
            customWriter: try! DatabaseQueue(),
            using: dependencies
        )
        @TestState(cache: .general, in: dependencies) var mockGeneralCache: MockGeneralCache! = MockGeneralCache(
            initialSetup: { cache in
                cache.when { $0.sessionId }.thenReturn(SessionId(.standard, hex: TestConstants.publicKey))
            }
        )
        @TestState(cache: .libSession, in: dependencies) var libSessionCache: LibSession.Cache! = LibSession.Cache(
            userSessionId: SessionId(.standard, hex: TestConstants.publicKey),
            using: dependencies
        )
        @TestState(singleton: .mediaDecoder, in: dependencies) var mockMediaDecoder: MockMediaDecoder! = MockMediaDecoder(initialSetup: { $0.defaultInitialSetup() })
        @TestState var initialResult: Result<Void, Error>! = nil
        @TestState var finalResult: Result<Void, Error>! = nil
        
        let allMigrations: [Migration.Type] = SNMessagingKit.migrations
        let dynamicTests: [MigrationTest] = MigrationTest.extractTests(allMigrations)
        let allTableTypes: [(TableRecord & FetchableRecord).Type] = MigrationTest.extractDatabaseTypes(allMigrations)
        MigrationTest.explicitValues = [
            // Specific enum values needed
            TableColumn(SessionThread.self, .notificationSound): 1000,
            TableColumn(ConfigDump.self, .variant): "userProfile",
            TableColumn(Interaction.self, .state): Interaction.State.sent.rawValue,
            
            // libSession will throw if we try to insert a community with an invalid
            // 'server' value or a room that is too long
            TableColumn(OpenGroup.self, .server): "https://www.oxen.io",
            TableColumn(OpenGroup.self, .roomToken): "testRoom",
            
            // libSession will fail to load state if the ConfigDump data is invalid
            TableColumn(ConfigDump.self, .data): Data()
        ]
        
        beforeSuite {
            snapshotCache.removeAll()
        }
        afterSuite {
            snapshotCache.removeAll()
        }
        
        // MARK: - a Database
        describe("a Database") {
            // MARK: -- can be created from an empty state
            it("can be created from an empty state") {
                mockStorage.perform(
                    migrations: allMigrations,
                    async: false,
                    onProgressUpdate: nil,
                    onComplete: { result in initialResult = result }
                )
                
                expect(initialResult).to(beSuccess())
            }
            
            // MARK: -- can still parse the database table types
            it("can still parse the database table types") {
                mockStorage.perform(
                    migrations: allMigrations,
                    async: false,
                    onProgressUpdate: nil,
                    onComplete: { result in initialResult = result }
                )
                expect(initialResult).to(beSuccess())
                
                // Generate dummy data (fetching below won't do anything)
                expect(try MigrationTest.generateDummyData(mockStorage, nullsWherePossible: false))
                    .toNot(throwError())
                
                // Fetch the records which are required by the migrations or were modified by them to
                // ensure the decoding is also still working correctly
                mockStorage.read { db in
                    allTableTypes.forEach { table in
                        expect { try table.fetchAll(db) }.toNot(throwError())
                    }
                }
            }
            
            // MARK: -- can still parse the database types setting null where possible
            it("can still parse the database types setting null where possible") {
                mockStorage.perform(
                    migrations: allMigrations,
                    async: false,
                    onProgressUpdate: nil,
                    onComplete: { result in initialResult = result }
                )
                expect(initialResult).to(beSuccess())
                
                // Generate dummy data (fetching below won't do anything)
                expect(try MigrationTest.generateDummyData(mockStorage, nullsWherePossible: true))
                    .toNot(throwError())
                
                // Fetch the records which are required by the migrations or were modified by them to
                // ensure the decoding is also still working correctly
                mockStorage.read { db in
                    allTableTypes.forEach { table in
                        expect { try table.fetchAll(db) }.toNot(throwError())
                    }
                }
            }
            
            // MARK: -- can migrate from X to Y
            dynamicTests.forEach { test in
                it("can migrate from \(test.initialMigrationIdentifier) to \(test.finalMigrationIdentifier)") {
                    let initialStateResult: Result<DatabaseQueue, Error> = {
                        if let cachedResult: Result<DatabaseQueue, Error> = snapshotCache[test.initialMigrationIdentifier] {
                            return cachedResult
                        }
                        
                        do {
                            let dbQueue = try DatabaseQueue()
                            let storage = SynchronousStorage(
                                customWriter: dbQueue,
                                using: dependencies
                            )
                            
                            // Generate dummy data (otherwise structural issues or invalid foreign keys won't error)
                            var initialResult: Result<Void, Error>!
                            storage.perform(
                                migrations: test.initialMigrations,
                                async: false,
                                onProgressUpdate: nil,
                                onComplete: { result in initialResult = result }
                            )
                            try initialResult.get()
                            
                            // Generate dummy data (otherwise structural issues or invalid foreign keys won't error)
                            try MigrationTest.generateDummyData(storage, nullsWherePossible: false)
                            
                            snapshotCache[test.initialMigrationIdentifier] = .success(dbQueue)
                            return .success(dbQueue)
                        } catch {
                            snapshotCache[test.initialMigrationIdentifier] = .failure(error)
                            return .failure(error)
                        }
                    }()
                    
                    var sourceDb: DatabaseQueue!
                    switch initialStateResult {
                        case .success(let db): sourceDb = db
                        case .failure(let error):
                            fail("Failed to prepare the initial state for '\(test.initialMigrationIdentifier)'. Error: \(error)")
                            return
                    }
                    
                    // Copy the cached initial state over to a new instance to run this test
                    let testDb = try! DatabaseQueue()
                    try! sourceDb.backup(to: testDb)
                    mockStorage = SynchronousStorage(customWriter: testDb, using: dependencies)

                    // Peform the target migrations to ensure the migrations themselves worked correctly
                    mockStorage.perform(
                        migrations: test.migrationsToTest,
                        async: false,
                        onProgressUpdate: nil,
                        onComplete: { result in finalResult = result }
                    )
                    
                    switch finalResult {
                        case .success: break
                        case .failure(let error):
                            fail("Failed to migrate from '\(test.initialMigrationIdentifier)' to '\(test.finalMigrationIdentifier)'. Error: \(error)")
                        case .none:
                            fail("Failed to migrate from '\(test.initialMigrationIdentifier)' to '\(test.finalMigrationIdentifier)'. Error: No result")
                    }
                }
            }
            
            // MARK: -- migration order hasn't changed
            it("migration order hasn't changed") {
                expect(SNMessagingKit.migrations.map { $0.identifier }).to(equal([
                    "utilitiesKit.initialSetup",
                    "utilitiesKit.SetupStandardJobs",
                    "utilitiesKit.YDBToGRDBMigration",
                    "snodeKit.initialSetup",
                    "snodeKit.SetupStandardJobs",
                    "messagingKit.initialSetup",
                    "messagingKit.SetupStandardJobs",
                    "snodeKit.YDBToGRDBMigration",
                    "messagingKit.YDBToGRDBMigration",
                    "snodeKit.FlagMessageHashAsDeletedOrInvalid",
                    "messagingKit.RemoveLegacyYDB",
                    "utilitiesKit.AddJobPriority",
                    "messagingKit.FixDeletedMessageReadState",
                    "messagingKit.FixHiddenModAdminSupport",
                    "messagingKit.HomeQueryOptimisationIndexes",
                    "uiKit.ThemePreferences",
                    "messagingKit.EmojiReacts",
                    "messagingKit.OpenGroupPermission",
                    "messagingKit.AddThreadIdToFTS",
                    "utilitiesKit.AddJobUniqueHash",
                    "snodeKit.AddSnodeReveivedMessageInfoPrimaryKey",
                    "snodeKit.DropSnodeCache",
                    "snodeKit.SplitSnodeReceivedMessageInfo",
                    "snodeKit.ResetUserConfigLastHashes",
                    "messagingKit.AddPendingReadReceipts",
                    "messagingKit.AddFTSIfNeeded",
                    "messagingKit.SessionUtilChanges",
                    "messagingKit.GenerateInitialUserConfigDumps",
                    "messagingKit.BlockCommunityMessageRequests",
                    "messagingKit.MakeBrokenProfileTimestampsNullable",
                    "messagingKit.RebuildFTSIfNeeded_2_4_5",
                    "messagingKit.DisappearingMessagesWithTypes",
                    "messagingKit.ScheduleAppUpdateCheckJob",
                    "messagingKit.AddMissingWhisperFlag",
                    "messagingKit.ReworkRecipientState",
                    "messagingKit.GroupsRebuildChanges",
                    "messagingKit.GroupsExpiredFlag",
                    "messagingKit.FixBustedInteractionVariant",
                    "messagingKit.DropLegacyClosedGroupKeyPairTable",
                    "messagingKit.MessageDeduplicationTable",
                    "utilitiesKit.RenameTableSettingToKeyValueStore",
                    "messagingKit.MoveSettingsToLibSession",
                    "messagingKit.RenameAttachments",
                    "messagingKit.AddProMessageFlag",
                    "LastProfileUpdateTimestamp"
                ]))
            }
            
            // MARK: -- there are no duplicate migration names
            it("there are no duplicate migration names") {
                expect(Set(SNMessagingKit.migrations.map { $0.identifier }).sorted())
                    .to(equal(SNMessagingKit.migrations.map { $0.identifier }.sorted()))
            }
        }
    }
}

// MARK: - Convenience

private extension Database.ColumnType {
    init(rawValue: Any) {
        switch rawValue as? String {
            case .some(let value): self = Database.ColumnType(rawValue: value)
            case .none: self = Database.ColumnType.any
        }
    }
}

private struct TableColumn: Hashable {
    let tableName: String
    let columnName: String
    
    init<T: TableRecord & ColumnExpressible>(_ type: T.Type, _ column: T.Columns) {
        self.tableName = T.databaseTableName
        self.columnName = column.name
    }
    
    init?(_ tableName: String, _ columnName: Any?) {
        guard let finalColumnName: String = columnName as? String else { return nil }
        
        self.tableName = tableName
        self.columnName = finalColumnName
    }
}

private class MigrationTest {
    static var explicitValues: [TableColumn: (any DatabaseValueConvertible)] = [:]
    
    let initialMigrations: [Migration.Type]
    let migrationsToTest: [Migration.Type]
    
    var initialMigrationIdentifier: String { return (initialMigrations.last?.identifier ?? "an empty database") }
    var finalMigrationIdentifier: String { return (migrationsToTest.last?.identifier ?? "invalid") }

    private init(
        initialMigrations: [Migration.Type],
        migrationsToTest: [Migration.Type]
    ) {
        self.initialMigrations = initialMigrations
        self.migrationsToTest = migrationsToTest
    }
    
    // MARK: - Test Data
    
    static func extractTests(_ allMigrations: [Migration.Type]) -> [MigrationTest] {
        return (0..<(allMigrations.count - 1))
            .flatMap { index -> [MigrationTest] in
                ((index + 1)..<allMigrations.count).map { targetMigrationIndex -> MigrationTest in
                    MigrationTest(
                        initialMigrations: Array(allMigrations[0..<index]),
                        migrationsToTest: Array(allMigrations[index..<targetMigrationIndex])
                    )
                }
            }
    }
    
    static func extractDatabaseTypes(_ allMigrations: [Migration.Type]) -> [(TableRecord & FetchableRecord).Type] {
        return Array(allMigrations
            .reduce(into: [:]) { result, next in
                next.createdTables.forEach { table in
                    result[ObjectIdentifier(table).hashValue] = table
                }
            }
            .values)
    }
    
    // MARK: - Mock Data
    
    static func generateDummyData(_ storage: Storage, nullsWherePossible: Bool) throws {
        var generationError: Error? = nil
        
        // The `PRAGMA foreign_keys` is a no-op within a transaction so we have to do it outside of one
        try storage.testDbWriter?.writeWithoutTransaction { db in try db.execute(sql: "PRAGMA foreign_keys = OFF") }
        storage.write { db in
            do {
                try MigrationTest.generateDummyData(db, nullsWherePossible: nullsWherePossible)
                try db.checkForeignKeys()
            }
            catch { generationError = error }
        }
        try storage.testDbWriter?.writeWithoutTransaction { db in try db.execute(sql: "PRAGMA foreign_keys = ON") }
        
        // Throw the error if there was one
        if let error: Error = generationError { throw error }
    }
    
    private static func generateDummyData(_ db: ObservingDatabase, nullsWherePossible: Bool) throws {
        // Fetch table schema information
        let disallowedPrefixes: Set<String> = DatabaseSpec.ignoredTables
            .filter { $0.hasPrefix("*") && !$0.hasSuffix("*") }
            .map { String($0[$0.index(after: $0.startIndex)...]) }
            .asSet()
        let disallowedSuffixes: Set<String> = DatabaseSpec.ignoredTables
            .filter { $0.hasSuffix("*") && !$0.hasPrefix("*") }
            .map { String($0[$0.startIndex..<$0.index(before: $0.endIndex)]) }
            .asSet()
        let disallowedContains: Set<String> = DatabaseSpec.ignoredTables
            .filter { $0.hasPrefix("*") && $0.hasSuffix("*") }
            .map { String($0[$0.index(after: $0.startIndex)..<$0.index(before: $0.endIndex)]) }
            .asSet()
        let tables: [Row] = try Row
            .fetchAll(db, sql: "SELECT * from sqlite_schema WHERE type = 'table'")
            .filter { tableInfo -> Bool in
                guard let name: String = tableInfo["name"] else { return false }
                
                return (
                    !DatabaseSpec.ignoredTables.contains(name) &&
                    !disallowedPrefixes.contains(where: { name.hasPrefix($0) }) &&
                    !disallowedSuffixes.contains(where: { name.hasSuffix($0) }) &&
                    !disallowedContains.contains(where: { name.contains($0) })
                )
            }
        
        // Generate data via schema inspection for all other tables
        try tables.forEach { tableInfo in
            switch tableInfo["name"] as? String {
                case .none: throw StorageError.generic
                
                case Identity.databaseTableName:
                    // If there is an 'Identity' table then insert "proper" identity info (otherwise mock
                    // data might get deleted as invalid in libSession migrations)
                    try [
                        Identity(variant: .x25519PublicKey, data: Data(hex: TestConstants.publicKey)),
                        Identity(variant: .x25519PrivateKey, data: Data(hex: TestConstants.privateKey)),
                        Identity(variant: .ed25519PublicKey, data: Data(hex: TestConstants.edPublicKey)),
                        Identity(variant: .ed25519SecretKey, data: Data(hex: TestConstants.edSecretKey))
                    ].forEach { try $0.insert(db) }
                    
                case JobDependencies.databaseTableName:
                    // Unsure why but for some reason this causes foreign key constraint errors during tests
                    // so just validate that the columns haven't changed since this was added
                    guard
                        JobDependencies.Columns.allCases.count == 2 &&
                        JobDependencies.Columns.jobId.name == "jobId" &&
                        JobDependencies.Columns.dependantId.name == "dependantId"
                    else { throw StorageError.invalidData }
                    return
                    
                case .some(let name):
                    // No need to insert dummy data if it already exists in the table
                    guard try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM '\(name)'") == 0 else { return }
                    
                    let columnInfo: [Row] = try Row.fetchAll(db, sql: "PRAGMA table_info('\(name)');")
                    let validNames: [String] = columnInfo.compactMap { $0["name"].map { "'\($0)'" } }
                    let columnNames: String = validNames.joined(separator: ", ")
                    let columnArgs: String = validNames.map { _ in "?" }.joined(separator: ", ")
                    
                    try db.execute(
                        sql: "INSERT INTO \(name) (\(columnNames)) VALUES (\(columnArgs))",
                        arguments: StatementArguments(columnInfo.map { (column: Row) in
                            // If we want to allow setting nulls (and the column is nullable but not a primary
                            // key) then use null for it's value
                            let notNull: Int = column["notnull"]
                            let primaryKey: Int = column["pk"]
                            
                            guard !nullsWherePossible || notNull != 0 || primaryKey == 1 else {
                                return nil
                            }
                            
                            // If this column has an explicitly defined value then use that
                            if
                                let key: TableColumn = TableColumn(name, column["name"]),
                                let explicitValue: (any DatabaseValueConvertible) = MigrationTest.explicitValues[key]
                            {
                                return explicitValue
                            }
                            
                            // Otherwise generate some mock data (trying to use potentially real values in case
                            // something is a primary/foreign key)
                            switch Database.ColumnType(rawValue: column["type"]) {
                                case .text: return "05\(TestConstants.publicKey)"
                                case .blob: return Data([1, 2, 3])
                                case .boolean: return false
                                case .integer, .numeric, .double, .real: return 1
                                case .date, .datetime: return Date(timeIntervalSince1970: 1234567890)
                                case .any: return nil
                                default: return nil
                            }
                        })
                    )
            }
        }
    }
}
