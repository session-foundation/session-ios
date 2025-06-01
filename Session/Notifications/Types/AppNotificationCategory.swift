// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation

enum AppNotificationCategory: CaseIterable {
    case incomingMessage
    case errorMessage
    case threadlessErrorMessage
    case info
    
    // TODO: Remove in future release
    case deprecatedIncomingMessage
}

extension AppNotificationCategory {
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

    var actions: [AppNotificationAction] {
        switch self {
            case .incomingMessage: return [.markAsRead, .reply]
            // TODO: Remove in future release
            case .deprecatedIncomingMessage: return [.markAsRead, .reply]
            default: return []
        }
    }
}
