// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit

/// This migration adds a flag indicating whether a profile has indicated it is blocking community message requests
enum _015_BlockCommunityMessageRequests: Migration {
    static let target: TargetMigrations.Identifier = .messagingKit
    static let identifier: String = "BlockCommunityMessageRequests"
    static let needsConfigSync: Bool = false
    static let minExpectedRunDuration: TimeInterval = 0.01
    
    static func migrate(_ db: Database) throws {
        // Add the new 'Profile' properties
        try db.alter(table: Profile.self) { t in
            t.add(.blocksCommunityMessageRequests, .boolean)
            t.add(.lastBlocksCommunityMessageRequests, .integer)
                .notNull()
                .defaults(to: 0)
        }
        
        // If the user exists and the 'checkForCommunityMessageRequests' hasn't already been set then default it to "false"
        if
            Identity.userExists(db),
            (try Setting.exists(db, id: Setting.BoolKey.checkForCommunityMessageRequests.rawValue)) == false
        {
            db[.checkForCommunityMessageRequests] = true
        }
        
        Storage.update(progress: 1, for: self, in: target) // In case this is the last migration
    }
}
