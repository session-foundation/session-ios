// Copyright © 2026 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit

enum _049_JobRunnerRefactorChanges: Migration {
    static let identifier: String = "JobRunnerRefactorChanges"
    static let minExpectedRunDuration: TimeInterval = 0.1
    static var createdTables: [(FetchableRecord & TableRecord).Type] = []
    
    static func migrate(_ db: ObservingDatabase, using dependencies: Dependencies) throws {
        /// Drop old "standard" jobs (we now explicitly add them on startup)
        try db.execute(literal: """
            DELETE FROM job
            WHERE (
                behaviour = \(LegacyBehaviour.recurringOnLaunch) OR
                behaviour = \(LegacyBehaviour.recurringOnActive)
            )
        """)
        try db.execute(literal: """
            DELETE FROM job
            WHERE variant = \(Job.Variant.checkForAppUpdates.rawValue)
        """)
        
        /// Retrieve any jobs that have the `nextRunTimestamp` set
        let existingTimestampDependantJobs: [Row] = try Row.fetchAll(db, sql: """
            SELECT id, nextRunTimestamp
            FROM job
            WHERE nextRunTimestamp > 0
        """)
        
        /// Retrieve any jobs that have the `runOnceAfterConfigSyncIgnoringPermanentFailure` behaviour
        let existingConfigSyncDependantJobs: [Row] = try Row.fetchAll(db, sql: """
            SELECT id, threadId
            FROM job
            WHERE behaviour = \(LegacyBehaviour.runOnceAfterConfigSyncIgnoringPermanentFailure.rawValue)
        """)
        
        /// Drop columns and indexes which are no longer used
        try db.execute(literal: """
            DROP INDEX job_on_variant;
            DROP INDEX job_on_behaviour;
            DROP INDEX job_on_shouldBlock;
            DROP INDEX job_on_nextRunTimestamp;
        """)
        try db.alter(table: "job") { t in
            t.drop(column: "priority")
            t.drop(column: "behaviour")
            t.drop(column: "shouldBlock")
            t.drop(column: "shouldSkipLaunchBecomeActive")
            t.drop(column: "nextRunTimestamp")
            t.drop(column: "uniqueHashValue")
        }
        
        try db.create(table: "jobDependency") { t in
            t.column("jobId", .integer)
                .notNull()
                .indexed()                                            // Quicker querying
                .references("job", onDelete: .cascade)                // Delete if Job deleted
            t.column("variant", .integer)
                .notNull()
                .indexed()                                            // Quicker querying
            t.column("otherJobId", .integer)
                .indexed()                                            // Quicker querying
                .references("job", onDelete: .setNull)                // Delete if Job deleted
            t.column("timestamp", .double)
            t.column("threadId", .text)
        }
        
        /// Copy any existing dependencies across
        try db.execute(
            sql: """
                INSERT INTO jobDependency
                SELECT
                    jobId,
                    ? AS variant,
                    dependantId AS otherJobId,
                    NULL AS timestamp,
                    NULL AS threadId
                FROM jobDependencies
            """,
            arguments: [
                0   /// The value for `JobDependency.Variant.job`
            ]
        )
        
        try db.drop(table: "jobDependencies")
        
        /// Add `timestamp` dependencies for the `existingTimestampDependantJobs`
        for jobRow in existingTimestampDependantJobs {
            guard
                let id: Int64 = jobRow["id"] as? Int64,
                let nextRunTimestamp: TimeInterval = jobRow["nextRunTimestamp"] as? TimeInterval
            else { continue }
            
            try db.execute(
                sql: """
                    INSERT INTO jobDependency (
                        jobId,
                        variant,
                        otherJobId,
                        timestamp,
                        threadId
                    )
                    VALUES (?, ?, ?, ?, ?)
                """,
                arguments: [
                    id,
                    1,  /// The value for `JobDependency.Variant.configSync`
                    nil,
                    nextRunTimestamp,
                    nil
                ]
            )
        }
        
        /// Add `configSync` dependencies for the `existingConfigSyncDependantJobs`
        for jobRow in existingConfigSyncDependantJobs {
            guard
                let id: Int64 = jobRow["id"] as? Int64,
                let threadId: String = jobRow["threadId"] as? String
            else { continue }
            
            try db.execute(
                sql: """
                    INSERT INTO jobDependency (
                        jobId,
                        variant,
                        otherJobId,
                        timestamp,
                        threadId
                    )
                    VALUES (?, ?, ?, ?, ?)
                """,
                arguments: [
                    id,
                    2,  /// The value for `JobDependency.Variant.configSync`
                    nil,
                    nil,
                    threadId
                ]
            )
        }
        
        MigrationExecution.updateProgress(1)
    }
}

private extension _049_JobRunnerRefactorChanges {
    enum LegacyBehaviour: Int, Codable, DatabaseValueConvertible {
        case runOnce
        case runOnceNextLaunch
        case recurring
        case recurringOnLaunch
        case recurringOnActive
        case runOnceAfterConfigSyncIgnoringPermanentFailure
    }
}
