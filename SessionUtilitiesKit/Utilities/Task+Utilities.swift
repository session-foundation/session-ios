// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation

public extension Task where Success == Never, Failure == Never {
    /// Suspends the current task until the given deadline (compatibility version).
    @available(iOS, introduced: 13.0, obsoleted: 16.0, message: "Use built-in Task.sleep(for:) accepting Swift.Duration on iOS 16+")
    static func sleep(for interval: DispatchTimeInterval) async throws {
        /// Calculate total nanoseconds safely (avoid `UInt64` overflow if something like `Date.distantFuture` is provided)
        let nanoseconds: UInt64
        
        switch interval {
            case .seconds(let s):
                let multiplier: UInt64 = 1_000_000_000
                
                if UInt64(s) > (UInt64.max / multiplier) {
                    nanoseconds = UInt64.max
                } else {
                    nanoseconds = UInt64(s) * multiplier
                }
                
            case .milliseconds(let ms):
                let multiplier: UInt64 = 1_000_000
                
                if UInt64(ms) > (UInt64.max / multiplier) {
                    nanoseconds = UInt64.max
                } else {
                    nanoseconds = UInt64(ms) * multiplier
                }
                
            case .microseconds(let us):
                let multiplier: UInt64 = 1_000
                
                if UInt64(us) > (UInt64.max / multiplier) {
                    nanoseconds = UInt64.max
                } else {
                    nanoseconds = UInt64(us) * multiplier
                }
                
            case .nanoseconds(let ns): nanoseconds = UInt64(ns)
            case .never: nanoseconds = UInt64.max
            @unknown default: nanoseconds = UInt64.max
        }
        
        try await Task.sleep(nanoseconds: min(nanoseconds, UInt64.max - 1))
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
