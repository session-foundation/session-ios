// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import SessionUtilitiesKit
import SessionNetworkingKit

extension MessageReceiver {
    internal static func handleNewLegacyClosedGroup(
        _ db: ObservingDatabase,
        legacyGroupSessionId: String,
        name: String,
        members: [String],
        admins: [String],
        formationTimestampMs: UInt64,
        forceApprove: Bool,
        using dependencies: Dependencies
    ) throws {
        // With new closed groups we only want to create them if the admin creating the closed group is an
        // approved contact (to prevent spam via closed groups getting around message requests if users are
        // on old or modified clients)
        var hasApprovedAdmin: Bool = false

        for adminId in admins {
            if let contact: Contact = try? Contact.fetchOne(db, id: adminId), contact.isApproved {
                hasApprovedAdmin = true
                break
            }
        }

        // If we want to force approve the group (eg. if it came from config handling) then it
        // doesn't matter if we have an approved admin - we should add it regardless
        guard hasApprovedAdmin || forceApprove else { return }

        // Create the group
        _ = try SessionThread.upsert(
            db,
            id: legacyGroupSessionId,
            variant: .legacyGroup,
            values: SessionThread.TargetValues(
                creationDateTimestamp: .setTo((TimeInterval(formationTimestampMs) / 1000)),
                shouldBeVisible: .setTo(true)
            ),
            using: dependencies
        )
        _ = try ClosedGroup(
            threadId: legacyGroupSessionId,
            name: name,
            formationTimestamp: (TimeInterval(formationTimestampMs) / 1000),
            shouldPoll: true,   // Legacy groups should always poll
            invited: false      // Legacy groups are never in the "invite" state
        ).upserted(db)

        // Create the GroupMember records if needed
        try members.forEach { memberId in
            try GroupMember(
                groupId: legacyGroupSessionId,
                profileId: memberId,
                role: .standard,
                roleStatus: .accepted,  // Legacy group members don't have role statuses
                isHidden: false
            ).upsert(db)
        }

        try admins.forEach { adminId in
            try GroupMember(
                groupId: legacyGroupSessionId,
                profileId: adminId,
                role: .admin,
                roleStatus: .accepted,  // Legacy group members don't have role statuses
                isHidden: false
            ).upsert(db)
        }
    }
}
