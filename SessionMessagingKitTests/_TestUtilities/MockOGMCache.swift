// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import SessionUtilitiesKit

@testable import SessionMessagingKit

class MockOGMCache: Mock<OGMCacheType>, OGMCacheType {
    var defaultRoomsPublisher: AnyPublisher<[OpenGroupManager.DefaultRoomInfo], Error>? {
        get { return accept() as? AnyPublisher<[OpenGroupManager.DefaultRoomInfo], Error> }
        set { accept(args: [newValue]) }
    }
    
    var groupImagePublishers: [String: AnyPublisher<Data, Error>] {
        get { return accept() as! [String: AnyPublisher<Data, Error>] }
        set { accept(args: [newValue]) }
    }
    
    var pollers: [String: OpenGroupAPI.Poller] {
        get { return accept() as! [String: OpenGroupAPI.Poller] }
        set { accept(args: [newValue]) }
    }
    
    var isPolling: Bool {
        get { return accept() as! Bool }
        set { accept(args: [newValue]) }
    }
    
    var hasPerformedInitialPoll: [String: Bool] {
        get { return accept() as! [String: Bool] }
        set { accept(args: [newValue]) }
    }
    
    var timeSinceLastPoll: [String: TimeInterval] {
        get { return accept() as! [String: TimeInterval] }
        set { accept(args: [newValue]) }
    }
    
    var pendingChanges: [OpenGroupAPI.PendingChange] {
        get { return accept() as! [OpenGroupAPI.PendingChange] }
        set { accept(args: [newValue]) }
    }
    
    func getTimeSinceLastOpen(using dependencies: Dependencies) -> TimeInterval {
        return accept(args: [dependencies]) as! TimeInterval
    }
}
