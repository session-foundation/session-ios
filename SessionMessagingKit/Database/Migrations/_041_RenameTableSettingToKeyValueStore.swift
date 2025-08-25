// Copyright © 2024 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit

enum _041_RenameTableSettingToKeyValueStore: Migration {
    static let identifier: String = "utilitiesKit.RenameTableSettingToKeyValueStore"
    static let minExpectedRunDuration: TimeInterval = 0.1
    static let createdTables: [(TableRecord & FetchableRecord).Type] = [ KeyValueStore.self ]
    
    static func migrate(_ db: ObservingDatabase, using dependencies: Dependencies) throws {
        try db.rename(table: "setting", to: "keyValueStore")
        
        MigrationExecution.updateProgress(1)
    }
}
