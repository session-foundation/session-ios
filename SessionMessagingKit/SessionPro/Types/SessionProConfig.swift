// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtil
import SessionNetworkingKit
import SessionUtilitiesKit

public extension SessionPro {
    struct ProConfig {
        let rotatingPrivateKey: [UInt8]
        let proProof: Network.SessionPro.ProProof
        
        init(_ libSessionValue: pro_pro_config) {
            rotatingPrivateKey = libSessionValue.get(\.rotating_privkey)
            proProof = Network.SessionPro.ProProof(libSessionValue.proof)
        }
    }
}

extension pro_pro_config: @retroactive CAccessible {}
