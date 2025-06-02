// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import UserNotifications
import SessionUIKit
import SignalUtilitiesKit
import SessionMessagingKit
import SessionUtilitiesKit

public class NSENotificationPresenter: NotificationsManagerType {
    public let dependencies: Dependencies
    private var notifications: [String: UNNotificationRequest] = [:]
    
    // MARK: - Initialization
    
    required public init(using dependencies: Dependencies) {
        self.dependencies = dependencies
    }
    
    // MARK: - Registration
    
    public func setDelegate(_ delegate: (any UNUserNotificationCenterDelegate)?) {}
    
    public func registerNotificationSettings() -> AnyPublisher<Void, Never> {
        return Just(()).eraseToAnyPublisher()
    }
    
    // MARK: - Unique Logic
    
    public func notificationUserInfo(threadId: String, threadVariant: SessionThread.Variant) -> [String: Any] {
        return [
            NotificationUserInfoKey.isFromRemote: true,
            NotificationUserInfoKey.threadId: threadId,
            NotificationUserInfoKey.threadVariantRaw: threadVariant.rawValue
        ]
    }
    
    public func notificationShouldPlaySound(applicationState: UIApplication.State) -> Bool {
        return true
    }
    
    // MARK: - Presentation
    
    public func notifyForFailedSend(threadId: String, threadVariant: SessionThread.Variant, applicationState: UIApplication.State) {
        // Not possible in the NotificationServiceExtension
    }
    
    public func scheduleSessionNetworkPageLocalNotifcation(force: Bool) {}
    
    public func addNotificationRequest(
        content: NotificationContent,
        notificationSettings: Preferences.NotificationSettings,
        extensionBaseUnreadCount: Int?
    ) {
        let notificationContent: UNMutableNotificationContent = content.toMutableContent(
            shouldPlaySound: notificationShouldPlaySound(applicationState: content.applicationState)
        )
        
        /// Since we will have already written the message to disk at this stage we can just add the number of unread message files
        /// directly to the `originalUnreadCount` in order to get the updated unread count
        if
            let extensionBaseUnreadCount: Int = extensionBaseUnreadCount,
            let unreadPendingMessageCount: Int = dependencies[singleton: .extensionHelper].unreadMessageCount()
        {
            notificationContent.badge = NSNumber(value: extensionBaseUnreadCount + unreadPendingMessageCount)
        }
        
        let request = UNNotificationRequest(
            identifier: content.identifier,
            content: notificationContent,
            trigger: nil
        )
        
        Log.info("Add remote notification request: \(content.identifier)")
        let semaphore = DispatchSemaphore(value: 0)
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                Log.error("Failed to add notification request '\(content.identifier)' due to error: \(error)")
            }
            semaphore.signal()
        }
        semaphore.wait()
        Log.info("Finish adding remote notification request '\(content.identifier)")
    }
    
    // MARK: - Clearing
    
    public func cancelNotifications(identifiers: [String]) {
        let notificationCenter = UNUserNotificationCenter.current()
        notificationCenter.removePendingNotificationRequests(withIdentifiers: identifiers)
        notificationCenter.removeDeliveredNotifications(withIdentifiers: identifiers)
    }
    
    public func clearAllNotifications() {
        let notificationCenter = UNUserNotificationCenter.current()
        notificationCenter.removeAllPendingNotificationRequests()
        notificationCenter.removeAllDeliveredNotifications()
    }
}
