// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import UIKit
import CryptoKit
import GRDB

#if DEBUG
import Darwin
#endif

// MARK: - Singleton

public extension Singleton {
    static let storage: SingletonConfig<Storage> = Dependencies.create(
        identifier: "storage",
        createInstance: { dependencies, _ in Storage.create(using: dependencies) }
    )
    static let scheduler: SingletonConfig<ValueObservationScheduler> = Dependencies.create(
        identifier: "scheduler",
        createInstance: { _, _ in AsyncValueObservationScheduler.async(onQueue: .main) }
    )
}

// MARK: - Log.Category

public extension Log.Category {
    static let storage: Log.Category = .create("Storage", defaultLevel: .info)
}

// MARK: - KeychainStorage

public extension KeychainStorage.DataKey { static let dbCipherKeySpec: Self = "GRDBDatabaseCipherKeySpec" }

// MARK: - Storage

public actor Storage {
    public static let base32: String = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"
    public static let queuePrefix: String = "SessionDatabase"
    public static let dbFileName: String = "Session.sqlite"
    private static let SQLCipherKeySpecLength: Int = 48
    
    /// If a transaction takes longer than this duration a warning will be logged but the transaction will continue to run
    private static let slowTransactionThreshold: TimeInterval = 3
    
    /// When attempting to do a write the transaction will wait this long to acquite a lock before failing
    private static let writeTransactionStartTimeout: TimeInterval = 5
    
    public static var sharedDatabaseDirectoryPath: String { "\(SessionFileManager.nonInjectedAppSharedDataDirectoryPath)/database" }
    private static var databasePath: String { "\(Storage.sharedDatabaseDirectoryPath)/\(Storage.dbFileName)" }
    private static var databasePathShm: String { "\(Storage.sharedDatabaseDirectoryPath)/\(Storage.dbFileName)-shm" }
    private static var databasePathWal: String { "\(Storage.sharedDatabaseDirectoryPath)/\(Storage.dbFileName)-wal" }
    
    nonisolated private let id: String = (0..<5).map { _ in "\(base32.randomElement() ?? "0")" }.joined()
    nonisolated private let dependencies: Dependencies
    fileprivate var dbWriter: DatabaseWriter?
    private var preSuspendState: State = .notSetup
    private let _state: CurrentValueAsyncStream<State> = CurrentValueAsyncStream(.notSetup)
    
    /// Flagged as `nonisolated(unsafe)` to suppress the warning but the only time it's written to in a nonisolated way is within
    /// the `init` so it should be safe
    nonisolated(unsafe) private var initTask: Task<Void, Never>?
    private var migrationTask: Task<Void, Never>?
    
    // MARK: - Database State Variables
    
    private var startupError: Error?
    public var state: AsyncStream<State> { _state.stream }
    nonisolated public let syncState: StorageSyncState = StorageSyncState()
    nonisolated public var isDatabasePasswordAccessible: Bool {
        ((try? getDatabaseCipherKeySpec()) != nil)
    }
    
    /// This property gets set the first time we successfully read from the database
    public private(set) var hasSuccessfullyRead: Bool = false
    
    /// This property gets set the first time we successfully write to the database
    public private(set) var hasSuccessfullyWritten: Bool = false
    
    /// This property keeps track of all current database calls and can be used when suspending the database to explicitly
    /// cancel any currently running tasks
    private var currentCalls: Set<CallInfo> = []
    
    /// This property keeps track of all current database observers for logging purposes
    private var currentObservers: Set<ObserverInfo> = []
    
    // MARK: - Initialization
    
    public static func create(using dependencies: Dependencies) -> Storage {
        return Storage(customWriter: nil, using: dependencies)
    }
    
    public static func createForTesting(using dependencies: Dependencies) throws -> (storage: Storage, queue: DatabaseQueue) {
        let queue: DatabaseQueue = try DatabaseQueue()
        
        return (Storage(customWriter: queue, using: dependencies), queue)
    }
    
    public static func createForTesting(using dependencies: Dependencies) throws -> Storage {
        return try createForTesting(using: dependencies).storage
    }
    
    private init(customWriter: DatabaseWriter? = nil, using dependencies: Dependencies) {
        self.dependencies = dependencies
        
        switch customWriter {
            case .some:
                /// Synchronous initialization for unit tests (which generally provide
                self.dbWriter = customWriter
                self.syncState.update(
                    hasValidDatabaseConnection: .set(to: true),
                    state: .set(to: .pendingMigrations),
                    testDbWriter: .set(to: customWriter)
                )
                Task { await _state.send(.pendingMigrations) }
                
            case .none:
                initTask = Task {
                    await configureDatabase()
                }
        }
    }
    
    deinit {
        initTask?.cancel()
    }
    
    public func configureDatabase() async {
        /// Create the database directory if needed and ensure it's protection level is set before attempting to create the database
        /// KeySpec or the database itself
        try? dependencies[singleton: .fileManager].ensureDirectoryExists(at: Storage.sharedDatabaseDirectoryPath)
        try? dependencies[singleton: .fileManager].protectFileOrFolder(at: Storage.sharedDatabaseDirectoryPath)
        
        /// Explicitly protect existing db files (no-ops if they don't exist) - this is needed just in case because iOS 26 changed how files
        /// inherit file protections
        try? dependencies[singleton: .fileManager].protectFileOrFolder(at: Storage.databasePath)
        try? dependencies[singleton: .fileManager].protectFileOrFolder(at: Storage.databasePathShm)
        try? dependencies[singleton: .fileManager].protectFileOrFolder(at: Storage.databasePathWal)
        
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
        
        /// Output the database file sizes and protection info for debugging
        Log.info(.storage, "Opening database (db: \(fileInfoString(at: Storage.databasePath)), shm: \(fileInfoString(at: Storage.databasePathShm)), wal: \(fileInfoString(at: Storage.databasePathWal)))")
        
        /// Configure the database and create the DatabasePool for interacting with the database
        var config = Configuration()
        config.label = Storage.queuePrefix
        config.maximumReaderCount = 10                   /// Increase the max read connection limit - Default is 5
        config.busyMode = .timeout(Storage.writeTransactionStartTimeout)

        /// Load in the SQLCipher keys
        config.prepareDatabase { [dependencies] db in
            var keySpec: Data = try dependencies[singleton: .keychain].getOrGenerateEncryptionKey(
                forKey: .dbCipherKeySpec,
                length: Storage.SQLCipherKeySpecLength,
                cat: .storage,
                legacyKey: "GRDBDatabaseCipherKeySpec",
                legacyService: "TSKeyChainService"
            )
            defer { keySpec.resetBytes(in: 0..<keySpec.count) } // Reset content immediately after use
            
            /// Use a raw key spec, where the 96 hexadecimal digits are provided (i.e. 64 hex for the 256 bit key, followed by 32 hex
            /// for the 128 bit salt) using explicit BLOB syntax, e.g.:
            ///
            /// x'98483C6EB40B6C31A448C22A66DED3B5E5E8D5119CAC8327B655C8B5C483648101010101010101010101010101010101'
            keySpec = try (keySpec.toHexString().data(using: .utf8) ?? {
                throw KeychainStorageError.keySpecInvalid
            }())
            keySpec.insert(contentsOf: [120, 39], at: 0)    // "x'" prefix
            keySpec.append(39)                              // "'" suffix
            
            try db.usePassphrase(keySpec)
            
            /// According to the SQLCipher docs iOS needs the `cipher_plaintext_header_size` value set to at least `32`
            /// as iOS extends special privileges to the database and needs this header to be in plaintext to determine the file type
            ///
            /// For more info see: https://www.zetetic.net/sqlcipher/sqlcipher-api/#cipher_plaintext_header_size
            try db.execute(sql: "PRAGMA cipher_plaintext_header_size = 32")
            
            /// Re-protect the db files as SQLite may have just created them
            try? dependencies[singleton: .fileManager].protectFileOrFolder(at: Storage.databasePath)
            try? dependencies[singleton: .fileManager].protectFileOrFolder(at: Storage.databasePathShm)
            try? dependencies[singleton: .fileManager].protectFileOrFolder(at: Storage.databasePathWal)
        }
        
        /// Create the DatabasePool to allow us to connect to the database and mark the storage as valid
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
                
                /// Try to initialise the dbWriter again (hoping the above resolves the lock)
                dbWriter = try DatabasePool(
                    path: "\(Storage.sharedDatabaseDirectoryPath)/\(Storage.dbFileName)",
                    configuration: config
                )
            }
            catch let error as DatabaseError where error.resultCode == .SQLITE_CANTOPEN {
                /// If the app gets killed by the watchdog then it can take some time to release file locks resulting in the
                /// `SQLITE_CANTOPEN` error being thrown, so if this happens we want to try to wait and retry - the below gives
                /// a `~3.5s` window to try to recover which shouldn't be too unreasonable from a users perspective
                var lastError: Error = error
                let delays: [DispatchTimeInterval] = [.milliseconds(500), .seconds(1), .seconds(2)]
                
                for delay in delays {
                    Log.warn(.storage, "Database reported SQLITE_CANTOPEN (\(error.extendedResultCode)), retrying after \(delay)")
                    try? await Task.sleep(for: delay)
                    
                    do {
                        dbWriter = try DatabasePool(
                            path: "\(Storage.sharedDatabaseDirectoryPath)/\(Storage.dbFileName)",
                            configuration: config
                        )
                        lastError = error
                        break
                    }
                    catch let retryError as DatabaseError where retryError.resultCode == .SQLITE_CANTOPEN {
                        lastError = retryError
                        continue
                    }
                }
                
                if dbWriter == nil {
                    throw lastError
                }
            }
            catch let error as DatabaseError where error.resultCode == .SQLITE_IOERR {
                Log.error(.storage, "Database reported that it couldn't open during startup (\(error.extendedResultCode))")
                throw error
            }
            
            syncState.update(
                hasValidDatabaseConnection: .set(to: true),
                state: .set(to: .pendingMigrations),
                testDbWriter: .set(to: dbWriter)
            )
            await _state.send(.pendingMigrations)
        }
        catch {
            startupError = error
            syncState.update(
                hasValidDatabaseConnection: .set(to: false),
                state: .set(to: .noDatabaseConnection)
            )
            await _state.send(.noDatabaseConnection)
        }
    }
    
    // MARK: - Migrations
    
    public static func appliedMigrationIdentifiers(_ db: ObservingDatabase) -> Set<String> {
        let migrator: DatabaseMigrator = DatabaseMigrator()
        
        return (try? migrator.appliedIdentifiers(db.originalDb))
            .defaulting(to: [])
    }
    
    public func perform(
        migrations: [Migration.Type],
        onProgressUpdate: ((CGFloat, TimeInterval) -> ())? = nil
    ) async throws {
        /// Ensure the initialization has completed before continuing
        await initTask?.value
        
        guard let dbWriter else {
            let error: Error = (startupError ?? StorageError.startupFailed)
            Log.error(.storage, "Startup failed with error: \(error)")
            throw error
        }
        
        /// Update the state
        syncState.update(state: .set(to: .performingMigrations))
        await _state.send(.performingMigrations)
        
        /// Setup and run any required migrations
        var migrator: DatabaseMigrator = DatabaseMigrator()
        migrations.forEach { migration in
            migrator.registerMigration(migration.identifier) { [dependencies] db in
                let migration = migration.loggedMigrate(using: dependencies)
                try migration(ObservingDatabase.create(db, using: dependencies))
            }
        }
        
        /// Determine which migrations need to be performed and gather the relevant settings needed to inform the app of progress/states
        let completedMigrations: [String] = (try? await dbWriter.read { [migrator] db in try migrator.completedMigrations(db) })
            .defaulting(to: [])
        let unperformedMigrations: [Migration.Type] = migrations
            .reduce(into: []) { result, next in
                guard !completedMigrations.contains(next.identifier) else { return }
                
                result.append(next)
            }
        let unperformedMigrationDurations: [TimeInterval] = unperformedMigrations.map { $0.minExpectedRunDuration }
        let totalMinExpectedDuration: TimeInterval = unperformedMigrationDurations.reduce(0, +)
        
        /// Store the logic to handle migration progress and completion
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
        
        /// If there aren't any migrations to run then just complete immediately (this way the migrator doesn't try to execute on the
        /// DBWrite thread so returning from the background can't get blocked due to some weird endless process running)
        guard !unperformedMigrations.isEmpty else {
            syncState.update(state: .set(to: .readyForUse))
            await _state.send(.readyForUse)
            return
        }
        
        /// Create the `MigrationContext`
        let migrationContext: MigrationExecution.Context = MigrationExecution.Context(progressUpdater: progressUpdater)
        
        /// If we have an unperformed migration then trigger the progress updater immediately
        if let firstMigrationIdentifier: String = unperformedMigrations.first?.identifier {
            migrationContext.progressUpdater(firstMigrationIdentifier, 0)
        }
        
        let migrationResult: Result<Void, Error> = await withCheckedContinuation { [weak self, dbWriter, dependencies] continuation in
            let task = Task {
                await withTaskCancellationHandler(
                    operation: {
                        MigrationExecution.$current.withValue(migrationContext) { [dbWriter, dependencies] in
                            migrator.asyncMigrate(dbWriter) { [dependencies] result in
                                /// Make sure to transition the progress updater to 100% for the final migration (just in case the migration
                                /// itself didn't update to 100% itself)
                                if let lastMigrationIdentifier: String = unperformedMigrations.last?.identifier {
                                    MigrationExecution.current?.progressUpdater(lastMigrationIdentifier, 1)
                                }
                                
                                /// Output any events tracked during the migration and trigger any `postCommitActions` which should occur
                                if let events: [ObservedEvent] = MigrationExecution.current?.observedEvents {
                                    dependencies.notifyAsync(events: events)
                                }
                                
                                if let actions: [String: () -> Void] = MigrationExecution.current?.postCommitActions {
                                    actions.values.forEach { $0() }
                                }
                                
                                /// Resume the continuation
                                continuation.resume(with: .success(result.map { _ in () }))
                            }
                        }
                    },
                    onCancel: { [dbWriter] in
                        /// `interrupt()` is safe here specifically because we are abandoning this migration entirely, the pool
                        /// will reconnect fresh on resume and the migrator is idempotent so the interrupted migration will be
                        /// retried cleanly
                        dbWriter.interrupt()
                    }
                )
            }
            Task { [weak self] in await self?.setMigrationTask(task) }
        }
        migrationTask = nil
        
        /// Don't log anything in the case of a `success` or if the database is suspended (the latter will happen if the
        /// user happens to return to the background too quickly on launch so is unnecessarily alarming, it also gets
        /// caught and logged separately by the `write` functions anyway)
        switch migrationResult {
            case .success:
                /// Only transition into `readyForUse` if we aren't suspended
                guard await _state.getCurrent() != .suspended else { break }
                syncState.update(state: .set(to: .readyForUse))
                await _state.send(.readyForUse)
                
            case .failure(DatabaseError.SQLITE_ABORT): await _state.send(.suspended)
            case .failure(let error):
                /// Only log and transition into `migrationsFailed` if we aren't suspended
                guard await _state.getCurrent() != .suspended else { break }
                
                let completedMigrations: [String] = (try? await dbWriter
                    .read { [migrator] db in try migrator.completedMigrations(db) })
                    .defaulting(to: [])
                let failedMigrationName: String = migrator.migrations
                    .filter { !completedMigrations.contains($0) }
                    .first
                    .defaulting(to: "Unknown")
                Log.critical(.migration, "Migration '\(failedMigrationName)' failed with error: \(error)")
                syncState.update(state: .set(to: .migrationsFailed))
                await _state.send(.migrationsFailed)
        }
        
        /// Trigger the error if it was a failure
        _ = try migrationResult.get()
    }
    
    private func setMigrationTask(_ task: Task<Void, Never>) {
        migrationTask = task
    }
    
    // MARK: - Security
    
    nonisolated private func getDatabaseCipherKeySpec() throws -> Data {
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
    public func suspendDatabaseAccess() async {
        let currentState: State = await _state.getCurrent()
        guard currentState != .suspended else { return }
        
        preSuspendState = currentState
        syncState.update(state: .set(to: .suspended))
        await _state.send(.suspended)
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
        
        /// Cancel any in-flight database tasks so the database can shut down
        migrationTask?.cancel()
        migrationTask = nil
        currentCalls.forEach { $0.cancel() }
        currentCalls = []
        
        /// Do NOT call `dbWriter?.interrupt()` here, as `sqlite3_interrupt()` aborts operations at the SQLite level
        /// but bypasses GRDB's transaction state machine, leaving `SerializedDatabase` believing transactions are still open
        /// that SQLite has already rolled back - this causes `preconditionNoUnsafeTransactionLeft` crashes when GRDB
        /// later tries to close or reuse those connections.
        ///
        /// Instead we rely on Swift Task cancellation (which GRDB's async read/write functions handle correctly), these should roll
        /// back any open transaction and update GRDB's internal state before throwing `CancellationError`
        ///
        /// This brief delay gives in-flight tasks a chance to reach a GRDB cancellation point and clean up before we checkpoint
        try? await Task.sleep(for: .milliseconds(50))
        
        /// We want to force a checkpoint (ie. write any data in the WAL to disk, to ensure the main database is in a valid state)
        do { try forceCheckpoint(.truncate) }
        catch { Log.info(.storage, "Failed to checkpoint database due to error: \(error)") }
        
        /// Log the successful suspension
        Log.info(.storage, "Database suspended successfully for \(id) (db: \(fileInfoString(at: Storage.databasePath)), shm: \(fileInfoString(at: Storage.databasePathShm)), wal: \(fileInfoString(at: Storage.databasePathWal))).")
        
        await dependencies.notify(key: .databaseLifecycle(.suspended))
    }
    
    /// This method reverses the database suspension used to prevent the `0xdead10cc` exception (see `suspendDatabaseAccess()`
    /// above for more information
    public func resumeDatabaseAccess() async {
        guard await _state.getCurrent() == .suspended else { return }
        
        let resumeState: State = (preSuspendState == .performingMigrations ?
            .pendingMigrations :
            preSuspendState
        )
        syncState.update(state: .set(to: resumeState))
        await _state.send(resumeState)
        Log.info(.storage, "Database access resumed.")
        await dependencies.notify(key: .databaseLifecycle(.resumed))
    }
    
    /// Bypasses the suspension check
    private func forceCheckpoint(_ mode: Database.CheckpointMode) throws {
        try dbWriter?.writeWithoutTransaction { db in _ = try db.checkpoint(mode) }
    }
    
    public func checkpoint(_ mode: Database.CheckpointMode) async throws {
        guard await _state.getCurrent() != .suspended else { throw StorageError.databaseSuspended }
        try forceCheckpoint(mode)
    }
    
    public func closeDatabase() async {
        await suspendDatabaseAccess()
        syncState.update(
            hasValidDatabaseConnection: .set(to: false),
            state: .set(to: .noDatabaseConnection),
            testDbWriter: .set(to: nil)
        )
        await _state.send(.noDatabaseConnection)
        dbWriter = nil
    }
    
    public func resetAllStorage() async {
        syncState.update(
            hasValidDatabaseConnection: .set(to: false),
            state: .set(to: .noDatabaseConnection),
            testDbWriter: .set(to: nil)
        )
        await _state.send(.noDatabaseConnection)
        currentCalls.forEach { $0.cancel() }
        currentCalls = []
        dbWriter = nil
        
        deleteDatabaseFiles()
        do { try deleteDbKeys() } catch { Log.warn(.storage, "Failed to delete database keys.") }
    }
    
    public func reconfigureDatabase() {
        initTask?.cancel()
        initTask = Task {
            await configureDatabase()
        }
    }
    
    public func resetForCleanMigration() async {
        /// Clear existing content
        await resetAllStorage()
        
        /// Reconfigure
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
    
    private func fileInfoString(at path: String) -> String {
        guard dependencies[singleton: .fileManager].fileExists(atPath: path) else {
            return "missing"
        }
        
        let size: String = (try? dependencies[singleton: .fileManager].attributesOfItem(atPath: path))
            .map { attributes in
                (attributes[.size] as? Int64)
                    .map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
                    .defaulting(to: "unknown size")
            }
            .defaulting(to: "inaccessible")
        
        let protection: String = (try? FileManager.default.attributesOfItem(atPath: path))
            .map { attributes in
                guard let protection = attributes[.protectionKey] as? FileProtectionType else {
                    return "unknown protection"
                }
                
                if #available(iOS 17.0, *) {
                    switch protection {
                        case .completeWhenUserInactive: return "completeWhenUserInactive"
                        default: break
                    }
                }
                
                switch protection {
                    case .complete: return "complete"
                    case .completeUnlessOpen: return "completeUnlessOpen"
                    case .completeUntilFirstUserAuthentication: return "completeUntilFirstUserAuthentication"
                    case .none: return "none"
                    default: return "unknown(\(protection.rawValue))"
                }
            }
            .defaulting(to: "inaccessible")
        
        return "\(size) [\(protection)]"
    }
    
    // MARK: - Operations
    
    @discardableResult private func executeOperation<T>(
        _ info: CallInfo,
        _ operation: @escaping (ObservingDatabase) throws -> T
    ) async throws -> T {
        /// Ensure the database has finished initialization
        await initTask?.value
        
        /// Validate the state
        switch await _state.getCurrent() {
            case .suspended:
                info.errored(StorageError.databaseSuspended)
                throw StorageError.databaseSuspended

            case .notSetup, .noDatabaseConnection, .migrationsFailed:
                let error = startupError ?? StorageError.databaseInvalid
                info.errored(error)
                throw error

            case .pendingMigrations, .performingMigrations, .readyForUse:
                break
        }
        
        guard let dbWriter else {
            let error: Error = (startupError ?? StorageError.databaseInvalid)
            info.errored(error)
            throw error
        }
        
        info.schedule()
        currentCalls.insert(info)
        defer { currentCalls.remove(info) }
        
        /// Wrap the GRDB call in its own Task so `cancel()`, called by `suspendDatabaseAccess`, can reach and cancel the
        /// actual in-flight work. GRDB's async read/write functions are cancellation-aware and will cleanly roll back any open
        /// transaction before throwing `CancellationError`
        typealias DatabaseOutput = (
            result: T,
            events: [ObservedEvent],
            postCommitActions: [() -> Void]
        )
        typealias DatabaseResult = (result: T, postCommitActions: [() -> Void])
        let operationTask: Task<DatabaseResult, Error> = Task { [dbWriter, dependencies] in
            if dependencies[feature: .forceSlowDatabaseQueries] {
                try? await Task.sleep(for: .seconds(1))
            }
            
            let tracked: @Sendable (Database) throws -> DatabaseOutput = { db in
                info.start()
                
                /// Create the `ObservingDatabase` and store it in the `ObservationContext` so objects can access
                /// it while the operation is running (this allows us to use things like `aroundInsert` without having to resort
                /// to hacks to give it access to the `ObservingDatabase` or `Dependencies` instances
                let observingDatabase: ObservingDatabase = ObservingDatabase.create(db, using: dependencies)
                let result: T = try ObservationContext.$observingDb.withValue(observingDatabase) {
                    try operation(observingDatabase)
                }
                
                return (
                    result,
                    observingDatabase.events,
                    Array(observingDatabase.postCommitActions.values)
                )
            }
            
            let (value, events, postCommitActions) = try await (info.isWrite ?
                dbWriter.write(tracked) :
                dbWriter.read(tracked)
            )
            
            /// Trigger the observations in a detached task so we don't block
            Task.detached { [dependencies] in await dependencies.notify(events: events) }
            return (value, postCommitActions)
        }
        info.setOperationTask(operationTask)
        
        
        do {
            let output: DatabaseResult = try await operationTask.value
            
            /// Update the state flags
            hasSuccessfullyWritten = (hasSuccessfullyWritten || info.isWrite)
            hasSuccessfullyRead = (hasSuccessfullyRead || !info.isWrite)
            
            /// If the database operation completed successfully we should trigger any of the `postCommitActions`
            output.postCommitActions.forEach { $0() }
            
            /// Return the actual result
            info.complete()
            return output.result
        } catch {
            info.errored(error)
            throw error
        }
    }
    
    private func removeObserver(_ observer: ObserverInfo) {
        currentObservers.remove(observer)
    }
    
    // MARK: - Functions
    
    @discardableResult public func write<T>(
        fileName file: String = #fileID,
        functionName funcN: String = #function,
        lineNumber line: Int = #line,
        updates: @escaping (ObservingDatabase) throws -> T
    ) async throws -> T {
        return try await executeOperation(CallInfo(id, file, funcN, line, isWrite: true), updates)
    }
    
    @discardableResult public func read<T>(
        fileName file: String = #fileID,
        functionName funcN: String = #function,
        lineNumber line: Int = #line,
        value: @escaping (ObservingDatabase) throws -> T
    ) async throws -> T {
        return try await executeOperation(CallInfo(id, file, funcN, line, isWrite: false), value)
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
        onError: @MainActor @Sendable @escaping (Error) -> Void,
        onChange: @MainActor @Sendable @escaping (Reducer.Value) -> Void
    ) async -> Task<Void, Never> {
        await initTask?.value
        
        guard await _state.getCurrent() != .suspended, let dbWriter: DatabaseWriter = dbWriter else {
            await onError(StorageError.databaseInvalid)
            return Task {}
        }
        
        let info: ObserverInfo = ObserverInfo(fileName, functionName, lineNumber)
        currentObservers.insert(info)
        
        let cancellable: AnyDatabaseCancellable = observation
            .handleEvents(didCancel: { [weak self] in
                info.stop()
                Task { [weak self] in await self?.removeObserver(info) }
            })
            .start(
                in: dbWriter,
                scheduling: scheduler,
                onError: { error in Task { @MainActor in onError(error) } },
                onChange: { value in Task { @MainActor in onChange(value) } }
            )
        info.start()
        info.setObservation(cancellable)
        
        let (stream, streamContinuation) = AsyncStream<Never>.makeStream()
        return Task {
            await withTaskCancellationHandler(
                operation: { for await _ in stream {} },
                onCancel: {
                    cancellable.cancel()
                    streamContinuation.finish()
                }
            )
        }
    }
    
    /// Add a database observation
    ///
    /// **Note:** This function **MUST NOT** be called from the main thread
    public func addObserver(
        fileName: String = #fileID,
        functionName: String = #function,
        lineNumber: Int = #line,
        _ observer: IdentifiableTransactionObserver?
    ) async {
        guard
            await _state.getCurrent() != .suspended,
            let dbWriter: DatabaseWriter = dbWriter,
            let observer: IdentifiableTransactionObserver = observer
        else { return }
        
        let info: ObserverInfo = ObserverInfo(observer: observer, fileName, functionName, lineNumber)
        currentObservers.insert(info)
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
    ) async {
        guard let dbWriter, let observer else { return }
        
        currentObservers = currentObservers.filter { info -> Bool in
            guard info.id == observer.id else { return true }
            info.stop()
            return false
        }
        dbWriter.remove(transactionObserver: observer)
    }
}

