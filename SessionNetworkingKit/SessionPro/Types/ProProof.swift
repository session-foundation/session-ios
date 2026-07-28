// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtil
import SessionUtilitiesKit

public extension Network.SessionPro {
    struct ProProof: Sendable, Codable, Equatable, Hashable {
        public let version: UInt8
        public let revocationTag: [UInt8]
        public let rotatingPubkey: [UInt8]
        public let expiryUnixTimestampSeconds: UInt64
        public let signature: [UInt8]
        
        public var libSessionValue: session_protocol_pro_proof {
            var result: session_protocol_pro_proof = session_protocol_pro_proof()
            result.version = version
            /// libsession renamed `gen_index_hash` -> `revocation_tag`. The proof expiry is whole
            /// unix seconds on both the C side (`expiry_ts`) and our domain, so this is a direct assign.
            result.set(\.revocation_tag, to: revocationTag)
            result.set(\.rotating_pubkey, to: rotatingPubkey)
            result.expiry_ts = Int64(expiryUnixTimestampSeconds)
            result.set(\.sig, to: signature)

            return result
        }
        
        // MARK: - Initialization
        
        public init(
            version: UInt8 = Network.SessionPro.apiVersion,
            revocationTag: [UInt8] = [],
            rotatingPubkey: [UInt8] = [],
            expiryUnixTimestampSeconds: UInt64 = 0,
            signature: [UInt8] = []
        ) {
            self.version = version
            self.revocationTag = revocationTag
            self.rotatingPubkey = rotatingPubkey
            self.expiryUnixTimestampSeconds = expiryUnixTimestampSeconds
            self.signature = signature
        }
        
        public init(_ libSessionValue: session_protocol_pro_proof) {
            version = libSessionValue.version
            /// `revocation_tag` (renamed from `gen_index_hash`); expiry is whole unix seconds on the C side
            revocationTag = libSessionValue.get(\.revocation_tag)
            rotatingPubkey = libSessionValue.get(\.rotating_pubkey)
            expiryUnixTimestampSeconds = UInt64(max(0, libSessionValue.expiry_ts))
            signature = libSessionValue.get(\.sig)
        }
    }
}

extension session_protocol_pro_proof: @retroactive CMutable & CAccessible {}
