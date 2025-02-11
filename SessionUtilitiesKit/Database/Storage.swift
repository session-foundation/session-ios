// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import UIKit
import CryptoKit
import Combine
import GRDB

// MARK: - KeychainStorage

public extension KeychainStorage.DataKey { static let dbCipherKeySpec: Self = "GRDBDatabaseCipherKeySpec" }

// MARK: - Storage

open class Storage {
    public struct CurrentlyRunningMigration: ThreadSafeType {
        public let identifier: TargetMigrations.Identifier
        public let migration: Migration.Type
    }
    
    public static let queuePrefix: String = "SessionDatabase"
    public static let dbFileName: String = "Session.sqlite"
    private static let kSQLCipherKeySpecLength: Int = 48
    
    /// If a transaction takes longer than this duration a warning will be logged but the transaction will continue to run
    private static let slowTransactionThreshold: TimeInterval = 3
    
    /// When attempting to do a write the transaction will wait this long to acquite a lock before failing
    private static let writeTransactionStartTimeout: TimeInterval = 5
    
    /// If a transaction takes longer than this duration then we should fail the transaction rather than keep hanging
    private static let transactionDeadlockTimeoutSeconds: Int = 5
    
    private static var sharedDatabaseDirectoryPath: String { "\(FileManager.default.appSharedDataDirectoryPath)/database" }
    private static var databasePath: String { "\(Storage.sharedDatabaseDirectoryPath)/\(Storage.dbFileName)" }
    private static var databasePathShm: String { "\(Storage.sharedDatabaseDirectoryPath)/\(Storage.dbFileName)-shm" }
    private static var databasePathWal: String { "\(Storage.sharedDatabaseDirectoryPath)/\(Storage.dbFileName)-wal" }
    
    public static var hasCreatedValidInstance: Bool { internalHasCreatedValidInstance }
    public static var isDatabasePasswordAccessible: Bool {
        guard (try? getDatabaseCipherKeySpec()) != nil else { return false }
        
        return true
    }
    
    private var startupError: Error?
    @ThreadSafe private var migrationsCompleted: Bool = false
    @ThreadSafe private static var internalHasCreatedValidInstance: Bool = false
    @ThreadSafe private var internalCurrentlyRunningMigration: CurrentlyRunningMigration? = nil
    
    public static let shared: Storage = Storage()
    public private(set) var isValid: Bool = false
    public private(set) var isSuspended: Bool = false
    
    /// This property gets set the first time we successfully read from the database
    public private(set) var hasSuccessfullyRead: Bool = false
    
    /// This property gets set the first time we successfully write to the database
    public private(set) var hasSuccessfullyWritten: Bool = false
    
    public var hasCompletedMigrations: Bool { migrationsCompleted }
    public var currentlyRunningMigration: CurrentlyRunningMigration? {
        internalCurrentlyRunningMigration
    }
    public static let defaultPublisherScheduler: ValueObservationScheduler = .async(onQueue: .main)
    
    fileprivate var dbWriter: DatabaseWriter?
    internal var testDbWriter: DatabaseWriter? { dbWriter }
    @ThreadSafeObject private var unprocessedMigrationRequirements: [MigrationRequirement] = MigrationRequirement.allCases
    @ThreadSafeObject private var migrationProgressUpdater: ((String, CGFloat) -> ())?
    @ThreadSafeObject private var migrationRequirementProcesser: ((Database, MigrationRequirement) -> ())?
    
    // MARK: - Initialization
    
    public init(customWriter: DatabaseWriter? = nil) {
        configureDatabase(customWriter: customWriter)
    }
    
    public init(
        testAccessTo databasePath: String,
        encryptedKeyPath: String,
        encryptedKeyPassword: String
    ) throws {
        try testAccess(
            databasePath: databasePath,
            encryptedKeyPath: encryptedKeyPath,
            encryptedKeyPassword: encryptedKeyPassword
        )
    }
    
