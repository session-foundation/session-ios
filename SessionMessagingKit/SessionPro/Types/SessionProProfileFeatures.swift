// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtil

public extension SessionPro {
    struct ProfileFeatures: OptionSet, Sendable, Codable, Equatable, Hashable, CustomStringConvertible {
        public let rawValue: UInt64
        
        public static let none: ProfileFeatures = ProfileFeatures(rawValue: 0)
        public static let proBadge: ProfileFeatures = ProfileFeatures(rawValue: 1 << 0)
        public static let animatedAvatar: ProfileFeatures = ProfileFeatures(rawValue: 1 << 1)
        public static let all: ProfileFeatures = [ proBadge, animatedAvatar ]
        
        var libSessionValue: session_protocol_pro_profile_bitset {
            var result: session_protocol_pro_profile_bitset = session_protocol_pro_profile_bitset()
            result.data = rawValue
            
            return result
        }
        
        // MARK: - Initialization
        
        public init(rawValue: UInt64) {
            self.rawValue = rawValue
        }
        
        public init(_ libSessionValue: session_protocol_pro_profile_bitset) {
            self = ProfileFeatures(rawValue: libSessionValue.data)
        }
        
        // MARK: - CustomStringConvertible
        
        // stringlint:ignore_contents
        public var description: String {
            var results: [String] = []
            
            if self.contains(.proBadge) {
                results.append("proBadge")
            }
            if self.contains(.animatedAvatar) {
                results.append("animatedAvatar")
            }
            
            return "[\(results.joined(separator: ", "))]"
        }
    }
}
