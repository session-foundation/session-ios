// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit

/// This migration recreates the interaction FTS table and adds the threadId so we can do a performant in-conversation
/// searh (currently it's much slower than the global search)
enum _019_AddThreadIdToFTS: Migration {
    static let identifier: String = "messagingKit.AddThreadIdToFTS"
    static let minExpectedRunDuration: TimeInterval = 3
    static let createdTables: [(TableRecord & FetchableRecord).Type] = []
    
    static func migrate(_ db: ObservingDatabase, using dependencies: Dependencies) throws {
        // Can't actually alter a virtual table in SQLite so we need to drop and recreate it,
        // luckily this is actually pretty quick
        if try db.tableExists("interaction_fts") {
            try db.drop(table: "interaction_fts")
            try db.dropFTS5SynchronizationTriggers(forTable: "interaction_fts")
        }
        
        try db.create(virtualTable: "interaction_fts", using: FTS5()) { t in
            t.synchronize(withTable: "interaction")
            t.tokenizer = _006_SMK_InitialSetupMigration.fullTextSearchTokenizer

            t.column("body")
            t.column("threadId")
        }
        
        MigrationExecution.updateProgress(1)
    }
}