    private func configureDatabase(customWriter: DatabaseWriter? = nil) {
        // Create the database directory if needed and ensure it's protection level is set before attempting to
        // create the database KeySpec or the database itself
        try? FileSystem.ensureDirectoryExists(at: Storage.sharedDatabaseDirectoryPath)
        try? FileSystem.protectFileOrFolder(at: Storage.sharedDatabaseDirectoryPath)
        
        // If a custom writer was provided then use that (for unit testing)
        guard customWriter == nil else {
            dbWriter = customWriter
            isValid = true
            Storage.internalHasCreatedValidInstance = true
            return
        }
        
        /// Generate the database KeySpec if needed (this MUST be done before we try to access the database as a different thread
        /// might attempt to access the database before the key is successfully created)
        ///
        /// We reset the bytes immediately after generation to ensure the database key doesn't hang around in memory unintentionally
        ///
        /// **Note:** If we fail to get/generate the keySpec then don't bother continuing to setup the Database as it'll just be invalid,
        /// in this case the App/Extensions will have logic that checks the `isValid` flag of the database
        do {
            var tmpKeySpec: Data = try getOrGenerateDatabaseKeySpec()
            tmpKeySpec.resetBytes(in: 0..<tmpKeySpec.count)
        }
        catch { return }
        
        // Configure the database and create the DatabasePool for interacting with the database
        var config = Configuration()
        config.label = Storage.queuePrefix
        config.maximumReaderCount = 10                   /// Increase the max read connection limit - Default is 5

        /// It seems we should do this per https://github.com/groue/GRDB.swift/pull/1485 but with this change
        /// we then need to define how long a write transaction should wait for before timing out (read transactions always run
        /// in`DEFERRED` mode so won't be affected by these settings)
        config.defaultTransactionKind = .immediate
        config.busyMode = .timeout(Storage.writeTransactionStartTimeout)

        /// Load in the SQLCipher keys
        config.prepareDatabase { [weak self] db in
            var keySpec: Data = try self?.getOrGenerateDatabaseKeySpec() ?? { throw StorageError.invalidKeySpec }()
            defer { keySpec.resetBytes(in: 0..<keySpec.count) } // Reset content immediately after use
            
            // Use a raw key spec, where the 96 hexadecimal digits are provided
            // (i.e. 64 hex for the 256 bit key, followed by 32 hex for the 128 bit salt)
            // using explicit BLOB syntax, e.g.:
            //
            // x'98483C6EB40B6C31A448C22A66DED3B5E5E8D5119CAC8327B655C8B5C483648101010101010101010101010101010101'
            keySpec = try (keySpec.toHexString().data(using: .utf8) ?? { throw StorageError.invalidKeySpec }())
            keySpec.insert(contentsOf: [120, 39], at: 0)    // "x'" prefix
            keySpec.append(39)                              // "'" suffix
            
            try db.usePassphrase(keySpec)
            
            // According to the SQLCipher docs iOS needs the 'cipher_plaintext_header_size' value set to at least
            // 32 as iOS extends special privileges to the database and needs this header to be in plaintext
            // to determine the file type
            //
            // For more info see: https://www.zetetic.net/sqlcipher/sqlcipher-api/#cipher_plaintext_header_size
            try db.execute(sql: "PRAGMA cipher_plaintext_header_size = 32")
        }
        
        // Create the DatabasePool to allow us to connect to the database and mark the storage as valid
        do {
            dbWriter = try DatabasePool(
                path: "\(Storage.sharedDatabaseDirectoryPath)/\(Storage.dbFileName)",
                configuration: config
            )
            isValid = true
            Storage.internalHasCreatedValidInstance = true
        }
        catch { startupError = error }
    }
    
    // MARK: - Migrations
    
    public typealias KeyedMigration = (key: String, identifier: TargetMigrations.Identifier, migration: Migration.Type)
    
    public static func appliedMigrationIdentifiers(_ db: Database) -> Set<String> {
        let migrator: DatabaseMigrator = DatabaseMigrator()
        
        return (try? migrator.appliedIdentifiers(db))
            .defaulting(to: [])
    }
    
    public static func sortedMigrationInfo(migrationTargets: [MigratableTarget.Type]) -> [KeyedMigration] {
        typealias MigrationInfo = (identifier: TargetMigrations.Identifier, migrations: TargetMigrations.MigrationSet)
        
        return migrationTargets
            .map { target -> TargetMigrations in target.migrations() }
            .sorted()
            .reduce(into: [[MigrationInfo]]()) { result, next in
                next.migrations.enumerated().forEach { index, migrationSet in
                    if result.count <= index {
                        result.append([])
                    }

                    result[index] = (result[index] + [(next.identifier, migrationSet)])
                }
            }
            .reduce(into: []) { result, next in
                next.forEach { identifier, migrations in
                    result.append(contentsOf: migrations.map { (identifier.key(with: $0), identifier, $0) })
                }
            }
    }
    
    public func perform(
        migrationTargets: [MigratableTarget.Type],
        async: Bool = true,
        onProgressUpdate: ((CGFloat, TimeInterval) -> ())?,
        onMigrationRequirement: @escaping (Database, MigrationRequirement) -> (),
        onComplete: @escaping (Swift.Result<Void, Error>, Bool) -> (),
        using dependencies: Dependencies
    ) {
        perform(
            sortedMigrations: Storage.sortedMigrationInfo(migrationTargets: migrationTargets),
            async: async,
            onProgressUpdate: onProgressUpdate,
            onMigrationRequirement: onMigrationRequirement,
            onComplete: onComplete,
            using: dependencies
        )
    }
    
