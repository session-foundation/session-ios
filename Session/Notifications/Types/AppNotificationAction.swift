// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import SessionMessagingKit

enum AppNotificationAction: CaseIterable {
    case markAsRead
    case reply
    
    // TODO: Remove in future release
    case deprecatedMarkAsRead
    case deprecatedReply
}

extension AppNotificationAction {
    var identifier: String {
        switch self {
            case .markAsRead: return "Session.AppNotifications.Action.markAsRead"
            case .reply: return "Session.AppNotifications.Action.reply"
            
            // TODO: Remove in future release
            case .deprecatedMarkAsRead: return "Signal.AppNotifications.Action.markAsRead"
            case .deprecatedReply: return "Signal.AppNotifications.Action.reply"
            
        }
    }
}

extension NotificationCategory {
    var actions: [AppNotificationAction] {
        switch self {
            case .incomingMessage: return [.markAsRead, .reply]
            case .errorMessage: return []
            case .threadlessErrorMessage: return []
            case .info: return []
            
            // TODO: Remove in future release
            case .deprecatedIncomingMessage: return [.markAsRead, .reply]
        }
    }
}
