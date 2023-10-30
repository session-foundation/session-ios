// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtilitiesKit

extension SnodeAPI {
    public class UnrevokeSubaccountRequest: SnodeAuthenticatedRequestBody {
        enum CodingKeys: String, CodingKey {
            case subaccountToUnrevoke = "unrevoke"
        }
        
        let subaccountToUnrevoke: [UInt8]
        
        override var verificationBytes: [UInt8] {
            /// Ed25519 signature of `("unrevoke_subaccount" || timestamp || subaccount)`; this signs the subkey tag,
            /// using `pubkey` to sign. Must be base64 encoded for json requests; binary for OMQ requests.
            SnodeAPI.Endpoint.unrevokeSubaccount.path.bytes
                .appending(contentsOf: timestampMs.map { "\($0)" }?.data(using: .ascii)?.bytes)
                .appending(contentsOf: subaccountToUnrevoke)
        }
        
        // MARK: - Init
        
        public init(
            subaccountToUnrevoke: [UInt8],
            authMethod: AuthenticationMethod,
            timestampMs: UInt64
        ) {
            self.subaccountToUnrevoke = subaccountToUnrevoke
            
            super.init(
                authMethod: authMethod,
                timestampMs: timestampMs
            )
        }
        
        // MARK: - Coding
        
        override public func encode(to encoder: Encoder) throws {
            var container: KeyedEncodingContainer<CodingKeys> = encoder.container(keyedBy: CodingKeys.self)
            
            /// The `subaccountToRevoke` should be sent as a hex string
            try container.encode(subaccountToUnrevoke.toHexString(), forKey: .subaccountToUnrevoke)
            
            try super.encode(to: encoder)
        }
    }
}
