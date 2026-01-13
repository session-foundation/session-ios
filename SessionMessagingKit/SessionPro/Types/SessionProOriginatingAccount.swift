// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation

public extension SessionPro {
    enum OriginatingAccount: Sendable, Equatable, Hashable, CaseIterable, CustomStringConvertible, ExpressibleByBooleanLiteral {
        case originatingAccount
        case nonOriginatingAccount
        
        public init(booleanLiteral value: Bool) {
            self = (value ? .originatingAccount : .nonOriginatingAccount)
        }
        
        public init(_ value: Bool) {
            self = OriginatingAccount(booleanLiteral: value)
        }
        
        // stringlint:ignore_contents
        public var description: String {
            switch self {
                case .originatingAccount: return "Originating Account"
                case .nonOriginatingAccount: return "Non-originating Account"
            }
        }
    }
}
