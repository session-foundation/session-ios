// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit

extension MessageReceiver {
    internal static func handleTypingIndicator(
        _ db: Database,
        threadId: String,
        threadVariant: SessionThread.Variant,
        message: TypingIndicator
    ) throws {
        guard let thread: SessionThread = try SessionThread.fetchOne(db, id: threadId) else { return }
        
        switch message.kind {
            case .started:
                let needsToStartTypingIndicator: Bool = TypingIndicators.didStartTypingNeedsToStart(
                    threadId: threadId,
                    threadVariant: threadVariant,
                    threadIsMessageRequest: thread.isMessageRequest(db),
                    direction: .incoming,
                    timestampMs: message.sentTimestamp.map { Int64($0) }
                )
                
                if needsToStartTypingIndicator {
                    TypingIndicators.start(db, threadId: thread.id, direction: .incoming)
                }
                
            case .stopped:
                TypingIndicators.didStopTyping(db, threadId: thread.id, direction: .incoming)
            
            default:
                SNLog("Unknown TypingIndicator Kind ignored")
                return
        }
    }
}
