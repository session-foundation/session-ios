// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtilitiesKit

extension Network.StorageServer {
    public class UpdateExpiryResponse: BaseRecursiveResponse<UpdateExpiryResponse.SwarmItem> {}
    
    public struct UpdateExpiryResponseResult {
        public let changed: [String: UInt64]
        public let unchanged: [String: UInt64]
        public let didError: Bool

        /// Whether this sub-response actually told us which hashes it still holds
        ///
        /// The storage server only includes the `unchanged` array when the request set `extend` or `shorten`, so
        /// when this is `false` a hash appearing in neither `changed` nor `unchanged` carries **no information** -
        /// it may well still be present, it just wasn't modified. See `ConfigExpiryDetection`
        public let hasUnchangedInfo: Bool

        public init(
            changed: [String: UInt64],
            unchanged: [String: UInt64],
            didError: Bool,
            hasUnchangedInfo: Bool
        ) {
            self.changed = changed
            self.unchanged = unchanged
            self.didError = didError
            self.hasUnchangedInfo = hasUnchangedInfo
        }
    }
}

// MARK: - SwarmItem

public extension Network.StorageServer.UpdateExpiryResponse {
    class SwarmItem: Network.StorageServer.BaseSwarmItem {
        private enum CodingKeys: String, CodingKey {
            case updated
            case unchanged
            case expiry
        }
        
        public let updated: [String]

        /// The hashes this service node still holds but didn't modify, mapped to their current expiry
        ///
        /// **Note:** This is `nil` when the response omitted the `unchanged` key entirely, which the storage server
        /// does unless the request set `extend` or `shorten` - it is deliberately **not** defaulted to an empty
        /// dictionary because "this node holds nothing else" and "this node didn't tell us" must not be conflated
        /// (a hash in neither array would otherwise look expired on every poll)
        public let unchanged: [String: UInt64]?
        public let expiry: UInt64?

        // MARK: - Initialization

        required init(from decoder: Decoder) throws {
            let container: KeyedDecodingContainer<CodingKeys> = try decoder.container(keyedBy: CodingKeys.self)

            updated = ((try? container.decode([String].self, forKey: .updated)) ?? [])
            unchanged = try? container.decode([String: UInt64].self, forKey: .unchanged)
            expiry = try? container.decode(UInt64.self, forKey: .expiry)

            try super.init(from: decoder)
        }

        public override func encode(to encoder: any Encoder) throws {
            var container: KeyedEncodingContainer<CodingKeys> = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(updated, forKey: .updated)
            try container.encodeIfPresent(unchanged, forKey: .unchanged)
            try container.encodeIfPresent(expiry, forKey: .expiry)

            try super.encode(to: encoder)
        }
    }
}

// MARK: - ValidatableResponse

extension Network.StorageServer.UpdateExpiryResponse: ValidatableResponse {
    typealias ValidationData = [String]
    typealias ValidationResponse = Network.StorageServer.UpdateExpiryResponseResult
    
    /// All responses in the swarm must be valid
    internal static var requiredSuccessfulResponses: Int { -1 }
    
    internal func validResultMap(
        swarmPublicKey: String,
        validationData: [String],
        using dependencies: Dependencies
    ) throws -> [String: Network.StorageServer.UpdateExpiryResponseResult] {
        let validationMap: [String: Network.StorageServer.UpdateExpiryResponseResult] = try swarm.reduce(into: [:]) { result, next in
            guard
                !next.value.failed,
                let appliedExpiry: UInt64 = next.value.expiry,
                let signatureBase64: String = next.value.signatureBase64,
                let encodedSignature: Data = Data(base64Encoded: signatureBase64)
            else {
                result[next.key] = Network.StorageServer.UpdateExpiryResponseResult(
                    changed: [:],
                    unchanged: [:],
                    didError: true,
                    hasUnchangedInfo: false
                )

                if let reason: String = next.value.reason, let statusCode: Int = next.value.code {
                    Log.warn(.validator(self), "Couldn't update expiry from: \(next.key) due to error: \(reason) (\(statusCode)).")
                }
                else {
                    Log.warn(.validator(self), "Couldn't update expiry from: \(next.key).")
                }
                return
            }
            
            /// Signature of
            /// `( PUBKEY_HEX || EXPIRY || RMSGs... || UMSGs... || CMSG_EXPs... )`
            /// where RMSGs are the requested expiry hashes, UMSGs are the actual updated hashes, and
            /// CMSG_EXPs are (HASH || EXPIRY) values, ascii-sorted by hash, for the unchanged message
            /// hashes included in the "unchanged" field.  The signature uses the node's ed25519 pubkey.
            ///
            /// **Note:** If `updated` is empty then the `expiry` value will match the value that was
            /// included in the original request
            let verificationBytes: [UInt8] = swarmPublicKey.bytes
                .appending(contentsOf: "\(appliedExpiry)".data(using: .ascii)?.bytes)
                .appending(contentsOf: validationData.joined().bytes)
                .appending(contentsOf: next.value.updated.sorted().joined().bytes)
                .appending(contentsOf: (next.value.unchanged ?? [:])
                    .sorted(by: { lhs, rhs in lhs.key < rhs.key })
                    .reduce(into: [UInt8]()) { result, nextUnchanged in
                        result.append(contentsOf: nextUnchanged.key.bytes)
                        result.append(contentsOf: "\(nextUnchanged.value)".data(using: .ascii)?.bytes ?? [])
                    }
                )
            let isValid: Bool = dependencies[singleton: .crypto].verify(
                .signature(
                    message: verificationBytes,
                    publicKey: Data(hex: next.key).bytes,
                    signature: encodedSignature.bytes
                )
            )
            
            // If the update signature is invalid then we want to fail here
            guard isValid else { throw StorageServerError.signatureVerificationFailed }
            
            result[next.key] = Network.StorageServer.UpdateExpiryResponseResult(
                changed: next.value.updated.reduce(into: [:]) { prev, next in prev[next] = appliedExpiry },
                unchanged: (next.value.unchanged ?? [:]),
                didError: false,
                hasUnchangedInfo: (next.value.unchanged != nil)
            )
        }
        
        return try Self.validated(map: validationMap, totalResponseCount: swarm.count)
    }
}
