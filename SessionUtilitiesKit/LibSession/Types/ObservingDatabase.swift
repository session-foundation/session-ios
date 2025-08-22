// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB

// MARK: - ObservingDatabase

public class ObservingDatabase {
    public let dependencies: Dependencies
    internal let originalDb: Database
    internal var events: [ObservedEvent] = []
    internal var postCommitActions: [String: () -> Void] = [:]
    
    // MARK: - Initialization
    
    /// The observation mechanism works via the `Storage` wrapper so if we create a new `ObservingDatabase` outside of that
    /// mechanism the observed events won't be emitted
    public static func create(_ db: Database, using dependencies: Dependencies) -> ObservingDatabase {
        return ObservingDatabase(db, using: dependencies)
    }
    
    private init(_ db: Database, using dependencies: Dependencies) {
        self.dependencies = dependencies
        self.originalDb = db
    }
    
    // MARK: - Functions
    
    public func addEvent(_ event: ObservedEvent) {
        events.append(event)
    }
    
    public func afterCommit(
        dedupeId: String = UUID().uuidString,
        closure: @escaping () -> Void
    ) {
        /// If there is already an entry for `dedupeId` then don't do anything (this allows us to schedule an action to run at most once
        /// per commit (eg. scheduling a job to run after receiving messages)
        guard postCommitActions[dedupeId] == nil else { return }
        
        postCommitActions[dedupeId] = closure
    }
}

public extension ObservingDatabase {
    func addEvent(_ key: ObservableKey) {
        addEvent(ObservedEvent(key: key, value: nil))
    }
    
    func addEvent<T: Hashable>(_ value: T?, forKey key: ObservableKey) {
        addEvent(ObservedEvent(key: key, value: value))
    }
}

// MARK: - ObservationContext

public enum ObservationContext {
    /// This `TaskLocal` variable is set and accessible within the context of a single `Task` and allows any code running within
    /// the task to access the isntance without running into threading issues or needing to manage multiple instances
    @TaskLocal
    public static var observingDb: ObservingDatabase?
}

// MARK: - Convenience

public extension FetchableRecord where Self: TableRecord {
    static func fetchAll(_ db: ObservingDatabase) throws -> [Self] {
        return try self.fetchAll(db.originalDb)
    }
    
    static func fetchOne(_ db: ObservingDatabase) throws -> Self? {
        return try self.fetchOne(db.originalDb)
    }
    
    static func fetchCount(_ db: ObservingDatabase) throws -> Int {
        return try self.fetchCount(db.originalDb)
    }
}

public extension FetchableRecord where Self: TableRecord, Self: Hashable {
    static func fetchSet(_ db: ObservingDatabase) throws -> Set<Self> {
        return try self.fetchSet(db.originalDb)
    }
}

public extension FetchableRecord where Self: TableRecord, Self: Identifiable, Self.ID: DatabaseValueConvertible {
    static func fetchAll(_ db: ObservingDatabase, ids: some Collection<Self.ID>) throws -> [Self] {
        return try self.fetchAll(db.originalDb, ids: ids)
    }
    
    static func fetchOne(_ db: ObservingDatabase, id: Self.ID) throws -> Self? {
        return try self.fetchOne(db.originalDb, id: id)
    }
}

public extension FetchRequest where Self.RowDecoder: FetchableRecord {
    func fetchCursor(_ db: ObservingDatabase) throws -> RecordCursor<Self.RowDecoder> {
        return try self.fetchCursor(db.originalDb)
    }
    
    func fetchAll(_ db: ObservingDatabase) throws -> [Self.RowDecoder] {
        return try self.fetchAll(db.originalDb)
    }
    
    func fetchOne(_ db: ObservingDatabase) throws -> Self.RowDecoder? {
        return try self.fetchOne(db.originalDb)
    }
}

public extension FetchRequest where Self.RowDecoder: FetchableRecord, Self.RowDecoder: Hashable {
    func fetchSet(_ db: ObservingDatabase) throws -> Set<Self.RowDecoder> {
        return try self.fetchSet(db.originalDb)
    }
}

public extension FetchRequest where Self.RowDecoder: DatabaseValueConvertible {
    func fetchAll(_ db: ObservingDatabase) throws -> [Self.RowDecoder] {
        return try self.fetchAll(db.originalDb)
    }
    
    func fetchOne(_ db: ObservingDatabase) throws -> Self.RowDecoder? {
        return try self.fetchOne(db.originalDb)
    }
}

public extension FetchRequest where Self.RowDecoder: DatabaseValueConvertible, Self.RowDecoder: StatementColumnConvertible {
    func fetchAll(_ db: ObservingDatabase) throws -> [Self.RowDecoder] {
        return try self.fetchAll(db.originalDb)
    }
    
    func fetchOne(_ db: ObservingDatabase) throws -> Self.RowDecoder? {
        return try self.fetchOne(db.originalDb)
    }
}

