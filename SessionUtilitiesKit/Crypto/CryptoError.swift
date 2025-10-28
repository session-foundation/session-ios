// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation

public enum CryptoError: Error, CustomStringConvertible {
    case invalidSeed
    case invalidPublicKey
    case keyGenerationFailed
    case randomGenerationFailed
    case signatureGenerationFailed
    case signatureVerificationFailed
    case encryptionFailed
    case decryptionFailed
    case failedToGenerateOutput
    case missingUserSecretKey
    case invalidAuthentication
    case invalidBase64EncodedData
    
    public var description: String {
        switch self {
            case .invalidSeed: return "CryptoError: Invalid seed"
            case .invalidPublicKey: return "CryptoError: Invalid public key"
            case .keyGenerationFailed: return "CryptoError: Key generation failed"
            case .randomGenerationFailed: return "CryptoError: Random generation failed"
            case .signatureGenerationFailed: return "CryptoError: Signature generation failed"
            case .signatureVerificationFailed: return "CryptoError: Signature verification failed"
            case .encryptionFailed: return "CryptoError: Encryption failed"
            case .decryptionFailed: return "CryptoError: Decryption failed"
            case .failedToGenerateOutput: return "CryptoError: Failed to generate output"
            case .missingUserSecretKey: return "CryptoError: Missing user secret key"
            case .invalidAuthentication: return "CryptoError: Invalid authentication"
            case .invalidBase64EncodedData: return "CryptoError: Invalid Base64 encoded data"
        }
    }
}
