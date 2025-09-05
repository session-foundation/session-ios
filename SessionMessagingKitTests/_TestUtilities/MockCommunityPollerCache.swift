// Copyright © 2024 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import TestUtilities

@testable import SessionMessagingKit

class MockCommunityPollerManager: CommunityPollerManagerType, Mockable {
    nonisolated let handler: MockHandler<CommunityPollerManagerType>
    
    required init(handler: MockHandler<CommunityPollerManagerType>) {
        self.handler = handler
    }
    
    required init(handlerForBuilder: any MockFunctionHandler) {
        self.handler = MockHandler(forwardingHandler: handlerForBuilder)
    }
    
    nonisolated var syncState: CommunityPollerManagerSyncState { handler.mock() }
    var serversBeingPolled: Set<String> { get async { handler.mock() } }
    var allPollers: [any PollerType] { get async { handler.mock() } }
    
    func startAllPollers() async { handler.mockNoReturn() }
    @discardableResult func getOrCreatePoller(for info: CommunityPoller.Info) async -> any PollerType {
        handler.mock(args: [info])
    }
    func stopAndRemovePoller(for server: String) async { handler.mockNoReturn(args: [server]) }
    func stopAndRemoveAllPollers() async { handler.mockNoReturn() }
}
