// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit

/// This migration adds a table to track pending read receipts (it's possible to receive a read receipt message before getting the original
/// message due to how one-to-one conversations work, by storing pending read receipts we should be able to prevent this case)
enum _012_AddFTSIfNeeded: Migration {
    static let target: TargetMigrations.Identifier = .messagingKit
    static let identifier: String = "AddFTSIfNeeded"
    static let needsConfigSync: Bool = false
    static let minExpectedRunDuration: TimeInterval = 0.1
    
    static func migrate(_ db: Database) throws {
        // Fix an issue that the fullTextSearchTable was dropped unintentionally and global search won't work.
        // This issue only happens to internal test users.
        if try db.tableExists(Interaction.fullTextSearchTableName) == false {
            try db.create(virtualTable: Interaction.fullTextSearchTableName, using: FTS5()) { t in
                t.synchronize(withTable: Interaction.databaseTableName)
                t.tokenizer = _001_InitialSetupMigration.fullTextSearchTokenizer
                
                t.column(Interaction.Columns.body.name)
                t.column(Interaction.Columns.threadId.name)
            }
        }
        
        Storage.update(progress: 1, for: self, in: target) // In case this is the last migration
    }
}
