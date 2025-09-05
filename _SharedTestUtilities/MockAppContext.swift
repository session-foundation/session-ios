// Copyright © 2024 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import SessionUtilitiesKit
import TestUtilities

class MockAppContext: AppContext, Mockable {
    public var handler: MockHandler<AppContext>
    
    required init(handler: MockHandler<AppContext>) {
        self.handler = handler
    }
    
    required init(handlerForBuilder: any MockFunctionHandler) {
        self.handler = MockHandler(forwardingHandler: handlerForBuilder)
    }
    
    var mainWindow: UIWindow? { handler.mock() }
    var frontMostViewController: UIViewController? { handler.mock() }
    
    var isValid: Bool { handler.mock() }
    var appLaunchTime: Date { handler.mock() }
    var isMainApp: Bool { handler.mock() }
    var isMainAppAndActive: Bool { handler.mock() }
    var isShareExtension: Bool { handler.mock() }
    var reportedApplicationState: UIApplication.State { handler.mock() }
    var backgroundTimeRemaining: TimeInterval { handler.mock() }
    
    // Override the extension functions
    var isInBackground: Bool { handler.mock() }
    var isAppForegroundAndActive: Bool { handler.mock() }
    
    func setMainWindow(_ mainWindow: UIWindow) {
        handler.mockNoReturn(args: [mainWindow])
    }
    
    func ensureSleepBlocking(_ shouldBeBlocking: Bool, blockingObjects: [Any]) {
        handler.mockNoReturn(args: [shouldBeBlocking, blockingObjects])
    }
    
    func beginBackgroundTask(expirationHandler: @escaping () -> ()) -> UIBackgroundTaskIdentifier {
        return handler.mock(args: [expirationHandler])
    }
    
    func endBackgroundTask(_ backgroundTaskIdentifier: UIBackgroundTaskIdentifier) {
        handler.mockNoReturn(args: [backgroundTaskIdentifier])
    }
}
