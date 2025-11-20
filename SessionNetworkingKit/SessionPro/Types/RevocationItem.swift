// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtil
import SessionUtilitiesKit

public extension Network.SessionPro {
    struct RevocationItem: Equatable {
        public let genIndexHash: [UInt8]
        public let expiryUnixTimestampMs: UInt64
        
        init(_ libSessionValue: session_pro_backend_pro_revocation_item) {
            genIndexHash = libSessionValue.get(\.gen_index_hash)
            expiryUnixTimestampMs = libSessionValue.expiry_unix_ts_ms
        }
    }
}

extension session_pro_backend_pro_revocation_item: @retroactive CAccessible {}
