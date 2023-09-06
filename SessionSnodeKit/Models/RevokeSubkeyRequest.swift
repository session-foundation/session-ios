// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtilitiesKit

extension SnodeAPI {
    public class RevokeSubkeyRequest: SnodeAuthenticatedRequestBody {
        enum CodingKeys: String, CodingKey {
            case subkeyToRevoke = "revoke_subkey"
        }
        
        let subkeyToRevoke: String
        
        // MARK: - Init
        
        public init(
            subkeyToRevoke: String,
            authInfo: AuthenticationInfo
        ) {
            self.subkeyToRevoke = subkeyToRevoke
            
            super.init(authInfo: authInfo)
        }
        
        // MARK: - Coding
        
        override public func encode(to encoder: Encoder) throws {
            var container: KeyedEncodingContainer<CodingKeys> = encoder.container(keyedBy: CodingKeys.self)
            
            try container.encode(subkeyToRevoke, forKey: .subkeyToRevoke)
            
            try super.encode(to: encoder)
        }
        
        // MARK: - Abstract Methods
        
        override func generateSignature(using dependencies: Dependencies) throws -> [UInt8] {
            /// Ed25519 signature of `("revoke_subkey" || subkey)`; this signs the subkey tag,
            /// using `pubkey` to sign. Must be base64 encoded for json requests; binary for OMQ requests.
            let verificationBytes: [UInt8] = SnodeAPI.Endpoint.revokeSubkey.path.bytes
                .appending(contentsOf: subkeyToRevoke.bytes)
            
            return try authInfo.generateSignature(with: verificationBytes, using: dependencies)
        }
    }
}
