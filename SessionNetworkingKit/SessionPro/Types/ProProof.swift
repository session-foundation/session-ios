// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtil
import SessionUtilitiesKit

public extension Network.SessionPro {
    struct ProProof: Sendable, Codable, Equatable {
        public let version: UInt8
        public let genIndexHash: [UInt8]
        public let rotatingPubkey: [UInt8]
        public let expiryUnixTimestampMs: UInt64
        public let signature: [UInt8]
        
        public var libSessionValue: session_protocol_pro_proof {
            var result: session_protocol_pro_proof = session_protocol_pro_proof()
            result.version = version
            result.set(\.gen_index_hash, to: genIndexHash)
            result.set(\.rotating_pubkey, to: rotatingPubkey)
            result.expiry_unix_ts_ms = expiryUnixTimestampMs
            result.set(\.sig, to: signature)
            
            return result
        }
        
        // MARK: - Initialization
        
        public init(
            version: UInt8 = Network.SessionPro.apiVersion,
            genIndexHash: [UInt8] = [],
            rotatingPubkey: [UInt8] = [],
            expiryUnixTimestampMs: UInt64 = 0,
            signature: [UInt8] = []
        ) {
            self.version = version
            self.genIndexHash = genIndexHash
            self.rotatingPubkey = rotatingPubkey
            self.expiryUnixTimestampMs = expiryUnixTimestampMs
            self.signature = signature
        }
        
        public init(_ libSessionValue: session_protocol_pro_proof) {
            version = libSessionValue.version
            genIndexHash = libSessionValue.get(\.gen_index_hash)
            rotatingPubkey = libSessionValue.get(\.rotating_pubkey)
            expiryUnixTimestampMs = libSessionValue.expiry_unix_ts_ms
            signature = libSessionValue.get(\.sig)
        }
    }
}

extension session_protocol_pro_proof: @retroactive CMutable & CAccessible {}
