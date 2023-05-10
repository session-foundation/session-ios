// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation

extension SnodeAPI {
    public class DeleteAllMessagesRequest: SnodeAuthenticatedRequestBody {
        enum CodingKeys: String, CodingKey {
            case namespace
        }
        
        /// The message namespace from which to delete messages.  The request will delete all messages
        /// from the specific namespace, or from all namespaces when not provided
        ///
        /// **Note:** If omitted when sending the request, messages are deleted from the default namespace
        /// only (namespace 0)
        let namespace: SnodeAPI.Namespace?
        
        // MARK: - Init
        
        public init(
            namespace: SnodeAPI.Namespace?,
            pubkey: String,
            timestampMs: UInt64,
            ed25519PublicKey: [UInt8],
            ed25519SecretKey: [UInt8]
        ) {
            self.namespace = namespace
            
            super.init(
                pubkey: pubkey,
                ed25519PublicKey: ed25519PublicKey,
                ed25519SecretKey: ed25519SecretKey,
                timestampMs: timestampMs
            )
        }
        
        // MARK: - Coding
        
        override public func encode(to encoder: Encoder) throws {
            var container: KeyedEncodingContainer<CodingKeys> = encoder.container(keyedBy: CodingKeys.self)
            
            // If no namespace is specified it defaults to the default namespace only (namespace
            // 0), so instead in this case we want to explicitly delete from `all` namespaces
            switch namespace {
                case .some(let namespace): try container.encode(namespace, forKey: .namespace)
                case .none: try container.encode("all", forKey: .namespace)
            }
            
            try super.encode(to: encoder)
        }
        
        // MARK: - Abstract Methods
        
        override func generateSignature() throws -> [UInt8] {
            /// Ed25519 signature of `( "delete_all" || namespace || timestamp )`, where
            /// `namespace` is the empty string for the default namespace (whether explicitly specified or
            /// not), and otherwise the stringified version of the namespace parameter (i.e. "99" or "-42" or "all").
            /// The signature must be signed by the ed25519 pubkey in `pubkey` (omitting the leading prefix).
            /// Must be base64 encoded for json requests; binary for OMQ requests.
            let verificationBytes: [UInt8] = SnodeAPI.Endpoint.deleteAll.rawValue.bytes
                .appending(
                    contentsOf: (namespace == nil ?
                        "all" :
                        namespace?.verificationString
                    )?.bytes
                )
                .appending(contentsOf: timestampMs.map { "\($0)" }?.data(using: .ascii)?.bytes)
            
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
