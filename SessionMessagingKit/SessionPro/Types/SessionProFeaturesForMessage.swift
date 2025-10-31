// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtil
import SessionUtilitiesKit

public extension SessionPro {
    struct FeaturesForMessage: Equatable {
        let status: FeatureStatus
        let error: String?
        let features: Features
        let codePointCount: Int
        
        static let invalidString: FeaturesForMessage = FeaturesForMessage(status: .utfDecodingError)
        
        // MARK: - Initialization
        
        init(status: FeatureStatus, error: String? = nil, features: Features = [], codePointCount: Int = 0) {
            self.status = status
            self.error = error
            self.features = features
            self.codePointCount = codePointCount
        }
        
        init(_ libSessionValue: session_protocol_pro_features_for_msg) {
            status = FeatureStatus(libSessionValue.status)
            error = libSessionValue.get(\.error, nullIfEmpty: true)
            features = Features(libSessionValue.features)
            codePointCount = libSessionValue.codepoint_count
        }
    }
}

extension session_protocol_pro_features_for_msg: @retroactive CAccessible {}
