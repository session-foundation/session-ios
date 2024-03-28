// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import SessionUtilitiesKit

public enum SnodeAPIError: LocalizedError {
    case clockOutOfSync
    case snodePoolUpdatingFailed
    case inconsistentSnodePools
    case noKeyPair
    case signingFailed
    case signatureVerificationFailed
    case invalidIP
    case responseFailedValidation
    case rateLimited
    case missingSnodeVersion
    case unsupportedSnodeVersion(String)
    
    // Onion Request Errors
    case emptySnodePool
    case insufficientSnodes
    case ranOutOfRandomSnodes
    
    // ONS
    case decryptionFailed
    case hashingFailed
    case validationFailed
    
    // Quic
    case invalidPayload
    case missingSecretKey
    case unreachable
    case unassociatedPubkey

    public var errorDescription: String? {
        switch self {
            case .clockOutOfSync: return "Your clock is out of sync with the Service Node network. Please check that your device's clock is set to automatic time."
            case .snodePoolUpdatingFailed: return "Failed to update the Service Node pool."
            case .inconsistentSnodePools: return "Received inconsistent Service Node pool information from the Service Node network."
            case .noKeyPair: return "Missing user key pair."
            case .signingFailed: return "Couldn't sign message."
            case .signatureVerificationFailed: return "Failed to verify the signature."
            case .invalidIP: return "Invalid IP."
            case .responseFailedValidation: return "Response failed validation."
            case .rateLimited: return "Rate limited."
            case .missingSnodeVersion: return "Missing Service Node version."
            case .unsupportedSnodeVersion(let version): return "Unsupported Service Node version: \(version)."
                
            // Onion Request Errors
            case .emptySnodePool: return "Service Node pool is empty."
            case .insufficientSnodes: return "Couldn't find enough Service Nodes to build a path."
            case .ranOutOfRandomSnodes: return "Ran out of random snodes to send the request through."
                
            // ONS
            case .decryptionFailed: return "Couldn't decrypt ONS name."
            case .hashingFailed: return "Couldn't compute ONS name hash."
            case .validationFailed: return "ONS name validation failed."
                
            // Quic
            case .invalidPayload: return "Invalid payload."
            case .missingSecretKey: return "Missing secret key."
            case .unreachable: return "The service node is unreachable."
            case .unassociatedPubkey: return "The service node is no longer associated with the public key."
        }
    }
}
