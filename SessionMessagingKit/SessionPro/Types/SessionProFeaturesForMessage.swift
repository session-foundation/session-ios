// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtil
import SessionUtilitiesKit

public extension SessionPro {
    struct FeaturesForMessage: Equatable {
        public let status: FeatureStatus
        public let error: String?
        public let features: MessageFeatures

        // MARK: - Initialization

        init(status: FeatureStatus, error: String? = nil, features: MessageFeatures = []) {
            self.status = status
            self.error = error
            self.features = features
        }

        init(_ libSessionValue: session_protocol_pro_features_for_msg) {
            status = FeatureStatus(libSessionValue.status)
            error = libSessionValue.get(\.error, nullIfEmpty: true)
            features = MessageFeatures(libSessionValue.bitset)
        }
    }
}

extension session_protocol_pro_features_for_msg: @retroactive CAccessible {}
