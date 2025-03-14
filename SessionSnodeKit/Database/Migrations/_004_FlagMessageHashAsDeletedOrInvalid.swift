// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit

/// This migration adds a flag to the `SnodeReceivedMessageInfo` so that when deleting interactions we can
/// ignore their hashes when subsequently trying to fetch new messages (which results in the storage server returning
/// messages from the beginning of time)
enum _004_FlagMessageHashAsDeletedOrInvalid: Migration {
    static let target: TargetMigrations.Identifier = .snodeKit
    static let identifier: String = "FlagMessageHashAsDeletedOrInvalid"
    static let minExpectedRunDuration: TimeInterval = 0.2
    static let createdTables: [(TableRecord & FetchableRecord).Type] = []
    
    static func migrate(_ db: Database, using dependencies: Dependencies) throws {
        try db.alter(table: "snodeReceivedMessageInfo") { t in
            t.add(column: "wasDeletedOrInvalid", .boolean)
                .indexed()                                 // Faster querying
        }
        
        Storage.update(progress: 1, for: self, in: target, using: dependencies)
    }
}
