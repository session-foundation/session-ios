// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtilitiesKit

public extension Network.StorageServer {
    class SendMessageRequest: BaseAuthenticatedRequestBody {
        private enum CodingKeys: String, CodingKey {
            case recipient = "pubkey"
            case namespace
            case data
            case ttl
            case timestampMs = "timestamp"
        }
        
        /// The hex encoded public key of the recipient.
        public let recipient: String
        
        /// The namespace the message shoudl be stored in.
        public let namespace: Namespace
        
        /// The content of the message.
        public let data: String
        
        /// The time to live for the message in milliseconds.
        public let ttl: UInt64
        
        override var verificationBytes: [UInt8] {
            /// Ed25519 signature of `("store" || namespace || timestamp)`, where namespace and
            /// `timestamp` are the base10 expression of the namespace and `timestamp` values.  Must be
            /// base64 encoded for json requests; binary for OMQ requests.  For non-05 type pubkeys (i.e. non
            /// session ids) the signature will be verified using `pubkey`.  For 05 pubkeys, see the following
            /// option.
            Endpoint.sendMessage.path.bytes
                .appending(contentsOf: namespace.verificationString.bytes)
                .appending(contentsOf: timestampMs.map { "\($0)" }?.data(using: .ascii)?.bytes)
        }
        
        // MARK: - Init
        
        public init(
            recipient: String,
            namespace: Namespace,
            data: Data,
            ttl: UInt64,
            timestampMs: UInt64,
            authMethod: AuthenticationMethod
        ) {
            self.recipient = recipient
            self.namespace = namespace
            self.data = data.base64EncodedString()
            self.ttl = ttl
            
            super.init(
                timestampMs: timestampMs,
                authMethod: authMethod
            )
        }
        
        // MARK: - Coding
        
        override public func encode(to encoder: Encoder) throws {
            var container: KeyedEncodingContainer<CodingKeys> = encoder.container(keyedBy: CodingKeys.self)
            
            try container.encode(recipient, forKey: .recipient)
            try container.encode(namespace, forKey: .namespace)
            try container.encode(data, forKey: .data)
            try container.encode(ttl, forKey: .ttl)
            
            try super.encode(to: encoder)
        }
    }
}
