// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtil

public extension SessionPro {
    struct Features: OptionSet, Sendable, Codable, Equatable, Hashable {
        public let rawValue: UInt64
        
        public static let none: Features = Features(rawValue: 0)
        public static let largerCharacterLimit: Features = Features(rawValue: 1 << 0)
        public static let proBadge: Features = Features(rawValue: 1 << 1)
        public static let animatedAvatar: Features = Features(rawValue: 1 << 2)
        public static let all: Features = [ largerCharacterLimit, proBadge, animatedAvatar ]
        
        var libSessionValue: SESSION_PROTOCOL_PRO_FEATURES {
            SESSION_PROTOCOL_PRO_FEATURES(rawValue)
        }
        
        // MARK: - Initialization
        
        public init(rawValue: UInt64) {
            self.rawValue = rawValue
        }
        
        init(_ libSessionValue: SESSION_PROTOCOL_PRO_FEATURES) {
            self = Features(rawValue: libSessionValue)
        }
    }
}
