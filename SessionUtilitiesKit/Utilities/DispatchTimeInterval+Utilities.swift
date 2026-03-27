// Copyright © 2026 Rangeproof Pty Ltd. All rights reserved.

import Foundation

public extension DispatchTimeInterval {
    static func seconds(from interval: DispatchTimeInterval) -> UInt64 {
        switch interval {
            case .seconds(let s): return (s > 0 ? UInt64(s) : 0)
            case .milliseconds(let ms): return UInt64(Double(ms) / 1_000)
            case .microseconds(let us): return UInt64(Double(us) / 1_000_000)
            case .nanoseconds(let ns): return UInt64(Double(ns) / 1_000_000_000)
            case .never: return .max
            @unknown default: return .max
        }
    }
    
    static func milliseconds(from interval: DispatchTimeInterval) -> UInt64 {
        switch interval {
            case .seconds(let s): return safeMultiply(s, 1_000)
            case .milliseconds(let ms): return (ms > 0 ? UInt64(ms) : 0)
            case .microseconds(let us): return UInt64(Double(us) / 1_000)
            case .nanoseconds(let ns): return UInt64(Double(ns) / 1_000_000)
            case .never: return .max
            @unknown default: return .max
        }
    }
    
    static func nanoseconds(from interval: DispatchTimeInterval) -> UInt64 {
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