/// We manually handle thread-safety using the `NSLock` so can ensure this is `Sendable`
public final class StorageSyncState: @unchecked Sendable {
    private let lock = NSLock()
    private var _hasValidDatabaseConnection: Bool = false
    private var _state: Storage.State = .notSetup
    private var _testDbWriter: DatabaseWriter? = nil
    
    public var hasValidDatabaseConnection: Bool { lock.withLock { _hasValidDatabaseConnection } }
    public var state: Storage.State { lock.withLock { _state } }
    internal var testDbWriter: DatabaseWriter? { lock.withLock { _testDbWriter } }

    func update(
        hasValidDatabaseConnection: Update<Bool> = .useExisting,
        state: Update<Storage.State> = .useExisting,
        testDbWriter: Update<DatabaseWriter?> = .useExisting
    ) {
        lock.withLock {
            self._hasValidDatabaseConnection = hasValidDatabaseConnection.or(self._hasValidDatabaseConnection)
            self._state = state.or(self._state)
            self._testDbWriter = testDbWriter.or(self._testDbWriter)
        }
    }
}

// MARK: - Storage.State

public extension Storage {
    enum State {
        case notSetup
        case noDatabaseConnection
        case pendingMigrations
        case performingMigrations
        case migrationsFailed
        case suspended
        case readyForUse
    }
}

