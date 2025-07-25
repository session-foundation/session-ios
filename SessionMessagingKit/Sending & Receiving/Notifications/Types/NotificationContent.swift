// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import UserNotifications

public struct NotificationContent {
    public let threadId: String?
    public let threadVariant: SessionThread.Variant?
    public let identifier: String
    public let category: NotificationCategory
    public let title: String?
    public let body: String?
    public let delay: TimeInterval?
    public let sound: Preferences.Sound
    public let userInfo: [AnyHashable: Any]
    public let applicationState: UIApplication.State
    
    // MARK: - Init
    
    public init(
        threadId: String?,
        threadVariant: SessionThread.Variant?,
        identifier: String,
        category: NotificationCategory,
        title: String? = nil,
        body: String? = nil,
        delay: TimeInterval? = nil,
        sound: Preferences.Sound = .none,
        userInfo: [AnyHashable: Any] = [:],
        applicationState: UIApplication.State
    ) {
        self.threadId = threadId
        self.threadVariant = threadVariant
        self.identifier = identifier
        self.category = category
        self.title = title
        self.body = body
        self.delay = delay
        self.sound = sound
        self.userInfo = userInfo
        self.applicationState = applicationState
    }
    
    // MARK: - Functions
    
    public func with(
        title: String? = nil,
        body: String? = nil,
        sound: Preferences.Sound? = nil
    ) -> NotificationContent {
        return NotificationContent(
            threadId: threadId,
            threadVariant: threadVariant,
            identifier: identifier,
            category: category,
            title: (title ?? self.title),
            body: (body ?? self.body),
            delay: self.delay,
            sound: (sound ?? self.sound),
            userInfo: userInfo,
            applicationState: applicationState
        )
    }
    
    public func toMutableContent(shouldPlaySound: Bool) -> UNMutableNotificationContent {
        let content: UNMutableNotificationContent = UNMutableNotificationContent()
        content.categoryIdentifier = category.identifier
        content.userInfo = userInfo
        
        if let threadId: String = threadId { content.threadIdentifier = threadId }
        if let title: String = title { content.title = title }
        if let body: String = body { content.body = body }
        
        if shouldPlaySound {
            content.sound = sound.notificationSound(isQuiet: (applicationState == .active))
        }
        
        return content
    }
}
