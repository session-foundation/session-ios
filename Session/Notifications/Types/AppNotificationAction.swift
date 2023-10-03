// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation

enum AppNotificationAction: CaseIterable {
    case markAsRead
    case reply
    case showThread
}

extension AppNotificationAction {
    var identifier: String {
        switch self {
            case .markAsRead: return "Signal.AppNotifications.Action.markAsRead"
            case .reply: return "Signal.AppNotifications.Action.reply"
            case .showThread: return "Signal.AppNotifications.Action.showThread"
        }
    }
}
