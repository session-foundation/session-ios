// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit

/// This migration adds a table to track pending read receipts (it's possible to receive a read receipt message before getting the original
/// message due to how one-to-one conversations work, by storing pending read receipts we should be able to prevent this case)
enum _025_AddPendingReadReceipts: Migration {
    static let identifier: String = "messagingKit.AddPendingReadReceipts"
    static let minExpectedRunDuration: TimeInterval = 0.01
    static let createdTables: [(TableRecord & FetchableRecord).Type] = [PendingReadReceipt.self]
    
    static func migrate(_ db: ObservingDatabase, using dependencies: Dependencies) throws {
        try db.create(table: "pendingReadReceipt") { t in
            t.column("threadId", .text)
                .notNull()
                .indexed()                                            // Quicker querying
                .references("thread", onDelete: .cascade)             // Delete if Thread deleted
            t.column("interactionTimestampMs", .integer)
                .notNull()
                .indexed()                                            // Quicker querying
            t.column("readTimestampMs", .integer)
                .notNull()
            t.column("serverExpirationTimestamp", .double)
                .notNull()
            
            t.primaryKey(["threadId", "interactionTimestampMs"])
        }
        
        MigrationExecution.updateProgress(1)
    }
}
