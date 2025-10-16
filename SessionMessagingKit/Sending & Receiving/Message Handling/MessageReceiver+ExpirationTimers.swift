// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUIKit
import SessionUtilitiesKit

extension MessageReceiver {
    internal static func handleExpirationTimerUpdate(
        _ db: ObservingDatabase,
        threadId: String,
        threadVariant: SessionThread.Variant,
        message: Message,
        serverExpirationTimestamp: TimeInterval?,
        proto: SNProtoContent,
        using dependencies: Dependencies
    ) throws -> InsertedInteractionInfo? {
        guard proto.hasExpirationType || proto.hasExpirationTimer else {
            throw MessageError.invalidMessage("Message missing required fields")
        }
        guard
            threadVariant == .contact,    // Groups are handled via the GROUP_INFO config instead
            let sender: String = message.sender,
            let timestampMs: UInt64 = message.sentTimestampMs
        else { throw MessageError.invalidMessage("Message missing required fields") }
        
        let localConfig: DisappearingMessagesConfiguration = try DisappearingMessagesConfiguration
            .fetchOne(db, id: threadId)
            .defaulting(to: DisappearingMessagesConfiguration.defaultWith(threadId))
        
        let durationSeconds: TimeInterval = (proto.hasExpirationTimer ? TimeInterval(proto.expirationTimer) : 0)
        let disappearingType: DisappearingMessagesConfiguration.DisappearingMessageType? = (proto.hasExpirationType ?
            .init(protoType: proto.expirationType) :
            .unknown
        )
        let updatedConfig: DisappearingMessagesConfiguration = localConfig.with(
            isEnabled: (durationSeconds != 0),
            durationSeconds: durationSeconds,
            type: disappearingType
        )
        
        // Handle Note to Self:
        // We sync disappearing messages config through shared config message only.
        // If the updated config from this message is different from local config,
        // this control message should already be removed.
        if threadId == dependencies[cache: .general].sessionId.hexString && updatedConfig != localConfig {
            throw MessageError.ignorableMessage
        }
        
        return try updatedConfig.insertControlMessage(
            db,
            threadVariant: threadVariant,
            authorId: sender,
            timestampMs: Int64(timestampMs),
            serverHash: message.serverHash,
            serverExpirationTimestamp: serverExpirationTimestamp,
            using: dependencies
        )
    }
    
    public static func updateContactDisappearingMessagesVersionIfNeeded(
        _ db: ObservingDatabase,
        messageVariant: Message.Variant?,
        contactId: String?,
        version: FeatureVersion?,
        using dependencies: Dependencies
    ) {
        guard
            let messageVariant: Message.Variant = messageVariant,
            let contactId: String = contactId,
            let version: FeatureVersion = version
        else { return }
        
        guard [ .visibleMessage, .expirationTimerUpdate ].contains(messageVariant) else { return }
        
        _ = try? Contact
            .filter(id: contactId)
            .updateAllAndConfig(
                db,
                Contact.Columns.lastKnownClientVersion.set(to: version),
                using: dependencies
            )
    }
}
