// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit

enum _045_LastProfileUpdateTimestamp: Migration {
    static let identifier: String = "LastProfileUpdateTimestamp"
    static let minExpectedRunDuration: TimeInterval = 0.1
    static var createdTables: [(FetchableRecord & TableRecord).Type] = []
    
    static func migrate(_ db: ObservingDatabase, using dependencies: Dependencies) throws {
        try db.alter(table: "Profile") { t in
            t.drop(column: "lastNameUpdate")
            t.drop(column: "lastBlocksCommunityMessageRequests")
            t.rename(column: "displayPictureLastUpdated", to: "profileLastUpdated")
        }
        
        MigrationExecution.updateProgress(1)
    }
}