// MARK: - CallInfo

private extension Storage {
    class CallInfo: Hashable {
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
        
        private let uniqueId: UUID = UUID()
        let id: String = (0..<4).map { _ in "\(base32.randomElement() ?? "0")" }.joined()
        let storageId: String
        let file: String
        let function: String
        let line: Int
        let isWrite: Bool
        
        private var cancelOperation: (() -> Void)?
        private var slowQueryTask: Task<Void, Never>?
        private var startTime: CFTimeInterval?
        private(set) var wasSlowTransaction: Bool = false
        
        // MARK: - Initialization
        
        init(
            _ storageId: String,
            _ file: String,
            _ function: String,
            _ line: Int,
            isWrite: Bool
        ) {
            self.storageId = storageId
            self.file = file
            self.function = function
            self.line = line
            self.isWrite = isWrite
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
                    Log.error(.storage, "Failed \(action) as database \(storageId) is invalid - [ \(callInfo) ]")
                    
                case (.errored, _, .some(StorageError.databaseSuspended)):
                    Log.error(.storage, "Failed \(action) as database \(storageId) is suspended - [ \(callInfo) ]")
                
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
            slowQueryTask = Task.detached { [weak self] in
                try? await Task.sleep(for: .seconds(Int(Storage.slowTransactionThreshold)))
                
                guard !Task.isCancelled else { return }
                
                self?.wasSlowTransaction = true
                self?.log(.detectedSlowQuery)
            }
        }
        
