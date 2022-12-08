// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Sodium
import SessionUtilitiesKit

public class UpdateExpiryAllResponse: SnodeRecursiveResponse<UpdateExpiryAllResponse.SwarmItem> {
    // MARK: - Convenience
    
    internal func validResultMap(
        userX25519PublicKey: String,
        expiryMs: UInt64,
        sodium: Sodium
    ) throws -> [String: [String]] {
        return try swarm.reduce(into: [:]) { result, next in
            guard
                !next.value.failed,
                let encodedSignature: Data = Data(base64Encoded: next.value.signatureBase64)
            else {
                result[next.key] = []
                
                if let reason: String = next.value.reason, let statusCode: Int = next.value.code {
                    SNLog("Couldn't update expiry from: \(next.key) due to error: \(reason) (\(statusCode)).")
                }
                else {
                    SNLog("Couldn't update expiry from: \(next.key).")
                }
                return
            }
            
            /// Signature of `( PUBKEY_HEX || EXPIRY || UPDATED[0] || ... || UPDATED[N] )`
            /// signed by the node's ed25519 pubkey.  When doing a multi-namespace delete the `UPDATED`
            /// values are totally ordered (i.e. among all the hashes deleted regardless of namespace)
            let verificationBytes: [UInt8] = userX25519PublicKey.bytes
                .appending(contentsOf: "\(expiryMs)".data(using: .ascii)?.bytes)
                .appending(contentsOf: next.value.updated.joined().bytes)
            
            let isValid: Bool = sodium.sign.verify(
                message: verificationBytes,
                publicKey: Data(hex: next.key).bytes,
                signature: encodedSignature.bytes
            )
            
            // If the update signature is invalid then we want to fail here
            guard isValid else { throw SnodeAPIError.signatureVerificationFailed }
            
            result[next.key] = next.value.updated
        }
    }
}

// MARK: - SwarmItem

public extension UpdateExpiryAllResponse {
    class SwarmItem: SnodeSwarmItem {
        private enum CodingKeys: String, CodingKey {
            case updated
        }
        
        public let updated: [String]
        public let updatedNamespaced: [String: [String]]
        
        // MARK: - Initialization
        
        required init(from decoder: Decoder) throws {
            let container: KeyedDecodingContainer<CodingKeys> = try decoder.container(keyedBy: CodingKeys.self)
            
            if let decodedUpdatedNamespaced: [String: [String]] = try? container.decode([String: [String]].self, forKey: .updated) {
                updatedNamespaced = decodedUpdatedNamespaced
                
                /// **Note:** When doing a multi-namespace delete the `UPDATED` values are totally
                /// ordered (i.e. among all the hashes deleted regardless of namespace)
                updated = decodedUpdatedNamespaced
                    .reduce(into: []) { result, next in result.append(contentsOf: next.value) }
                    .sorted()
            }
            else {
                updated = ((try? container.decode([String].self, forKey: .updated)) ?? [])
                updatedNamespaced = [:]
            }
            
            try super.init(from: decoder)
        }
    }
}
