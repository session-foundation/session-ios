// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import DifferenceKit
import SessionUtilitiesKit

public extension Preferences {
    enum NotificationMode: Int, CaseIterable, EnumIntSetting, Differentiable {
        /// Notifications should be shown for all messages
        case all
        
        /// Notifications should be shown only for messages which mention the current user
        case mentionsOnly
        
        /// Notifications should not be shown for any messages
        case none
        
        public static func defaultMode(for threadVariant: SessionThread.Variant) -> NotificationMode {
            return .all
        }
    }
}