    internal func perform(
        sortedMigrations: [KeyedMigration],
        async: Bool,
        onProgressUpdate: ((CGFloat, TimeInterval) -> ())?,
        onMigrationRequirement: @escaping (Database, MigrationRequirement) -> (),
        onComplete: @escaping (Swift.Result<Void, Error>, Bool) -> (),
        using dependencies: Dependencies
    ) {
        guard isValid, let dbWriter: DatabaseWriter = dbWriter else {
            let error: Error = (startupError ?? StorageError.startupFailed)
            SNLog("[Database Error] Statup failed with error: \(error)")
            onComplete(.failure(error), false)
            return
        }
        
        // Setup and run any required migrations
        var migrator: DatabaseMigrator = DatabaseMigrator()
        sortedMigrations.forEach { _, identifier, migration in
            migrator.registerMigration(self, targetIdentifier: identifier, migration: migration, using: dependencies)
        }
        
        // Determine which migrations need to be performed and gather the relevant settings needed to
        // inform the app of progress/states
        let completedMigrations: [String] = (try? dbWriter.read { db in try migrator.completedMigrations(db) })
            .defaulting(to: [])
        let unperformedMigrations: [KeyedMigration] = sortedMigrations
            .reduce(into: []) { result, next in
                guard !completedMigrations.contains(next.key) else { return }
                
                result.append(next)
            }
        let migrationToDurationMap: [String: TimeInterval] = unperformedMigrations
            .reduce(into: [:]) { result, next in
                result[next.key] = next.migration.minExpectedRunDuration
            }
        let unperformedMigrationDurations: [TimeInterval] = unperformedMigrations
            .map { _, _, migration in migration.minExpectedRunDuration }
        let totalMinExpectedDuration: TimeInterval = migrationToDurationMap.values.reduce(0, +)
        let needsConfigSync: Bool = unperformedMigrations
            .contains(where: { _, _, migration in migration.needsConfigSync })
        
        self._migrationProgressUpdater.set(to: { targetKey, progress in
            guard let migrationIndex: Int = unperformedMigrations.firstIndex(where: { key, _, _ in key == targetKey }) else {
                return
            }
            
            let completedExpectedDuration: TimeInterval = (
                (migrationIndex > 0 ? unperformedMigrationDurations[0..<migrationIndex].reduce(0, +) : 0) +
                (unperformedMigrationDurations[migrationIndex] * progress)
            )
            let totalProgress: CGFloat = (completedExpectedDuration / totalMinExpectedDuration)
            
            DispatchQueue.main.async {
                onProgressUpdate?(totalProgress, totalMinExpectedDuration)
            }
        })
        self._migrationRequirementProcesser.set(to: onMigrationRequirement)
        
        // Store the logic to run when the migration completes
        let migrationCompleted: (Swift.Result<Void, Error>) -> () = { [weak self] result in
            // Process any unprocessed requirements which need to be processed before completion
            // then clear out the state
            let requirementProcessor: ((Database, MigrationRequirement) -> ())? = self?.migrationRequirementProcesser
            let remainingMigrationRequirements: [MigrationRequirement] = (self?.unprocessedMigrationRequirements
                .filter { $0.shouldProcessAtCompletionIfNotRequired })
                .defaulting(to: [])
            self?.migrationsCompleted = true
            self?._migrationProgressUpdater.set(to: nil)
            self?._migrationRequirementProcesser.set(to: nil)
            
            // Process any remaining migration requirements
            if !remainingMigrationRequirements.isEmpty {
                self?.write { db in
                    remainingMigrationRequirements.forEach { requirementProcessor?(db, $0) }
                }
            }
            
            // Reset in case there is a requirement on a migration which runs when returning from
            // the background
            self?._unprocessedMigrationRequirements.set(to: MigrationRequirement.allCases)
            
            // Don't log anything in the case of a 'success' or if the database is suspended (the
            // latter will happen if the user happens to return to the background too quickly on
            // launch so is unnecessarily alarming, it also gets caught and logged separately by
            // the 'write' functions anyway)
            switch result {
                case .success: break
                case .failure(DatabaseError.SQLITE_ABORT): break
                case .failure(let error): SNLog("[Migration Error] Migration failed with error: \(error)")
            }
            
            onComplete(result, needsConfigSync)
        }
        
        // if there aren't any migrations to run then just complete immediately (this way the migrator
        // doesn't try to execute on the DBWrite thread so returning from the background can't get blocked
        // due to some weird endless process running)
        guard !unperformedMigrations.isEmpty else {
            migrationCompleted(.success(()))
            return
        }
        
        // If we have an unperformed migration then trigger the progress updater immediately
        if let firstMigrationKey: String = unperformedMigrations.first?.key {
            self.migrationProgressUpdater?(firstMigrationKey, 0)
        }
        
        // Note: The non-async migration should only be used for unit tests
        guard async else { return migrationCompleted(Result(try migrator.migrate(dbWriter))) }
        
        migrator.asyncMigrate(dbWriter) { result in
            let finalResult: Result<Void, Error> = {
                switch result {
                    case .failure(let error): return .failure(error)
                    case .success: return .success(())
                }
            }()
            
            // Note: We need to dispatch this to the next run toop to prevent blocking if the callback
            // performs subsequent database operations
            DispatchQueue.global(qos: .userInitiated).async(using: dependencies) {
                migrationCompleted(finalResult)
            }
        }
    }
    
    public func willStartMigration(
        _ db: Database,
        _ migration: Migration.Type,
        _ identifier: TargetMigrations.Identifier
    ) {
        internalCurrentlyRunningMigration = CurrentlyRunningMigration(
            identifier: identifier,
            migration: migration
        )
        
        let unprocessedRequirements: Set<MigrationRequirement> = migration.requirements.asSet()
            .intersection(unprocessedMigrationRequirements.asSet())
        
        // No need to do anything if there are no unprocessed requirements
        guard !unprocessedRequirements.isEmpty else { return }
        
        // Process all of the requirements for this migration
        unprocessedRequirements.forEach { migrationRequirementProcesser?(db, $0) }
        
        // Remove any processed requirements from the list (don't want to process them multiple times)
        _unprocessedMigrationRequirements.performUpdate {
            Array($0.asSet().subtracting(migration.requirements.asSet()))
        }
    }
    
