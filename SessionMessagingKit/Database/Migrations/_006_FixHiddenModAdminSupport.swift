// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit

/// This migration fixes an issue where hidden mods/admins weren't getting recognised as mods/admins, it reset's the `info_updates`
/// for open groups so they will fully re-fetch their mod/admin lists
enum _006_FixHiddenModAdminSupport: Migration {
    static let target: TargetMigrations.Identifier = .messagingKit
    static let identifier: String = "FixHiddenModAdminSupport"
    static let minExpectedRunDuration: TimeInterval = 0.01
    static let createdTables: [(TableRecord & FetchableRecord).Type] = []
    
    static func migrate(_ db: ObservingDatabase, using dependencies: Dependencies) throws {
        try db.alter(table: "groupMember") { t in
            t.add(column: "isHidden", .boolean)
                .notNull()
                .defaults(to: false)
        }
        
        // When modifying OpenGroup behaviours we should always look to reset the `infoUpdates`
        // value for all OpenGroups to ensure they all have the correct state for newly
        // added/changed fields
        try db.execute(sql: "UPDATE openGroup SET infoUpdates = 0")
        
        MigrationExecution.updateProgress(1)
    }
}