        func complete() {
            slowQueryTask?.cancel()
            slowQueryTask = nil
            log(.completed)
        }
        
        func errored(_ error: Error) {
            slowQueryTask?.cancel()
            slowQueryTask = nil
            log(.errored(error))
        }
        
        func cancel() {
            cancelOperation?()
            cancelOperation = nil
            slowQueryTask?.cancel()
            slowQueryTask = nil
            log(.cancelled)
        }
        
        func setOperationTask<T>(_ task: Task<T, Error>) {
            cancelOperation = { task.cancel() }
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
        
        private weak var observer: IdentifiableTransactionObserver?
        private weak var cancellable: AnyDatabaseCancellable?
        
        private var callInfo: String {
            let fileInfo: String = (file.components(separatedBy: "/").last.map { "\($0):\(line) - " } ?? "")
            
            return "\(fileInfo)\(function)"
        }
        
        // MARK: - Initialization
        
        init(
            observer: IdentifiableTransactionObserver? = nil,
            _ file: String,
            _ function: String,
            _ line: Int
        ) {
            self.id = (observer?.id ?? (0..<4).map { _ in "\(base32.randomElement() ?? "0")" }.joined())
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
        
        func stop() {
            guard cancellable != nil || observer != nil else { return }
            
            cancellable?.cancel()
            cancellable = nil
            observer = nil
            Log.verbose(.storage, "Stopped observer \(id) - [ \(callInfo) ]")
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

// MARK: - Debug Convenience

public extension Storage {
    static let encKeyFilename: String = "key.enc"
    
    static func testAccess(
        databasePath: String,
        encryptedKeyPath: String,
        encryptedKeyPassword: String
    ) throws {
        /// First we need to ensure we can decrypt the encrypted key file
        do {
            var tmpKeySpec: Data = try Storage.decryptSecureExportedKey(
                path: encryptedKeyPath,
                password: encryptedKeyPassword
            )
            tmpKeySpec.resetBytes(in: 0..<tmpKeySpec.count)
        }
        catch { return }
        
        /// Then configure the database using the key
        var config = Configuration()

        /// Load in the SQLCipher keys
        config.prepareDatabase { db in
            var keySpec: Data = try Storage.decryptSecureExportedKey(
                path: encryptedKeyPath,
                password: encryptedKeyPassword
            )
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
        
        // Ensure we can create a DatabasePool
        let dbWriter = try DatabasePool(path: databasePath, configuration: config)
        try? dbWriter.close()
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
        var keySpec: Data = try Storage.decryptSecureExportedKey(path: path, password: password)
        defer { keySpec.resetBytes(in: 0..<keySpec.count) } // Reset content immediately after use
        
        try dependencies[singleton: .keychain].set(data: keySpec, forKey: .dbCipherKeySpec)
    }
    
    fileprivate static func decryptSecureExportedKey(path: String, password: String) throws -> Data {
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

private extension String.StringInterpolation {
    mutating func appendInterpolation(_ value: Double, format: String, omitZeroDecimal: Bool = false) {
        guard !omitZeroDecimal || Int(exactly: value) == nil else {
            appendLiteral("\(Int(exactly: value)!)")
            return
        }
        
        let result: String = String(format: "%\(format)f", value)
        appendLiteral(result)
    }
}
