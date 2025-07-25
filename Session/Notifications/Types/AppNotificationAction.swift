// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation

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
