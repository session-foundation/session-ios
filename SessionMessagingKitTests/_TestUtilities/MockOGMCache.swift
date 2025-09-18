// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import SessionUtilitiesKit

@testable import SessionMessagingKit

class MockOGMCache: Mock<OGMCacheType>, OGMCacheType {
    var defaultRoomsPublisher: AnyPublisher<[OpenGroupManager.DefaultRoomInfo], Error> {
        mock()
    }
    
    var pendingChanges: [OpenGroupManager.PendingChange] {
        get { return mock() }
        set { mockNoReturn(args: [newValue]) }
    }
    
    func getLastSuccessfulCommunityPollTimestamp() -> TimeInterval {
        return mock()
    }
    
    func setLastSuccessfulCommunityPollTimestamp(_ timestamp: TimeInterval) {
        mockNoReturn(args: [timestamp])
    }
    
    func setDefaultRoomInfo(_ info: [OpenGroupManager.DefaultRoomInfo]) {
        mockNoReturn(args: [info])
    }
}
