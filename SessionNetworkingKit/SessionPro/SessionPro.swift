// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import SessionUtilitiesKit

public extension Network {
    enum SessionPro {
        public static let apiVersion: UInt8 = 0
        static let server = "{NEED_TO_SET}"
        public static let serverEdPublicKey = "{NEED_TO_SET}"
        
        internal static func x25519PublicKey(using dependencies: Dependencies) throws -> String {
            let x25519Pubkey: [UInt8] = try dependencies[singleton: .crypto].tryGenerate(
                .x25519(ed25519Pubkey: Array(Data(hex: serverEdPublicKey)))
            )
            
            return x25519Pubkey.toHexString()
        }
    }
}
