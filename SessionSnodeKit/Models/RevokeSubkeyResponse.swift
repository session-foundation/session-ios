// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Sodium
import SessionUtilitiesKit

public class RevokeSubkeyResponse: SnodeRecursiveResponse<SnodeSwarmItem> {
    // MARK: - Convenience
    
    internal func validateResult(
        userX25519PublicKey: String,
        subkeyToRevoke: String,
        sodium: Sodium
    ) throws {
        try swarm.forEach { snodePublicKey, swarmItem in
            guard
                !swarmItem.failed,
                let encodedSignature: Data = Data(base64Encoded: swarmItem.signatureBase64)
            else {
                if let reason: String = swarmItem.reason, let statusCode: Int = swarmItem.code {
                    SNLog("Couldn't revoke subkey from: \(snodePublicKey) due to error: \(reason) (\(statusCode)).")
                }
                else {
                    SNLog("Couldn't revoke subkey from: \(snodePublicKey).")
                }
                return
            }
            
            /// Signature of `( PUBKEY_HEX || SUBKEY_TAG_BYTES )` where `SUBKEY_TAG_BYTES` is the
            /// requested subkey tag for revocation
            let verificationBytes: [UInt8] = userX25519PublicKey.bytes
                .appending(contentsOf: subkeyToRevoke.bytes)
            let isValid: Bool = sodium.sign.verify(
                message: verificationBytes,
                publicKey: Data(hex: snodePublicKey).bytes,
                signature: encodedSignature.bytes
            )
            
            // If the update signature is invalid then we want to fail here
            guard isValid else { throw SnodeAPIError.signatureVerificationFailed }
        }
    }
}
