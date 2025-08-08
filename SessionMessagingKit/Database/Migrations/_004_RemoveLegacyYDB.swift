// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit
import SessionNetworkingKit

/// This migration used to remove the legacy YapDatabase files (the old logic has been removed and is no longer supported so it now does nothing)
enum _004_RemoveLegacyYDB: Migration {
    static let target: TargetMigrations.Identifier = .messagingKit
    static let identifier: String = "RemoveLegacyYDB"
    static let minExpectedRunDuration: TimeInterval = 0.1
    static let createdTables: [(TableRecord & FetchableRecord).Type] = []
    
    static func migrate(_ db: ObservingDatabase, using dependencies: Dependencies) throws {
        MigrationExecution.updateProgress(1)
    }
}
