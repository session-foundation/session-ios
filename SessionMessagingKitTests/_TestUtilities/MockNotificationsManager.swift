// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import SessionMessagingKit
import SessionUtilitiesKit

public class MockNotificationsManager: Mock<NotificationsManagerType>, NotificationsManagerType {
    public required init(using dependencies: Dependencies) {
        super.init()
        
        mockNoReturn(untrackedArgs: [dependencies])
    }
    
    internal required init(functionHandler: MockFunctionHandler_Old? = nil, initialSetup: ((Mock<NotificationsManagerType>) -> ())? = nil) {
        super.init(functionHandler: functionHandler, initialSetup: initialSetup)
    }
    
    public func setDelegate(_ delegate: (any UNUserNotificationCenterDelegate)?) {
        mockNoReturn(args: [delegate])
    }
    
    public func registerSystemNotificationSettings() -> AnyPublisher<Void, Never> {
        return mock()
    }
    
    public func settings(threadId: String?, threadVariant: SessionThread.Variant) -> Preferences.NotificationSettings {
        return mock(args: [threadId, threadVariant])
    }
    
    public func updateSettings(
        threadId: String,
        threadVariant: SessionThread.Variant,
        mentionsOnly: Bool,
        mutedUntil: TimeInterval?
    ) {
        return mock(args: [threadId, threadVariant, mentionsOnly, mutedUntil])
    }
    
    public func notificationUserInfo(
        threadId: String,
        threadVariant: SessionThread.Variant
    ) -> [String: AnyHashable] {
        return mock(args: [threadId, threadVariant])
    }
    
    public func notificationShouldPlaySound(applicationState: UIApplication.State) -> Bool {
        return mock(args: [applicationState])
    }
    
    public func notifyForFailedSend(
        threadId: String,
        threadVariant: SessionThread.Variant,
        applicationState: UIApplication.State
    ) {
        mockNoReturn(args: [threadId, threadVariant, applicationState])
    }
    
    public func scheduleSessionNetworkPageLocalNotifcation(force: Bool) {
        mockNoReturn(args: [force])
    }
    
    public func addNotificationRequest(
        content: NotificationContent,
        notificationSettings: Preferences.NotificationSettings,
        extensionBaseUnreadCount: Int?
    ) {
        mockNoReturn(args: [content, notificationSettings, extensionBaseUnreadCount])
    }
    
    public func cancelNotifications(identifiers: [String]) {
        mockNoReturn(args: [identifiers])
    }
    
    public func clearAllNotifications() {
        mockNoReturn()
    }
}

// MARK: - Convenience

extension Mock where T == NotificationsManagerType {
    func defaultInitialSetup() {
        self
            .when { $0.notificationUserInfo(threadId: .any, threadVariant: .any) }
            .thenReturn([:])
        self
            .when { $0.notificationShouldPlaySound(applicationState: .any) }
            .thenReturn(false)
        self
            .when {
                $0.addNotificationRequest(
                    content: .any,
                    notificationSettings: .any,
                    extensionBaseUnreadCount: .any
                )
            }
            .thenReturn(())
        self
            .when { $0.cancelNotifications(identifiers: .any) }
            .thenReturn(())
        self
            .when { $0.settings(threadId: .any, threadVariant: .any) }
            .thenReturn(
                Preferences.NotificationSettings(
                    previewType: .nameAndPreview,
                    sound: .note,
                    mentionsOnly: false,
                    mutedUntil: nil
                )
            )
        self
            .when {
                $0.updateSettings(
                    threadId: .any,
                    threadVariant: .any,
                    mentionsOnly: .any,
                    mutedUntil: .any
                )
            }
            .thenReturn(())
    }
}
