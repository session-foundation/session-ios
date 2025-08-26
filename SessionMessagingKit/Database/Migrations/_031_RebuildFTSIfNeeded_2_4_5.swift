// Copyright © 2024 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import GRDB
import SessionUtilitiesKit

/// This migration adds the FTS table back if either the tables or any of the triggers no longer exist
enum _031_RebuildFTSIfNeeded_2_4_5: Migration {
    static let identifier: String = "messagingKit.RebuildFTSIfNeeded_2_4_5"
    static let minExpectedRunDuration: TimeInterval = 0.01
    static let createdTables: [(TableRecord & FetchableRecord).Type] = []
    
    static func migrate(_ db: ObservingDatabase, using dependencies: Dependencies) throws {
        func ftsIsValid(_ db: ObservingDatabase, _ tableName: String) -> Bool {
            return (
                ((try? db.tableExists(tableName)) == true) &&            // Table itself
                ((try? db.triggerExists("__\(tableName)_ai")) == true) &&  // Insert trigger
                ((try? db.triggerExists("__\(tableName)_au")) == true) &&  // Update trigger
                ((try? db.triggerExists("__\(tableName)_ad")) == true)     // Delete trigger
            )
        }

        // Recreate the interaction FTS if needed
        if !ftsIsValid(db, "interaction_fts") {
            try db.execute(sql: "DROP TABLE IF EXISTS 'interaction_fts'")
            try db.dropFTS5SynchronizationTriggers(forTable: "interaction_fts")
            
            try db.create(virtualTable: "interaction_fts", using: FTS5()) { t in
                t.synchronize(withTable: "interaction")
                t.tokenizer = _006_SMK_InitialSetupMigration.fullTextSearchTokenizer
                
                t.column("body")
                t.column("threadId")
            }
        }
        
        // Recreate the profile FTS if needed
        if !ftsIsValid(db, "profile_fts") {
            try db.execute(sql: "DROP TABLE IF EXISTS 'profile_fts'")
            try db.dropFTS5SynchronizationTriggers(forTable: "profile_fts")
            
            try db.create(virtualTable: "profile_fts", using: FTS5()) { t in
                t.synchronize(withTable: "profile")
                t.tokenizer = _006_SMK_InitialSetupMigration.fullTextSearchTokenizer
                
                t.column("nickname")
                t.column("name")
            }
        }
        
        // Recreate the closedGroup FTS if needed
        if !ftsIsValid(db, "closedGroup_fts") {
            try db.execute(sql: "DROP TABLE IF EXISTS 'closedGroup_fts'")
            try db.dropFTS5SynchronizationTriggers(forTable: "closedGroup_fts")
            
            try db.create(virtualTable: "closedGroup_fts", using: FTS5()) { t in
                t.synchronize(withTable: "closedGroup")
                t.tokenizer = _006_SMK_InitialSetupMigration.fullTextSearchTokenizer
                
                t.column("name")
            }
        }
        
        // Recreate the openGroup FTS if needed
        if !ftsIsValid(db, "openGroup_fts") {
            try db.execute(sql: "DROP TABLE IF EXISTS 'openGroup_fts'")
            try db.dropFTS5SynchronizationTriggers(forTable: "openGroup_fts")
            
            try db.create(virtualTable: "openGroup_fts", using: FTS5()) { t in
                t.synchronize(withTable: "openGroup")
                t.tokenizer = _006_SMK_InitialSetupMigration.fullTextSearchTokenizer
                
                t.column("name")
            }
        }
        
        MigrationExecution.updateProgress(1)
    }
}
