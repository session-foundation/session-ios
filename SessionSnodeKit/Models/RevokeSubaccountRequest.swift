// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtilitiesKit

extension SnodeAPI {
    public class RevokeSubaccountRequest: SnodeAuthenticatedRequestBody {
        enum CodingKeys: String, CodingKey {
            case subaccountToRevoke = "revoke"
        }
        
        let subaccountToRevoke: String
        
        override var verificationBytes: [UInt8] {
            /// Ed25519 signature of `("revoke_subaccount" || subaccount)`; this signs the subkey tag,
            /// using `pubkey` to sign. Must be base64 encoded for json requests; binary for OMQ requests.
            SnodeAPI.Endpoint.revokeSubaccount.path.bytes
                .appending(contentsOf: subaccountToRevoke.bytes)
        }
        
        // MARK: - Init
        
        public init(
            subaccountToRevoke: String,
            authMethod: AuthenticationMethod
        ) {
            self.subaccountToRevoke = subaccountToRevoke
            
            super.init(authMethod: authMethod)
        }
        
        // MARK: - Coding
        
        override public func encode(to encoder: Encoder) throws {
            var container: KeyedEncodingContainer<CodingKeys> = encoder.container(keyedBy: CodingKeys.self)
            
            try container.encode(subaccountToRevoke, forKey: .subaccountToRevoke)
            
            try super.encode(to: encoder)
        }
    }
}
