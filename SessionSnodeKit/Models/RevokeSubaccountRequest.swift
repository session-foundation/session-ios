// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtilitiesKit

extension SnodeAPI {
    public class RevokeSubaccountRequest: SnodeAuthenticatedRequestBody {
        enum CodingKeys: String, CodingKey {
            case subaccountToRevoke = "revoke"
        }
        
        let subaccountToRevoke: [UInt8]
        
        override var verificationBytes: [UInt8] {
            /// Ed25519 signature of `("revoke_subaccount" || timestamp || SUBACCOUNT_TAG_BYTES)`; this signs the subkey tag,
            /// using `pubkey` to sign. Must be base64 encoded for json requests; binary for OMQ requests.
            SnodeAPI.Endpoint.revokeSubaccount.path.bytes
                .appending(contentsOf: timestampMs.map { "\($0)" }?.data(using: .ascii)?.bytes)
                .appending(contentsOf: subaccountToRevoke)
        }
        
        // MARK: - Init
        
        public init(
            subaccountToRevoke: [UInt8],
            authMethod: AuthenticationMethod,
            timestampMs: UInt64
        ) {
            self.subaccountToRevoke = subaccountToRevoke
            
            super.init(
                authMethod: authMethod,
                timestampMs: timestampMs
            )
        }
        
        // MARK: - Coding
        
        override public func encode(to encoder: Encoder) throws {
            var container: KeyedEncodingContainer<CodingKeys> = encoder.container(keyedBy: CodingKeys.self)
            
            /// The `subaccountToRevoke` should be sent as a hex string
            try container.encode(subaccountToRevoke.toHexString(), forKey: .subaccountToRevoke)
            
            try super.encode(to: encoder)
        }
    }
}
