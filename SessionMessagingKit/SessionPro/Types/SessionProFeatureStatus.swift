// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtil

public extension SessionPro {
    enum FeatureStatus: Equatable {
        case success
        case exceedsCharacterLimit

        var libSessionValue: SESSION_PROTOCOL_PRO_FEATURES_FOR_MSG_STATUS {
            switch self {
                case .success: return SESSION_PROTOCOL_PRO_FEATURES_FOR_MSG_STATUS_SUCCESS
                case .exceedsCharacterLimit: return SESSION_PROTOCOL_PRO_FEATURES_FOR_MSG_STATUS_EXCEEDS_CHARACTER_LIMIT
            }
        }

        init(_ libSessionValue: SESSION_PROTOCOL_PRO_FEATURES_FOR_MSG_STATUS) {
            switch libSessionValue {
                case SESSION_PROTOCOL_PRO_FEATURES_FOR_MSG_STATUS_EXCEEDS_CHARACTER_LIMIT: self = .exceedsCharacterLimit
                /// Only `SUCCESS`/`EXCEEDS_CHARACTER_LIMIT` exist now (the message text — and thus any
                /// decoding error — is no longer passed to libsession); default to `.success`.
                default: self = .success
            }
        }
    }
}
