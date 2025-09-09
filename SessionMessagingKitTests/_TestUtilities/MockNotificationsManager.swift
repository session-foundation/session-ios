// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import SessionMessagingKit
import SessionUtilitiesKit
import TestUtilities

class MockNotificationsManager: NotificationsManagerType, Mockable {
    let handler: MockHandler<NotificationsManagerType>
    let dependencies: Dependencies = TestDependencies.any
    
    required init(handler: MockHandler<NotificationsManagerType>) {
        self.handler = handler
    }
    
    required init(handlerForBuilder: any MockFunctionHandler) {
        self.handler = MockHandler(forwardingHandler: handlerForBuilder)
    }
    
    public required init(using dependencies: Dependencies) {
        handler = MockHandler(dummyProvider: { _ in MockNotificationsManager(handler: .invalid()) })
        handler.mockNoReturn()
    }
    
    public func setDelegate(_ delegate: (any UNUserNotificationCenterDelegate)?) {
        handler.mockNoReturn(args: [delegate])
    }
    
    public func registerSystemNotificationSettings() -> AnyPublisher<Void, Never> {
        return handler.mock()
    }
    
    public func settings(threadId: String?, threadVariant: SessionThread.Variant) -> Preferences.NotificationSettings {
        return handler.mock(args: [threadId, threadVariant])
    }
    
    public func updateSettings(
        threadId: String,
        threadVariant: SessionThread.Variant,
        mentionsOnly: Bool,
        mutedUntil: TimeInterval?
    ) {
        return handler.mock(args: [threadId, threadVariant, mentionsOnly, mutedUntil])
    }
    
    public func notificationUserInfo(
        threadId: String,
        threadVariant: SessionThread.Variant
    ) -> [String: AnyHashable] {
        return handler.mock(args: [threadId, threadVariant])
    }
    
    public func notificationShouldPlaySound(applicationState: UIApplication.State) -> Bool {
        return handler.mock(args: [applicationState])
    }
    
    public func notifyForFailedSend(
        threadId: String,
        threadVariant: SessionThread.Variant,
        applicationState: UIApplication.State
    ) {
        handler.mockNoReturn(args: [threadId, threadVariant, applicationState])
    }
    
    public func scheduleSessionNetworkPageLocalNotifcation(force: Bool) {
        handler.mockNoReturn(args: [force])
    }
    
    public func addNotificationRequest(
        content: NotificationContent,
        notificationSettings: Preferences.NotificationSettings,
        extensionBaseUnreadCount: Int?
    ) {
        handler.mockNoReturn(args: [content, notificationSettings, extensionBaseUnreadCount])
    }
    
    public func cancelNotifications(identifiers: [String]) {
        handler.mockNoReturn(args: [identifiers])
    }
    
    public func clearAllNotifications() {
        handler.mockNoReturn()
    }
}

// MARK: - Convenience

extension MockNotificationsManager {
    func defaultInitialSetup() async throws {
        try await self
            .when { $0.notificationUserInfo(threadId: .any, threadVariant: .any) }
            .thenReturn([:])
        try await self
            .when { $0.notificationShouldPlaySound(applicationState: .any) }
            .thenReturn(false)
        try await self
            .when {
                $0.addNotificationRequest(
                    content: .any,
                    notificationSettings: .any,
                    extensionBaseUnreadCount: .any
                )
            }
            .thenReturn(())
        try await self
            .when { $0.cancelNotifications(identifiers: .any) }
            .thenReturn(())
        try await self
            .when { $0.settings(threadId: .any, threadVariant: .any) }
            .thenReturn(
                Preferences.NotificationSettings(
                    previewType: .nameAndPreview,
                    sound: .note,
                    mentionsOnly: false,
                    mutedUntil: nil
                )
            )
        try await self
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
