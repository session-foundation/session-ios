// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import Sodium
import SessionUtilitiesKit
import SessionSnodeKit

extension MessageReceiver {
    
    // MARK: - Specific Handling
    
    private static func handleNewClosedGroup(
        _ db: Database,
        message: ClosedGroupControlMessage,
        using dependencies: Dependencies
    ) throws {
    }
    
    internal static func handleNewGroup(
        _ db: Database,
        groupSessionId: String,
        groupIdentityPrivateKey: Data?,
        name: String?,
        authData: Data?,
        joinedAt: Int64,
        invited: Bool,
        calledFromConfigHandling: Bool,
        using dependencies: Dependencies
    ) throws {
        
        // Create the group
        let thread: SessionThread = try SessionThread
            .fetchOrCreate(db, id: groupSessionId, variant: .group, shouldBeVisible: true)
        let closedGroup: ClosedGroup = try ClosedGroup(
            threadId: groupSessionId,
            name: (name ?? "GROUP_TITLE_FALLBACK".localized()),
            formationTimestamp: TimeInterval(joinedAt),
            shouldPoll: false,
            groupIdentityPrivateKey: groupIdentityPrivateKey,
            authData: authData,
            invited: invited
        ).saved(db)
        
        if !calledFromConfigHandling {
            // Update libSession
            try? SessionUtil.add(
                db,
                groupSessionId: groupSessionId,
                groupIdentityPrivateKey: groupIdentityPrivateKey,
                name: name,
                authData: authData,
                joinedAt: joinedAt,
                invited: invited,
                using: dependencies
            )
        }
        
        // If the group is not in the invite state then handle the approval process
        guard !invited else { return }
        
        try ClosedGroup.approveGroup(
            db,
            group: closedGroup,
            calledFromConfigHandling: calledFromConfigHandling,
            using: dependencies
        )
    }
}
