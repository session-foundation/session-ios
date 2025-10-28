// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtil
import SessionUtilitiesKit

public extension Network.SessionPro {
    struct GetProStatusResponse: Decodable, Equatable {
        public let header: ResponseHeader
        public let items: [PaymentItem]
        public let status: ProStatus
        public let errorReport: ErrorReport
        public let autoRenewing: Bool
        public let expiryTimestampMs: UInt64
        public let gracePeriodDurationMs: UInt64
        
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
                session_pro_backend_get_pro_status_response_parse(
                    bytes.baseAddress?.assumingMemoryBound(to: CChar.self),
                    jsonData.count
                )
            }
            defer { session_pro_backend_get_pro_status_response_free(&result) }
            
            self.header = ResponseHeader(result.header)
            self.status = ProStatus(result.status)
            self.errorReport = ErrorReport(result.error_report)
            self.autoRenewing = result.auto_renewing
            self.expiryTimestampMs = result.expiry_unix_ts_ms
            self.gracePeriodDurationMs = result.grace_period_duration_ms
            
            if result.items_count > 0 {
                self.items = (0..<result.items_count).map { index in
                    PaymentItem(result.items[index])
                }
            }
            else {
                self.items = []
            }
        }
    }
}

public extension Network.SessionPro.GetProStatusResponse {
    enum ErrorReport: CaseIterable {
        case success
        case genericError
        
        var libSessionValue: SESSION_PRO_BACKEND_GET_PRO_STATUS_ERROR_REPORT {
            switch self {
                case .success: return SESSION_PRO_BACKEND_GET_PRO_STATUS_ERROR_REPORT_SUCCESS
                case .genericError: return SESSION_PRO_BACKEND_GET_PRO_STATUS_ERROR_REPORT_GENERIC_ERROR
            }
        }
        
        init(_ libSessionValue: SESSION_PRO_BACKEND_GET_PRO_STATUS_ERROR_REPORT) {
            switch libSessionValue {
                case SESSION_PRO_BACKEND_GET_PRO_STATUS_ERROR_REPORT_SUCCESS: self = .success
                case SESSION_PRO_BACKEND_GET_PRO_STATUS_ERROR_REPORT_GENERIC_ERROR: self = .genericError
                default: self = .genericError
            }
        }
    }
}
