// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionNetworkingKit
import SessionUtilitiesKit

/// This migration resets the `lastHash` value for all user config namespaces to force the app to fetch the latest config
/// messages in case there are multi-part config message we had previously seen and failed to merge
enum _024_ResetUserConfigLastHashes: Migration {
    static let identifier: String = "snodeKit.ResetUserConfigLastHashes"
    static let minExpectedRunDuration: TimeInterval = 0.1
    static let createdTables: [(TableRecord & FetchableRecord).Type] = []
    
    static func migrate(_ db: ObservingDatabase, using dependencies: Dependencies) throws {
        try db.execute(literal: """
            DELETE FROM snodeReceivedMessageInfo
            WHERE namespace IN (\(Network.SnodeAPI.Namespace.configContacts.rawValue), \(Network.SnodeAPI.Namespace.configUserProfile.rawValue), \(Network.SnodeAPI.Namespace.configUserGroups.rawValue), \(Network.SnodeAPI.Namespace.configConvoInfoVolatile.rawValue))
        """)
        
        MigrationExecution.updateProgress(1)
    }
}