    public func didCompleteMigration() {
        internalCurrentlyRunningMigration = nil
    }
    
    public static func update(
        progress: CGFloat,
        for migration: Migration.Type,
        in target: TargetMigrations.Identifier
    ) {
        // In test builds ignore any migration progress updates (we run in a custom database writer anyway)
        guard !SNUtilitiesKit.isRunningTests else { return }
        
        Storage.shared.migrationProgressUpdater?(target.key(with: migration), progress)
    }
    
    // MARK: - Security
    
    private static func getDatabaseCipherKeySpec() throws -> Data {
        try Singleton.keychain.migrateLegacyKeyIfNeeded(
            legacyKey: "GRDBDatabaseCipherKeySpec",
            legacyService: "TSKeyChainService",
            toKey: .dbCipherKeySpec
        )
        return try Singleton.keychain.data(forKey: .dbCipherKeySpec)
    }
    
    @discardableResult private func getOrGenerateDatabaseKeySpec() throws -> Data {
        do {
            var keySpec: Data = try Storage.getDatabaseCipherKeySpec()
            defer { keySpec.resetBytes(in: 0..<keySpec.count) }
            
            guard keySpec.count == Storage.kSQLCipherKeySpecLength else { throw StorageError.invalidKeySpec }
            
            return keySpec
        }
        catch {
            switch (error, (error as? KeychainStorageError)?.code) {
                case (StorageError.invalidKeySpec, _):
                    // For these cases it means either the keySpec or the keychain has become corrupt so in order to
                    // get back to a "known good state" and behave like a new install we need to reset the storage
                    // and regenerate the key
                    if !SNUtilitiesKit.isRunningTests {
                        // Try to reset app by deleting database.
                        resetAllStorage()
                    }
                    fallthrough
                
                case (_, errSecItemNotFound):
                    // No keySpec was found so we need to generate a new one
                    do {
                        var keySpec: Data = try Randomness.generateRandomBytes(numberBytes: Storage.kSQLCipherKeySpecLength)
                        defer { keySpec.resetBytes(in: 0..<keySpec.count) } // Reset content immediately after use
                        
                        try Singleton.keychain.set(data: keySpec, forKey: .dbCipherKeySpec)
                        return keySpec
                    }
                    catch {
                        SNLog("Setting keychain value failed with error: \(error)")
                        Thread.sleep(forTimeInterval: 15)    // Sleep to allow any background behaviours to complete
                        throw StorageError.keySpecCreationFailed
                    }
                    
                default:
                    // Because we use kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly, the keychain will be inaccessible
                    // after device restart until device is unlocked for the first time. If the app receives a push
                    // notification, we won't be able to access the keychain to process that notification, so we should
                    // just terminate by throwing an uncaught exception
                    if Singleton.hasAppContext && (Singleton.appContext.isMainApp || Singleton.appContext.isInBackground) {
                        let appState: UIApplication.State = Singleton.appContext.reportedApplicationState
                        SNLog("CipherKeySpec inaccessible. New install or no unlock since device restart?, ApplicationState: \(appState.name)")
                        
                        // In this case we should have already detected the situation earlier and exited
                        // gracefully (in the app delegate) using isDatabasePasswordAccessible, but we
                        // want to stop the app running here anyway
                        Thread.sleep(forTimeInterval: 5)    // Sleep to allow any background behaviours to complete
                        throw StorageError.keySpecInaccessible
                    }
                    
                    SNLog("CipherKeySpec inaccessible; not main app.")
                    Thread.sleep(forTimeInterval: 5)    // Sleep to allow any background behaviours to complete
                    throw StorageError.keySpecInaccessible
            }
        }
    }
    
    // MARK: - File Management
    
    /// In order to avoid the `0xdead10cc` exception we manually track whether database access should be suspended, when
    /// in a suspended state this class will fail/reject all read/write calls made to it. Additionally if there was an existing transaction
    /// in progress it will be interrupted.
    ///
    /// The generally suggested approach is to avoid this entirely by not storing the database in an AppGroup folder and sharing it
    /// with extensions - this may be possible but will require significant refactoring and a potentially painful migration to move the
    /// database and other files into the App folder
    public func suspendDatabaseAccess() {
        guard !isSuspended else { return }
        
        isSuspended = true
        Log.info("[Storage] Database access suspended.")
        
        /// Interrupt any open transactions (if this function is called then we are expecting that all processes have finished running
        /// and don't actually want any more transactions to occur)
        dbWriter?.interrupt()
    }
    
    /// This method reverses the database suspension used to prevent the `0xdead10cc` exception (see `suspendDatabaseAccess()`
    /// above for more information
    public func resumeDatabaseAccess() {
        guard isSuspended else { return }

        isSuspended = false
        Log.info("[Storage] Database access resumed.")
    }
    
    public func checkpoint(_ mode: Database.CheckpointMode) throws {
        try dbWriter?.writeWithoutTransaction { db in _ = try db.checkpoint(mode) }
    }
    
    public func closeDatabase() throws {
        suspendDatabaseAccess()
        isValid = false
        dbWriter = nil
    }
    
