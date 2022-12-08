// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation

extension SnodeAPI {
    public class UpdateExpiryRequest: SnodeAuthenticatedRequestBody {
        enum CodingKeys: String, CodingKey {
            case messageHashes = "messages"
            case expiryMs = "expiry"
        }
        
        let messageHashes: [String]
        let expiryMs: UInt64
        
        // MARK: - Init
        
        public init(
            messageHashes: [String],
            expiryMs: UInt64,
            pubkey: String,
            ed25519PublicKey: [UInt8],
            ed25519SecretKey: [UInt8],
            subkey: String?
        ) {
            self.messageHashes = messageHashes
            self.expiryMs = expiryMs
            
            super.init(
                pubkey: pubkey,
                ed25519PublicKey: ed25519PublicKey,
                ed25519SecretKey: ed25519SecretKey,
                subkey: subkey
            )
        }
        
        // MARK: - Coding
        
        override public func encode(to encoder: Encoder) throws {
            var container: KeyedEncodingContainer<CodingKeys> = encoder.container(keyedBy: CodingKeys.self)
            
            try container.encode(messageHashes, forKey: .messageHashes)
            try container.encode(expiryMs, forKey: .expiryMs)
            
            try super.encode(to: encoder)
        }
        
        // MARK: - Abstract Methods
        
        override func generateSignature() throws -> [UInt8] {
            /// Ed25519 signature of `("expire" || expiry || messages[0] || ... || messages[N])`
            /// where `expiry` is the expiry timestamp expressed as a string.  The signature must be base64
            /// encoded (json) or bytes (bt).
            let verificationBytes: [UInt8] = SnodeAPI.Endpoint.expire.rawValue.bytes
                .appending(contentsOf: "\(expiryMs)".data(using: .ascii)?.bytes)
                .appending(contentsOf: messageHashes.joined().bytes)
            
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
