// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB

// MARK: - Log.Category

public extension Log.Category {
    static let migration: Log.Category = .create("Migration", defaultLevel: .info)
}

// MARK: - Migration

public protocol Migration {
    static var target: TargetMigrations.Identifier { get }
    static var identifier: String { get }
    static var minExpectedRunDuration: TimeInterval { get }
    static var createdTables: [(TableRecord & FetchableRecord).Type] { get }
    
    static func migrate(_ db: ObservingDatabase, using dependencies: Dependencies) throws
}

public extension Migration {
    static func loggedMigrate(
        _ storage: Storage?,
        targetIdentifier: TargetMigrations.Identifier,
        using dependencies: Dependencies
    ) -> ((_ db: ObservingDatabase) throws -> ()) {
        return { (db: ObservingDatabase) in
            Log.info(.migration, "Starting \(targetIdentifier.key(with: self))")
            
            /// Store the `currentlyRunningMigration` in case it's useful
            MigrationExecution.current?.currentlyRunningMigration = MigrationExecution.CurrentlyRunningMigration(
                identifier: targetIdentifier,
                migration: self
            )
            defer { MigrationExecution.current?.currentlyRunningMigration = nil }
            
            /// Perform the migration
            try migrate(db, using: dependencies)
            
            /// If the migration was successful then we should add the `events` and `postCommitActions` to the context to be
            /// run at the end of all migrations
            MigrationExecution.current?.observedEvents.append(contentsOf: db.events)
            MigrationExecution.current?.postCommitActions.merge(db.postCommitActions) { old, _ in old }
            
            Log.info(.migration, "Completed \(targetIdentifier.key(with: self))")
        }
    }
}

// MARK: - MigrationExecution

public enum MigrationExecution {
    public struct CurrentlyRunningMigration: ThreadSafeType {
        public let identifier: TargetMigrations.Identifier
        public let migration: Migration.Type
        
        public var key: String { identifier.key(with: migration) }
    }
    
    public final class Context {
        let progressUpdater: (String, CGFloat) -> ()
        var currentlyRunningMigration: CurrentlyRunningMigration?
        var observedEvents: [ObservedEvent] = []
        var postCommitActions: [String: () -> Void] = [:]
        
        init(progressUpdater: @escaping (String, CGFloat) -> Void) {
            self.progressUpdater = progressUpdater
        }
        
        // Helper method to add events safely.
        func add(events: [ObservedEvent]) {
            self.observedEvents.append(contentsOf: events)
        }
        
        // Helper method to add actions with deduplication.
        func add(postCommitActions: [String: () -> Void]) {
            self.postCommitActions.merge(postCommitActions, uniquingKeysWith: { (current, _) in current })
        }
    }
    
    @TaskLocal
    public static var current: Context?
    
    public static func updateProgress(_ progress: CGFloat) {
        // In test builds ignore any migration progress updates (we run in a custom database writer anyway)
        guard !SNUtilitiesKit.isRunningTests else { return }
        
        let identifier: String = (MigrationExecution.current?.currentlyRunningMigration?.key ?? "Unknown Migration")
        MigrationExecution.current?.progressUpdater(identifier, progress)
    }
}
