// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtil

public extension Network.SessionPro {
    enum AddProPaymentResponseStatus: CaseIterable {
        case success
        case error
        case parseError
        case alreadyRedeemed
        case unknownPayment
        
        var libSessionValue: SESSION_PRO_BACKEND_ADD_PRO_PAYMENT_RESPONSE_STATUS {
            switch self {
                case .success: return SESSION_PRO_BACKEND_ADD_PRO_PAYMENT_RESPONSE_STATUS_SUCCESS
                case .error: return SESSION_PRO_BACKEND_ADD_PRO_PAYMENT_RESPONSE_STATUS_ERROR
                case .parseError: return SESSION_PRO_BACKEND_ADD_PRO_PAYMENT_RESPONSE_STATUS_PARSE_ERROR
                case .alreadyRedeemed: return SESSION_PRO_BACKEND_ADD_PRO_PAYMENT_RESPONSE_STATUS_ALREADY_REDEEMED
                case .unknownPayment: return SESSION_PRO_BACKEND_ADD_PRO_PAYMENT_RESPONSE_STATUS_UNKNOWN_PAYMENT
            }
        }
        
        init(_ libSessionValue: SESSION_PRO_BACKEND_ADD_PRO_PAYMENT_RESPONSE_STATUS) {
            switch libSessionValue {
                case SESSION_PRO_BACKEND_ADD_PRO_PAYMENT_RESPONSE_STATUS_SUCCESS: self = .success
                case SESSION_PRO_BACKEND_ADD_PRO_PAYMENT_RESPONSE_STATUS_ERROR: self = .error
                case SESSION_PRO_BACKEND_ADD_PRO_PAYMENT_RESPONSE_STATUS_PARSE_ERROR: self = .parseError
                case SESSION_PRO_BACKEND_ADD_PRO_PAYMENT_RESPONSE_STATUS_ALREADY_REDEEMED: self = .alreadyRedeemed
                case SESSION_PRO_BACKEND_ADD_PRO_PAYMENT_RESPONSE_STATUS_UNKNOWN_PAYMENT: self = .unknownPayment
                default: self = .error
            }
        }
    }
}
