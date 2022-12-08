// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Sodium
import SessionUtilitiesKit

public class DeleteAllBeforeResponse: SnodeRecursiveResponse<DeleteAllMessagesResponse.SwarmItem> {
    // MARK: - Convenience
    
    internal func validResultMap(
        userX25519PublicKey: String,
        beforeMs: UInt64,
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
            
            /// Signature of `( PUBKEY_HEX || BEFORE || DELETEDHASH[0] || ... || DELETEDHASH[N] )`
            /// signed by the node's ed25519 pubkey.  When doing a multi-namespace delete the `DELETEDHASH`
            /// values are totally ordered (i.e. among all the hashes deleted regardless of namespace)
            let verificationBytes: [UInt8] = userX25519PublicKey.bytes
                .appending(contentsOf: "\(beforeMs)".data(using: .ascii)?.bytes)
                .appending(contentsOf: next.value.deleted.joined().bytes)
            
            result[next.key] = sodium.sign.verify(
                message: verificationBytes,
                publicKey: Data(hex: next.key).bytes,
                signature: encodedSignature.bytes
            )
        }
    }
}
