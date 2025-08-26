// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import UIKit
import CryptoKit
import Combine
import GRDB

#if DEBUG
import Darwin
#endif

// MARK: - Singleton

public extension Singleton {
    static let storage: SingletonConfig<Storage> = Dependencies.create(
        identifier: "storage",
        createInstance: { dependencies in Storage(using: dependencies) }
    )
    static let scheduler: SingletonConfig<ValueObservationScheduler> = Dependencies.create(
        identifier: "scheduler",
        createInstance: { _ in AsyncValueObservationScheduler.async(onQueue: .main) }
    )
}

// MARK: - Log.Category

public extension Log.Category {
    static let storage: Log.Category = .create("Storage", defaultLevel: .info)
}

// MARK: - KeychainStorage

public extension KeychainStorage.DataKey { static let dbCipherKeySpec: Self = "GRDBDatabaseCipherKeySpec" }

// MARK: - Storage

open class Storage {
    public static let base32: String = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"
    public static let queuePrefix: String = "SessionDatabase"
    public static let dbFileName: String = "Session.sqlite"
    private static let SQLCipherKeySpecLength: Int = 48
    
    /// If a transaction takes longer than this duration a warning will be logged but the transaction will continue to run
    private static let slowTransactionThreshold: TimeInterval = 3
    
    /// When attempting to do a write the transaction will wait this long to acquite a lock before failing
    private static let writeTransactionStartTimeout: TimeInterval = 5
    
    /// If a transaction takes longer than this duration then we should fail the transaction rather than keep hanging
    ///
    /// **Note:** This timeout only applies to synchronous operations (the assumption being that if we know an operation is going to
    /// take a long time then we should probably be handling it asynchronously rather than a synchronous way)
    private static let transactionDeadlockTimeoutSeconds: Int = 5
    
    public static var sharedDatabaseDirectoryPath: String { "\(SessionFileManager.nonInjectedAppSharedDataDirectoryPath)/database" }
    private static var databasePath: String { "\(Storage.sharedDatabaseDirectoryPath)/\(Storage.dbFileName)" }
    private static var databasePathShm: String { "\(Storage.sharedDatabaseDirectoryPath)/\(Storage.dbFileName)-shm" }
    private static var databasePathWal: String { "\(Storage.sharedDatabaseDirectoryPath)/\(Storage.dbFileName)-wal" }
    
    private let id: String = (0..<5).map { _ in "\(base32.randomElement() ?? "0")" }.joined()
    private let dependencies: Dependencies
    fileprivate var dbWriter: DatabaseWriter?
    internal var testDbWriter: DatabaseWriter? { dbWriter }
    
    // MARK: - Database State Variables
    
    private var startupError: Error?
    public private(set) var isValid: Bool = false
    public private(set) var isSuspended: Bool = false
    public var isDatabasePasswordAccessible: Bool { ((try? getDatabaseCipherKeySpec()) != nil) }
    public private(set) var hasCompletedMigrations: Bool = false
    
    /// This property gets set the first time we successfully read from the database
    public private(set) var hasSuccessfullyRead: Bool = false
    
    /// This property gets set the first time we successfully write to the database
    public private(set) var hasSuccessfullyWritten: Bool = false
    
    /// This property keeps track of all current database calls and can be used when suspending the database to explicitly
    /// cancel any currently running tasks
    @ThreadSafeObject private var currentCalls: Set<CallInfo> = []
    
    /// This property keeps track of all current database observers for logging purposes
    @ThreadSafeObject private var currentObservers: Set<ObserverInfo> = []
    
    // MARK: - Initialization
    
    public init(customWriter: DatabaseWriter? = nil, using dependencies: Dependencies) {
        self.dependencies = dependencies
        
        configureDatabase(customWriter: customWriter)
    }
    
    public init(
        testAccessTo databasePath: String,
        encryptedKeyPath: String,
        encryptedKeyPassword: String,
        using dependencies: Dependencies
    ) throws {
        self.dependencies = dependencies
        
        try testAccess(
            databasePath: databasePath,
            encryptedKeyPath: encryptedKeyPath,
            encryptedKeyPassword: encryptedKeyPassword
        )
    }
    
