// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import SessionUtilitiesKit
import TestUtilities

@testable import SessionMessagingKit

class MockOGMCache: OGMCacheType, Mockable {
    public var handler: MockHandler<OGMCacheType>
    
    required init(handler: MockHandler<OGMCacheType>) {
        self.handler = handler
    }
    
    required init(handlerForBuilder: any MockFunctionHandler) {
        self.handler = MockHandler(forwardingHandler: handlerForBuilder)
    }
    
    var defaultRoomsPublisher: AnyPublisher<[OpenGroupManager.DefaultRoomInfo], Error> {
        handler.mock()
    }
    
    var pendingChanges: [OpenGroupAPI.PendingChange] {
        get { return handler.mock() }
        set { handler.mockNoReturn(args: [newValue]) }
    }
    
    func getLastSuccessfulCommunityPollTimestamp() -> TimeInterval {
        return handler.mock()
    }
    
    func setLastSuccessfulCommunityPollTimestamp(_ timestamp: TimeInterval) {
        handler.mockNoReturn(args: [timestamp])
    }
    
    func setDefaultRoomInfo(_ info: [OpenGroupManager.DefaultRoomInfo]) {
        handler.mockNoReturn(args: [info])
    }
}