public extension FetchRequest where Self.RowDecoder: DatabaseValueConvertible, Self.RowDecoder: Hashable {
    func fetchSet(_ db: ObservingDatabase) throws -> Set<Self.RowDecoder> {
        return try self.fetchSet(db.originalDb)
    }
}

public extension FetchRequest where Self.RowDecoder: DatabaseValueConvertible, Self.RowDecoder : StatementColumnConvertible, Self.RowDecoder: Hashable {
    func fetchSet(_ db: ObservingDatabase) throws -> Set<Self.RowDecoder> {
        return try self.fetchSet(db.originalDb)
    }
}

public extension PersistableRecord {
    func insert(_ db: ObservingDatabase, onConflict conflictResolution: Database.ConflictResolution? = nil) throws {
        try self.insert(db.originalDb, onConflict: conflictResolution)
    }
    
    func upsert(_ db: ObservingDatabase) throws {
        return try self.upsert(db.originalDb)
    }
    
    func save(_ db: ObservingDatabase, onConflict conflictResolution: Database.ConflictResolution? = nil) throws {
        try self.save(db.originalDb, onConflict: conflictResolution)
    }
}

public extension SQLRequest {
    func fetchCount(_ db: ObservingDatabase) throws -> Int {
        return try self.fetchCount(db.originalDb)
    }
}

public extension MutablePersistableRecord {
    mutating func insert(_ db: ObservingDatabase, onConflict conflictResolution: Database.ConflictResolution? = nil) throws {
        try self.insert(db.originalDb, onConflict: conflictResolution)
    }
    
    func inserted(_ db: ObservingDatabase, onConflict conflictResolution: Database.ConflictResolution? = nil) throws -> Self {
        return try self.inserted(db.originalDb, onConflict: conflictResolution)
    }
    
    mutating func upsert(_ db: ObservingDatabase) throws {
        try self.upsert(db.originalDb)
    }
    
    func update(_ db: ObservingDatabase, onConflict conflictResolution: Database.ConflictResolution? = nil) throws {
        try self.update(db.originalDb, onConflict: conflictResolution)
    }
    
    mutating func save(_ db: ObservingDatabase, onConflict conflictResolution: Database.ConflictResolution? = nil) throws {
        try self.save(db.originalDb, onConflict: conflictResolution)
    }
    
    func saved(_ db: ObservingDatabase, onConflict conflictResolution: Database.ConflictResolution? = nil) throws -> Self {
        return try self.saved(db.originalDb, onConflict: conflictResolution)
    }
    
    @discardableResult
    func delete(_ db: ObservingDatabase) throws -> Bool {
        return try self.delete(db.originalDb)
    }
}

public extension AdaptedFetchRequest {
    func fetchCount(_ db: ObservingDatabase) throws -> Int {
        return try self.fetchCount(db.originalDb)
    }
}

public extension QueryInterfaceRequest {
    func fetchCount(_ db: ObservingDatabase) throws -> Int {
        return try self.fetchCount(db.originalDb)
    }
    
    func isEmpty(_ db: ObservingDatabase) throws -> Bool {
        return try self.isEmpty(db.originalDb)
    }
    
    func updateAndFetchAll(
        _ db: ObservingDatabase,
        onConflict conflictResolution: Database.ConflictResolution? = nil,
        _ assignments: [ColumnAssignment]
    ) throws -> [RowDecoder] where RowDecoder: FetchableRecord, RowDecoder: TableRecord {
        return try self.updateAndFetchAll(db.originalDb, onConflict: conflictResolution, assignments)
    }
    
    @discardableResult
    func updateAll(
        _ db: ObservingDatabase,
        onConflict conflictResolution: Database.ConflictResolution? = nil,
        _ assignments: [ColumnAssignment]
    ) throws -> Int {
        return try self.updateAll(db.originalDb, onConflict: conflictResolution, assignments)
    }
    
    @discardableResult
    func updateAll(
        _ db: ObservingDatabase,
        onConflict conflictResolution: Database.ConflictResolution? = nil,
        _ assignments: ColumnAssignment...
    ) throws -> Int {
        return try self.updateAll(db.originalDb, onConflict: conflictResolution, assignments)
    }
    
    @discardableResult
    func deleteAll(_ db: ObservingDatabase) throws -> Int {
        return try self.deleteAll(db.originalDb)
    }
}

public extension Row {
    static func fetchAll(
        _ db: ObservingDatabase,
        sql: String,
        arguments: StatementArguments = StatementArguments(),
        adapter: (any RowAdapter)? = nil
    ) throws -> [Row] {
        return try self.fetchAll(db.originalDb, sql: sql, arguments: arguments, adapter: adapter)
    }
    
    static func fetchOne(
        _ db: ObservingDatabase,
        sql: String,
        arguments: StatementArguments = StatementArguments(),
        adapter: (any RowAdapter)? = nil
    ) throws -> Row? {
        return try self.fetchOne(db.originalDb, sql: sql, arguments: arguments, adapter: adapter)
    }
}