    public func configureDatabase(customWriter: DatabaseWriter? = nil) {
        /// If we have verbose logging enabled then retrieve and output the size of the database files
        if dependencies[feature: .logLevel(cat: .storage)] == .verbose {
            let dbFileSize: String = (try? dependencies[singleton: .fileManager]
                .attributesOfItem(atPath: Storage.databasePath)
                .getting(.size) as? Int64)
                .map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
                .defaulting(to: "N/A")
            let dbShmFileSize: String = (try? dependencies[singleton: .fileManager]
                .attributesOfItem(atPath: Storage.databasePathShm)
                .getting(.size) as? Int64)
                .map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
                .defaulting(to: "N/A")
            let dbWalFileSize: String = (try? dependencies[singleton: .fileManager]
                .attributesOfItem(atPath: Storage.databasePathWal)
                .getting(.size) as? Int64)
                .map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
                .defaulting(to: "N/A")
            Log.verbose(.storage, "Configuring new database instance: \(id) (db: \(dbFileSize), shm: \(dbShmFileSize), wal: \(dbWalFileSize)).")
        }
        
        /// Create the database directory if needed and ensure it's protection level is set before attempting to create the database
        /// KeySpec or the database itself
        try? dependencies[singleton: .fileManager].ensureDirectoryExists(at: Storage.sharedDatabaseDirectoryPath)
        try? dependencies[singleton: .fileManager].protectFileOrFolder(at: Storage.sharedDatabaseDirectoryPath)
        
        // If a custom writer was provided then use that (for unit testing)
        guard customWriter == nil else {
            dbWriter = customWriter
            isValid = true
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
            var tmpKeySpec: Data = try dependencies[singleton: .keychain].getOrGenerateEncryptionKey(
                forKey: .dbCipherKeySpec,
                length: Storage.SQLCipherKeySpecLength,
                cat: .storage,
                legacyKey: "GRDBDatabaseCipherKeySpec",
                legacyService: "TSKeyChainService"
            )
            tmpKeySpec.resetBytes(in: 0..<tmpKeySpec.count)
        }
        catch { return }
        
        // Configure the database and create the DatabasePool for interacting with the database
        var config = Configuration()
        config.label = Storage.queuePrefix
        config.maximumReaderCount = 10                   /// Increase the max read connection limit - Default is 5
        config.busyMode = .timeout(Storage.writeTransactionStartTimeout)

        /// Load in the SQLCipher keys
        config.prepareDatabase { [weak self] db in
            var keySpec: Data = try self?.dependencies[singleton: .keychain].getOrGenerateEncryptionKey(
                forKey: .dbCipherKeySpec,
                length: Storage.SQLCipherKeySpecLength,
                cat: .storage,
                legacyKey: "GRDBDatabaseCipherKeySpec",
                legacyService: "TSKeyChainService"
            ) ?? { throw KeychainStorageError.keySpecInvalid }()
            defer { keySpec.resetBytes(in: 0..<keySpec.count) } // Reset content immediately after use
            
            // Use a raw key spec, where the 96 hexadecimal digits are provided
            // (i.e. 64 hex for the 256 bit key, followed by 32 hex for the 128 bit salt)
            // using explicit BLOB syntax, e.g.:
            //
            // x'98483C6EB40B6C31A448C22A66DED3B5E5E8D5119CAC8327B655C8B5C483648101010101010101010101010101010101'
            keySpec = try (keySpec.toHexString().data(using: .utf8) ?? {
                throw KeychainStorageError.keySpecInvalid
            }())
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
            do {
                dbWriter = try DatabasePool(
                    path: "\(Storage.sharedDatabaseDirectoryPath)/\(Storage.dbFileName)",
                    configuration: config
                )
            }
            catch DatabaseError.SQLITE_BUSY {
                /// According to the docs in GRDB there are a few edge-cases where opening the database
                /// can fail due to it reporting a "busy" state, by changing the behaviour from `immediateError`
                /// to `timeout(1)` we give the database a 1 second grace period to deal with it's issues
                /// and get back into a valid state - adding this helps the database resolve situations where it
                /// can get confused due to crashing mid-transaction
                config.busyMode = .timeout(1)
                Log.warn(.storage, "Database reported busy state during startup, adding grace period to allow startup to continue")
                
                // Try to initialise the dbWriter again (hoping the above resolves the lock)
                dbWriter = try DatabasePool(
                    path: "\(Storage.sharedDatabaseDirectoryPath)/\(Storage.dbFileName)",
                    configuration: config
                )
            }
            catch let error as DatabaseError where error.resultCode == .SQLITE_CANTOPEN {
                /// We were seeing some cases where the PN extension could get an error where it coudln't open the
                /// database but based on the logs all previous queires and everything had completed, so if this happens
                /// we want to wait for a brief period and try again in case it was due to something weird the OS was
                /// doing with the files
                Log.warn(.storage, "Database reported that it couldn't open during startup (\(error.extendedResultCode)), retrying after a short delay")
                Thread.sleep(forTimeInterval: 1)
                
                // Try to initialise the dbWriter again (hoping the above resolves the lock)
                dbWriter = try DatabasePool(
                    path: "\(Storage.sharedDatabaseDirectoryPath)/\(Storage.dbFileName)",
                    configuration: config
                )
            }
            catch let error as DatabaseError where error.resultCode == .SQLITE_IOERR {
                Log.error(.storage, "Database reported that it couldn't open during startup (\(error.extendedResultCode))")
                throw error
            }
            isValid = true
        }
        catch { startupError = error }
    }
    
    // MARK: - Migrations
    
    public static func appliedMigrationIdentifiers(_ db: ObservingDatabase) -> Set<String> {
        let migrator: DatabaseMigrator = DatabaseMigrator()
        
        return (try? migrator.appliedIdentifiers(db.originalDb))
            .defaulting(to: [])
    }
    
