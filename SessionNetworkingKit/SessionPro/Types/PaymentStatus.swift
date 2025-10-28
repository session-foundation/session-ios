// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtil

public extension Network.SessionPro {
    enum PaymentStatus: CaseIterable {
        case none
        case unredeemed
        case redeemed
        case expired
        case refunded
        
        var libSessionValue: SESSION_PRO_BACKEND_PAYMENT_STATUS {
            switch self {
                case .none: return SESSION_PRO_BACKEND_PAYMENT_STATUS_NIL
                case .unredeemed: return SESSION_PRO_BACKEND_PAYMENT_STATUS_UNREDEEMED
                case .redeemed: return SESSION_PRO_BACKEND_PAYMENT_STATUS_REDEEMED
                case .expired: return SESSION_PRO_BACKEND_PAYMENT_STATUS_EXPIRED
                case .refunded: return SESSION_PRO_BACKEND_PAYMENT_STATUS_REFUNDED
            }
        }
        
        init(_ libSessionValue: SESSION_PRO_BACKEND_PAYMENT_STATUS) {
            switch libSessionValue {
                case SESSION_PRO_BACKEND_PAYMENT_STATUS_NIL: self = .none
                case SESSION_PRO_BACKEND_PAYMENT_STATUS_UNREDEEMED: self = .unredeemed
                case SESSION_PRO_BACKEND_PAYMENT_STATUS_REDEEMED: self = .redeemed
                case SESSION_PRO_BACKEND_PAYMENT_STATUS_EXPIRED: self = .expired
                case SESSION_PRO_BACKEND_PAYMENT_STATUS_REFUNDED: self = .refunded
                default: self = .none
            }
        }
    }
}
