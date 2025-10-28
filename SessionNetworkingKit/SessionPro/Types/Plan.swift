// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtil

public extension Network.SessionPro {
    enum Plan: CaseIterable {
        case none
        case oneMonth
        case threeMonths
        case twelveMonths
        
        var libSessionValue: SESSION_PRO_BACKEND_PLAN {
            switch self {
                case .none: return SESSION_PRO_BACKEND_PLAN_NIL
                case .oneMonth: return SESSION_PRO_BACKEND_PLAN_ONE_MONTH
                case .threeMonths: return SESSION_PRO_BACKEND_PLAN_THREE_MONTHS
                case .twelveMonths: return SESSION_PRO_BACKEND_PLAN_TWELVE_MONTHS
            }
        }
        
        init(_ libSessionValue: SESSION_PRO_BACKEND_PLAN) {
            switch libSessionValue {
                case SESSION_PRO_BACKEND_PLAN_NIL: self = .none
                case SESSION_PRO_BACKEND_PLAN_ONE_MONTH: self = .oneMonth
                case SESSION_PRO_BACKEND_PLAN_THREE_MONTHS: self = .threeMonths
                case SESSION_PRO_BACKEND_PLAN_TWELVE_MONTHS: self = .twelveMonths
                default: self = .none
            }
        }
    }
}
