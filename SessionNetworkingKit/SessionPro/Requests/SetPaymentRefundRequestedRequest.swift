// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtil
import SessionUtilitiesKit

public extension Network.SessionPro {
    struct SetPaymentRefundRequestedRequest: Encodable, Equatable {
        public let masterPublicKey: [UInt8]
        public let masterSignature: Signature
        public let timestampMs: UInt64
        public let refundRequestedTimestampMs: UInt64
        public let transaction: UserTransaction
        
        // MARK: - Functions
        
        func toLibSession() -> session_pro_backend_set_payment_refund_requested_request {
            var result: session_pro_backend_set_payment_refund_requested_request = session_pro_backend_set_payment_refund_requested_request()
            result.version = Network.SessionPro.apiVersion
            result.set(\.master_pkey, to: masterPublicKey)
            result.set(\.master_sig, to: masterSignature.signature)
            result.unix_ts_ms = timestampMs
            result.refund_requested_unix_ts_ms = refundRequestedTimestampMs
            result.payment_tx = transaction.toLibSession()
            
            return result
        }
        
        public func encode(to encoder: any Encoder) throws {
            var cRequest: session_pro_backend_set_payment_refund_requested_request = toLibSession()
            var cJson: session_pro_backend_to_json = session_pro_backend_set_payment_refund_requested_request_to_json(&cRequest);
            defer { session_pro_backend_to_json_free(&cJson) }
            
            guard cJson.success else { throw NetworkError.invalidPayload }
            
            let jsonData: Data = Data(bytes: cJson.json.data, count: cJson.json.size)
            let decoded: [String: AnyCodable] = try JSONDecoder().decode([String: AnyCodable].self, from: jsonData)
            try decoded.encode(to: encoder)
        }
    }
}

extension session_pro_backend_set_payment_refund_requested_request: @retroactive CMutable {}
