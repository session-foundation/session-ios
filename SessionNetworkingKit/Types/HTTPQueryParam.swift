// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation

public struct HTTPQueryParam: RawRepresentable, Codable, ExpressibleByStringLiteral, Hashable {
    public let rawValue: String
    
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init?(rawValue: String) { self.init(rawValue) }
    public init(stringLiteral value: String) { self.init(value) }
    public init(unicodeScalarLiteral value: String) { self.init(value) }
    public init(extendedGraphemeClusterLiteral value: String) { self.init(value) }
}

public extension HTTPQueryParam {
    static func string(for parameters: [HTTPQueryParam: String]) -> String {
        return parameters
            .map { key, value in "\(key.rawValue)=\(value)" }
            .joined(separator: "&")
    }
}
