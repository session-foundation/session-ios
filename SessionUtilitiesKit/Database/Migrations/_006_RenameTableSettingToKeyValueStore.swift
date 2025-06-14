// Copyright © 2024 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB

enum _006_RenameTableSettingToKeyValueStore: Migration {
    static let target: TargetMigrations.Identifier = .utilitiesKit
    static let identifier: String = "RenameTableSettingToKeyValueStore" // stringlint:disable
    static let minExpectedRunDuration: TimeInterval = 0.1
    static let createdTables: [(TableRecord & FetchableRecord).Type] = [ KeyValueStore.self ]
    
    static func migrate(_ db: Database, using dependencies: Dependencies) throws {
        try db.rename(table: "setting", to: "keyValueStore")
        
        Storage.update(progress: 1, for: self, in: target, using: dependencies)
    }
}
