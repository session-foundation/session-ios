// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit

extension MessageReceiver {
    internal static func handleExpirationTimerUpdate(_ db: Database, message: ExpirationTimerUpdate) throws {
        // Get the target thread
        guard
            !DisappearingMessagesConfiguration.isNewConfigurationEnabled,
            let targetId: String = MessageReceiver.threadInfo(db, message: message, openGroupId: nil)?.id,
            let sender: String = message.sender,
            let thread: SessionThread = try? SessionThread.fetchOne(db, id: targetId)
        else { return }
        
        // Update the configuration
        //
        // Note: Messages which had been sent during the previous configuration will still
        // use it's settings (so if you enable, send a message and then disable disappearing
        // message then the message you had sent will still disappear)
        
        let defaultType: DisappearingMessagesConfiguration.DisappearingMessageType? = {
            switch thread.variant {
                case .contact:
                    if thread.id == getUserHexEncodedPublicKey() { fallthrough }
                    return .disappearAfterRead
                case .closedGroup:
                    return .disappearAfterSend
                case .openGroup:
                    return nil // Shouldn't happen
            }
        }()
        
        let localConfig: DisappearingMessagesConfiguration = try thread.disappearingMessagesConfiguration
            .fetchOne(db)
            .defaulting(to: DisappearingMessagesConfiguration.defaultWith(thread.id))
        
        let remoteConfig: DisappearingMessagesConfiguration = localConfig.with(
            // If there is no duration then we should disable the expiration timer
            isEnabled: ((message.duration ?? 0) > 0),
            durationSeconds: (
                message.duration.map { TimeInterval($0) } ??
                DisappearingMessagesConfiguration.defaultDuration
            ),
            type: defaultType
        )
        
        try remoteConfig.save(db)
        
        // Remove previous info messages
        _ = try Interaction
            .filter(Interaction.Columns.threadId == thread.id)
            .filter(Interaction.Columns.variant == Interaction.Variant.infoDisappearingMessagesUpdate)
            .deleteAll(db)
        
        // Add an info message for the user
        _ = try Interaction(
            serverHash: nil, // Intentionally null so sync messages are seen as duplicates
            threadId: thread.id,
            authorId: sender,
            variant: .infoDisappearingMessagesUpdate,
            body: remoteConfig.messageInfoString(
                with: (sender != getUserHexEncodedPublicKey(db) ?
                    Profile.displayName(db, id: sender) :
                    nil
                ),
                isPreviousOff: false
            ),
            timestampMs: Int64(message.sentTimestamp ?? 0),   // Default to `0` if not set
            expiresInSeconds: remoteConfig.isEnabled ? nil : localConfig.durationSeconds
        ).inserted(db)
    }
}
