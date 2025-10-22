// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtil
import SessionUtilitiesKit

public extension Network.SessionPro {
    struct ProProof: Equatable {
        let version: UInt8
        let genIndexHash: [UInt8]
        let rotatingPubkey: [UInt8]
        let expiryUnixTimestampMs: UInt64
        let signature: [UInt8]
        
        init(_ libSessionValue: session_protocol_pro_proof) {
            version = libSessionValue.version
            genIndexHash = libSessionValue.get(\.gen_index_hash)
            rotatingPubkey = libSessionValue.get(\.rotating_pubkey)
            expiryUnixTimestampMs = libSessionValue.expiry_unix_ts_ms
            signature = libSessionValue.get(\.sig)
        }
    }
}

extension session_protocol_pro_proof: @retroactive CAccessible {}
