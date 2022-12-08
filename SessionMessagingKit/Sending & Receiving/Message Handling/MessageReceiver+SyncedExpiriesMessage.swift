// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SignalCoreKit
import SessionUtilitiesKit

extension MessageReceiver {
    internal static func handleSyncedExpiriesMessage(
        _ db: Database,
        message: SyncedExpiriesMessage,
        dependencies: SMKDependencies
    ) throws {
        let userPublicKey: String = getUserHexEncodedPublicKey(db, dependencies: dependencies)
        guard userPublicKey == message.sender else { return }
        
        message.conversationExpiries.forEach { (syncTarget, expiries) in
            expiries.forEach { syncExpiry in
                guard
                    let interaction = try? Interaction.filter(
                        Interaction.Columns.threadId == syncTarget &&
                        Interaction.Columns.serverHash == syncExpiry.serverHash
                    ).fetchOne(db),
                    let durationSeconds = interaction.expiresInSeconds
                else { return }
                
                try? interaction.with(
                    wasRead: true,
                    expiresStartedAtMs: Double(syncExpiry.expirationTimestamp) - durationSeconds * 1000
                ).update(db)
            }
        }
    }
}
