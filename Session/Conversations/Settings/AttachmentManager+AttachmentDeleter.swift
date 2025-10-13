// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtilitiesKit
import SessionMessagingKit

extension AttachmentManager {
    // Reusable delete function for all the media preview instances
    public func deleteAttachments(_ items: [MediaGalleryViewModel.Item], completion: @escaping () -> Void) {
        let desiredIDSet: Set<Int64> = Set(items.map { $0.interactionId })
        
        willTriggerDeleteOption?(desiredIDSet) {
            completion()
        }
    }
}
