// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation

extension DispatchTimeInterval {
    var milliseconds: Int {
        switch self {
            case .seconds(let s): return s * 1_000
            case .milliseconds(let ms): return ms
            case .microseconds(let us): return us / 1_000  // integer division truncates any remainder
            case .nanoseconds(let ns): return ns / 1_000_000
            case .never: return -1
            @unknown default: return -1
        }
    }
}
