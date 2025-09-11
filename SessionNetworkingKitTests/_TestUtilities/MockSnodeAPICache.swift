// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation

import Foundation
import Combine
import SessionUtilitiesKit
import TestUtilities

@testable import SessionNetworkingKit

class MockSnodeAPICache: SnodeAPICacheType, Mockable {
    public var handler: MockHandler<SnodeAPICacheType>
    
    required init(handler: MockHandler<SnodeAPICacheType>) {
        self.handler = handler
    }
    
    required init(handlerForBuilder: any MockFunctionHandler) {
        self.handler = MockHandler(forwardingHandler: handlerForBuilder)
    }
    
    var hardfork: Int {
        get { return handler.mock() }
        set { handler.mockNoReturn(args: [newValue]) }
    }
    
    var softfork: Int {
        get { return handler.mock() }
        set { handler.mockNoReturn(args: [newValue]) }
    }
    
    var clockOffsetMs: Int64 { handler.mock() }
    
    func currentOffsetTimestampMs<T>() -> T where T: Numeric {
        return handler.mock(generics: [T.self])
    }
    
    func setClockOffsetMs(_ clockOffsetMs: Int64) {
        handler.mockNoReturn(args: [clockOffsetMs])
    }
}

// MARK: - Convenience

extension MockSnodeAPICache {
    func defaultInitialSetup() async throws {
        try await self.when { $0.hardfork }.thenReturn(0)
        try await self.when { $0.hardfork = .any }.thenReturn(())
        try await self.when { $0.softfork }.thenReturn(0)
        try await self.when { $0.softfork = .any }.thenReturn(())
        try await self.when { $0.clockOffsetMs }.thenReturn(0)
        try await self.when { $0.setClockOffsetMs(.any) }.thenReturn(())
        try await self.when { $0.currentOffsetTimestampMs() }.thenReturn(Double(1234567890000))
        try await self.when { $0.currentOffsetTimestampMs() }.thenReturn(Int(1234567890000))
        try await self.when { $0.currentOffsetTimestampMs() }.thenReturn(Int64(1234567890000))
        try await self.when { $0.currentOffsetTimestampMs() }.thenReturn(UInt64(1234567890000))
    }
}
