// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit

extension MessageReceiver {
    internal static func handleTypingIndicator(
        _ db: ObservingDatabase,
        threadId: String,
        threadVariant: SessionThread.Variant,
        message: TypingIndicator,
        using dependencies: Dependencies
    ) throws {
        guard try SessionThread.exists(db, id: threadId) else { return }
        
        switch message.kind {
            case .started:
                Task {
                    await dependencies[singleton: .typingIndicators].startIfNeeded(
                        threadId: threadId,
                        threadVariant: threadVariant,
                        direction: .incoming,
                        timestampMs: message.sentTimestampMs.map { Int64($0) }
                    )
                }
                
            case .stopped:
                Task {
                    await dependencies[singleton: .typingIndicators].didStopTyping(
                        threadId: threadId,
                        direction: .incoming
                    )
                }
            
            default:
                Log.warn(.messageReceiver, "Unknown TypingIndicator Kind ignored")
                return
        }
    }
}
