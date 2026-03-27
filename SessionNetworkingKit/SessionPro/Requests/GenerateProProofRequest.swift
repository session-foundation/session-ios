// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtil
import SessionUtilitiesKit

public extension Network.SessionPro {
    struct GenerateProProofRequest: Encodable, Equatable {
        public let masterPublicKey: [UInt8]
        public let rotatingPublicKey: [UInt8]
        public let timestampMs: UInt64
        public let signatures: Signatures
        
        // MARK: - Functions
        
        func toLibSession() -> session_pro_backend_generate_pro_proof_request {
            var result: session_pro_backend_generate_pro_proof_request = session_pro_backend_generate_pro_proof_request()
            result.version = Network.SessionPro.apiVersion
            result.set(\.master_pkey, to: masterPublicKey)
            result.set(\.rotating_pkey, to: rotatingPublicKey)
            result.unix_ts_ms = timestampMs
            result.set(\.master_sig, to: signatures.masterSignature)
            result.set(\.rotating_sig, to: signatures.rotatingSignature)
            
            return result
        }
        
        public func encode(to encoder: any Encoder) throws {
            var cRequest: session_pro_backend_generate_pro_proof_request = toLibSession()
            var cJson: session_pro_backend_to_json = session_pro_backend_generate_pro_proof_request_to_json(&cRequest);
            defer { session_pro_backend_to_json_free(&cJson) }
            
            guard cJson.success else { throw NetworkError.invalidPayload }
            
            let jsonData: Data = Data(bytes: cJson.json.data, count: cJson.json.size)
            let decoded: [String: AnyCodable] = try JSONDecoder().decode([String: AnyCodable].self, from: jsonData)
            try decoded.encode(to: encoder)
        }
    }
}

extension session_pro_backend_generate_pro_proof_request: @retroactive CMutable {}
