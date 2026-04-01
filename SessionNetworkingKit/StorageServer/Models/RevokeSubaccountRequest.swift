// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtilitiesKit

extension Network.StorageServer {
    class RevokeSubaccountRequest: BaseAuthenticatedRequestBody {
        enum CodingKeys: String, CodingKey {
            case subaccountsToRevoke = "revoke"
        }
        
        let subaccountsToRevoke: [[UInt8]]
        
        override var verificationBytes: [UInt8] {
            /// Ed25519 signature of `("revoke_subaccount" || timestamp || SUBACCOUNT_TAG_BYTES...)`; this
            /// signs the subaccount token, using `pubkey` to sign. Must be base64 encoded for json requests; binary for OMQ requests.
            Endpoint.revokeSubaccount.path.bytes
                .appending(contentsOf: timestampMs.map { "\($0)" }?.data(using: .ascii)?.bytes)
                .appending(contentsOf: Array(subaccountsToRevoke.joined()))
        }
        
        // MARK: - Init
        
        public init(
            subaccountsToRevoke: [[UInt8]],
            timestampMs: UInt64,
            authMethod: AuthenticationMethod
        ) {
            self.subaccountsToRevoke = subaccountsToRevoke
            
            super.init(
                timestampMs: timestampMs,
                authMethod: authMethod
            )
        }
        
        // MARK: - Coding
        
        override public func encode(to encoder: Encoder) throws {
            var container: KeyedEncodingContainer<CodingKeys> = encoder.container(keyedBy: CodingKeys.self)
            
            /// The `subaccountToRevoke` should be sent as either a single hex string or an array of them
            switch subaccountsToRevoke.count {
                case 1: try container.encode(subaccountsToRevoke[0].toHexString(), forKey: .subaccountsToRevoke)
                default: try container.encode(subaccountsToRevoke.map { $0.toHexString() }, forKey: .subaccountsToRevoke)
            }
            
            try super.encode(to: encoder)
        }
    }
}
