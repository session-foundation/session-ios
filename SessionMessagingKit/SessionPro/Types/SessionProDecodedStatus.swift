// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import SessionUtil
import SessionUtilitiesKit

public extension SessionPro {
    enum DecodedStatus: Sendable, Codable, CaseIterable {
        case invalidProBackendSig
        case invalidUserSig
        case valid
        case expired
        
        public init?(_ libSessionValue: SESSION_PROTOCOL_PRO_STATUS) {
            switch libSessionValue {
                case SESSION_PROTOCOL_PRO_STATUS_NIL: return nil
                case SESSION_PROTOCOL_PRO_STATUS_INVALID_PRO_BACKEND_SIG: self = .invalidProBackendSig
                case SESSION_PROTOCOL_PRO_STATUS_INVALID_USER_SIG: self = .invalidUserSig
                case SESSION_PROTOCOL_PRO_STATUS_VALID: self = .valid
                case SESSION_PROTOCOL_PRO_STATUS_EXPIRED: self = .expired
                default: return nil
            }
        }
    }
}
