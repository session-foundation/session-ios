// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation

public enum Setting {}

// MARK: - Setting Keys

public extension Setting {
    protocol Key: RawRepresentable, ExpressibleByStringLiteral, Hashable {
        var rawValue: String { get }
        init(_ rawValue: String)
    }
    
    struct BoolKey: Key {
        public let rawValue: String
        public init(_ rawValue: String) { self.rawValue = rawValue }
    }
    
    struct EnumKey: Key {
        public let rawValue: String
        public init(_ rawValue: String) { self.rawValue = rawValue }
    }
}

public extension Setting.Key {
    init?(rawValue: String) { self.init(rawValue) }
    init(stringLiteral value: String) { self.init(value) }
    init(unicodeScalarLiteral value: String) { self.init(value) }
    init(extendedGraphemeClusterLiteral value: String) { self.init(value) }
}