    public func resetAllStorage() {
        isValid = false
        Storage.internalHasCreatedValidInstance = false
        migrationsCompleted = false
        dbWriter = nil
        
        deleteDatabaseFiles()
        do { try deleteDbKeys() } catch { Log.warn("Failed to delete database keys.") }
    }
    
    public func reconfigureDatabase() {
        configureDatabase()
    }
    
    public func resetForCleanMigration() {
        // Clear existing content
        resetAllStorage()
        
        // Reconfigure
        reconfigureDatabase()
    }
    
    private func deleteDatabaseFiles() {
        do { try FileSystem.deleteFile(at: Storage.databasePath) } catch { Log.warn("Failed to delete database.") }
        do { try FileSystem.deleteFile(at: Storage.databasePathShm) } catch { Log.warn("Failed to delete database-shm.") }
        do { try FileSystem.deleteFile(at: Storage.databasePathWal) } catch { Log.warn("Failed to delete database-wal.") }
    }
    
    private func deleteDbKeys() throws {
        try Singleton.keychain.remove(key: .dbCipherKeySpec)
    }
    
    // MARK: - Logging Functions
    
    enum StorageState {
        case valid(DatabaseWriter)
        case invalid(Error)
        
        init(_ storage: Storage?) {
            switch (storage?.isSuspended, storage?.isValid, storage?.dbWriter) {
                case (true, _, _): self = .invalid(StorageError.databaseSuspended)
                case (false, true, .some(let dbWriter)): self = .valid(dbWriter)
                default: self = .invalid(StorageError.databaseInvalid)
            }
        }
        
        static func logIfNeeded(_ error: Error, isWrite: Bool) {
            switch error {
                case DatabaseError.SQLITE_ABORT, DatabaseError.SQLITE_INTERRUPT, DatabaseError.SQLITE_ERROR:
                    let message: String = ((error as? DatabaseError)?.message ?? "Unknown")
                    Log.error("[Storage] Database \(isWrite ? "write" : "read") failed due to error: \(message)")
                
                case StorageError.databaseSuspended:
                    Log.error("[Storage] Database \(isWrite ? "write" : "read") failed as the database is suspended.")
                    
                case StorageError.transactionDeadlockTimeout:
                    Log.critical("[Storage] Database \(isWrite ? "write" : "read") failed due to a potential synchronous query deadlock timeout.")
                    
                default: break
            }
        }
        
        static func logIfNeeded<T>(_ error: Error, isWrite: Bool) -> T? {
            logIfNeeded(error, isWrite: isWrite)
            return nil
        }
        
        static func logIfNeeded<T>(_ error: Error, isWrite: Bool) -> AnyPublisher<T, Error> {
            logIfNeeded(error, isWrite: isWrite)
            return Fail<T, Error>(error: error).eraseToAnyPublisher()
        }
    }
    
    // MARK: - Operations
    
    private static func track<T>(
        _ db: Database,
        _ info: CallInfo,
        _ operation: @escaping (Database) throws -> T
    ) throws -> T {
        guard info.storage?.isSuspended == false else { throw StorageError.databaseSuspended }
        
        let timer: TransactionTimer = TransactionTimer.start(
            duration: Storage.slowTransactionThreshold,
            info: info
        )
        defer { timer.stop() }
        
        // Get the result
        let result: T = try operation(db)
        
        // Update the state flags
        switch info.isWrite {
            case true: info.storage?.hasSuccessfullyWritten = true
            case false: info.storage?.hasSuccessfullyRead = true
        }
        
        return result
    }
    
    /// This function manually performs `read`/`write` operations in either a synchronous or asyncronous way using a semaphore to
    /// block the syncrhonous version because `GRDB` has an internal assertion when using it's built-in synchronous `read`/`write`
    /// functions to prevent reentrancy which is unsupported
    ///
    /// Unfortunately this results in the code getting messy when trying to chain multiple database transactions (even
    /// when using `db.afterNextTransaction`) which is somewhat unintuitive
    ///
    /// The `async` variants don't need to worry about this reentrancy issue so instead we route we use those for all operations instead
    /// and just block the thread when we want to perform a synchronous operation
    @discardableResult private static func performOperation<T>(
        _ info: CallInfo,
        _ operation: @escaping (Database) throws -> T,
        _ completion: ((Result<T, Error>) -> Void)? = nil
    ) -> Result<T, Error> {
        var result: Result<T, Error> = .failure(StorageError.invalidQueryResult)
        let semaphore: DispatchSemaphore? = (info.isAsync ? nil : DispatchSemaphore(value: 0))
        let logErrorIfNeeded: (Result<T, Error>) -> () = { result in
            switch result {
                case .success: break
                case .failure(let error): StorageState.logIfNeeded(error, isWrite: info.isWrite)
            }
        }
        
        /// Perform the actual operation
        switch (StorageState(info.storage), info.isWrite) {
            case (.invalid(let error), _):
                result = .failure(error)
                semaphore?.signal()
            
            case (.valid(let dbWriter), true):
                dbWriter.asyncWrite(
                    { db in result = .success(try Storage.track(db, info, operation)) },
                    completion: { _, dbResult in
                        switch dbResult {
                            case .success: break
                            case .failure(let error): result = .failure(error)
                        }
                        semaphore?.signal()
                        
                        if info.isAsync { logErrorIfNeeded(result) }
                        completion?(result)
                    }
                )
                
            case (.valid(let dbWriter), false):
                dbWriter.asyncRead { dbResult in
                    do {
                        switch dbResult {
                            case .failure(let error): throw error
                            case .success(let db): result = .success(try Storage.track(db, info, operation))
                        }
                    } catch {
                        result = .failure(error)
                    }
                    semaphore?.signal()
                    
                    if info.isAsync { logErrorIfNeeded(result) }
                    completion?(result)
                }
        }
        
        /// If this is a synchronous operation then `semaphore` will exist and will block here waiting on the signal from one of the
        /// above closures to be sent
        let semaphoreResult: DispatchTimeoutResult? = semaphore?.wait(timeout: .now() + .seconds(Storage.transactionDeadlockTimeoutSeconds))
        
        /// If the transaction timed out then log the error and report a failure
        guard semaphoreResult != .timedOut else {
            StorageState.logIfNeeded(StorageError.transactionDeadlockTimeout, isWrite: info.isWrite)
            return .failure(StorageError.transactionDeadlockTimeout)
        }
        
        if !info.isAsync { logErrorIfNeeded(result) }
        return result
    }
    
