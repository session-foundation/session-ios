// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation

public enum NotificationCategory: CaseIterable, Equatable {
    case incomingMessage
    case errorMessage
    case threadlessErrorMessage
    case info
    
    // TODO: Remove in future release
    case deprecatedIncomingMessage
}

public extension NotificationCategory {
    var identifier: String {
        switch self {
            case .incomingMessage: return "Session.AppNotificationCategory.incomingMessage"
            case .errorMessage: return "Session.AppNotificationCategory.errorMessage"
            case .threadlessErrorMessage: return "Session.AppNotificationCategory.threadlessErrorMessage"
            case .info: return " Session.AppNotificationCategory.info"
            
            // TODO: Remove in future release
            case .deprecatedIncomingMessage: return "Signal.AppNotificationCategory.incomingMessage"
        }
    }
}
