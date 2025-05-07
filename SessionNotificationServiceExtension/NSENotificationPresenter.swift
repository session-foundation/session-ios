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
    
    public func notifyForFailedSend(_ db: Database, in thread: SessionThread, applicationState: UIApplication.State) {
        // Not possible in the NotificationServiceExtension
    }
    
    public func addNotificationRequest(
        threadId: String,
        threadVariant: SessionThread.Variant,
        identifier: String,
        category: NotificationCategory,
        content: UNMutableNotificationContent,
        notificationSettings: Preferences.NotificationSettings,
        applicationState: UIApplication.State
    ) {
        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil
        )
        
        Log.info("Add remote notification request: \(identifier)")
        let semaphore = DispatchSemaphore(value: 0)
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                Log.error("Failed to add notification request '\(identifier)' due to error: \(error)")
            }
            semaphore.signal()
        }
        semaphore.wait()
        Log.info("Finish adding remote notification request '\(identifier)")
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
