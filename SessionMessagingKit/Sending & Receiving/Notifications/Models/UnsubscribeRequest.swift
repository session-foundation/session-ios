// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionSnodeKit
import SessionUtilitiesKit

extension PushNotificationAPI {
    struct UnsubscribeRequest: Encodable {
        struct ServiceInfo: Codable {
            private enum CodingKeys: String, CodingKey {
                case token
            }
            
            private let token: String
            
            // MARK: - Initialization
            
            init(token: String) {
                self.token = token
            }
        }
        
        private enum CodingKeys: String, CodingKey {
            case pubkey
            case ed25519PublicKey = "session_ed25519"
            case subkey = "subkey_tag"
            case timestamp = "sig_ts"
            case signatureBase64 = "signature"
            case service
            case serviceInfo = "service_info"
        }
        
        /// Dict of service-specific data; typically this includes just a "token" field with a device-specific token, but different services in the
        /// future may have different input requirements.
        private let serviceInfo: ServiceInfo
        
        /// The authentication information needed to subscribe for notifications
        private let authInfo: SnodeAPI.AuthenticationInfo
        
        /// The signature unix timestamp (seconds, not ms)
        private let timestamp: Int64
        
        // MARK: - Initialization
        
        init(
            serviceInfo: ServiceInfo,
            authInfo: SnodeAPI.AuthenticationInfo,
            timestamp: TimeInterval
        ) {
            self.serviceInfo = serviceInfo
            self.authInfo = authInfo
            self.timestamp = Int64(timestamp)   // Server expects rounded seconds
        }
        
        // MARK: - Coding
        
        public func encode(to encoder: Encoder) throws {
            var container: KeyedEncodingContainer<CodingKeys> = encoder.container(keyedBy: CodingKeys.self)
            
            // Generate the signature for the request for encoding
            let signatureBase64: String = try generateSignature(using: encoder.dependencies).toBase64()
            try container.encode(timestamp, forKey: .timestamp)
            try container.encode(signatureBase64, forKey: .signatureBase64)
            try container.encode(Service.apns, forKey: .service)
            try container.encode(serviceInfo, forKey: .serviceInfo)
            
            switch authInfo {
                case .standard(let pubkey, let ed25519KeyPair):
                    try container.encode(pubkey, forKey: .pubkey)
                    try container.encode(ed25519KeyPair.publicKey.toHexString(), forKey: .ed25519PublicKey)
                    
                case .groupAdmin(let pubkey, _):
                    try container.encode(pubkey, forKey: .pubkey)
                    
                case .groupMember(let pubkey, let authData):
                    try container.encode(pubkey, forKey: .pubkey)
            }
        }
        
        // MARK: - Abstract Methods
        
        func generateSignature(using dependencies: Dependencies) throws -> [UInt8] {
            /// A signature is signed using the account's Ed25519 private key (or Ed25519 subkey, if using
            /// subkey authentication with a `subkey_tag`, for future closed group subscriptions), and signs the value:
            /// `"UNSUBSCRIBE" || HEX(ACCOUNT) || SIG_TS`
            ///
            /// Where `SIG_TS` is the `sig_ts` value as a base-10 string and must be within 24 hours of the current time.
            let verificationBytes: [UInt8] = "UNSUBSCRIBE".bytes
                .appending(contentsOf: authInfo.publicKey.bytes)
                .appending(contentsOf: "\(timestamp)".data(using: .ascii)?.bytes)
            
            return try authInfo.generateSignature(with: verificationBytes, using: dependencies)
        }
    }
}
