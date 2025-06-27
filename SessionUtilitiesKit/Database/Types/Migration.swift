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
            storage?.willStartMigration(db, self, targetIdentifier)
            defer { storage?.didCompleteMigration() }
            
            try migrate(db, using: dependencies)
            Log.info(.migration, "Completed \(targetIdentifier.key(with: self))")
        }
    }
}
