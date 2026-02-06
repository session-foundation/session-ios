// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit

extension MessageReceiver {
    internal static func handleReadReceipt(
        _ db: ObservingDatabase,
        message: ReadReceipt,
        decodedMessage: DecodedMessage,
        serverExpirationTimestamp: TimeInterval?,
        using dependencies: Dependencies
    ) throws {
        guard let timestampMsValues: [Int64] = message.timestamps?.map({ Int64($0) }) else { return }
        guard let readTimestampMs: Int64 = message.receivedTimestampMs.map({ Int64($0) }) else { return }
        
        let pendingTimestampMs: Set<Int64> = try Interaction.markAsRecipientRead(
            db,
            threadId: decodedMessage.sender.hexString,
            timestampMsValues: timestampMsValues,
            readTimestampMs: readTimestampMs,
            using: dependencies
        )
        
        guard !pendingTimestampMs.isEmpty else { return }
        
        // We have some pending read receipts so store them in the database
        try pendingTimestampMs.forEach { timestampMs in
            try PendingReadReceipt(
                threadId: decodedMessage.sender.hexString,
                interactionTimestampMs: timestampMs,
                readTimestampMs: readTimestampMs,
                serverExpirationTimestamp: (serverExpirationTimestamp ?? 0)
            ).upsert(db)
        }
    }
}
