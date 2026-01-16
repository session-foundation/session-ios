// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtil

public extension Network.SessionPro {
    enum PaymentProvider: Sendable, Equatable, Hashable, CaseIterable {
        case playStore
        case appStore
        
        var libSessionValue: SESSION_PRO_BACKEND_PAYMENT_PROVIDER {
            switch self {
                case .playStore: return SESSION_PRO_BACKEND_PAYMENT_PROVIDER_GOOGLE_PLAY_STORE
                case .appStore: return SESSION_PRO_BACKEND_PAYMENT_PROVIDER_IOS_APP_STORE
            }
        }
        
        init?(_ libSessionValue: SESSION_PRO_BACKEND_PAYMENT_PROVIDER) {
            switch libSessionValue {
                case SESSION_PRO_BACKEND_PAYMENT_PROVIDER_NIL: return nil
                case SESSION_PRO_BACKEND_PAYMENT_PROVIDER_GOOGLE_PLAY_STORE: self = .playStore
                case SESSION_PRO_BACKEND_PAYMENT_PROVIDER_IOS_APP_STORE: self = .appStore
                default: return nil
            }
        }
    }
}