    private func performPublisherOperation<T>(
        _ fileName: String,
        _ functionName: String,
        _ lineNumber: Int,
        isWrite: Bool,
        _ operation: @escaping (Database) throws -> T
    ) -> AnyPublisher<T, Error> {
        switch StorageState(self) {
            case .invalid(let error): return StorageState.logIfNeeded(error, isWrite: false)
            case .valid:
                /// **Note:** GRDB does have `readPublisher`/`writePublisher` functions but it appears to asynchronously
                /// trigger both the `output` and `complete` closures at the same time which causes a lot of unexpected
                /// behaviours (this behaviour is apparently expected but still causes a number of odd behaviours in our code
                /// for more information see https://github.com/groue/GRDB.swift/issues/1334)
                ///
                /// Instead of this we are just using `Deferred { Future {} }` which is executed on the specified scheduled
                /// which behaves in a much more expected way than the GRDB `readPublisher`/`writePublisher` does
                let info: CallInfo = CallInfo(self, fileName, functionName, lineNumber, .syncWrite)
                return Deferred {
                    Future { resolver in
                        resolver(Storage.performOperation(info, operation))
                    }
                }.eraseToAnyPublisher()
        }
    }
    
    // MARK: - Functions
    
    @discardableResult public func write<T>(
        fileName file: String = #file,
        functionName funcN: String = #function,
        lineNumber line: Int = #line,
        using dependencies: Dependencies = Dependencies(),
        updates: @escaping (Database) throws -> T?
    ) -> T? {
        switch Storage.performOperation(CallInfo(self, file, funcN, line, .syncWrite), updates) {
            case .failure: return nil
            case .success(let result): return result
        }
    }
    
    open func writeAsync<T>(
        fileName file: String = #file,
        functionName funcN: String = #function,
        lineNumber line: Int = #line,
        using dependencies: Dependencies = Dependencies(),
        updates: @escaping (Database) throws -> T,
        completion: @escaping (Result<T, Error>) -> Void = { _ in }
    ) {
        Storage.performOperation(CallInfo(self, file, funcN, line, .asyncWrite), updates, completion)
    }
    
    open func writePublisher<T>(
        fileName: String = #file,
        functionName: String = #function,
        lineNumber: Int = #line,
        using dependencies: Dependencies = Dependencies(),
        updates: @escaping (Database) throws -> T
    ) -> AnyPublisher<T, Error> {
        return performPublisherOperation(fileName, functionName, lineNumber, isWrite: true, updates)
    }
    
    @discardableResult public func read<T>(
        fileName file: String = #file,
        functionName funcN: String = #function,
        lineNumber line: Int = #line,
        using dependencies: Dependencies = Dependencies(),
        _ value: @escaping (Database) throws -> T?
    ) -> T? {
        switch Storage.performOperation(CallInfo(self, file, funcN, line, .syncRead), value) {
            case .failure: return nil
            case .success(let result): return result
        }
    }
    
    open func readPublisher<T>(
        fileName: String = #file,
        functionName: String = #function,
        lineNumber: Int = #line,
        using dependencies: Dependencies = Dependencies(),
        value: @escaping (Database) throws -> T
    ) -> AnyPublisher<T, Error> {
        return performPublisherOperation(fileName, functionName, lineNumber, isWrite: false, value)
    }
    
    /// Rever to the `ValueObservation.start` method for full documentation
    ///
    /// - parameter observation: The observation to start
    /// - parameter scheduler: A Scheduler. By default, fresh values are
    ///   dispatched asynchronously on the main queue.
    /// - parameter onError: A closure that is provided eventual errors that
    ///   happen during observation
    /// - parameter onChange: A closure that is provided fresh values
    /// - returns: a DatabaseCancellable
    public func start<Reducer: ValueReducer>(
        _ observation: ValueObservation<Reducer>,
        scheduling scheduler: ValueObservationScheduler = .async(onQueue: .main),
        onError: @escaping (Error) -> Void,
        onChange: @escaping (Reducer.Value) -> Void
    ) -> DatabaseCancellable {
        guard isValid, let dbWriter: DatabaseWriter = dbWriter else {
            onError(StorageError.databaseInvalid)
            return AnyDatabaseCancellable(cancel: {})
        }
        
        return observation.start(
            in: dbWriter,
            scheduling: scheduler,
            onError: onError,
            onChange: onChange
        )
    }
    
