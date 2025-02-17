// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit

/// This migration fixes a bug where certain message variants could incorrectly be counted as unread messages
enum _005_FixDeletedMessageReadState: Migration {
    static let target: TargetMigrations.Identifier = .messagingKit
    static let identifier: String = "FixDeletedMessageReadState"
    static let minExpectedRunDuration: TimeInterval = 0.01
    static let fetchedTables: [(TableRecord & FetchableRecord).Type] = []
    static let createdOrAlteredTables: [(TableRecord & FetchableRecord).Type] = []
    static let droppedTables: [(TableRecord & FetchableRecord).Type] = []
    
    static func migrate(_ db: Database, using dependencies: Dependencies) throws {
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
        
        Storage.update(progress: 1, for: self, in: target, using: dependencies)
    }
}
