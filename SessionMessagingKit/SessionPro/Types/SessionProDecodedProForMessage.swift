// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtil
import SessionNetworkingKit

public extension SessionPro {
    struct DecodedProForMessage: Sendable, Codable, Equatable {
        let status: SessionPro.DecodedStatus?
        let proProof: Network.SessionPro.ProProof
        let messageFeatures: MessageFeatures
        let profileFeatures: ProfileFeatures
        
        // MARK: - Initialization
        
        init(
            status: SessionPro.DecodedStatus?,
            proProof: Network.SessionPro.ProProof,
            messageFeatures: MessageFeatures,
            profileFeatures: ProfileFeatures
        ) {
            self.status = status
            self.proProof = proProof
            self.messageFeatures = messageFeatures
            self.profileFeatures = profileFeatures
        }
        
        init(_ libSessionValue: session_protocol_decoded_pro) {
            status = SessionPro.DecodedStatus(libSessionValue.status)
            proProof = Network.SessionPro.ProProof(libSessionValue.proof)
            messageFeatures = MessageFeatures(libSessionValue.msg_bitset)
            profileFeatures = ProfileFeatures(libSessionValue.profile_bitset)
        }
    }
}
