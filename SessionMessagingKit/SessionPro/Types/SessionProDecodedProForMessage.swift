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

        /// Whether the pro content can be trusted, ie. whether `libSession` verified the proof against the Session Pro backend's
        /// public key when the message was decoded (`libSession` documents this as the way to decide whether the proof and it's
        /// features can be respected - see `session_protocol.h` `session_protocol_decode_envelope`)
        ///
        /// **Note:** We include the `expired` case because it's possible another device received and synced it while the data was
        /// `valid` and we don't want to incorrectly remove pro state (or cause a config ping-pong due to inconsistent behaviours) -
        /// an expired proof still grants no features because expiry is re-checked when resolving a profile's features
        var isVerified: Bool {
            switch status {
                case .valid, .expired: return true
                case .none, .invalidProBackendSig, .invalidUserSig: return false
            }
        }

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
