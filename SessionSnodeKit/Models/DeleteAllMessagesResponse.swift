// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Sodium
import SessionUtilitiesKit

public class DeleteAllMessagesResponse: SnodeRecursiveResponse<DeleteAllMessagesResponse.SwarmItem> {
    // MARK: - Convenience
    
    internal func validResultMap(
        userX25519PublicKey: String,
        timestampMs: UInt64,
        sodium: Sodium
    ) -> [String: Bool] {
        return swarm.reduce(into: [:]) { result, next in
            guard
                !next.value.failed,
                let encodedSignature: Data = Data(base64Encoded: next.value.signatureBase64)
            else {
                result[next.key] = false
                
                if let reason: String = next.value.reason, let statusCode: Int = next.value.code {
                    SNLog("Couldn't delete data from: \(next.key) due to error: \(reason) (\(statusCode)).")
                }
                else {
                    SNLog("Couldn't delete data from: \(next.key).")
                }
                return
            }
            
            /// Signature of `( PUBKEY_HEX || TIMESTAMP || DELETEDHASH[0] || ... || DELETEDHASH[N] )`
            /// signed by the node's ed25519 pubkey.  When doing a multi-namespace delete the `DELETEDHASH`
            /// values are totally ordered (i.e. among all the hashes deleted regardless of namespace)
            let verificationBytes: [UInt8] = userX25519PublicKey.bytes
                .appending(contentsOf: "\(timestampMs)".data(using: .ascii)?.bytes)
                .appending(contentsOf: next.value.deleted.joined().bytes)
            
            result[next.key] = sodium.sign.verify(
                message: verificationBytes,
                publicKey: Data(hex: next.key).bytes,
                signature: encodedSignature.bytes
            )
        }
    }
}

// MARK: - SwarmItem

public extension DeleteAllMessagesResponse {
    class SwarmItem: SnodeSwarmItem {
        private enum CodingKeys: String, CodingKey {
            case deleted
        }
        
        public let deleted: [String]
        public let deletedNamespaced: [String: [String]]
        
        // MARK: - Initialization
        
        required init(from decoder: Decoder) throws {
            let container: KeyedDecodingContainer<CodingKeys> = try decoder.container(keyedBy: CodingKeys.self)
            
            if let decodedDeletedNamespaced: [String: [String]] = try? container.decode([String: [String]].self, forKey: .deleted) {
                deletedNamespaced = decodedDeletedNamespaced
                
                /// **Note:** When doing a multi-namespace delete the `DELETEDHASH` values are totally
                /// ordered (i.e. among all the hashes deleted regardless of namespace)
                deleted = decodedDeletedNamespaced
                    .reduce(into: []) { result, next in result.append(contentsOf: next.value) }
                    .sorted()
            }
            else {
                deleted = ((try? container.decode([String].self, forKey: .deleted)) ?? [])
                deletedNamespaced = [:]
            }
            
            try super.init(from: decoder)
        }
    }
}
