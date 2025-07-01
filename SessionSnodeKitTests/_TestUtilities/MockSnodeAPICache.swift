// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation

import Foundation
import Combine
import SessionUtilitiesKit

@testable import SessionSnodeKit

class MockSnodeAPICache: Mock<SnodeAPICacheType>, SnodeAPICacheType {
    var hardfork: Int {
        get { return mock() }
        set { mockNoReturn(args: [newValue]) }
    }
    
    var softfork: Int {
        get { return mock() }
        set { mockNoReturn(args: [newValue]) }
    }
    
    var clockOffsetMs: Int64 { mock() }
    
    func currentOffsetTimestampMs<T>() -> T where T: Numeric {
        return mock(generics: [T.self])
    }
    
    func setClockOffsetMs(_ clockOffsetMs: Int64) {
        mockNoReturn(args: [clockOffsetMs])
    }
}

// MARK: - Convenience

extension Mock where T == SnodeAPICacheType {
    func defaultInitialSetup() {
        self.when { $0.hardfork }.thenReturn(0)
        self.when { $0.hardfork = .any }.thenReturn(())
        self.when { $0.softfork }.thenReturn(0)
        self.when { $0.softfork = .any }.thenReturn(())
        self.when { $0.clockOffsetMs }.thenReturn(0)
        self.when { $0.setClockOffsetMs(.any) }.thenReturn(())
        self.when { $0.currentOffsetTimestampMs() }.thenReturn(Double(1234567890000))
        self.when { $0.currentOffsetTimestampMs() }.thenReturn(Int(1234567890000))
        self.when { $0.currentOffsetTimestampMs() }.thenReturn(Int64(1234567890000))
        self.when { $0.currentOffsetTimestampMs() }.thenReturn(UInt64(1234567890000))
    }
}
