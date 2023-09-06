// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtilitiesKit

extension SnodeAPI {
    public class GetExpiriesRequest: SnodeAuthenticatedRequestBody {
        enum CodingKeys: String, CodingKey {
            case messageHashes = "messages"
        }
        
        /// Array of message hash strings (as provided by the storage server) to update. Messages can be from any namespace(s).
        /// You may pass a single message id of "all" to retrieve the timestamps of all
        let messageHashes: [String]
        
        // MARK: - Init
        
        public init(
            messageHashes: [String],
            authInfo: AuthenticationInfo,
            timestampMs: UInt64
        ) {
            self.messageHashes = messageHashes
            
            super.init(
                authInfo: authInfo,
                timestampMs: timestampMs
            )
        }
        
        // MARK: - Coding
        
        override public func encode(to encoder: Encoder) throws {
            var container: KeyedEncodingContainer<CodingKeys> = encoder.container(keyedBy: CodingKeys.self)
            
            try container.encode(messageHashes, forKey: .messageHashes)
            
            try super.encode(to: encoder)
        }
        
        // MARK: - Abstract Methods
        
        override func generateSignature(using dependencies: Dependencies) throws -> [UInt8] {
            /// Ed25519 signature of `("get_expiries" || timestamp || messages[0] || ... || messages[N])`
            /// where `timestamp` is expressed as a string (base10).  The signature must be base64 encoded (json) or bytes (bt).
            let verificationBytes: [UInt8] = SnodeAPI.Endpoint.getExpiries.path.bytes
                .appending(contentsOf: timestampMs.map { "\($0)" }?.data(using: .ascii)?.bytes)
                .appending(contentsOf: messageHashes.joined().bytes)
            
            return try authInfo.generateSignature(with: verificationBytes, using: dependencies)
        }
    }
}
