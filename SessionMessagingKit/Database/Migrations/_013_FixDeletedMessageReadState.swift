// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit

/// This migration fixes a bug where certain message variants could incorrectly be counted as unread messages
enum _013_FixDeletedMessageReadState: Migration {
    static let identifier: String = "messagingKit.FixDeletedMessageReadState"
    static let minExpectedRunDuration: TimeInterval = 0.01
    static let createdTables: [(TableRecord & FetchableRecord).Type] = []
    
    static func migrate(_ db: ObservingDatabase, using dependencies: Dependencies) throws {
        try db.execute(
            sql: """
                UPDATE interaction
                SET wasRead = true
                WHERE variant IN (?, ?, ?)
            """,
            arguments: [
                Interaction.Variant.standardIncomingDeleted.rawValue,
                Interaction.Variant.standardOutgoing.rawValue,
                Interaction.Variant.infoDisappearingMessagesUpdate.rawValue
            ])
        
        MigrationExecution.updateProgress(1)
    }
}
