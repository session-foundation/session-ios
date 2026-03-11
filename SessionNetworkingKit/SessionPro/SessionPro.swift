// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import SessionUtilitiesKit

public extension Network {
    enum SessionPro {
        public static let apiVersion: UInt8 = 0
        static let server = "https://pro-backend-dev-pgsql.getsession.org/"
        public static let serverEdPublicKey = "fc947730f49eb01427a66e050733294d9e520e545c7a27125a780634e0860a27"
        
        internal static func x25519PublicKey(using dependencies: Dependencies) throws -> String {
            let x25519Pubkey: [UInt8] = try dependencies[singleton: .crypto].tryGenerate(
                .x25519(ed25519Pubkey: Array(Data(hex: serverEdPublicKey)))
            )
            
            return x25519Pubkey.toHexString()
        }
    }
}
