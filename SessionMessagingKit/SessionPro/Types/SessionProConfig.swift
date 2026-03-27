// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtil
import SessionNetworkingKit
import SessionUtilitiesKit

public extension SessionPro {
    struct ProConfig {
        let rotatingPrivateKey: [UInt8]
        let proProof: Network.SessionPro.ProProof
        
        var libSessionValue: pro_pro_config {
            var config: pro_pro_config = pro_pro_config()
            config.set(\.rotating_privkey, to: rotatingPrivateKey)
            config.proof = proProof.libSessionValue
            
            return config
        }
        
        // MARK: - Initialization
        
        init(
            rotatingPrivateKey: [UInt8],
            proProof: Network.SessionPro.ProProof
        ) {
            self.rotatingPrivateKey = rotatingPrivateKey
            self.proProof = proProof
        }
        
        init(_ libSessionValue: pro_pro_config) {
            rotatingPrivateKey = libSessionValue.get(\.rotating_privkey)
            proProof = Network.SessionPro.ProProof(libSessionValue.proof)
        }
    }
}

extension pro_pro_config: @retroactive CAccessible & CMutable {}