    public func perform(
        migrations: [Migration.Type],
        onProgressUpdate: ((CGFloat, TimeInterval) -> ())?
    ) async throws {
        guard isValid, let dbWriter: DatabaseWriter = dbWriter else {
            let error: Error = (startupError ?? StorageError.startupFailed)
            Log.error(.storage, "Startup failed with error: \(error)")
            throw error
        }
        
        // Setup and run any required migrations
        var migrator: DatabaseMigrator = DatabaseMigrator()
        migrations.forEach { migration in
            migrator.registerMigration(migration.identifier) { [dependencies] db in
                let migration = migration.loggedMigrate(using: dependencies)
                try migration(ObservingDatabase.create(db, using: dependencies))
            }
        }
        
        // Determine which migrations need to be performed and gather the relevant settings needed to
        // inform the app of progress/states
        let completedMigrations: [String] = (try? await dbWriter.read { [migrator] db in try migrator.completedMigrations(db) })
            .defaulting(to: [])
        let unperformedMigrations: [Migration.Type] = migrations
            .reduce(into: []) { result, next in
                guard !completedMigrations.contains(next.identifier) else { return }
                
                result.append(next)
            }
        let migrationToDurationMap: [String: TimeInterval] = unperformedMigrations
            .reduce(into: [:]) { result, next in
                result[next.identifier] = next.minExpectedRunDuration
            }
        let unperformedMigrationDurations: [TimeInterval] = unperformedMigrations.map { $0.minExpectedRunDuration }
        let totalMinExpectedDuration: TimeInterval = migrationToDurationMap.values.reduce(0, +)
        
        // Store the logic to handle migration progress and completion
        let progressUpdater: (String, CGFloat) -> Void = { (targetKey: String, progress: CGFloat) in
            guard let migrationIndex: Int = unperformedMigrations.firstIndex(where: { $0.identifier == targetKey }) else {
                return
            }
            
            let completedExpectedDuration: TimeInterval = (
                (migrationIndex > 0 ? unperformedMigrationDurations[0..<migrationIndex].reduce(0, +) : 0) +
                (unperformedMigrationDurations[migrationIndex] * progress)
            )
            let totalProgress: CGFloat = (completedExpectedDuration / totalMinExpectedDuration)
            
            Task { @MainActor in
                onProgressUpdate?(totalProgress, totalMinExpectedDuration)
            }
        }
        
        // if there aren't any migrations to run then just complete immediately (this way the migrator
        // doesn't try to execute on the DBWrite thread so returning from the background can't get blocked
        // due to some weird endless process running)
        guard !unperformedMigrations.isEmpty else { return }
        
        // Create the `MigrationContext` 
        let migrationContext: MigrationExecution.Context = MigrationExecution.Context(progressUpdater: progressUpdater)
        
        // If we have an unperformed migration then trigger the progress updater immediately
        if let firstMigrationIdentifier: String = unperformedMigrations.first?.identifier {
            migrationContext.progressUpdater(firstMigrationIdentifier, 0)
        }
        
        return try await withCheckedThrowingContinuation { [weak self, migrator, dependencies] continuation in
            MigrationExecution.$current.withValue(migrationContext) { [weak self, migrator, dependencies] in
                migrator.asyncMigrate(dbWriter) { [weak self, migrator, dependencies] result in
                    let finalResult: Result<Void, Error> = {
                        switch result {
                            case .failure(let error): return .failure(error)
                            case .success: return .success(())
                        }
                    }()
                    
                    // Make sure to transition the progress updater to 100% for the final migration (just
                    // in case the migration itself didn't update to 100% itself)
                    if let lastMigrationIdentifier: String = unperformedMigrations.last?.identifier {
                        MigrationExecution.current?.progressUpdater(lastMigrationIdentifier, 1)
                    }
                    
                    self?.hasCompletedMigrations = true
                    
                    // Output any events tracked during the migration and trigger any `postCommitActions` which
                    // should occur
                    if let events: [ObservedEvent] = MigrationExecution.current?.observedEvents {
                        dependencies.notifyAsync(events: events)
                    }
                    
                    if let actions: [String: () -> Void] = MigrationExecution.current?.postCommitActions {
                        actions.values.forEach { $0() }
                    }
                    
                    /// Don't log anything in the case of a `success` or if the database is suspended (the latter will happen if the
                    /// user happens to return to the background too quickly on launch so is unnecessarily alarming, it also gets
                    /// caught and logged separately by the `write` functions anyway)
                    switch result {
                        case .success: break
                        case .failure(DatabaseError.SQLITE_ABORT): break
                        case .failure(let error):
                            Task { [migrator] in
                                let completedMigrations: [String] = (try? await dbWriter
                                    .read { [migrator] db in try migrator.completedMigrations(db) })
                                    .defaulting(to: [])
                                let failedMigrationName: String = migrator.migrations
                                    .filter { !completedMigrations.contains($0) }
                                    .first
                                    .defaulting(to: "Unknown")
                                Log.critical(.migration, "Migration '\(failedMigrationName)' failed with error: \(error)")
                            }
                    }
                    
                    /// Resume the continuation
                    switch result {
                        case .failure(let error): continuation.resume(throwing: error)
                        case .success: continuation.resume()
                    }
                }
            }
        }
    }
    
    // MARK: - Security
    
    private func getDatabaseCipherKeySpec() throws -> Data {
        try dependencies[singleton: .keychain].migrateLegacyKeyIfNeeded(
            legacyKey: "GRDBDatabaseCipherKeySpec",
            legacyService: "TSKeyChainService",
            toKey: .dbCipherKeySpec
        )
        return try dependencies[singleton: .keychain].data(forKey: .dbCipherKeySpec)
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
        Log.info(
            .storage,
            [
                "Database access suspended - ",
                "cancelling \(currentCalls.count) running task(s)\(currentCalls.isEmpty ? "" : " (\(currentCalls.map(\.id).joined(separator: ", ")))"), ",
                "\(currentObservers.count) active observers(s)\(currentObservers.isEmpty ? "" : " (\(currentObservers.map(\.id).joined(separator: ", ")))"), checkpointing and closing connection."
            ].joined()
        )
        
        /// Instruct GRDB to release as much memory as it can (non-blocking)
        (dbWriter as? DatabasePool)?.releaseMemoryEventually()
        
        /// Before triggering an `interrupt` (which will forcibly kill in-progress database queries) we want to try to cancel all
        /// database tasks to give them a small chance to resolve cleanly before we take a brute-force approach
        currentCalls.forEach { $0.cancel() }
        _currentCalls.performUpdate { _ in [] }
        
        /// We want to force a checkpoint (ie. write any data in the WAL to disk, to ensure the main database is in a valid state)
        do { try checkpoint(.truncate) }
        catch { Log.info(.storage, "Failed to checkpoint database due to error: \(error)") }
        
        /// Interrupt any open transactions (if this function is called then we are expecting that all processes have finished running
        /// and don't actually want any more transactions to occur)
        dbWriter?.interrupt()
        
        /// If we have verbose logging enabled then retrieve and output the size of the database files
        if dependencies[feature: .logLevel(cat: .storage)] == .verbose {
            let dbFileSize: String = (try? dependencies[singleton: .fileManager]
                .attributesOfItem(atPath: Storage.databasePath)
                .getting(.size) as? Int64)
                .map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
                .defaulting(to: "N/A")
            let dbShmFileSize: String = (try? dependencies[singleton: .fileManager]
                .attributesOfItem(atPath: Storage.databasePathShm)
                .getting(.size) as? Int64)
                .map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
                .defaulting(to: "N/A")
            let dbWalFileSize: String = (try? dependencies[singleton: .fileManager]
                .attributesOfItem(atPath: Storage.databasePathWal)
                .getting(.size) as? Int64)
                .map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
                .defaulting(to: "N/A")
            Log.verbose(.storage, "Database suspended successfully for \(id) (db: \(dbFileSize), shm: \(dbShmFileSize), wal: \(dbWalFileSize)).")
        }
    }
    
    /// This method reverses the database suspension used to prevent the `0xdead10cc` exception (see `suspendDatabaseAccess()`
    /// above for more information
    public func resumeDatabaseAccess() {
        guard isSuspended else { return }
        
        isSuspended = false
        Log.info(.storage, "Database access resumed.")
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
        hasCompletedMigrations = false
        dbWriter = nil
        
        deleteDatabaseFiles()
        do { try deleteDbKeys() } catch { Log.warn(.storage, "Failed to delete database keys.") }
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
        do { try dependencies[singleton: .fileManager].removeItem(atPath: Storage.databasePath) }
        catch { Log.warn(.storage, "Failed to delete database.") }
        do { try dependencies[singleton: .fileManager].removeItem(atPath: Storage.databasePathShm) }
        catch { Log.warn(.storage, "Failed to delete database-shm.") }
        do { try dependencies[singleton: .fileManager].removeItem(atPath: Storage.databasePathWal) }
        catch { Log.warn(.storage, "Failed to delete database-wal.") }
    }
    
