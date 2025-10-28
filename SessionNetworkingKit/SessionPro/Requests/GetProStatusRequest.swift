// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtil
import SessionUtilitiesKit

public extension Network.SessionPro {
    struct GetProStatusRequest: Encodable, Equatable {
        public let masterPublicKey: [UInt8]
        public let timestampMs: UInt64
        public let includeHistory: Bool
        public let signature: Signature
        
        // MARK: - Functions
        
        func toLibSession() -> session_pro_backend_get_pro_status_request {
            var result: session_pro_backend_get_pro_status_request = session_pro_backend_get_pro_status_request()
            result.version = Network.SessionPro.apiVersion
            result.set(\.master_pkey, to: masterPublicKey)
            result.set(\.master_sig, to: signature.signature)
            result.unix_ts_ms = timestampMs
            result.history = includeHistory
            
            return result
        }
        
        public func encode(to encoder: any Encoder) throws {
            var cRequest: session_pro_backend_get_pro_status_request = toLibSession()
            var cJson: session_pro_backend_to_json = session_pro_backend_get_pro_status_request_to_json(&cRequest);
            defer { session_pro_backend_to_json_free(&cJson) }
            
            guard cJson.success else { throw NetworkError.invalidPayload }
            
            let jsonData: Data = Data(bytes: cJson.json.data, count: cJson.json.size)
            let decoded: [String: AnyCodable] = try JSONDecoder().decode([String: AnyCodable].self, from: jsonData)
            try decoded.encode(to: encoder)
        }
    }
}

extension session_pro_backend_get_pro_status_request: @retroactive CMutable {}
