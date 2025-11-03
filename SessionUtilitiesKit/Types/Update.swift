// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation

public enum Update<T> {
    case set(to: T)
    case useExisting
    
    public func or(_ existing: T) -> T {
        switch self {
            case .set(let value): return value
            case .useExisting: return existing
        }
    }
}
