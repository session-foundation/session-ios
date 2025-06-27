// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import SessionMessagingKit
import SessionUtilitiesKit

public class NSENotificationPresenter: NotificationsManagerType {
    public let dependencies: Dependencies
    private var notifications: [String: UNNotificationRequest] = [:]
    @ThreadSafeObject private var settingsStorage: [String: Preferences.NotificationSettings] = [:]
    @ThreadSafe private var notificationSound: Preferences.Sound = .defaultNotificationSound
    @ThreadSafe private var notificationPreviewType: Preferences.NotificationPreviewType = .defaultPreviewType
    
    // MARK: - Initialization
    
    required public init(using dependencies: Dependencies) {
        self.dependencies = dependencies
        
        dependencies.mutate(cache: .libSession) {
            notificationPreviewType = $0.get(.preferencesNotificationPreviewType)
                .defaulting(to: .defaultPreviewType)
            notificationSound = $0.get(.defaultNotificationSound)
                .defaulting(to: .defaultNotificationSound)
        }
        _settingsStorage.set(
            to: dependencies[singleton: .extensionHelper]
                .loadNotificationSettings(
                    previewType: notificationPreviewType,
                    sound: notificationSound
                )
                .defaulting(to: [:])
        )
    }
    
    // MARK: - Registration
    
    public func setDelegate(_ delegate: (any UNUserNotificationCenterDelegate)?) {}
    
    public func registerSystemNotificationSettings() -> AnyPublisher<Void, Never> {
        return Just(()).eraseToAnyPublisher()
    }
    
    // MARK: - Unique Logic
    
    public func settings(threadId: String? = nil, threadVariant: SessionThread.Variant) -> Preferences.NotificationSettings {
        return settingsStorage[threadId].defaulting(
            to: Preferences.NotificationSettings(
                previewType: notificationPreviewType,
                sound: notificationSound,
                mentionsOnly: false,
                mutedUntil: nil
            )
        )
    }
    
    public func updateSettings(
        threadId: String,
        threadVariant: SessionThread.Variant,
        mentionsOnly: Bool,
        mutedUntil: TimeInterval?
    ) {}
    
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
