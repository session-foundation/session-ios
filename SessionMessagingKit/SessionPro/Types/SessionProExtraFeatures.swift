// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtil

public extension SessionPro {
    struct ExtraFeatures: OptionSet, Equatable, Hashable {
        public let rawValue: UInt64
        
        public static let none: ExtraFeatures = ExtraFeatures(rawValue: 0)
        public static let proBadge: ExtraFeatures = ExtraFeatures(rawValue: 1 << 0)
        public static let animatedAvatar: ExtraFeatures = ExtraFeatures(rawValue: 1 << 1)
        public static let all: ExtraFeatures = [ proBadge, animatedAvatar ]
        
        var libSessionValue: SESSION_PROTOCOL_PRO_EXTRA_FEATURES {
            SESSION_PROTOCOL_PRO_EXTRA_FEATURES(rawValue)
        }
        
        // MARK: - Initialization
        
        public init(rawValue: UInt64) {
            self.rawValue = rawValue
        }
        
        init(_ libSessionValue: SESSION_PROTOCOL_PRO_EXTRA_FEATURES) {
            self = ExtraFeatures(rawValue: libSessionValue)
        }
    }
}

