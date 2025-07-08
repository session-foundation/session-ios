// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:ignore

import Foundation
import GRDB

enum _001_InitialSetupMigration: Migration {
    static let target: TargetMigrations.Identifier = .utilitiesKit
    static let identifier: String = "initialSetup"
    static let minExpectedRunDuration: TimeInterval = 0.1
    static let createdTables: [(TableRecord & FetchableRecord).Type] = [
        Identity.self, Job.self, JobDependencies.self
    ]
    
    static func migrate(_ db: ObservingDatabase, using dependencies: Dependencies) throws {
        try db.create(table: "identity") { t in
            t.column("variant", .text)
                .notNull()
                .unique()
                .primaryKey()
            t.column("data", .blob).notNull()
        }
        
        try db.create(table: "job") { t in
            t.column("id", .integer)
                .notNull()
                .primaryKey(autoincrement: true)
            t.column("failureCount", .integer)
                .notNull()
                .defaults(to: 0)
            t.column("variant", .integer)
                .notNull()
                .indexed()                                            // Quicker querying
            t.column("behaviour", .integer)
                .notNull()
                .indexed()                                            // Quicker querying
            t.column("shouldBlock", .boolean)
                .notNull()
                .indexed()                                            // Quicker querying
                .defaults(to: false)
            t.column("shouldSkipLaunchBecomeActive", .boolean)
                .notNull()
                .defaults(to: false)
            t.column("nextRunTimestamp", .double)
                .notNull()
                .indexed()                                            // Quicker querying
                .defaults(to: 0)
            t.column("threadId", .text)
                .indexed()                                            // Quicker querying
            t.column("interactionId", .text)
                .indexed()                                            // Quicker querying
            t.column("details", .blob)
        }
        
        try db.create(table: "jobDependencies") { t in
            t.column("jobId", .integer)
                .notNull()
                .references("job", onDelete: .cascade)                // Delete if Job deleted
            t.column("dependantId", .integer)
                .indexed()                                            // Quicker querying
                .references("job", onDelete: .setNull)                // Delete if Job deleted
            
            t.primaryKey(["jobId", "dependantId"])
        }
        
        try db.create(table: "setting") { t in
            t.column("key", .text)
                .notNull()
                .unique()
                .primaryKey()
            t.column("value", .blob).notNull()
        }
        
        MigrationExecution.updateProgress(1)
    }
}
