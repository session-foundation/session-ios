// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation

public enum CryptoError: Error, CustomStringConvertible {
    case invalidSeed
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
    case invalidKey
    
    public var description: String {
        switch self {
            case .invalidSeed: return "Invalid seed."
            case .keyGenerationFailed: return "Key generation failed."
            case .randomGenerationFailed: return "Random generation failed."
            case .signatureGenerationFailed: return "Signature generation failed."
            case .signatureVerificationFailed: return "Signature verification failed."
            case .encryptionFailed: return "Encryption failed."
            case .decryptionFailed: return "Decryption failed."
            case .failedToGenerateOutput: return "Failed to generate output."
            case .missingUserSecretKey: return "Missing user secret key."
            case .invalidAuthentication: return "Invalid authentication."
            case .invalidBase64EncodedData: return "Invalid base64 encoded data."
            case .invalidKey: return "Invalid key."
        }
    }
}
