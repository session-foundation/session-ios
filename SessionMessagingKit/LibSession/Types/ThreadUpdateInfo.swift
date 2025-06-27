// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit

extension LibSession {
    struct ThreadUpdateInfo: Codable, FetchableRecord, Identifiable {
        static let threadColumns: [SessionThread.Columns] = [
            .id, .variant, .pinnedPriority, .shouldBeVisible,
            .mutedUntilTimestamp, .onlyNotifyForMentions
        ]
        
        let id: String
        let variant: SessionThread.Variant
        let pinnedPriority: Int32?
        let shouldBeVisible: Bool
        let mutedUntilTimestamp: TimeInterval?
        let onlyNotifyForMentions: Bool
    }
}
