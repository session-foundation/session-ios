// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation

public struct HTTPFragmentParam: RawRepresentable, Codable, ExpressibleByStringLiteral, Hashable {
    public let rawValue: String
    
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init?(rawValue: String) { self.init(rawValue) }
    public init(stringLiteral value: String) { self.init(value) }
    public init(unicodeScalarLiteral value: String) { self.init(value) }
    public init(extendedGraphemeClusterLiteral value: String) { self.init(value) }
}

public extension HTTPFragmentParam {
    static func string(for fragments: [HTTPFragmentParam: String]) -> String {
        /// The clients are set up to handle keys with no values so exclude them since they would just waste characters
        return fragments
            .map { key, value in "\(key.rawValue)\(!value.isEmpty ? "=\(value)" : "")" }
            .joined(separator: "&")
    }
}
