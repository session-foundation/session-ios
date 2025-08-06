// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionSnodeKit
import SessionUtilitiesKit

extension MessageReceiver {
    internal static func handleDataExtractionNotification(
        _ db: ObservingDatabase,
        threadId: String,
        threadVariant: SessionThread.Variant,
        message: DataExtractionNotification,
        serverExpirationTimestamp: TimeInterval?,
        using dependencies: Dependencies
    ) throws -> InsertedInteractionInfo? {
        guard
            threadVariant == .contact,
            let sender: String = message.sender,
            let messageKind: DataExtractionNotification.Kind = message.kind
        else { throw MessageReceiverError.invalidMessage }
        
        /// We no longer support the old screenshot notification
        guard messageKind != .screenshot else { throw MessageReceiverError.deprecatedMessage }
        
        let timestampMs: Int64 = (
            message.sentTimestampMs.map { Int64($0) } ??
            dependencies[cache: .snodeAPI].currentOffsetTimestampMs()
        )
        
        let wasRead: Bool = dependencies.mutate(cache: .libSession) { cache in
            cache.timestampAlreadyRead(
                threadId: threadId,
                threadVariant: threadVariant,
                timestampMs: timestampMs,
                openGroupUrlInfo: nil
            )
        }
        let messageExpirationInfo: Message.MessageExpirationInfo = Message.getMessageExpirationInfo(
            threadVariant: threadVariant,
            wasRead: wasRead,
            serverExpirationTimestamp: serverExpirationTimestamp,
            expiresInSeconds: message.expiresInSeconds,
            expiresStartedAtMs: message.expiresStartedAtMs,
            using: dependencies
        )
        let interaction: Interaction = try Interaction(
            serverHash: message.serverHash,
            threadId: threadId,
            threadVariant: threadVariant,
            authorId: sender,
            variant: .infoMediaSavedNotification,
            timestampMs: timestampMs,
            wasRead: wasRead,
            expiresInSeconds: messageExpirationInfo.expiresInSeconds,
            expiresStartedAtMs: messageExpirationInfo.expiresStartedAtMs,
            using: dependencies
        )
        .inserted(db)
        
        if messageExpirationInfo.shouldUpdateExpiry {
            Message.updateExpiryForDisappearAfterReadMessages(
                db,
                threadId: threadId,
                threadVariant: threadVariant,
                serverHash: message.serverHash,
                expiresInSeconds: messageExpirationInfo.expiresInSeconds,
                expiresStartedAtMs: messageExpirationInfo.expiresStartedAtMs,
                using: dependencies
            )
        }
        
        return interaction.id.map { (threadId, threadVariant, $0, interaction.variant, wasRead, 0) }
    }
}
