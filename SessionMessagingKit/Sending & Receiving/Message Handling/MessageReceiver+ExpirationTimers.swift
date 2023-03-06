// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit

extension MessageReceiver {
    internal static func handleExpirationTimerUpdate(
        _ db: Database,
        threadId: String,
        threadVariant: SessionThread.Variant,
        message: ExpirationTimerUpdate
    ) throws {
        guard
            // Only process these for contact and legacy groups (new groups handle it separately)
            (threadVariant == .contact || threadVariant == .legacyGroup),
            let sender: String = message.sender
        else { return }
        
        // Update the configuration
        //
        // Note: Messages which had been sent during the previous configuration will still
        // use it's settings (so if you enable, send a message and then disable disappearing
        // message then the message you had sent will still disappear)
        let config: DisappearingMessagesConfiguration = try DisappearingMessagesConfiguration
            .filter(id: threadId)
            .fetchOne(db)
            .defaulting(to: DisappearingMessagesConfiguration.defaultWith(threadId))
            .with(
                // If there is no duration then we should disable the expiration timer
                isEnabled: ((message.duration ?? 0) > 0),
                durationSeconds: (
                    message.duration.map { TimeInterval($0) } ??
                    DisappearingMessagesConfiguration.defaultDuration
                )
            )
        
        // Legacy closed groups need to update the SessionUtil
        switch threadVariant {
            case .legacyGroup:
                try SessionUtil
                    .update(
                        db,
                        groupPublicKey: threadId,
                        disappearingConfig: config
                    )
                
            default: break
        }
        
        // Add an info message for the user
        _ = try Interaction(
            serverHash: nil, // Intentionally null so sync messages are seen as duplicates
            threadId: threadId,
            authorId: sender,
            variant: .infoDisappearingMessagesUpdate,
            body: config.messageInfoString(
                with: (sender != getUserHexEncodedPublicKey(db) ?
                    Profile.displayName(db, id: sender) :
                    nil
                )
            ),
            timestampMs: Int64(message.sentTimestamp ?? 0)   // Default to `0` if not set
        ).inserted(db)
        
        // Finally save the changes to the DisappearingMessagesConfiguration (If it's a duplicate
        // then the interaction unique constraint will prevent the code from getting here)
        try config.save(db)
    }
}
