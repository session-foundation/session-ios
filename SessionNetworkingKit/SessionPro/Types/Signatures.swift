// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtil
import SessionUtilitiesKit

public extension Network.SessionPro {
    struct Signatures: Equatable {
        public let masterSignature: [UInt8]
        public let rotatingSignature: [UInt8]
        
        init(_ libSessionValue: session_pro_backend_master_rotating_signatures) throws {
            guard libSessionValue.success else {
                Log.error([.network, .sessionPro], "Failed to build signatures: \(libSessionValue.get(\.error))")
                throw CryptoError.signatureGenerationFailed
            }
            
            masterSignature = libSessionValue.get(\.master_sig)
            rotatingSignature = libSessionValue.get(\.rotating_sig)
        }
    }
}

extension session_pro_backend_master_rotating_signatures: @retroactive CAccessible {}
