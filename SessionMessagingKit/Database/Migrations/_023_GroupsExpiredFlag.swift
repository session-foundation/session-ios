// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import UIKit.UIImage
import GRDB
import SessionSnodeKit
import SessionUtilitiesKit

enum _023_GroupsExpiredFlag: Migration {
    static let target: TargetMigrations.Identifier = .messagingKit
    static let identifier: String = "GroupsExpiredFlag"
    static let minExpectedRunDuration: TimeInterval = 0.1
    static var createdTables: [(FetchableRecord & TableRecord).Type] = []
    
    static func migrate(_ db: Database, using dependencies: Dependencies) throws {
        try db.alter(table: "closedGroup") { t in
            t.add(column: "expired", .boolean).defaults(to: false)
        }
        
        Storage.update(progress: 1, for: self, in: target, using: dependencies)
    }
}

