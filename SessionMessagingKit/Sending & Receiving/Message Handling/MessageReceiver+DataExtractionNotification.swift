// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionSnodeKit
import SessionUtilitiesKit

extension MessageReceiver {
    internal static func handleDataExtractionNotification(
        _ db: Database,
        threadId: String,
        threadVariant: SessionThread.Variant,
        message: DataExtractionNotification
    ) throws {
        let timestampMs: Int64 = (
            message.sentTimestamp.map { Int64($0) } ??
            SnodeAPI.currentOffsetTimestampMs()
        )
        
        guard
            threadVariant == .contact,
            let sender: String = message.sender,
            let messageKind: DataExtractionNotification.Kind = message.kind
        else { throw MessageReceiverError.invalidMessage }
        
        /// Only process the message if the thread `shouldBeVisible` or it was sent after the libSession buffer period
        guard
            SessionThread
                .filter(id: threadId)
                .filter(SessionThread.Columns.shouldBeVisible == true)
                .isNotEmpty(db) ||
            SessionUtil.conversationInConfig(
                db,
                threadId: threadId,
                threadVariant: threadVariant,
                visibleOnly: true
            ) ||
            SessionUtil.canPerformChange(
                db,
                threadId: threadId,
                targetConfig: {
                    switch threadVariant {
                        case .contact:
                            let currentUserPublicKey: String = getUserHexEncodedPublicKey(db)
                            
                            return (threadId == currentUserPublicKey ? .userProfile : .contacts)
                            
                        default: return .userGroups
                    }
                }(),
                changeTimestampMs: timestampMs
            )
        else { throw MessageReceiverError.outdatedMessage }
        
        _ = try Interaction(
            serverHash: message.serverHash,
            threadId: threadId,
            authorId: sender,
            variant: {
                switch messageKind {
                    case .screenshot: return .infoScreenshotNotification
                    case .mediaSaved: return .infoMediaSavedNotification
                }
            }(),
            timestampMs: timestampMs
        ).inserted(db)
    }
}
