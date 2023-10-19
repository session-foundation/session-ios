// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtilitiesKit

extension SnodeAPI {
    public class UnrevokeSubaccountRequest: SnodeAuthenticatedRequestBody {
        enum CodingKeys: String, CodingKey {
            case subaccountToUnrevoke = "unrevoke"
        }
        
        let subaccountToUnrevoke: String
        
        override var verificationBytes: [UInt8] {
            /// Ed25519 signature of `("unrevoke_subaccount" || subaccount)`; this signs the subkey tag,
            /// using `pubkey` to sign. Must be base64 encoded for json requests; binary for OMQ requests.
            SnodeAPI.Endpoint.unrevokeSubaccount.path.bytes
                .appending(contentsOf: subaccountToUnrevoke.bytes)
        }
        
        // MARK: - Init
        
        public init(
            subaccountToUnrevoke: String,
            authMethod: AuthenticationMethod
        ) {
            self.subaccountToUnrevoke = subaccountToUnrevoke
            
            super.init(authMethod: authMethod)
        }
        
        // MARK: - Coding
        
        override public func encode(to encoder: Encoder) throws {
            var container: KeyedEncodingContainer<CodingKeys> = encoder.container(keyedBy: CodingKeys.self)
            
            try container.encode(subaccountToUnrevoke, forKey: .subaccountToUnrevoke)
            
            try super.encode(to: encoder)
        }
    }
}
