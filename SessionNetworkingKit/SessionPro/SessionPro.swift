// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import SessionUtil
import SessionUtilitiesKit

public extension Network {
    enum SessionPro {
        public static let apiVersion: UInt8 = 0

        /// The backend base URL + Ed25519 signing pubkey now come from libsession (single source of
        /// truth), replacing the previously hard-coded — and stale — client copies. libsession owns the
        /// prod/default values; a dev/test override, if needed, still lives client-side.
        static let server: String = (SESSION_PRO_BACKEND_URL.map { String(cString: $0) } ?? "")
        public static let serverEdPublicKey: String =
            (SESSION_PRO_BACKEND_PUBKEY.map { Data(bytes: $0, count: 32).toHexString() } ?? "")

        internal static func x25519PublicKey(using dependencies: Dependencies) throws -> String {
            let x25519Pubkey: [UInt8] = try dependencies[singleton: .crypto].tryGenerate(
                .x25519(ed25519Pubkey: Array(Data(hex: serverEdPublicKey)))
            )

            return x25519Pubkey.toHexString()
        }
    }
}
