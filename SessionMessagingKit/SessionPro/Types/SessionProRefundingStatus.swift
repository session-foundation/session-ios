// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation

public extension SessionPro {
    enum RefundingStatus: Sendable, Equatable, Hashable, CaseIterable, CustomStringConvertible, ExpressibleByBooleanLiteral {
        case notRefunding
        case refunding
        
        public init(booleanLiteral value: Bool) {
            self = (value ? .refunding : .notRefunding)
        }
        
        public init(_ value: Bool) {
            self = RefundingStatus(booleanLiteral: value)
        }
        
        // stringlint:ignore_contents
        public var description: String {
            switch self {
                case .notRefunding: return "Not Refunding"
                case .refunding: return "Refunding"
            }
        }
    }
}
