// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtilitiesKit

public extension Network.StorageServer {
    class BaseAuthenticatedRequestBody: Encodable {
        private enum CodingKeys: String, CodingKey {
            case pubkey
            case subaccount
            case timestampMs = "timestamp"
            case ed25519PublicKey = "pubkey_ed25519"
            case signatureBase64 = "signature"
            case subaccountSignatureBase64 = "subaccount_sig"
        }
        
        internal let timestampMs: UInt64?
        internal let authMethod: AuthenticationMethod
        
        var verificationBytes: [UInt8] { preconditionFailure("abstract class - override in subclass") }
        
        // MARK: - Initialization
        
        public init(
            timestampMs: UInt64?,
            authMethod: AuthenticationMethod
        ) {
            self.timestampMs = timestampMs
            self.authMethod = authMethod
        }
        
        // MARK: - Codable
        
        public func encode(to encoder: Encoder) throws {
            var container: KeyedEncodingContainer<CodingKeys> = encoder.container(keyedBy: CodingKeys.self)
            
            try container.encodeIfPresent(timestampMs, forKey: .timestampMs)

            // Generate the signature for the request for encoding
            let signature: Authentication.Signature = try authMethod.generateSignature(
                with: verificationBytes,
                using: try encoder.dependencies ?? { throw DependenciesError.missingDependencies }()
            )
            
            switch authMethod.info {
                case .standard(let sessionId, let ed25519PublicKey):
                    try container.encode(sessionId.hexString, forKey: .pubkey)
                    try container.encode(ed25519PublicKey.toHexString(), forKey: .ed25519PublicKey)
                    
                case .groupAdmin(let sessionId, _):
                    try container.encode(sessionId.hexString, forKey: .pubkey)
                    
                case .groupMember(let sessionId, _):
                    try container.encode(sessionId.hexString, forKey: .pubkey)
                    
                case .community: throw CryptoError.signatureGenerationFailed
            }
            
            switch signature {
                case .standard(let signature):
                    try container.encode(signature.toBase64(), forKey: .signatureBase64)
                    
                case .subaccount(let subaccount, let subaccountSig, let signature):
                    try container.encode(subaccount.toHexString(), forKey: .subaccount)
                    try container.encode(signature.toBase64(), forKey: .signatureBase64)
                    try container.encode(subaccountSig.toBase64(), forKey: .subaccountSignatureBase64)
            }
        }
    }
}
