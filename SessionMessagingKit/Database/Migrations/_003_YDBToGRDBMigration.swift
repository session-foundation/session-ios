// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit

// Note: Looks like the oldest iOS device we support (min iOS 13.0) has 2Gb of RAM, processing
// ~250k messages and ~1000 threads seems to take up
enum _003_YDBToGRDBMigration: Migration {
    static let target: TargetMigrations.Identifier = .messagingKit
    static let identifier: String = "YDBToGRDBMigration"
    static let needsConfigSync: Bool = true
    static let minExpectedRunDuration: TimeInterval = 0.1
    
    static func migrate(_ db: Database) throws {
        guard !SNUtilitiesKit.isRunningTests else { return Storage.update(progress: 1, for: self, in: target) }
        SNLogNotTests("[Migration Error] Attempted to perform legacy migation")
        throw StorageError.migrationNoLongerSupported
    }
}
