// Copyright © 2024 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit

enum _019_ScheduleAppUpdateCheckJob: Migration {
    static let target: TargetMigrations.Identifier = .messagingKit
    static let identifier: String = "ScheduleAppUpdateCheckJob"
    static let minExpectedRunDuration: TimeInterval = 0.1
    static let createdTables: [(TableRecord & FetchableRecord).Type] = []
    
    static func migrate(_ db: Database, using dependencies: Dependencies) throws {
        try db.execute(sql: """
            INSERT INTO job (variant, behaviour)
            VALUES (\(Job.Variant.checkForAppUpdates.rawValue), \(Job.Behaviour.recurring.rawValue))
        """)
        
        Storage.update(progress: 1, for: self, in: target, using: dependencies)
    }
}
