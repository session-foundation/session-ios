// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtil

public extension Network.SessionPro {
    enum PaymentProvider: CaseIterable {
        case none
        case playStore
        case appStore
        
        var libSessionValue: SESSION_PRO_BACKEND_PAYMENT_PROVIDER {
            switch self {
                case .none: return SESSION_PRO_BACKEND_PAYMENT_PROVIDER_NIL
                case .playStore: return SESSION_PRO_BACKEND_PAYMENT_PROVIDER_GOOGLE_PLAY_STORE
                case .appStore: return SESSION_PRO_BACKEND_PAYMENT_PROVIDER_IOS_APP_STORE
            }
        }
        
        init(_ libSessionValue: SESSION_PRO_BACKEND_PAYMENT_PROVIDER) {
            switch libSessionValue {
                case SESSION_PRO_BACKEND_PAYMENT_PROVIDER_NIL: self = .none
                case SESSION_PRO_BACKEND_PAYMENT_PROVIDER_GOOGLE_PLAY_STORE: self = .playStore
                case SESSION_PRO_BACKEND_PAYMENT_PROVIDER_IOS_APP_STORE: self = .appStore
                default: self = .none
            }
        }
    }
}
