// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit

enum _018_GroupsRebuildChanges: Migration {
    static let target: TargetMigrations.Identifier = .messagingKit
    static let identifier: String = "GroupsRebuildChanges"  // stringlint:disable
    static let needsConfigSync: Bool = false
    static let minExpectedRunDuration: TimeInterval = 0.1
    static var requirements: [MigrationRequirement] = [.sessionUtilStateLoaded]
    static var fetchedTables: [(FetchableRecord & TableRecord).Type] = [Identity.self]
    static var createdOrAlteredTables: [(FetchableRecord & TableRecord).Type] = [
        ClosedGroup.self, GroupMember.self
    ]
    
    static func migrate(_ db: Database, using dependencies: Dependencies) throws {
        try db.alter(table: ClosedGroup.self) { t in
            t.add(.groupDescription, .text)
            t.add(.displayPictureUrl, .text)
            t.add(.displayPictureFilename, .text)
            t.add(.displayPictureEncryptionKey, .blob)
            t.add(.lastDisplayPictureUpdate, .integer).defaults(to: 0)
            t.add(.shouldPoll, .boolean).defaults(to: false)
            t.add(.groupIdentityPrivateKey, .blob)
            t.add(.authData, .blob)
            t.add(.invited, .boolean).defaults(to: false)
        }
        
        try db.alter(table: GroupMember.self) { t in
            t.add(.roleStatus, .integer)
                .notNull()
                .defaults(to: GroupMember.RoleStatus.accepted)
        }
        
        // Update existing groups where the current user is a member to have `shouldPoll` as `true`
        try ClosedGroup
            .joining(
                required: ClosedGroup.members
                    .filter(GroupMember.Columns.profileId == getUserSessionId(db, using: dependencies).hexString)
            )
            .updateAll(
                db,
                ClosedGroup.Columns.shouldPoll.set(to: true)
            )
        
        Storage.update(progress: 1, for: self, in: target, using: dependencies)
    }
}

