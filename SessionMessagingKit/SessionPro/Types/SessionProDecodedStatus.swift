// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import SessionUtil
import SessionUtilitiesKit

public extension SessionPro {
    enum DecodedStatus: Sendable, Codable, CaseIterable {
        case none
        case invalidProBackendSig
        case invalidUserSig
        case valid
        case expired
        
        var libSessionValue: SESSION_PROTOCOL_PRO_STATUS {
            switch self {
                case .none: return SESSION_PROTOCOL_PRO_STATUS_NIL
                case .invalidProBackendSig: return SESSION_PROTOCOL_PRO_STATUS_INVALID_PRO_BACKEND_SIG
                case .invalidUserSig: return SESSION_PROTOCOL_PRO_STATUS_INVALID_USER_SIG
                case .valid: return SESSION_PROTOCOL_PRO_STATUS_VALID
                case .expired: return SESSION_PROTOCOL_PRO_STATUS_EXPIRED
            }
        }
        
        public init(_ libSessionValue: SESSION_PROTOCOL_PRO_STATUS) {
            switch libSessionValue {
                case SESSION_PROTOCOL_PRO_STATUS_NIL: self = .none
                case SESSION_PROTOCOL_PRO_STATUS_INVALID_PRO_BACKEND_SIG: self = .invalidProBackendSig
                case SESSION_PROTOCOL_PRO_STATUS_INVALID_USER_SIG: self = .invalidUserSig
                case SESSION_PROTOCOL_PRO_STATUS_VALID: self = .valid
                case SESSION_PROTOCOL_PRO_STATUS_EXPIRED: self = .expired
                default: self = .none
            }
        }
    }
}
