// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtil

public extension SessionPro {
    struct MessageFeatures: OptionSet, Sendable, Codable, Equatable, Hashable, CustomStringConvertible {
        public let rawValue: UInt64
        
        public static let none: MessageFeatures = MessageFeatures(rawValue: 0)
        public static let largerCharacterLimit: MessageFeatures = MessageFeatures(rawValue: 1 << 0)
        public static let all: MessageFeatures = [ largerCharacterLimit ]
        
        var libSessionValue: session_protocol_pro_message_bitset {
            var result: session_protocol_pro_message_bitset = session_protocol_pro_message_bitset()
            result.data = rawValue
            
            return result
        }
        
        var profileOnlyFeatures: MessageFeatures {
            self.subtracting(.largerCharacterLimit)
        }
        
        // MARK: - Initialization
        
        public init(rawValue: UInt64) {
            self.rawValue = rawValue
        }
        
        public init(_ libSessionValue: session_protocol_pro_message_bitset) {
            self = MessageFeatures(rawValue: libSessionValue.data)
        }
        
        // MARK: - CustomStringConvertible
        
        // stringlint:ignore_contents
        public var description: String {
            var results: [String] = []
            
            if self.contains(.largerCharacterLimit) {
                results.append("largerCharacterLimit")
            }
            
            return "[\(results.joined(separator: ", "))]"
        }
    }
}
