// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation

public enum StorageServerError: Error, CustomStringConvertible {
    case clockOutOfSync
    case snodePoolUpdatingFailed
    case inconsistentSnodePools
    case noKeyPair
    case signingFailed
    case signatureVerificationFailed
    case invalidIP
    case responseFailedValidation
    case unauthorised
    case rateLimited
    case missingSnodeVersion
    case unsupportedSnodeVersion(String)
    
    // Onion Request Errors
    case emptySnodePool
    case insufficientSnodes
    case ranOutOfRandomSnodes(Error?)
    
    // ONS
    case onsDecryptionFailed
    case onsHashingFailed
    case onsValidationFailed
    case onsNotFound
    
    // Quic
    case invalidPayload
    case missingSecretKey
    case nodeNotFound(String)
    case unassociatedPubkey
    case unableToRetrieveSwarm

    public var description: String {
        switch self {
            case .clockOutOfSync: return "Your clock is out of sync with the Service Node network. Please check that your device's clock is set to automatic time."
            case .snodePoolUpdatingFailed: return "Failed to update the Service Node pool."
            case .inconsistentSnodePools: return "Received inconsistent Service Node pool information from the Service Node network."
            case .noKeyPair: return "Missing user key pair."
            case .signingFailed: return "Couldn't sign message."
            case .signatureVerificationFailed: return "Failed to verify the signature."
            case .invalidIP: return "Invalid IP."
            case .responseFailedValidation: return "Response failed validation."
            case .unauthorised: return "Storage Server Unauthorized."
            case .rateLimited: return "Storage Server Rate limited."
            case .missingSnodeVersion: return "Missing Service Node version."
            case .unsupportedSnodeVersion(let version): return "Unsupported Service Node version: \(version)."
                
            // Onion Request Errors
            case .emptySnodePool: return "Service Node pool is empty."
            case .insufficientSnodes: return "Couldn't find enough Service Nodes to build a path."
            case .ranOutOfRandomSnodes(let maybeError):
                switch maybeError {
                    case .none: return "Ran out of random snodes."
                    case .some(let error): return "Ran out of random snodes with error: \(error)."
                }
                
            // ONS
            case .onsDecryptionFailed: return "Couldn't decrypt ONS name."
            case .onsHashingFailed: return "Couldn't compute ONS name hash."
            case .onsValidationFailed: return "ONS name validation failed."
            case .onsNotFound: return "ONS name not found"
                
            // Quic
            case .invalidPayload: return "Invalid payload."
            case .missingSecretKey: return "Missing secret key."
            case .nodeNotFound(let nodeHex): return "Error in Onion request path, with node \(nodeHex)."
                
            case .unassociatedPubkey: return "The service node is no longer associated with the public key."
            case .unableToRetrieveSwarm: return "Unable to retrieve the swarm for the given public key."
        }
    }
}
