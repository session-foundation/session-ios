// Copyright © 2024 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import SessionNetworkingKit
import SessionUtilitiesKit

@testable import SessionMessagingKit

class MockSwarmPoller: MockPoller<SwarmPollerType.PollResponse>, SwarmPollerType {
    var swarmDrainer: SwarmDrainer { handler.mock() }
}