    private func deleteDbKeys() throws {
        try dependencies[singleton: .keychain].remove(key: .dbCipherKeySpec)
    }
    
    // MARK: - Logging Functions
    
    enum StorageState {
        case valid(DatabaseWriter)
        case invalid(Error)
        
        var forcedError: Error {
            switch self {
                case .valid: return StorageError.validStorageIncorrectlyHandledAsError
                case .invalid(let error): return error
            }
        }
        
        init(_ storage: Storage?) {
            switch (storage?.isSuspended, storage?.isValid, storage?.dbWriter) {
                case (true, _, _): self = .invalid(StorageError.databaseSuspended)
                case (false, true, .some(let dbWriter)): self = .valid(dbWriter)
                default: self = .invalid(StorageError.databaseInvalid)
            }
        }
    }
    
    // MARK: - Operations
    
    /// Internal type to wrap the result for the `performOperation` so that its assignment is Sendable
    private final class ResultContainer<T> {
        var value: Result<T, Error>?
        
        init(value: Result<T, Error>? = nil) {
            self.value = value
        }
    }
    
    /// This function manually performs `read`/`write` operations via Swift Concurrency and should only be called via the appropriate
    /// `perform{x}Operation`functions to reduce duplication
    private static func performOperation<T>(
        _ info: CallInfo,
        _ dbWriter: DatabaseWriter,
        _ operation: @escaping (ObservingDatabase) throws -> T,
        _ dependencies: Dependencies
    ) async -> Result<T, Error> {
        typealias DatabaseOutput = (
            result: T,
            events: [ObservedEvent],
            postCommitActions: [() -> Void]
        )
        typealias DatabaseResult = (result: T, postCommitActions: [() -> Void])
        
        return await withThrowingTaskGroup(of: DatabaseResult.self) { group in
            /// Add the task to perform the actual database operation
            group.addTask {
                let trackedOperation: @Sendable (Database) throws -> DatabaseOutput = { db in
                    info.start()
                    guard info.storage?.isValid == true else { throw StorageError.databaseInvalid }
                    guard info.storage?.isSuspended == false else {
                        throw StorageError.databaseSuspended
                    }
                    
                    /// Create the `ObservingDatabase` and store it in the `ObservationContext` so objects can access
                    /// it while the operation is running (this allows us to use things like `aroundInsert` without having to resort
                    /// to hacks to give it access to the `ObservingDatabase` or `Dependencies` instances
                    let observingDatabase: ObservingDatabase = ObservingDatabase.create(db, using: dependencies)
                    let result: T = try ObservationContext.$observingDb.withValue(observingDatabase) {
                        try operation(observingDatabase)
                    }
                    
                    /// Update the state flags
                    switch info.isWrite {
                        case true: info.storage?.hasSuccessfullyWritten = true
                        case false: info.storage?.hasSuccessfullyRead = true
                    }
                    
                    return (
                        result,
                        observingDatabase.events,
                        Array(observingDatabase.postCommitActions.values)
                    )
                }
                
                /// Do this outside of the actually db operation as it's more for debugging queries running on the main thread
                /// than trying to slow the query itself
                if !SNUtilitiesKit.isRunningTests && dependencies[feature: .forceSlowDatabaseQueries] {
                    try await Task.sleep(for: .seconds(1))
                }
                
                let output: DatabaseOutput = (info.isWrite ?
                    try await dbWriter.write(trackedOperation) :
                    try await dbWriter.read(trackedOperation)
                )
                
                /// Trigger the observations
                dependencies.notifyAsync(events: output.events)
                
                return (output.result, output.postCommitActions)
            }
            
            /// If this is a syncronous task then we want to the operation to timeout to ensure we don't unintentionally
            /// create a deadlock
            if !info.isAsync {
                group.addTask {
                    /// If the debugger is attached then we want to have a lot of shorter sleep iterations as the clock doesn't get
                    /// paused when stopped on a breakpoint (and we don't want to end up having a bunch of false positive
                    /// database timeouts while debugging code)
                    ///
                    /// **Note:** `isDebuggerAttached` will always return `false` in production builds
                    if isDebuggerAttached() {
                        let numIterations: UInt64 = 50
                        
                        for _ in (0..<numIterations) {
                            try await Task.sleep(for: .seconds(Storage.transactionDeadlockTimeoutSeconds))
                        }
                    }
                    else if info.isWrite {
                        /// This if statement is redundant **but** it means when we get symbolicated crash logs we can distinguish
                        /// between the database threads which are reading and writing
                        try await Task.sleep(for: .seconds(Storage.transactionDeadlockTimeoutSeconds))
                    }
                    else {
                        try await Task.sleep(for: .seconds(Storage.transactionDeadlockTimeoutSeconds))
                    }
                    throw StorageError.transactionDeadlockTimeout
                }
            }
            
            /// Wait for the first task to finish
            ///
            /// **Note:** The case where `nextResult` returns `nil` is only meant to happen when the group has no
            /// tasks, so shouldn't be considered a valid case (hence the `invalidQueryResult` fallback)
            let output: Result<DatabaseResult, Error> = await (
                group.nextResult() ??
                .failure(StorageError.invalidQueryResult)
            )
            group.cancelAll()
            
            /// If the database operation completed successfully we should trigger any of the `postCommitActions`
            switch output {
                case .failure: break
                case .success(let result): result.postCommitActions.forEach { $0() }
            }
            
            /// Return the actual result
            return output.map { $0.result }
        }
    }
    
