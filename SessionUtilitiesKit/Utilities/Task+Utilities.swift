// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation

public extension Task where Success == Never, Failure == Never {
    /// Suspends the current task until the given deadline (compatibility version).
    @available(iOS, introduced: 13.0, obsoleted: 16.0, message: "Use built-in Task.sleep(for:) accepting Swift.Duration on iOS 16+")
    static func sleep(for interval: DispatchTimeInterval) async throws {
        let nanosecondsToSleep: UInt64 = (UInt64(interval.milliseconds) * 1_000_000)
        try await Task.sleep(nanoseconds: nanosecondsToSleep)
    }
    
    static func sleep(
        for interval: DispatchTimeInterval,
        checkingEvery checkInterval: DispatchTimeInterval = .milliseconds(100),
        until condition: () async -> Bool
    ) async throws {
        var currentWaitDuration: Int = 0
        
        while currentWaitDuration < interval.milliseconds {
            guard await !condition() else { return }
            
            try await Task.sleep(for: checkInterval)
            currentWaitDuration += checkInterval.milliseconds
        }
    }
}
