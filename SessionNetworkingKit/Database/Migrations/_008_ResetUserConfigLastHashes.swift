// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit

/// This migration resets the `lastHash` value for all user config namespaces to force the app to fetch the latest config
/// messages in case there are multi-part config message we had previously seen and failed to merge
enum _008_ResetUserConfigLastHashes: Migration {
    static let target: TargetMigrations.Identifier = .networkingKit
    static let identifier: String = "ResetUserConfigLastHashes"
    static let minExpectedRunDuration: TimeInterval = 0.1
    static let createdTables: [(TableRecord & FetchableRecord).Type] = []
    
    static func migrate(_ db: ObservingDatabase, using dependencies: Dependencies) throws {
        try db.execute(literal: """
            DELETE FROM snodeReceivedMessageInfo
            WHERE namespace IN (\(SnodeAPI.Namespace.configContacts.rawValue), \(SnodeAPI.Namespace.configUserProfile.rawValue), \(SnodeAPI.Namespace.configUserGroups.rawValue), \(SnodeAPI.Namespace.configConvoInfoVolatile.rawValue))
        """)
        
        MigrationExecution.updateProgress(1)
    }
}
