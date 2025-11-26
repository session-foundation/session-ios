// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtil
import SessionNetworkingKit

public extension SessionPro {
    struct DecodedProForMessage: Sendable, Codable, Equatable {
        let status: SessionPro.DecodedStatus
        let proProof: Network.SessionPro.ProProof
        let features: Features
        
        // MARK: - Initialization
        
        init(status: SessionPro.DecodedStatus, proProof: Network.SessionPro.ProProof, features: Features) {
            self.status = status
            self.proProof = proProof
            self.features = features
        }
        
        init(_ libSessionValue: session_protocol_decoded_pro) {
            status = SessionPro.DecodedStatus(libSessionValue.status)
            proProof = Network.SessionPro.ProProof(libSessionValue.proof)
            features = Features(libSessionValue.features)
        }
    }
}
