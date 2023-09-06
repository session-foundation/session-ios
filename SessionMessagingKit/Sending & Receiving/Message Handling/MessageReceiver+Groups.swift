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
        groupIdentityPublicKey: String,
        groupIdentityPrivateKey: Data?,
        name: String?,
        authData: Data?,
        created: Int64,
        approved: Bool,
        calledFromConfigHandling: Bool,
        using dependencies: Dependencies
    ) throws {
        
        // Create the group
        let thread: SessionThread = try SessionThread
            .fetchOrCreate(db, id: groupIdentityPublicKey, variant: .group, shouldBeVisible: true)
        let closedGroup: ClosedGroup = try ClosedGroup(
            threadId: groupIdentityPublicKey,
            name: (name ?? "GROUP_TITLE_FALLBACK".localized()),
            formationTimestamp: TimeInterval(created),
            groupIdentityPrivateKey: groupIdentityPrivateKey,
            authData: authData,
            approved: approved
        ).saved(db)
        
        if !calledFromConfigHandling {
            // Update libSession
            try? SessionUtil.add(
                db,
                groupIdentityPublicKey: groupIdentityPublicKey,
                groupIdentityPrivateKey: groupIdentityPrivateKey,
                name: name,
                authData: authData,
                joinedAt: created,
                approved: approved,
                using: dependencies
            )
        }
        
        // Only start polling and subscribe for PNs if the user has approved the group
        guard approved else { return }
        
        // Start polling
        dependencies[singleton: .closedGroupPoller].startIfNeeded(for: groupIdentityPublicKey, using: dependencies)
        
        // Resubscribe for group push notifications
        let currentUserPublicKey: String = getUserHexEncodedPublicKey(db, using: dependencies)
        
    }
}
