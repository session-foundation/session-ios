// Copyright © 2026 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import TestUtilities

@testable import SessionMessagingKit

class MockCommunityPollerCache: CommunityPollerCacheType, Mockable {
    nonisolated let handler: MockHandler<CommunityPollerCacheType>
    
    required init(handler: MockHandler<CommunityPollerCacheType>) {
        self.handler = handler
        
        /// Register `any PollerType` with the `MockFallbackRegistry` so we don't need to explicitly mock `getOrCreatePoller`
        MockFallbackRegistry.register(
            for: (any PollerType).self,
            provider: { MockPoller<CommunityPollerType.PollResponse>(handler: .invalid()) }
        )
    }
    
    required init(handlerForBuilder: any MockFunctionHandler) {
        self.handler = MockHandler(forwardingHandler: handlerForBuilder)
    }
    
    var serversBeingPolled: Set<String> { handler.mock() }
    var allPollers: [any PollerType] { handler.mock() }
    
    func startAllPollers() {
        handler.mockNoReturn()
    }
    
    @discardableResult func getOrCreatePoller(for info: CommunityPoller.Info) -> any PollerType {
        return handler.mock(args: [info])
    }
    
    func stopAndRemovePoller(for server: String) {
        handler.mockNoReturn(args: [server])
    }
    
    func stopAndRemoveAllPollers() {
        handler.mockNoReturn()
    }
}

extension CommunityPoller.Info: @retroactive Mocked {
    public static let any: CommunityPoller.Info = CommunityPoller.Info(server: .any, pollFailureCount: .any)
    public static let mock: CommunityPoller.Info = CommunityPoller.Info(server: .mock, pollFailureCount: .mock)
}
