// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtil
import SessionUtilitiesKit

public extension Network.SessionPro {
    struct SetPaymentRefundRequestedResponse: Decodable, Equatable {
        public let header: ResponseHeader
        public let version: UInt8
        public let updated: Bool
        
        public init(from decoder: any Decoder) throws {
            let container: SingleValueDecodingContainer = try decoder.singleValueContainer()
            let jsonData: Data
            
            if let data: Data = try? container.decode(Data.self) {
                jsonData = data
            }
            else if let jsonString: String = try? container.decode(String.self) {
                guard let data: Data = jsonString.data(using: .utf8) else {
                    throw DecodingError.dataCorruptedError(
                        in: container,
                        debugDescription: "Invalid UTF-8 in JSON string" // stringlint:ignore
                    )
                }
                
                jsonData = data
            }
            else {
                let anyValue: AnyCodable = try container.decode(AnyCodable.self)
                jsonData = try JSONEncoder().encode(anyValue)
            }
            
            var result = jsonData.withUnsafeBytes { bytes in
                session_pro_backend_set_payment_refund_requested_response_parse(
                    bytes.baseAddress?.assumingMemoryBound(to: CChar.self),
                    jsonData.count
                )
            }
            defer { session_pro_backend_set_payment_refund_requested_response_free(&result) }
            
            self.header = ResponseHeader(result.header)
            self.version = result.version
            self.updated = result.updated
        }
    }
}
