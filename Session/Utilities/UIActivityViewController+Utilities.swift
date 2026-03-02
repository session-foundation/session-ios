// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import SessionMessagingKit
import SessionUtilitiesKit

public extension UIActivityViewController {
    static func notifyIfNeeded(_ success: Bool, using dependencies: Dependencies) {
        if success {
            if let threadId: String = dependencies[defaults: .appGroup, key: .lastSharedThreadId] {
                let interactionId: Int64 = Int64(dependencies[defaults: .appGroup, key: .lastSharedMessageId])
                
                Task(priority: .userInitiated) {
                    // FIXME: It would be nice to decouple these "add{X}Event" functions from the database so we don't need to create a write transaction here
                    try? await dependencies[singleton: .storage].readAsync { db in
                        db.addMessageEvent(id: interactionId, threadId: threadId, type: .created)
                    }
                }
            }
            
            dependencies[defaults: .appGroup].removeObject(forKey: .lastSharedThreadId)
            dependencies[defaults: .appGroup].removeObject(forKey: .lastSharedMessageId)
        }
    }
}
