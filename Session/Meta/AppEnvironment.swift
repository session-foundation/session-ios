// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import SessionUtilitiesKit
import SignalUtilitiesKit
import SessionMessagingKit

public class AppEnvironment {
    
    private static var _shared: AppEnvironment = AppEnvironment()

    public class var shared: AppEnvironment {
        get { return _shared }
        set {
            guard SNUtilitiesKit.isRunningTests else {
                Log.error("[AppEnvironment] Can only switch environments in tests.")
                return
            }

            _shared = newValue
        }
    }

    public var notificationPresenter: NotificationPresenter

    // Stored properties cannot be marked as `@available`, only classes and functions.
    // Instead, store a private `Any` and wrap it with a public `@available` getter
    private var _userNotificationActionHandler: Any?

    public var userNotificationActionHandler: UserNotificationActionHandler {
        return _userNotificationActionHandler as! UserNotificationActionHandler
    }

    private init() {
        self.notificationPresenter = NotificationPresenter()
        self._userNotificationActionHandler = UserNotificationActionHandler()
        
        SwiftSingletons.register(self)
    }

    public func setup() {
        // Hang certain singletons on Environment too.
        SessionEnvironment.shared?.setNotificationsManager(to: notificationPresenter)
    }
}
