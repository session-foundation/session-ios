// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation

extension SnodeAPI {
    public class GetMessagesRequest: SnodeAuthenticatedRequestBody {
        enum CodingKeys: String, CodingKey {
            case lastHash = "last_hash"
            case namespace
        }
        
        let lastHash: String
        let namespace: SnodeAPI.Namespace?
        
        // MARK: - Init
        
        public init(
            lastHash: String,
            namespace: SnodeAPI.Namespace?,
            pubkey: String,
            subkey: String?,
            timestampMs: UInt64,
            ed25519PublicKey: [UInt8],
            ed25519SecretKey: [UInt8]
        ) {
            self.lastHash = lastHash
            self.namespace = namespace
            
            super.init(
                pubkey: pubkey,
                ed25519PublicKey: ed25519PublicKey,
                ed25519SecretKey: ed25519SecretKey,
                subkey: subkey,
                timestampMs: timestampMs
            )
        }
        
        // MARK: - Coding
        
        override public func encode(to encoder: Encoder) throws {
            var container: KeyedEncodingContainer<CodingKeys> = encoder.container(keyedBy: CodingKeys.self)
            
            try container.encode(lastHash, forKey: .lastHash)
            try container.encodeIfPresent(namespace, forKey: .namespace)
            
            try super.encode(to: encoder)
        }
        
        // MARK: - Abstract Methods
        
        override func generateSignature() throws -> [UInt8] {
            /// Ed25519 signature of `("retrieve" || namespace || timestamp)` (if using a non-0
            /// namespace), or `("retrieve" || timestamp)` when fetching from the default namespace.  Both
            /// namespace and timestamp are the base10 expressions of the relevant values.  Must be base64
            /// encoded for json requests; binary for OMQ requests.
            let verificationBytes: [UInt8] = SnodeAPI.Endpoint.getMessages.rawValue.bytes
                .appending(contentsOf: namespace?.verificationString.bytes)
                .appending(contentsOf: timestampMs.map { "\($0)" }?.data(using: .utf8)?.bytes)
            
            guard
                let signatureBytes: [UInt8] = sodium.wrappedValue.sign.signature(
                    message: verificationBytes,
                    secretKey: ed25519SecretKey
                )
            else {
                throw SnodeAPIError.signingFailed
            }
            
            return signatureBytes
        }
    }
}
