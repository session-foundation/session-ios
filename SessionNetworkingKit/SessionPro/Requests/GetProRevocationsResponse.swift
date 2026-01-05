// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtil
import SessionUtilitiesKit

public extension Network.SessionPro {
    struct GetProRevocationsResponse: Decodable, Equatable {
        public let header: ResponseHeader
        public let ticket: UInt32
        public let items: [RevocationItem]
        
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
                session_pro_backend_get_pro_revocations_response_parse(
                    bytes.baseAddress?.assumingMemoryBound(to: CChar.self),
                    jsonData.count
                )
            }
            defer { session_pro_backend_get_pro_revocations_response_free(&result) }
            
            self.header = ResponseHeader(result.header)
            self.ticket = result.ticket
            
            if result.items_count > 0 {
                self.items = (0..<result.items_count).map { index in
                    RevocationItem(result.items[index])
                }
            }
            else {
                self.items = []
            }
        }
    }
}
