// Copyright © 2026 Rangeproof Pty Ltd. All rights reserved.

import Foundation

public struct EquatablePair<First: Equatable & Hashable, Second: Equatable & Hashable>: Equatable & Hashable, CustomStringConvertible {
    public let first: First
    public let second: Second
    
    public init(_ first: First, _ second: Second) {
        self.first = first
        self.second = second
    }
    
    // stringlint:ignore_contents
    public var description: String {
        return "(first: \(first), second: \(second))"
    }
}