    /// This function manually performs `read`/`write` operations in either a synchronous or asyncronous way using a semaphore to
    /// block the syncrhonous version because `GRDB` has an internal assertion when using it's built-in synchronous `read`/`write`
    /// functions to prevent reentrancy which is unsupported
    ///
    /// The `async` variants don't need to worry about this reentrancy issue so instead we route we use those for all operations instead
    /// and just block the thread when we want to perform a synchronous operation
    ///
    /// **Note:** When running a synchronous operation the result will be returned and `asyncCompletion` will not be called, and
    /// vice-versa for an asynchronous operation
    @discardableResult private func performOperation<T>(
        _ info: CallInfo,
        _ dependencies: Dependencies,
        _ operation: @escaping (ObservingDatabase) throws -> T,
        _ asyncCompletion: ((Result<T, Error>) -> Void)? = nil
    ) -> Result<T, Error> {
        /// Ensure we are in a valid state
        let storageState: StorageState = StorageState(info.storage)
        
        guard case .valid(let dbWriter) = storageState else {
            info.errored(storageState.forcedError)
            return .failure(storageState.forcedError)
        }
        
        /// Setup required variables
        let semaphore: DispatchSemaphore? = (info.isAsync ? nil : DispatchSemaphore(value: 0))
        let syncResultContainer: ResultContainer<T>? = (info.isAsync ? nil : ResultContainer())
        
        /// Log that we are scheduling the operation (so we have a log in case it's blocked for some reason)
        info.schedule()
        
        /// Kick off and store the task in case we want to cancel it later
        info.task = Task {
            info.storage?.addCall(info)
            defer { info.storage?.removeCall(info) }
            
            let result = await Storage.performOperation(info, dbWriter, operation, dependencies)
                
            /// Log the result
            switch result {
                case .success: info.complete()
                case .failure(let error): info.errored(error)
            }
            
            /// Now that we have completed the database operation we don't need to track the task anymore so we can
            /// remove it
            ///
            /// **Note:** we want to remove it before `asyncCompletion` is called just in case that is a long running
            /// process
            info.storage?.removeCall(info)
            
            /// Send the result back
            switch info.isAsync {
                case true: asyncCompletion?(result)
                case false:
                    syncResultContainer?.value = result
                    semaphore?.signal()
            }
        }
        
        /// For the `async` operation the returned value should be ignored so just return the `invalidQueryResult` error
        if info.behaviour == .asyncRead || info.behaviour == .asyncWrite{
            return .failure(StorageError.invalidQueryResult)
        }
        
        /// Block until we have a result
        semaphore?.wait()
        return (syncResultContainer?.value ?? .failure(StorageError.transactionDeadlockTimeout))
    }
    
    private func performPublisherOperation<T>(
        _ fileName: String,
        _ functionName: String,
        _ lineNumber: Int,
        isWrite: Bool,
        _ operation: @escaping (ObservingDatabase) throws -> T
    ) -> AnyPublisher<T, Error> {
        let info: CallInfo = CallInfo(self, fileName, functionName, lineNumber, (isWrite ? .asyncWrite : .asyncRead))
        
        switch StorageState(self) {
            case .invalid(let error): return info.errored(error)
            case .valid:
                /// Log that we are scheduling the operation (so we have a log in case it's blocked for some reason)
                info.schedule()
                
                /// **Note:** GRDB does have `readPublisher`/`writePublisher` functions but they appear to asynchronously
                /// trigger both the `output` and `complete` closures at the same time which causes a lot of unexpected
                /// behaviours (this behaviour is apparently expected but still causes a number of odd behaviours in our code
                /// for more information see https://github.com/groue/GRDB.swift/issues/1334)
                ///
                /// Instead of this we are just using `Deferred { PassthroughSubject }` which is executed on the specified
                /// scheduler (which behaves in a much more expected way than the GRDB `readPublisher`/`writePublisher`
                /// does) and hooking that into our `performOperation` function which uses the GRDB async/await functions that
                /// support cancellation (as we want to support cancellation as well)
                return Deferred { [dependencies] in
                    let subject = PassthroughSubject<T, Error>()
                    let bridge: PublisherBridge<T> = PublisherBridge(subject: subject)
                    
                    /// Kick off and store the task in case we want to cancel it later
                    info.task = Task {
                        info.storage?.addCall(info)
                        defer { info.storage?.removeCall(info) }
                        
                        /// Ensure we are in a valid state
                        let storageState: StorageState = StorageState(info.storage)
                
                        guard case .valid(let dbWriter) = storageState else {
                            await bridge.send(result: .failure(storageState.forcedError), info: info)
                            return
                        }
                        
                        let result = await Storage.performOperation(info, dbWriter, operation, dependencies)
                        
                        if Task.isCancelled {
                            return
                        }
                        
                        await bridge.send(result: result, info: info)
                    }
                    
                    return subject.handleEvents(receiveCancel: { [weak self, weak info] in
                        info?.cancel()
                        self?.removeCall(info)
                        Task { await bridge.cancel() }
                    })
                }
                .eraseToAnyPublisher()
        }
    }
    
    private func performSwiftConcurrencyOperation<T>(
        _ fileName: String,
        _ functionName: String,
        _ lineNumber: Int,
        isWrite: Bool,
        _ operation: @escaping (ObservingDatabase) throws -> T
    ) async throws -> T {
        let info: CallInfo = CallInfo(self, fileName, functionName, lineNumber, (isWrite ? .swiftConcurrencyWrite : .swiftConcurrencyRead))
        let storageState: StorageState = StorageState(self)
        
        guard case .valid(let dbWriter) = storageState else {
            info.errored(storageState.forcedError)
            throw storageState.forcedError
        }
        
        info.schedule()
        addCall(info)
        defer { removeCall(info) }
        
        return try await Storage.performOperation(info, dbWriter, operation, dependencies).get()
    }
    
    private func addCall(_ call: CallInfo) {
        _currentCalls.performUpdate { $0.inserting(call) }
    }
    
    private func removeCall(_ call: CallInfo?) {
        guard let call: CallInfo = call else { return }
        
        _currentCalls.performUpdate { $0.removing(call) }
    }
    
    private func addObserver(_ observer: ObserverInfo) {
        _currentObservers.performUpdate { $0.inserting(observer) }
    }
    
    private func removeObserver(_ observer: ObserverInfo) {
        _currentObservers.performUpdate { $0.removing(observer) }
    }
    
    private func stopAndRemoveObserver(forId id: String, explicitRemoval: Bool) {
        _currentObservers.performUpdate {
            $0.filter { info -> Bool in
                guard info.id == id else { return true }
                
                info.stop(explicitRemoval: explicitRemoval)
                return false
            }
        }
    }
    
    // MARK: - Functions
    
