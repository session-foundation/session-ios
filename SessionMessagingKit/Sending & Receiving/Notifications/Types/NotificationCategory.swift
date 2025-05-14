// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation

public enum NotificationCategory: CaseIterable {
    case incomingMessage
    case errorMessage
    case threadlessErrorMessage
}

public extension NotificationCategory {
    var identifier: String {
        switch self {
            case .incomingMessage: return "Signal.AppNotificationCategory.incomingMessage"
            case .errorMessage: return "Signal.AppNotificationCategory.errorMessage"
            case .threadlessErrorMessage: return "Signal.AppNotificationCategory.threadlessErrorMessage"
        }
    }
}
