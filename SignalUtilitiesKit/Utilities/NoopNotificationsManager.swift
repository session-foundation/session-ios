// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionMessagingKit
import SessionUtilitiesKit
import SignalCoreKit

public class NoopNotificationsManager: NotificationsProtocol {
    public init() {}
    
    public func notifyUser(
        _ db: Database,
        for interaction: Interaction,
        in thread: SessionThread,
        applicationState: UIApplication.State,
        using dependencies: Dependencies
    ) {
        owsFailDebug("")
    }
    
    public func notifyUser(_ db: Database, forIncomingCall interaction: Interaction, in thread: SessionThread, applicationState: UIApplication.State) {
        owsFailDebug("")
    }
    
    public func notifyUser(_ db: Database, forReaction reaction: Reaction, in thread: SessionThread, applicationState: UIApplication.State) {
        owsFailDebug("")
    }
    
    public func cancelNotifications(identifiers: [String]) {
        owsFailDebug("")
    }

    public func clearAllNotifications() {
        Logger.warn("clearAllNotifications")
    }
}