    @discardableResult public func write<T>(
        fileName file: String = #fileID,
        functionName funcN: String = #function,
        lineNumber line: Int = #line,
        updates: @escaping (ObservingDatabase) throws -> T?
    ) -> T? {
        switch performOperation(CallInfo(self, file, funcN, line, .syncWrite), dependencies, updates) {
            case .failure: return nil
            case .success(let result): return result
        }
    }
    
    open func writeAsync<T>(
        fileName file: String = #fileID,
        functionName funcN: String = #function,
        lineNumber line: Int = #line,
        updates: @escaping (ObservingDatabase) throws -> T,
        completion: @escaping (Result<T, Error>) -> Void = { _ in }
    ) {
        performOperation(CallInfo(self, file, funcN, line, .asyncWrite), dependencies, updates, completion)
    }
    
    @discardableResult public func writeAsync<T>(
        fileName file: String = #fileID,
        functionName funcN: String = #function,
        lineNumber line: Int = #line,
        updates: @escaping (ObservingDatabase) throws -> T
    ) async throws -> T {
        return try await performSwiftConcurrencyOperation(file, funcN, line, isWrite: true, updates)
    }
    
    open func writePublisher<T>(
        fileName: String = #fileID,
        functionName: String = #function,
        lineNumber: Int = #line,
        updates: @escaping (ObservingDatabase) throws -> T
    ) -> AnyPublisher<T, Error> {
        return performPublisherOperation(fileName, functionName, lineNumber, isWrite: true, updates)
    }
    
    @discardableResult public func read<T>(
        fileName file: String = #fileID,
        functionName funcN: String = #function,
        lineNumber line: Int = #line,
        _ value: @escaping (ObservingDatabase) throws -> T?
    ) -> T? {
        switch performOperation(CallInfo(self, file, funcN, line, .syncRead), dependencies, value) {
            case .failure: return nil
            case .success(let result): return result
        }
    }
    
    public func readAsync<T>(
        fileName file: String = #fileID,
        functionName funcN: String = #function,
        lineNumber line: Int = #line,
        retrieve: @escaping (ObservingDatabase) throws -> T,
        completion: @escaping (Result<T, Error>) -> Void
    ) {
        performOperation(CallInfo(self, file, funcN, line, .asyncRead), dependencies, retrieve, completion)
    }
    
    @discardableResult public func readAsync<T>(
        fileName file: String = #fileID,
        functionName funcN: String = #function,
        lineNumber line: Int = #line,
        value: @escaping (ObservingDatabase) throws -> T
    ) async throws -> T {
        return try await performSwiftConcurrencyOperation(file, funcN, line, isWrite: false, value)
    }
    
    open func readPublisher<T>(
        fileName: String = #fileID,
        functionName: String = #function,
        lineNumber: Int = #line,
        value: @escaping (ObservingDatabase) throws -> T
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
        fileName: String = #fileID,
        functionName: String = #function,
        lineNumber: Int = #line,
        scheduling scheduler: ValueObservationScheduler = .async(onQueue: .main),
        onError: @escaping (Error) -> Void,
        onChange: @escaping (Reducer.Value) -> Void
    ) -> DatabaseCancellable {
        guard isValid, let dbWriter: DatabaseWriter = dbWriter else {
            onError(StorageError.databaseInvalid)
            return AnyDatabaseCancellable(cancel: {})
        }
        
        let info: ObserverInfo = ObserverInfo(self, fileName, functionName, lineNumber)
        addObserver(info)
        
        let cancellable: AnyDatabaseCancellable = observation
            .handleEvents(didCancel: { [weak self] in
                info.stop(explicitRemoval: false)
                self?.removeObserver(info)
            })
            .start(
                in: dbWriter,
                scheduling: scheduler,
                onError: onError,
                onChange: onChange
            )
        info.setObservation(cancellable)
        
        return cancellable
    }
    
    /// Add a database observation
    ///
    /// **Note:** This function **MUST NOT** be called from the main thread
    public func addObserver(
        fileName: String = #fileID,
        functionName: String = #function,
        lineNumber: Int = #line,
        _ observer: IdentifiableTransactionObserver?
    ) {
        guard isValid, let dbWriter: DatabaseWriter = dbWriter else { return }
        guard let observer: IdentifiableTransactionObserver = observer else { return }
        
        let info: ObserverInfo = ObserverInfo(self, observer: observer, fileName, functionName, lineNumber)
        addObserver(info)
        
        /// This actually triggers a write to the database so can be blocked by other writes so shouldn't be called on the main thread,
        /// we don't dispatch to an async thread in here because `TransactionObserver` isn't `Sendable` so instead just require
        /// that it isn't called on the main thread
        Log.assertNotOnMainThread()
        dbWriter.add(transactionObserver: observer)
    }
    
    /// Remove a database observation
    ///
    /// **Note:** This function **MUST NOT** be called from the main thread
    public func removeObserver(
        fileName: String = #fileID,
        functionName: String = #function,
        lineNumber: Int = #line,
        _ observer: IdentifiableTransactionObserver?
    ) {
        guard isValid, let dbWriter: DatabaseWriter = dbWriter else { return }
        guard let observer: IdentifiableTransactionObserver = observer else { return }
        
        stopAndRemoveObserver(forId: observer.id, explicitRemoval: true)
        
        /// This actually triggers a write to the database so can be blocked by other writes so shouldn't be called on the main thread,
        /// we don't dispatch to an async thread in here because `TransactionObserver` isn't `Sendable` so instead just require
        /// that it isn't called on the main thread
        Log.assertNotOnMainThread()
        dbWriter.remove(transactionObserver: observer)
    }
}

// MARK: - Combine Extensions

public extension ValueObservation {
    func publisher(
        in storage: Storage,
        scheduling scheduler: ValueObservationScheduler
    ) -> AnyPublisher<Reducer.Value, Error> where Reducer: ValueReducer {
        guard storage.isValid, let dbWriter: DatabaseWriter = storage.dbWriter else {
            return Fail(error: StorageError.databaseInvalid).eraseToAnyPublisher()
        }
        
        return self.publisher(in: dbWriter, scheduling: scheduler)
            .eraseToAnyPublisher()
    }
}

