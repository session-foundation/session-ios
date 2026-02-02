// Copyright © 2026 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import TestUtilities

@testable import SessionMessagingKit

final class MockGroupPollerCache: GroupPollerCacheType, Mockable {
    let handler: MockHandler<GroupPollerCacheType>
    
    required init(handler: MockHandler<GroupPollerCacheType>) {
        self.handler = handler
    }
    
    required init(handlerForBuilder: any MockFunctionHandler) {
        self.handler = MockHandler(forwardingHandler: handlerForBuilder)
    }
    
    func startAllPollers() {
        handler.mockNoReturn()
    }
    
    @discardableResult func getOrCreatePoller(for swarmPublicKey: String) -> any PollerType {
        return handler.mock(args: [swarmPublicKey])
    }
    
    func stopAndRemovePoller(for swarmPublicKey: String) {
        handler.mockNoReturn(args: [swarmPublicKey])
    }
    
    func stopAndRemoveAllPollers() {
        handler.mockNoReturn()
    }
}
