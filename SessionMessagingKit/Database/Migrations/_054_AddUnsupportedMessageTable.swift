// Copyright © 2026 Session Technology Foundation. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit

/// Adds the table which retains raw swarm messages this client positively identified but can't process (see
/// `UnsupportedMessageRecord`)
enum _054_AddUnsupportedMessageTable: Migration {
    static let identifier: String = "AddUnsupportedMessageTable"
    static let minExpectedRunDuration: TimeInterval = 0.1
    static var createdTables: [(FetchableRecord & TableRecord).Type] = [
        UnsupportedMessageRecord.self
    ]

    static func migrate(_ db: ObservingDatabase, using dependencies: Dependencies) throws {
        try db.create(table: "unsupported_message") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("kind", .text).notNull()
            t.column("swarm_public_key", .text).notNull()
            t.column("namespace", .integer).notNull()
            t.column("hash", .text)
                .notNull()
                .unique()
            t.column("server_timestamp_ms", .integer).notNull()
            t.column("server_expiry_ms", .integer)
            t.column("data", .blob).notNull()
            t.column("placeholder_message_id", .integer)
                .indexed()
                .references("interaction", onDelete: .cascade)
            t.column("expires_at_ms", .integer).indexed()
            t.column("received_at_ms", .integer).notNull()
            t.column("last_attempt_version", .text).notNull()
        }

        MigrationExecution.updateProgress(1)
    }
}