public extension Publisher where Failure == Error {
    func flatMapStorageWritePublisher<T>(using dependencies: Dependencies, updates: @escaping (ObservingDatabase, Output) throws -> T) -> AnyPublisher<T, Error> {
        return self.flatMap { output -> AnyPublisher<T, Error> in
            dependencies[singleton: .storage].writePublisher(updates: { db in try updates(db, output) })
        }.eraseToAnyPublisher()
    }
    
    func flatMapStorageReadPublisher<T>(using dependencies: Dependencies, value: @escaping (ObservingDatabase, Output) throws -> T) -> AnyPublisher<T, Error> {
        return self.flatMap { output -> AnyPublisher<T, Error> in
            dependencies[singleton: .storage].readPublisher(value: { db in try value(db, output) })
        }.eraseToAnyPublisher()
    }
}

// MARK: - CallInfo

private extension Storage {
    private static let timerQueue = DispatchQueue(
        label: "\(Storage.queuePrefix)-.transactionTimer",
        qos: .background
    )
    
    class CallInfo: Hashable {
        enum Behaviour {
            case syncRead
            case asyncRead
            case syncWrite
            case asyncWrite
            case swiftConcurrencyRead
            case swiftConcurrencyWrite
        }
        
        private enum Event {
            case scheduled
            case started
            case detectedSlowQuery
            case completed
            case cancelled
            case errored(Error)
            
            var error: Error? {
                switch self {
                    case .errored(let error): return error
                    default: return nil
                }
            }
        }
        
        weak var storage: Storage?
        private let uniqueId: UUID = UUID()
        let id: String = (0..<4).map { _ in "\(base32.randomElement() ?? "0")" }.joined()
        let file: String
        let function: String
        let line: Int
        let behaviour: Behaviour
        var task: Task<(), Never>?
        
        private var timer: DispatchSourceTimer?
        private var startTime: CFTimeInterval?
        private(set) var wasSlowTransaction: Bool = false
        
        var isWrite: Bool {
            switch behaviour {
                case .syncWrite, .asyncWrite, .swiftConcurrencyWrite: return true
                case .syncRead, .asyncRead, .swiftConcurrencyRead: return false
            }
        }
        var isAsync: Bool {
            switch behaviour {
                case .asyncRead, .asyncWrite, .swiftConcurrencyWrite: return true
                case .syncRead, .syncWrite, .swiftConcurrencyRead: return false
            }
        }
        
        // MARK: - Initialization
        
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
        
        // MARK: - Functions
        
        private func log(_ event: Event) {
            let fileInfo: String = (file.components(separatedBy: "/").last.map { "\($0):\(line) - " } ?? "")
            let action: String = "\(isWrite ? "write" : "read") query \(id)"
            let callInfo: String = "\(fileInfo)\(function)"
            let end: CFTimeInterval = CACurrentMediaTime()
            let durationInfo: String = startTime
                .map { start in "after \(end - start, format: ".2", omitZeroDecimal: true)s" }
                .defaulting(to: "before it started")
            let databaseName: String = ((storage?.id)
                .map { "database \($0)" })
                .defaulting(to: "the database")
            
            switch (event, wasSlowTransaction, event.error) {
                case (.scheduled, _, _):
                    Log.verbose(.storage, "Scheduling \(action) - [ \(callInfo) ]")
                    
                case (.started, _, _):
                    Log.verbose(.storage, "Started \(action) - [ \(callInfo) ]")
                    
                case (.detectedSlowQuery, _, _):
                    Log.warn(.storage, "Slow \(action) taking longer than \(Storage.slowTransactionThreshold, format: ".2", omitZeroDecimal: true)s - [ \(callInfo) ]")
                    
                case (.completed, true, _):
                    Log.warn(.storage, "Completed slow \(action) \(durationInfo) - [ \(callInfo) ]")
                    
                case (.completed, false, _):
                    Log.verbose(.storage, "Completed \(action) \(durationInfo) - [ \(callInfo) ]")
                    
                case (.cancelled, _, _):
                    Log.verbose(.storage, "Cancelled \(action) \(durationInfo) - [ \(callInfo) ]")
                
                case (.errored(_ as CancellationError), _, _):
                    Log.verbose(.storage, "Cancelled \(action) \(durationInfo) - [ \(callInfo) ]")
                    
                case (.errored(let error as DatabaseError), _, .some(DatabaseError.SQLITE_ABORT)),
                    (.errored(let error as DatabaseError), _, .some(DatabaseError.SQLITE_INTERRUPT)),
                    (.errored(let error as DatabaseError), _, .some(DatabaseError.SQLITE_ERROR)):
                    Log.error(.storage, "Failed \(action) due to error: \(error) (\(error.extendedResultCode)")
                    
                case (.errored, _, .some(StorageError.databaseInvalid)):
                    let message: String = (storage?.startupError.map { "\($0)" } ?? "Unknown cause")
                    Log.error(.storage, "Failed \(action) as \(databaseName) is invalid (\(message)) - [ \(callInfo) ]")
                    
                case (.errored, _, .some(StorageError.databaseSuspended)):
                    Log.error(.storage, "Failed \(action) as \(databaseName) is suspended - [ \(callInfo) ]")
                    
                case (.errored, _, .some(StorageError.transactionDeadlockTimeout)):
                    Log.error(.storage, "Failed \(action) due to a potential synchronous query deadlock timeout - [ \(callInfo) ]")
                
                case (.errored(let error), _, _):
                    Log.verbose(.storage, "Failed \(action) due to error: \(error) - [ \(callInfo) ]")
            }
        }
        
        func schedule() {
            log(.scheduled)
        }
        
        func start() {
            log(.started)
            startTime = CACurrentMediaTime()
            timer = DispatchSource.makeTimerSource(queue: Storage.timerQueue)
            timer?.schedule(
                deadline: .now() + .seconds(Int(Storage.slowTransactionThreshold)),
                repeating: .infinity // Infinity to fire once
            )
            timer?.setEventHandler { [weak self] in
                self?.timer?.cancel()
                self?.timer = nil
                self?.wasSlowTransaction = true
                self?.log(.detectedSlowQuery)
            }
            timer?.resume()
        }
        
        func complete() {
            log(.completed)
            timer?.cancel()
            timer = nil
        }
        
