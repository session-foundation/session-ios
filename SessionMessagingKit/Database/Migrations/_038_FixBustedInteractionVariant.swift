// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit

/// There was a bug with internal releases of the Groups Rebuild feature where we incorrectly assigned an `Interaction.Variant`
/// value of `3` to deleted message artifacts when it should have been `2`, this migration updates any interactions with a value of `2`
/// to be `3`
enum _038_FixBustedInteractionVariant: Migration {
    static let identifier: String = "messagingKit.FixBustedInteractionVariant"
    static let minExpectedRunDuration: TimeInterval = 0.1
    static var createdTables: [(FetchableRecord & TableRecord).Type] = []
    
    static func migrate(_ db: ObservingDatabase, using dependencies: Dependencies) throws {
        try db.execute(sql: """
            UPDATE interaction
            SET variant = \(Interaction.Variant.standardIncomingDeleted.rawValue)
            WHERE variant = \(Interaction.Variant._legacyStandardIncomingDeleted.rawValue)
        """)
        
        MigrationExecution.updateProgress(1)
    }
}

