// Copyright © 2024 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit

enum _020_AddMissingWhisperFlag: Migration {
    static let target: TargetMigrations.Identifier = .messagingKit
    static let identifier: String = "AddMissingWhisperFlag"
    static let minExpectedRunDuration: TimeInterval = 0.1
    static let createdTables: [(TableRecord & FetchableRecord).Type] = []
    
    static func migrate(_ db: ObservingDatabase, using dependencies: Dependencies) throws {
        /// We should have had this column from the very beginning but it was missed, so add it in now for when we eventually
        /// support whispers in Community conversations
        try db.alter(table: "interaction") { t in
            t.add(column: "openGroupWhisper", .boolean)
                .notNull()
                .defaults(to: false)
        }
        
        MigrationExecution.updateProgress(1)
    }
}
