// Copyright © 2024 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import TestUtilities

@testable import SessionMessagingKit

final class MockGroupPollerManager: GroupPollerManagerType, Mockable {
    let handler: MockHandler<GroupPollerManagerType>
    
    required init(handler: MockHandler<GroupPollerManagerType>) {
        self.handler = handler
    }
    
    required init(handlerForBuilder: any MockFunctionHandler) {
        self.handler = MockHandler(forwardingHandler: handlerForBuilder)
    }
    
    func startAllPollers() { handler.mockNoReturn() }
    @discardableResult func getOrCreatePoller(for swarmPublicKey: String) -> any PollerType {
        return handler.mock(args: [swarmPublicKey])
    }
    func stopAndRemovePoller(for swarmPublicKey: String) { handler.mockNoReturn(args: [swarmPublicKey]) }
    func stopAndRemoveAllPollers() { handler.mockNoReturn() }
}
