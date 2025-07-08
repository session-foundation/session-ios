// Copyright © 2024 Rangeproof Pty Ltd. All rights reserved.

import Foundation

public struct EquatableHashableIgnoring<T>: Equatable, Hashable {
    public let value: T
    
    public init(value: T) {
        self.value = value
    }
    
    public static func == (lhs: EquatableHashableIgnoring<T>, rhs: EquatableHashableIgnoring<T>) -> Bool {
        return true
    }
    
    public func hash(into hasher: inout Hasher) {}
}
