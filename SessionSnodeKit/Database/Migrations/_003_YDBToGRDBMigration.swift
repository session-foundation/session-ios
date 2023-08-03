// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit

enum _003_YDBToGRDBMigration: Migration {
    static let target: TargetMigrations.Identifier = .snodeKit
    static let identifier: String = "YDBToGRDBMigration"
    static let needsConfigSync: Bool = false
    static let minExpectedRunDuration: TimeInterval = 0.1
    
    static func migrate(_ db: Database) throws {
        guard !SNUtilitiesKit.isRunningTests else { return Storage.update(progress: 1, for: self, in: target) }
        
        SNLogNotTests("[Migration Error] Attempted to perform legacy migation")
        throw StorageError.migrationNoLongerSupported
    }
}
