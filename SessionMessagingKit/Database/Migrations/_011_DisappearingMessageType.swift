// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit

enum _011_DisappearingMessageType: Migration {
    static let target: TargetMigrations.Identifier = .messagingKit
    static let identifier: String = "DisappearingMessageType"
    static let needsConfigSync: Bool = false
    static let minExpectedRunDuration: TimeInterval = 0.1
    
    static func migrate(_ db: GRDB.Database) throws {
//        try db.alter(table: DisappearingMessagesConfiguration.self) { t in
//            t.add(.permissions, .integer)
//                .defaults(to: OpenGroup.Permissions.all)
//        }
        
        Storage.update(progress: 1, for: self, in: target) // In case this is the last migration
    }
}

