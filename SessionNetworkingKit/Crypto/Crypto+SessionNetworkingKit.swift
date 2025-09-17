// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import SessionUtil
import SessionUtilitiesKit

// MARK: - ONS Response

internal extension Crypto.Generator {
    static func sessionId(
        name: String,
        response: Network.StorageServer.ONSResolveResponse
    ) -> Crypto.Generator<String> {
        return Crypto.Generator(
            id: "sessionId_for_ONS_response",
            args: [name, response]
        ) {
            guard var cName: [CChar] = name.lowercased().cString(using: .utf8) else {
                throw StorageServerError.onsDecryptionFailed
            }
            
            // Name must be in lowercase
            var cCiphertext: [UInt8] = Array(Data(hex: response.result.encryptedValue))
            var cSessionId: [CChar] = [CChar](repeating: 0, count: 67)
            
            // Need to switch on `result.nonce` and explciitly pass `nil` because passing an optional
            // to a C function doesn't seem to work correctly
            switch response.result.nonce {
                case .none:
                    guard
                        session_decrypt_ons_response(
                            &cName,
                            &cCiphertext,
                            cCiphertext.count,
                            nil,
                            &cSessionId
                        )
                    else { throw StorageServerError.onsDecryptionFailed }
                    
                case .some(let nonce):
                    var cNonce: [UInt8] = Array(Data(hex: nonce))
                    
                    guard
                        cNonce.count == 24,
                        session_decrypt_ons_response(
                            &cName,
                            &cCiphertext,
                            cCiphertext.count,
                            &cNonce,
                            &cSessionId
                        )
                    else { throw StorageServerError.onsDecryptionFailed }
            }
            
            return String(cString: cSessionId)
        }
    }
}
