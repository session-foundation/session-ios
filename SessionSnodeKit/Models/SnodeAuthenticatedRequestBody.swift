// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtilitiesKit

public class SnodeAuthenticatedRequestBody: Encodable {
    private enum CodingKeys: String, CodingKey {
        case pubkey
        case subkey
        case timestampMs = "timestamp"
        case ed25519PublicKey = "pubkey_ed25519"
        case signatureBase64 = "signature"
    }
    
    internal let authInfo: SnodeAPI.AuthenticationInfo
    internal let timestampMs: UInt64?
    
    // MARK: - Initialization

    public init(
        authInfo: SnodeAPI.AuthenticationInfo,
        timestampMs: UInt64? = nil
    ) {
        self.authInfo = authInfo
        self.timestampMs = timestampMs
    }
    
    // MARK: - Codable
    
    public func encode(to encoder: Encoder) throws {
        var container: KeyedEncodingContainer<CodingKeys> = encoder.container(keyedBy: CodingKeys.self)
        
        // Generate the signature for the request for encoding
        let signatureBase64: String = try generateSignature(using: encoder.dependencies).toBase64()
        try container.encodeIfPresent(timestampMs, forKey: .timestampMs)
        try container.encode(signatureBase64, forKey: .signatureBase64)
        
        switch authInfo {
            case .standard(let sessionId, let ed25519KeyPair):
                try container.encode(sessionId.hexString, forKey: .pubkey)
                try container.encode(ed25519KeyPair.publicKey.toHexString(), forKey: .ed25519PublicKey)
                
            case .groupAdmin(let sessionId, _):
                try container.encode(sessionId.hexString, forKey: .pubkey)
                
            case .groupMember(let sessionId, let authData):
                try container.encode(sessionId.hexString, forKey: .pubkey)
        }
    }
    
    // MARK: - Abstract Functions
    
    func generateSignature(using dependencies: Dependencies) throws -> [UInt8] {
        preconditionFailure("abstract class - override in subclass")
    }
}
