// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Sodium
import SessionUtilitiesKit

extension SnodeAPI {
    public class ONSResolveResponse: SnodeResponse {
        private struct Result: Codable {
            enum CodingKeys: String, CodingKey {
                case nonce
                case encryptedValue = "encrypted_value"
            }
            
            fileprivate let nonce: String?
            fileprivate let encryptedValue: String
        }
        
        enum CodingKeys: String, CodingKey {
            case result
        }
        
        private let result: Result
        
        // MARK: - Initialization
        
        required init(from decoder: Decoder) throws {
            let container: KeyedDecodingContainer<CodingKeys> = try decoder.container(keyedBy: CodingKeys.self)
            
            result = try container.decode(Result.self, forKey: .result)
            
            try super.init(from: decoder)
        }
        
        // MARK: - Convenience
        
        func sessionId(
            nameBytes: [UInt8],
            nameHashBytes: [UInt8],
            using dependencies: Dependencies
        ) throws -> String {
            let ciphertext: [UInt8] = Data(hex: result.encryptedValue).bytes
            
            // Handle old Argon2-based encryption used before HF16
            guard let hexEncodedNonce: String = result.nonce else {
                let salt: [UInt8] = Data(
                    repeating: 0,
                    count: dependencies[singleton: .crypto].size(.legacyArgon2PWHashSaltBytes)
                ).bytes
                
                guard
                    let key: [UInt8] = try? dependencies[singleton: .crypto].perform(
                        .legacyArgon2PWHash(
                            passwd: nameBytes,
                            salt: salt
                        )
                    )
                else { throw SnodeAPIError.hashingFailed }
                
                let nonce: [UInt8] = Data(
                    repeating: 0,
                    count: dependencies[singleton: .crypto].size(.legacyArgon2SecretBoxNonceBytes)
                ).bytes
                
                guard
                    let sessionIdAsData: [UInt8] = try? dependencies[singleton: .crypto].perform(
                        .legacyArgon2SecretBoxOpen(
                            authenticatedCipherText: ciphertext,
                            secretKey: key,
                            nonce: nonce
                        )
                    )
                else { throw SnodeAPIError.decryptionFailed }

                return sessionIdAsData.toHexString()
            }
            
            let nonceBytes: [UInt8] = Data(hex: hexEncodedNonce).bytes

            // xchacha-based encryption
            // key = H(name, key=H(name))
            guard
                let key: [UInt8] = try? dependencies[singleton: .crypto].perform(
                    .hash(message: nameBytes, key: nameHashBytes)
                )
            else { throw SnodeAPIError.hashingFailed }
            guard
                // Should always be equal in practice
                ciphertext.count >= (SessionId.byteCount + dependencies[singleton: .crypto].size(.aeadXChaCha20ABytes)),
                let sessionIdAsData = try? dependencies[singleton: .crypto].perform(
                    .decryptAeadXChaCha20(
                        authenticatedCipherText: ciphertext,
                        secretKey: key,
                        nonce: nonceBytes
                    )
                )
            else { throw SnodeAPIError.decryptionFailed }

            return sessionIdAsData.toHexString()
        }
    }
}
