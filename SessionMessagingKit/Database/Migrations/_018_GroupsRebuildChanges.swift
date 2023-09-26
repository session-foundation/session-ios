// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit

enum _018_GroupsRebuildChanges: Migration {
    static let target: TargetMigrations.Identifier = .messagingKit
    static let identifier: String = "GroupsRebuildChanges"
    static let needsConfigSync: Bool = false
    static let minExpectedRunDuration: TimeInterval = 0.1
    static var requirements: [MigrationRequirement] = [.sessionUtilStateLoaded]
    
    static func migrate(_ db: Database, using dependencies: Dependencies) throws {
        try db.alter(table: ClosedGroup.self) { t in
            t.add(.displayPictureUrl, .text)
            t.add(.displayPictureFilename, .text)
            t.add(.displayPictureEncryptionKey, .blob)
            t.add(.lastDisplayPictureUpdate, .integer)
                .notNull()
                .defaults(to: 0)
            t.add(.groupIdentityPrivateKey, .blob)
            t.add(.authData, .blob)
            t.add(.invited, .boolean)
                .notNull()
                .defaults(to: false)
        }
        
        Storage.update(progress: 1, for: self, in: target, using: dependencies)
    }
}

