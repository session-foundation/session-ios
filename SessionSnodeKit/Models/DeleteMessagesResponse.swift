// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Sodium
import SessionUtilitiesKit

public class DeleteMessagesResponse: SnodeRecursiveResponse<DeleteMessagesResponse.SwarmItem> {
    // MARK: - Convenience
    
    internal func validResultMap(
        userX25519PublicKey: String,
        serverHashes: [String],
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
            
            /// The signature format is `( PUBKEY_HEX || RMSG[0] || ... || RMSG[N] || DMSG[0] || ... || DMSG[M] )`
            let verificationBytes: [UInt8] = userX25519PublicKey.bytes
                .appending(contentsOf: serverHashes.joined().bytes)
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

public extension DeleteMessagesResponse {
    class SwarmItem: SnodeSwarmItem {
        private enum CodingKeys: String, CodingKey {
            case deleted
        }
        
        public let deleted: [String]
        
        // MARK: - Initialization
        
        required init(from decoder: Decoder) throws {
            let container: KeyedDecodingContainer<CodingKeys> = try decoder.container(keyedBy: CodingKeys.self)
            
            deleted = try container.decode([String].self, forKey: .deleted)
            
            try super.init(from: decoder)
        }
    }
}
