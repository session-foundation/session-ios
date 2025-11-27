// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit

enum _048_SessionProChanges: Migration {
    static let identifier: String = "SessionProChanges"
    static let minExpectedRunDuration: TimeInterval = 0.1
    static var createdTables: [(FetchableRecord & TableRecord).Type] = []
    
    static func migrate(_ db: ObservingDatabase, using dependencies: Dependencies) throws {
        try db.alter(table: "interaction") { t in
            t.drop(column: "isProMessage")
            t.add(column: "proMessageFeatures", .integer).defaults(to: 0)
            t.add(column: "proProfileFeatures", .integer).defaults(to: 0)
        }
        
        try db.alter(table: "profile") { t in
            t.add(column: "proFeatures", .integer).defaults(to: 0)
            t.add(column: "proExpiryUnixTimestampMs", .integer).defaults(to: 0)
            t.add(column: "proGenIndexHashHex", .text)
        }
        
        MigrationExecution.updateProgress(1)
    }
}