    public func addObserver(_ observer: TransactionObserver?) {
        guard isValid, let dbWriter: DatabaseWriter = dbWriter else { return }
        guard let observer: TransactionObserver = observer else { return }
        
        // Note: This actually triggers a write to the database so can be blocked by other
        // writes, since it's usually called on the main thread when creating a view controller
        // this can result in the UI hanging - to avoid this we dispatch (and hope there isn't
        // negative impact)
        DispatchQueue.global(qos: .default).async {
            dbWriter.add(transactionObserver: observer)
        }
    }
    
    public func removeObserver(_ observer: TransactionObserver?) {
        guard isValid, let dbWriter: DatabaseWriter = dbWriter else { return }
        guard let observer: TransactionObserver = observer else { return }
        
        // Note: This actually triggers a write to the database so can be blocked by other
        // writes, since it's usually called on the main thread when creating a view controller
        // this can result in the UI hanging - to avoid this we dispatch (and hope there isn't
        // negative impact)
        DispatchQueue.global(qos: .default).async {
            dbWriter.remove(transactionObserver: observer)
        }
    }
}

// MARK: - Combine Extensions

public extension ValueObservation {
    func publisher(
        in storage: Storage,
        scheduling scheduler: ValueObservationScheduler = Storage.defaultPublisherScheduler
    ) -> AnyPublisher<Reducer.Value, Error> where Reducer: ValueReducer {
        guard storage.isValid, let dbWriter: DatabaseWriter = storage.dbWriter else {
            return Fail(error: StorageError.databaseInvalid).eraseToAnyPublisher()
        }
        
        return self.publisher(in: dbWriter, scheduling: scheduler)
            .eraseToAnyPublisher()
    }
}

// MARK: - Debug Convenience

public extension Storage {
    static let encKeyFilename: String = "key.enc"
    
    func testAccess(
        databasePath: String,
        encryptedKeyPath: String,
        encryptedKeyPassword: String
    ) throws {
        /// First we need to ensure we can decrypt the encrypted key file
        do {
            var tmpKeySpec: Data = try decryptSecureExportedKey(
                path: encryptedKeyPath,
                password: encryptedKeyPassword
            )
            tmpKeySpec.resetBytes(in: 0..<tmpKeySpec.count)
        }
        catch { return }
        
        /// Then configure the database using the key
        var config = Configuration()

        /// Load in the SQLCipher keys
        config.prepareDatabase { [weak self] db in
            var keySpec: Data = try self?.decryptSecureExportedKey(
                path: encryptedKeyPath,
                password: encryptedKeyPassword
            ) ?? { throw StorageError.invalidKeySpec }()
            defer { keySpec.resetBytes(in: 0..<keySpec.count) } // Reset content immediately after use
            
            // Use a raw key spec, where the 96 hexadecimal digits are provided
            // (i.e. 64 hex for the 256 bit key, followed by 32 hex for the 128 bit salt)
            // using explicit BLOB syntax, e.g.:
            //
            // x'98483C6EB40B6C31A448C22A66DED3B5E5E8D5119CAC8327B655C8B5C483648101010101010101010101010101010101'
            keySpec = try (keySpec.toHexString().data(using: .utf8) ?? { throw StorageError.invalidKeySpec }())
            keySpec.insert(contentsOf: [120, 39], at: 0)    // "x'" prefix
            keySpec.append(39)                              // "'" suffix
            
            try db.usePassphrase(keySpec)
            
            // According to the SQLCipher docs iOS needs the 'cipher_plaintext_header_size' value set to at least
            // 32 as iOS extends special privileges to the database and needs this header to be in plaintext
            // to determine the file type
            //
            // For more info see: https://www.zetetic.net/sqlcipher/sqlcipher-api/#cipher_plaintext_header_size
            try db.execute(sql: "PRAGMA cipher_plaintext_header_size = 32")
        }
        
        // Create the DatabasePool to allow us to connect to the database and mark the storage as valid
        dbWriter = try DatabasePool(path: databasePath, configuration: config)
        isValid = true
    }
    
