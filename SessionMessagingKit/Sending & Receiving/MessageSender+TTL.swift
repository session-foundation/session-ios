// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit

extension MessageSender {
    public static func getSpecifiedTTL(_ db: Database, message: Message, isSyncMessage: Bool) -> UInt64? {
        let threadId: String = {
            if let threadId = message.threadId {
                return threadId
            }
            if let visibleMessage = message as? VisibleMessage, isSyncMessage, let syncTarget = visibleMessage.syncTarget {
                return syncTarget
            }
            return message.recipient!
        }()
        
        guard
            let disappearingMessagesConfiguration = try? DisappearingMessagesConfiguration.fetchOne(db, id: threadId),
            disappearingMessagesConfiguration.isEnabled
        else {
            return nil
        }
        
        guard disappearingMessagesConfiguration.type == .disappearAfterSend || isSyncMessage else {
            return nil
        }
        
        return UInt64(disappearingMessagesConfiguration.durationSeconds) * 1000
    }
}
