// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import SessionUtilitiesKit

public enum SnodeAPIError: LocalizedError {
    case generic
    case clockOutOfSync
    case snodePoolUpdatingFailed
    case inconsistentSnodePools
    case noKeyPair
    case signingFailed
    case signatureVerificationFailed
    case invalidIP
    case emptySnodePool
    case responseFailedValidation
    case rateLimited
    case invalidPreparedRequest
    case ranOutOfRandomSnodes
    
    // ONS
    case decryptionFailed
    case hashingFailed
    case validationFailed
    
    // Quic
    case invalidPayload
    case missingSecretKey
    case requestFailed(error: String, rawData: Data?)
    case timeout
    case unreachable
    case unassociatedPubkey
    case unknown

    public var errorDescription: String? {
        switch self {
            case .generic: return "An error occurred."
            case .clockOutOfSync: return "Your clock is out of sync with the Service Node network. Please check that your device's clock is set to automatic time."
            case .snodePoolUpdatingFailed: return "Failed to update the Service Node pool."
            case .inconsistentSnodePools: return "Received inconsistent Service Node pool information from the Service Node network."
            case .noKeyPair: return "Missing user key pair."
            case .signingFailed: return "Couldn't sign message."
            case .signatureVerificationFailed: return "Failed to verify the signature."
            case .invalidIP: return "Invalid IP."
            case .emptySnodePool: return "Service Node pool is empty."
            case .responseFailedValidation: return "Response failed validation."
            case .rateLimited: return "Rate limited."
            case .invalidPreparedRequest: return "Invalid PreparedRequest provided."
            case .ranOutOfRandomSnodes: return "Ran out of random snodes to send the request through."
                
            // ONS
            case .decryptionFailed: return "Couldn't decrypt ONS name."
            case .hashingFailed: return "Couldn't compute ONS name hash."
            case .validationFailed: return "ONS name validation failed."
                
            // Quic
            case .invalidPayload: return "Invalid payload."
            case .missingSecretKey: return "Missing secret key."
            case .requestFailed(let error, _): return error
            case .timeout: return "The request timed out."
            case .unreachable: return "The service node is unreachable."
            case .unassociatedPubkey: return "The service node is no longer associated with the public key."
            case .unknown: return "An unknown error occurred."
        }
    }
}

public extension SnodeAPIError {
    init?(
        _ success: Bool,
        _ timeout: Bool,
        _ statusCode: Int16,
        _ data: Data?,
        _ updatedPath: LibSession.OnionPath?,
        _ publicKey: String?,
        using dependencies: Dependencies
    ) {
        guard !success || statusCode < 200 || statusCode > 299 else { return nil }
        guard !timeout else {
            self = .timeout
            return
        }
        
        // Handle status codes with specific meanings
        switch (statusCode, data.map { String(data: $0, encoding: .utf8) }) {
            /// A snode will return a `406` but onion requests v4 seems to return `425` so handle both
            case (406, _), (425, _):
                SNLog("The user's clock is out of sync with the service node network.")
                self = .clockOutOfSync
                
            case (401, _):
                SNLog("Failed to verify the signature.")
                self = .signatureVerificationFailed
                
            case (421, _):
                // TODO: Need to handle the snode response, otherwise drop from the snode
                switch publicKey {
                    case .none: SNLog("Got a 421 without an associated public key.")
                    case .some(let publicKey):
                        if
                            let data: Data = data,
                            let swarmResponse: GetSwarmResponse = try? data.decoded(as: GetSwarmResponse.self, using: dependencies),
                            !swarmResponse.snodes.isEmpty
                        {
                            SnodeAPI.setSwarm(to: swarmResponse.snodes, for: publicKey)
                        }
                }
                self = .unassociatedPubkey
                
            case (429, _): self = .rateLimited
            case (500, _), (502, _), (503, _): self = .unreachable
            case (_, .none): self = .unknown
            case (_, .some(let responseString)): self = .requestFailed(error: responseString, rawData: data)
        }
        
        // Process the updatedPath
        guard let updatedPath: LibSession.OnionPath = updatedPath else { return }
        
        zip(updatedPath.path, updatedPath.nodeFailureCount, updatedPath.nodeInvalid).forEach { snode, failureCount, invalid in
            guard invalid else {
                SNLog("Couldn't reach snode at: \(snode); setting failure count to \(failureCount).")
                SnodeAPI.snodeFailureCount.mutate { $0[snode] = failureCount }
                return
            }
            
            SNLog("Failure threshold reached for: \(snode); dropping it.")
            if let publicKey = publicKey {
                SnodeAPI.dropSnodeFromSwarmIfNeeded(snode, publicKey: publicKey)
            }
            SnodeAPI.dropSnodeFromSnodePool(snode)
            SnodeAPI.snodeFailureCount.mutate { $0[snode] = 0 }
            SNLog("Snode pool count: \(SnodeAPI.snodePool.wrappedValue.count).")
        }
        
        // The guardSnode (first in the path) will be marked as invalid if the path has failed too many times at which
        // point we drop it and the path
        switch Array(zip(updatedPath.path, updatedPath.nodeInvalid)).first {
            case .some((let snode, true)):
                OnionRequestAPI.dropGuardSnode(snode)
                OnionRequestAPI.drop(updatedPath.path)
                
            default: OnionRequestAPI.pathFailureCount.mutate { $0[updatedPath.path] = updatedPath.pathFailureCount }
        }
    }
}