    func secureExportKey(password: String) throws -> String {
        var keySpec: Data = try getOrGenerateDatabaseKeySpec()
        defer { keySpec.resetBytes(in: 0..<keySpec.count) } // Reset content immediately after use
        
        guard var passwordData: Data = password.data(using: .utf8) else { throw StorageError.generic }
        defer { passwordData.resetBytes(in: 0..<passwordData.count) } // Reset content immediately after use
        
        /// Encrypt the `keySpec` value using a SHA256 of the password provided and a nonce then base64-encode the encrypted
        /// data and save it to a temporary file to share alongside the database
        ///
        /// Decrypt the key via the termincal on macOS by running the command in the project root directory
        /// `swift ./Scropts/DecryptExportedKey.swift {BASE64_CIPHERTEXT} {PASSWORD}`
        ///
        /// Where `BASE64_CIPHERTEXT` is the content of the `key.enc` file and `PASSWORD` is the password provided via the
        /// prompt during export
        let nonce: ChaChaPoly.Nonce = ChaChaPoly.Nonce()
        let hash: SHA256.Digest = SHA256.hash(data: passwordData)
        let key: SymmetricKey = SymmetricKey(data: Data(hash.makeIterator()))
        let sealedBox: ChaChaPoly.SealedBox = try ChaChaPoly.seal(keySpec, using: key, nonce: nonce, authenticating: Data())
        let keyInfoPath: String = (Singleton.hasAppContext ?
            "\(Singleton.appContext.temporaryDirectory)/\(Storage.encKeyFilename)" :
            "\(NSTemporaryDirectory())\(Storage.encKeyFilename)"
        )
        let encryptedKeyBase64: String = sealedBox.combined.base64EncodedString()
        try encryptedKeyBase64.write(toFile: keyInfoPath, atomically: true, encoding: .utf8)
        
        return keyInfoPath
    }
    
    func replaceDatabaseKey(path: String, password: String) throws {
        var keySpec: Data = try decryptSecureExportedKey(path: path, password: password)
        defer { keySpec.resetBytes(in: 0..<keySpec.count) } // Reset content immediately after use
        
        try Singleton.keychain.set(data: keySpec, forKey: .dbCipherKeySpec)
    }
    
    fileprivate func decryptSecureExportedKey(path: String, password: String) throws -> Data {
        let encKeyBase64: String = try String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8)
        
        guard
            var passwordData: Data = password.data(using: .utf8),
            var encKeyData: Data = Data(base64Encoded: encKeyBase64)
        else { throw StorageError.generic }
        defer {
            // Reset content immediately after use
            passwordData.resetBytes(in: 0..<passwordData.count)
            encKeyData.resetBytes(in: 0..<encKeyData.count)
        }
        
        let hash: SHA256.Digest = SHA256.hash(data: passwordData)
        let key: SymmetricKey = SymmetricKey(data: Data(hash.makeIterator()))
        
        let sealedBox: ChaChaPoly.SealedBox = try ChaChaPoly.SealedBox(combined: encKeyData)
        
        return try ChaChaPoly.open(sealedBox, using: key, authenticating: Data())
    }
}

// MARK: - CallInfo

private extension Storage {
    class CallInfo {
        enum Behaviour {
            case syncRead
            case asyncRead
            case syncWrite
            case asyncWrite
        }
        
        weak var storage: Storage?
        let file: String
        let function: String
        let line: Int
        let behaviour: Behaviour
        
        var callInfo: String {
            let fileInfo: String = (file.components(separatedBy: "/").last.map { "\($0):\(line) - " } ?? "")
            
            return "\(fileInfo)\(function)"
        }
        
        var isWrite: Bool {
            switch behaviour {
                case .syncWrite, .asyncWrite: return true
                case .syncRead, .asyncRead: return false
            }
        }
        var isAsync: Bool {
            switch behaviour {
                case .asyncRead, .asyncWrite: return true
                case .syncRead, .syncWrite: return false
            }
        }
        
        init(
            _ storage: Storage?,
            _ file: String,
            _ function: String,
            _ line: Int,
            _ behaviour: Behaviour
        ) {
            self.storage = storage
            self.file = file
            self.function = function
            self.line = line
            self.behaviour = behaviour
        }
    }
}

// MARK: - TransactionTimer

private extension Storage {
    private static let timerQueue = DispatchQueue(label: "\(Storage.queuePrefix)-.transactionTimer", qos: .background)
    
    class TransactionTimer {
        private let info: Storage.CallInfo
        private let start: CFTimeInterval = CACurrentMediaTime()
        private var timer: DispatchSourceTimer? = DispatchSource.makeTimerSource(queue: Storage.timerQueue)
        private var wasSlowTransaction: Bool = false
        
        private init(info: Storage.CallInfo) {
            self.info = info
        }

        static func start(duration: TimeInterval, info: Storage.CallInfo) -> TransactionTimer {
            let result: TransactionTimer = TransactionTimer(info: info)
            result.timer?.schedule(deadline: .now() + .seconds(Int(duration)), repeating: .infinity) // Infinity to fire once
            result.timer?.setEventHandler { [weak result] in
                result?.timer?.cancel()
                result?.timer = nil
                
                let action: String = (info.isWrite ? "write" : "read")
                Log.warn("[Storage] Slow \(action) taking longer than \(Storage.slowTransactionThreshold, format: ".2", omitZeroDecimal: true)s - [ \(info.callInfo) ]")
                result?.wasSlowTransaction = true
            }
            result.timer?.resume()
            
            return result
        }

        func stop() {
            timer?.cancel()
            timer = nil
            
            guard wasSlowTransaction else { return }
            
            let end: CFTimeInterval = CACurrentMediaTime()
            let action: String = (info.isWrite ? "write" : "read")
            Log.warn("[Storage] Slow \(action) completed after \(end - start, format: ".2", omitZeroDecimal: true)s - [ \(info.callInfo) ]")
        }
    }
}