        func errored(_ error: Error) {
            log(.errored(error))
            timer?.cancel()
            timer = nil
        }
        
        func errored<T>(_ error: Error) -> AnyPublisher<T, Error> {
            errored(error)
            return Fail<T, Error>(error: error).eraseToAnyPublisher()
        }
        
        func cancel() {
            task?.cancel()
            timer?.cancel()
            timer = nil
        }
        
        // MARK: - Conformance
        
        func hash(into hasher: inout Hasher) {
            uniqueId.hash(into: &hasher)
        }
        
        static func ==(lhs: CallInfo, rhs: CallInfo) -> Bool {
            return lhs.uniqueId == rhs.uniqueId
        }
    }
}

// MARK: - ObserverInfo

private extension Storage {
    class ObserverInfo: Hashable {
        private let uniqueId: UUID = UUID()
        let id: String
        let file: String
        let function: String
        let line: Int
        
        private weak var storage: Storage?
        private weak var observer: IdentifiableTransactionObserver?
        private weak var cancellable: AnyDatabaseCancellable?
        
        private var callInfo: String {
            let fileInfo: String = (file.components(separatedBy: "/").last.map { "\($0):\(line) - " } ?? "")
            
            return "\(fileInfo)\(function)"
        }
        
        // MARK: - Initialization
        
        init(
            _ storage: Storage?,
            observer: IdentifiableTransactionObserver? = nil,
            _ file: String,
            _ function: String,
            _ line: Int
        ) {
            self.id = (observer?.id ?? (0..<4).map { _ in "\(base32.randomElement() ?? "0")" }.joined())
            self.storage = storage
            self.file = file
            self.function = function
            self.line = line
            self.observer = observer
        }
        
        // MARK: - Functions
        
        func setObservation(_ cancellable: AnyDatabaseCancellable) {
            self.cancellable = cancellable
        }
        
        func start() {
            Log.verbose(.storage, "Started observer \(id) - [ \(callInfo) ]")
        }
        
        func stop(explicitRemoval: Bool) {
            guard cancellable != nil || observer != nil else { return }
            
            cancellable?.cancel()
            cancellable = nil
            
            if let observer: IdentifiableTransactionObserver = observer, !explicitRemoval {
                /// Need to set to `nil` first to prevent infinite loop
                self.observer = nil
                storage?.removeObserver(observer)
            }
            
            Log.verbose(.storage, "Stopped observer \(id) - [ \(callInfo) ]")
        }
        
        func cancel() {
            guard cancellable != nil || observer != nil else { return }
            
            cancellable?.cancel()
            cancellable = nil
            
            if let observer: IdentifiableTransactionObserver = observer {
                /// Need to set to `nil` first to prevent infinite loop
                self.observer = nil
                storage?.removeObserver(observer)
            }
            
            Log.verbose(.storage, "Cancelled observer \(id) - [ \(callInfo) ]")
        }
        
        // MARK: - Conformance
        
        func hash(into hasher: inout Hasher) {
            uniqueId.hash(into: &hasher)
        }
        
        static func ==(lhs: ObserverInfo, rhs: ObserverInfo) -> Bool {
            return lhs.uniqueId == rhs.uniqueId
        }
    }
}

// MARK: - IdentifiedTransactionObserver

public protocol IdentifiableTransactionObserver: TransactionObserver {
    var id: String { get }
}

// MARK: - PublisherBridge

private extension Storage {
    actor PublisherBridge<T> {
        private var subject: PassthroughSubject<T, Error>?
        private var isFinished: Bool = false
        
        init(subject: PassthroughSubject<T, Error>) {
            self.subject = subject
        }

        func send(result: Result<T, Error>, info: CallInfo) {
            guard !isFinished, let subject = self.subject else { return }
            
            self.isFinished = true
            self.subject = nil
            
            switch result {
                case .success(let value):
                    info.complete()
                    subject.send(value)
                    subject.send(completion: .finished)
                    
                case .failure(let error):
                    info.errored(error)
                    subject.send(completion: .failure(error))
            }
        }

        func cancel() {
            guard !isFinished else { return }
            
            self.isFinished = true
            self.subject = nil
        }
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
            ) ?? { throw KeychainStorageError.keySpecInvalid }()
            defer { keySpec.resetBytes(in: 0..<keySpec.count) } // Reset content immediately after use
            
            // Use a raw key spec, where the 96 hexadecimal digits are provided
            // (i.e. 64 hex for the 256 bit key, followed by 32 hex for the 128 bit salt)
            // using explicit BLOB syntax, e.g.:
            //
            // x'98483C6EB40B6C31A448C22A66DED3B5E5E8D5119CAC8327B655C8B5C483648101010101010101010101010101010101'
            keySpec = try (keySpec.toHexString().data(using: .utf8) ?? {
                throw KeychainStorageError.keySpecInvalid
            }())
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
        var keySpec: Data = try dependencies[singleton: .keychain].getOrGenerateEncryptionKey(
            forKey: .dbCipherKeySpec,
            length: Storage.SQLCipherKeySpecLength,
            cat: .storage,
            legacyKey: "GRDBDatabaseCipherKeySpec",
            legacyService: "TSKeyChainService"
        )
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
        let keyInfoPath: String = "\(dependencies[singleton: .fileManager].temporaryDirectory)/\(Storage.encKeyFilename)"
        let encryptedKeyBase64: String = sealedBox.combined.base64EncodedString()
        try encryptedKeyBase64.write(toFile: keyInfoPath, atomically: true, encoding: .utf8)
        
        return keyInfoPath
    }
    
    func replaceDatabaseKey(path: String, password: String) throws {
        var keySpec: Data = try decryptSecureExportedKey(path: path, password: password)
        defer { keySpec.resetBytes(in: 0..<keySpec.count) } // Reset content immediately after use
        
        try dependencies[singleton: .keychain].set(data: keySpec, forKey: .dbCipherKeySpec)
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

/// Function to determine if the debugger is attached
///
/// **Note:** Only contains logic when `DEBUG` is defined, otherwise it always returns false
func isDebuggerAttached() -> Bool {
#if DEBUG
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
    let sysctlResult = sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0)
    guard sysctlResult == 0 else { return false }
    return (info.kp_proc.p_flag & P_TRACED) != 0
#else
    return false
#endif
}
