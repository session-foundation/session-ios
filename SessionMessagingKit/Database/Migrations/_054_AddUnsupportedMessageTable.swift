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
            t.column("sender", .text)
            t.column("sent_timestamp_ms", .integer)
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
        
        /// A running total kept exact by triggers, so enforcing the retention limits on every insert doesn't need to scan the
        /// table (a flood of small rows would otherwise make each insert slower than the last)
        ///
        /// **Note:** Each row costs `length(data) + 256` against the byte budget, as a tiny row still takes up space on disk
        try db.execute(sql: """
            CREATE INDEX unsupported_message_kind_id ON unsupported_message(kind, id);
            
            CREATE TABLE unsupported_message_stats (
                id INTEGER PRIMARY KEY CHECK (id = 1),
                total_bytes INTEGER NOT NULL DEFAULT 0,
                newer_format_count INTEGER NOT NULL DEFAULT 0
            );
            INSERT INTO unsupported_message_stats (id, total_bytes, newer_format_count) VALUES (1, 0, 0);
            
            CREATE TRIGGER unsupported_message_stats_insert AFTER INSERT ON unsupported_message BEGIN
                UPDATE unsupported_message_stats SET
                    total_bytes = total_bytes + length(NEW.data) + 256,
                    newer_format_count = newer_format_count + (NEW.kind = 'newerFormat')
                WHERE id = 1;
            END;
            
            CREATE TRIGGER unsupported_message_stats_delete AFTER DELETE ON unsupported_message BEGIN
                UPDATE unsupported_message_stats SET
                    total_bytes = total_bytes - length(OLD.data) - 256,
                    newer_format_count = newer_format_count - (OLD.kind = 'newerFormat')
                WHERE id = 1;
            END;
            
            CREATE TRIGGER unsupported_message_stats_update AFTER UPDATE OF data, kind ON unsupported_message BEGIN
                UPDATE unsupported_message_stats SET
                    total_bytes = total_bytes - length(OLD.data) + length(NEW.data),
                    newer_format_count = newer_format_count - (OLD.kind = 'newerFormat') + (NEW.kind = 'newerFormat')
                WHERE id = 1;
            END;
        """)

        MigrationExecution.updateProgress(1)
    }
}
