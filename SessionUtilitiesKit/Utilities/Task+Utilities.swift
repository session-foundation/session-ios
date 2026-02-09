// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation

public extension Task where Success == Never, Failure == Never {
    /// Suspends the current task until the given deadline (compatibility version).
    @available(iOS, introduced: 13.0, obsoleted: 16.0, message: "Use built-in Task.sleep(for:) accepting Swift.Duration on iOS 16+")
    static func sleep(for interval: DispatchTimeInterval) async throws {
        /// Calculate total nanoseconds safely (avoid `UInt64` overflow if something like `Date.distantFuture` is provided)
        let nanoseconds: UInt64 = nanoseconds(from: interval)
        try await Task.sleep(nanoseconds: min(nanoseconds, UInt64.max - 1))
    }
    
    static func sleep(
        for interval: DispatchTimeInterval,
        checkingEvery checkInterval: DispatchTimeInterval = .milliseconds(100),
        until condition: () async -> Bool
    ) async throws {
        let totalNanoseconds: UInt64 = nanoseconds(from: interval)
        let checkNanoseconds: UInt64 = nanoseconds(from: checkInterval)

        guard checkNanoseconds > 0 else { return }
        
        var elapsed: UInt64 = 0

        
        while elapsed < totalNanoseconds {
            guard await !condition() else { return }
            
            try await Task.sleep(
                nanoseconds: min(checkNanoseconds, UInt64.max - 1)
            )

            elapsed = (elapsed > UInt64.max - checkNanoseconds ?
                UInt64.max :
                elapsed + checkNanoseconds
            )
        }
    }
    
    private static func nanoseconds(from interval: DispatchTimeInterval) -> UInt64 {
        switch interval {
            case .seconds(let s): return safeMultiply(s, 1_000_000_000)
            case .milliseconds(let ms): return safeMultiply(ms, 1_000_000)
            case .microseconds(let us): return safeMultiply(us, 1_000)
            case .nanoseconds(let ns): return (ns > 0 ? UInt64(ns) : 0)
            case .never: return .max
            @unknown default: return .max
        }
    }
    
    private static func safeMultiply(_ value: Int, _ multiplier: UInt64) -> UInt64 {
        guard value > 0 else { return 0 }
        
        let value: UInt64 = UInt64(value)
        
        return (value > UInt64.max / multiplier ?
            UInt64.max :
            value * multiplier
        )
    }
}
