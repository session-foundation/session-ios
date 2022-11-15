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
            guard let disappearingMessageConfiguration = try? DisappearingMessagesConfiguration.fetchOne(db, id: syncTarget) else { return }
            expiries.forEach { syncExpiry in
                let startedAtMs: Double = Double(syncExpiry.expirationTimestamp) - disappearingMessageConfiguration.durationSeconds * 1000
                
                let changeCount: Int? = try? Interaction
                    .filter(
                        Interaction.Columns.threadId == syncTarget &&
                        Interaction.Columns.serverHash == syncExpiry.serverHash
                    )
                    .updateAll(db, Interaction.Columns.expiresStartedAtMs.set(to: startedAtMs))
            }
        }
    }
}
