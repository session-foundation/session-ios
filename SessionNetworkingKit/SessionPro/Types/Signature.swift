// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtil
import SessionUtilitiesKit

public extension Network.SessionPro {
    struct Signature: Equatable {
        public let signature: [UInt8]
        
        init(_ libSessionValue: session_pro_backend_signature) throws {
            guard libSessionValue.success else {
                Log.error([.network, .sessionPro], "Failed to build signature: \(libSessionValue.get(\.error))")
                throw CryptoError.signatureGenerationFailed
            }
            
            signature = libSessionValue.get(\.sig)
        }
    }
}

extension session_pro_backend_signature: @retroactive CAccessible {}
