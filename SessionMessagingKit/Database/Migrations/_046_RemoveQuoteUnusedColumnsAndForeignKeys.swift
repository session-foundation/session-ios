// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit

enum _046_RemoveQuoteUnusedColumnsAndForeignKeys: Migration {
    static let identifier: String = "RemoveQuoteUnusedColumnsAndForeignKeys"
    static let minExpectedRunDuration: TimeInterval = 0.1
    static var createdTables: [(FetchableRecord & TableRecord).Type] = []
    
    static func migrate(_ db: ObservingDatabase, using dependencies: Dependencies) throws {
        // SQLite doesn't support adding a new primary key after creation so we need to create a new table with
        // the setup we want, copy data from the old table over, drop the old table and rename the new table
        try db.create(table: "tmpQuote") { t in
            t.column("interactionId", .integer)
                .notNull()
                .primaryKey()
                .references("interaction", onDelete: .cascade)        // Delete if interaction deleted
            t.column("authorId", .text).notNull()
            t.column("timestampMs", .double).notNull()
        }
        
        // Insert into the new table, drop the old table and rename the new table to be the old one
        try db.execute(literal: """
            INSERT INTO tmpQuote
            SELECT interactionId, authorId, timestampMs
            FROM quote
        """)
        
        try db.drop(table: "quote")
        try db.rename(table: "tmpQuote", to: "quote")
        
        // Need to create the indexes separately from creating 'tmpQuote' to ensure they have the
        // correct names
        try db.create(indexOn: "quote", columns: ["authorId", "timestampMs"])
        
        MigrationExecution.updateProgress(1)
    }
}
