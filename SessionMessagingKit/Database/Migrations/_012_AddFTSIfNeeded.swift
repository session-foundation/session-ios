// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit

/// This migration adds the FTS table back for internal test users whose FTS table was removed unintentionally
enum _012_AddFTSIfNeeded: Migration {
    static let target: TargetMigrations.Identifier = .messagingKit
    static let identifier: String = "AddFTSIfNeeded"
    static let minExpectedRunDuration: TimeInterval = 0.01
    static let createdTables: [(TableRecord & FetchableRecord).Type] = []
    
    static func migrate(_ db: ObservingDatabase, using dependencies: Dependencies) throws {
        // Fix an issue that the fullTextSearchTable was dropped unintentionally and global search won't work.
        // This issue only happens to internal test users.
        if try db.tableExists("interaction_fts") == false {
            try db.create(virtualTable: "interaction_fts", using: FTS5()) { t in
                t.synchronize(withTable: "interaction")
                t.tokenizer = _001_InitialSetupMigration.fullTextSearchTokenizer
                
                t.column("body")
                t.column("threadId")
            }
        }
        
        MigrationExecution.updateProgress(1)
    }
}
