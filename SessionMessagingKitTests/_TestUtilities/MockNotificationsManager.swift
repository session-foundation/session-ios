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
    
    internal required init(functionHandler: MockFunctionHandler? = nil, initialSetup: ((Mock<NotificationsManagerType>) -> ())? = nil) {
        super.init(functionHandler: functionHandler, initialSetup: initialSetup)
    }
    
    public func setDelegate(_ delegate: (any UNUserNotificationCenterDelegate)?) {
        mockNoReturn(args: [delegate])
    }
    
    public func registerNotificationSettings() -> AnyPublisher<Void, Never> {
        return mock()
    }
    
    public func notificationUserInfo(
        threadId: String,
        threadVariant: SessionThread.Variant
    ) -> [String: Any] {
        return mock(args: [threadId, threadVariant])
    }
    
    public func notificationShouldPlaySound(applicationState: UIApplication.State) -> Bool {
        return mock(args: [applicationState])
    }
    
    public func notifyForFailedSend(_ db: Database, in thread: SessionThread, applicationState: UIApplication.State) {
        mockNoReturn(args: [thread, applicationState], untrackedArgs: [db])
    }
    
    public func addNotificationRequest(
        content: NotificationContent,
        notificationSettings: Preferences.NotificationSettings
    ) {
        mockNoReturn(args: [content, notificationSettings])
    }
    
    public func cancelNotifications(identifiers: [String]) {
        mockNoReturn(args: [identifiers])
    }
    
    public func clearAllNotifications() {
        mockNoReturn()
    }
}
