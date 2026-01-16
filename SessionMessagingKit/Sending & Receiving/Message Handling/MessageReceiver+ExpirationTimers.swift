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
        decodedMessage: DecodedMessage,
        serverExpirationTimestamp: TimeInterval?,
        using dependencies: Dependencies
    ) throws -> InsertedInteractionInfo? {
        let proto: SNProtoContent = try decodedMessage.decodeProtoContent()
        
        guard proto.hasExpirationType || proto.hasExpirationTimer else {
            throw MessageError.invalidMessage("Message missing required fields")
        }
        guard threadVariant == .contact else { throw MessageError.invalidMessage("Message type should be handled by config change") }
        
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
            authorId: decodedMessage.sender.hexString,
            timestampMs: decodedMessage.sentTimestampMs,
            serverHash: message.serverHash,
            serverExpirationTimestamp: serverExpirationTimestamp,
            using: dependencies
        )
    }
    
    public static func updateContactDisappearingMessagesVersionIfNeeded(
        _ db: ObservingDatabase,
        messageVariant: Message.Variant?,
        contactId: String?,
        decodedMessage: DecodedMessage,
        using dependencies: Dependencies
    ) {
        guard
            let messageVariant: Message.Variant = messageVariant,
            let contactId: String = contactId,
            [ .visibleMessage, .expirationTimerUpdate ].contains(messageVariant),
            let proto: SNProtoContent = try? decodedMessage.decodeProtoContent()
        else { return }
        
        let version: FeatureVersion = ((!proto.hasExpirationType && !proto.hasExpirationTimer) ?
            .legacyDisappearingMessages :
            .newDisappearingMessages
        )
        
        _ = try? Contact
            .filter(id: contactId)
            .updateAllAndConfig(
                db,
                Contact.Columns.lastKnownClientVersion.set(to: version),
                using: dependencies
            )
    }
}
