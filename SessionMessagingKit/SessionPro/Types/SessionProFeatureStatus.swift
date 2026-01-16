// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtil

public extension SessionPro {
    enum FeatureStatus: Equatable {
        case success
        case utfDecodingError
        case exceedsCharacterLimit
        
        var libSessionValue: SESSION_PROTOCOL_PRO_FEATURES_FOR_MSG_STATUS {
            switch self {
                case .success: return SESSION_PROTOCOL_PRO_FEATURES_FOR_MSG_STATUS_SUCCESS
                case .utfDecodingError: return SESSION_PROTOCOL_PRO_FEATURES_FOR_MSG_STATUS_UTF_DECODING_ERROR
                case .exceedsCharacterLimit: return SESSION_PROTOCOL_PRO_FEATURES_FOR_MSG_STATUS_EXCEEDS_CHARACTER_LIMIT
            }
        }
        
        init(_ libSessionValue: SESSION_PROTOCOL_PRO_FEATURES_FOR_MSG_STATUS) {
            switch libSessionValue {
                case SESSION_PROTOCOL_PRO_FEATURES_FOR_MSG_STATUS_SUCCESS: self = .success
                case SESSION_PROTOCOL_PRO_FEATURES_FOR_MSG_STATUS_UTF_DECODING_ERROR: self = .utfDecodingError
                case SESSION_PROTOCOL_PRO_FEATURES_FOR_MSG_STATUS_EXCEEDS_CHARACTER_LIMIT: self = .exceedsCharacterLimit
                default: self = .utfDecodingError
            }
        }
    }
}