public extension DatabaseValueConvertible where Self: StatementColumnConvertible {
    static func fetchAll(
        _ db: ObservingDatabase,
        sql: String,
        arguments: StatementArguments = StatementArguments(),
        adapter: (any RowAdapter)? = nil
    ) throws -> [Self] {
        return try self.fetchAll(db.originalDb, sql: sql, arguments: arguments, adapter: adapter)
    }
    
    static func fetchOne(
        _ db: ObservingDatabase,
        sql: String,
        arguments: StatementArguments = StatementArguments(),
        adapter: (any RowAdapter)? = nil
    ) throws -> Self? {
        return try self.fetchOne(db.originalDb, sql: sql, arguments: arguments, adapter: adapter)
    }
}

public extension DatabaseValueConvertible where Self: StatementColumnConvertible, Self: Hashable {
    static func fetchSet(
        _ db: ObservingDatabase,
        sql: String,
        arguments: StatementArguments = StatementArguments(),
        adapter: (any RowAdapter)? = nil
    ) throws -> Set<Self> {
        return try self.fetchSet(db.originalDb, sql: sql, arguments: arguments, adapter: adapter)
    }
}

public extension TableRecord {
    @discardableResult
    static func updateAll(
        _ db: ObservingDatabase,
        onConflict conflictResolution: Database.ConflictResolution? = nil,
        _ assignments: ColumnAssignment...
    ) throws -> Int {
        return try self.updateAll(db.originalDb, onConflict: conflictResolution, assignments)
    }
    
    @discardableResult
    static func deleteAll(_ db: ObservingDatabase) throws -> Int {
        return try self.deleteAll(db.originalDb)
    }
}

public extension TableRecord where Self: Identifiable, Self.ID: DatabaseValueConvertible {
    static func exists(_ db: ObservingDatabase, id: Self.ID) throws -> Bool {
        return try self.exists(db.originalDb, id: id)
    }
    
    @discardableResult
    static func deleteAll(_ db: ObservingDatabase, ids: some Collection<Self.ID>) throws -> Int {
        return try self.deleteAll(db.originalDb, ids: ids)
    }
    
    @discardableResult
    static func deleteOne(_ db: ObservingDatabase, id: Self.ID) throws -> Bool {
        return try self.deleteOne(db.originalDb, id: id)
    }
}

public extension ObservingDatabase {
    func create(
        table name: String,
        options: TableOptions = [],
        body: (TableDefinition) throws -> Void
    ) throws {
        try self.originalDb.create(table: name, options: options, body: body)
    }
    
    func tableExists(_ name: String, in schemaName: String? = nil) throws -> Bool {
        try self.originalDb.tableExists(name, in: schemaName)
    }
    
    func triggerExists(_ name: String, in schemaName: String? = nil) throws -> Bool {
        try self.originalDb.triggerExists(name, in: schemaName)
    }
    
    func rename(table name: String, to newName: String) throws {
        try self.originalDb.rename(table: name, to: newName)
    }
    
    func alter(table name: String, body: (TableAlteration) -> Void) throws {
        try self.originalDb.alter(table: name, body: body)
    }
    
    func drop(table name: String) throws {
        try self.originalDb.drop(table: name)
    }
    
    func create(
        indexOn table: String,
        columns: [String],
        options: IndexOptions = [],
        condition: (any SQLExpressible)? = nil
    ) throws {
        try self.originalDb.create(indexOn: table, columns: columns, options: options, condition: condition)
    }
    
    func create<Module>(
        virtualTable tableName: String,
        options: VirtualTableOptions = [],
        using module: Module,
        _ body: ((Module.TableDefinition) throws -> Void)? = nil
    ) throws where Module: VirtualTableModule {
        try self.originalDb.create(virtualTable: tableName, options: options, using: module, body)
    }
    
    func makeFTS5Pattern(rawPattern: String, forTable table: String) throws -> FTS5Pattern {
        try self.originalDb.makeFTS5Pattern(rawPattern: rawPattern, forTable: table)
    }
    
    func makeFTS5Pattern<T>(rawPattern: String, forTable table: T.Type) throws -> FTS5Pattern where T: TableRecord, T: ColumnExpressible {
        return try makeFTS5Pattern(rawPattern: rawPattern, forTable: table.databaseTableName)
    }
    
    func dropFTS5SynchronizationTriggers(forTable tableName: String) throws {
        try self.originalDb.dropFTS5SynchronizationTriggers(forTable: tableName)
    }
    
    func execute(sql: String, arguments: StatementArguments = StatementArguments()) throws {
        try self.originalDb.execute(sql: sql, arguments: arguments)
    }
    
    func execute(literal sqlLiteral: SQL) throws {
        try self.originalDb.execute(literal: sqlLiteral)
    }
    
    func makeStatement(sql: String) throws -> Statement {
        try self.originalDb.makeStatement(sql: sql)
    }
    
    func add(
        transactionObserver: some TransactionObserver,
        extent: Database.TransactionObservationExtent = .observerLifetime
    ) {
        self.originalDb.add(transactionObserver: transactionObserver, extent: extent)
    }
    
    func checkForeignKeys() throws {
        try self.originalDb.checkForeignKeys()
    }
}
