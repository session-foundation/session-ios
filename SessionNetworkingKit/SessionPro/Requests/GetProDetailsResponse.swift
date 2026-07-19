// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtil
import SessionUtilitiesKit

public extension Network.SessionPro {
    struct GetProDetailsResponse: Equatable {
        public let header: ResponseHeader
        public let items: [PaymentItem]
        public let status: BackendUserProStatus
        public let errorReport: ErrorReport
        public let autoRenewing: Bool
        public let nextAutoRenewingTimestampMs: UInt64?
        public let expiryTimestampMs: UInt64
        public let gracePeriodDurationMs: UInt64
        public let paymentsTotal: UInt32

        /// Parse the RAW response bytes via libsession — the client never inspects/assumes the wire.
        public init(parsing data: Data) {
            var result = data.withUnsafeBytes { bytes in
                session_pro_backend_get_pro_details_response_parse(
                    bytes.baseAddress?.assumingMemoryBound(to: CChar.self),
                    data.count
                )
            }
            defer { session_pro_backend_get_pro_details_response_free(&result) }
            
            self.header = ResponseHeader(result.header)
            /// `status` (the account user-status) is now an opaque string code (char[64]) rather than an enum
            self.status = BackendUserProStatus(code: result.get(\.status).substring(to: result.status_count))
            self.errorReport = ErrorReport(result.error_report)
            self.autoRenewing = result.auto_renewing
            /// The wire is now whole seconds; we keep the Swift domain in milliseconds (boundary conversion)
            self.expiryTimestampMs = UInt64(max(0, result.expiry_ts)) * 1000
            self.gracePeriodDurationMs = UInt64(max(0, result.grace_period_duration)) * 1000
            self.paymentsTotal = result.payments_total
            
            if result.items_count > 0 {
                self.items = (0..<result.items_count).map { index in
                    PaymentItem(result.items[index])
                }
            }
            else {
                self.items = []
            }
            
            self.nextAutoRenewingTimestampMs = self.items.last?.expiryTimestampMs
        }
    }
}

public extension Network.SessionPro.GetProDetailsResponse {
    enum ErrorReport: CaseIterable {
        case success
        case genericError
        
        var libSessionValue: SESSION_PRO_BACKEND_GET_PRO_DETAILS_ERROR_REPORT {
            switch self {
                case .success: return SESSION_PRO_BACKEND_GET_PRO_DETAILS_ERROR_REPORT_SUCCESS
                case .genericError: return SESSION_PRO_BACKEND_GET_PRO_DETAILS_ERROR_REPORT_GENERIC_ERROR
            }
        }
        
        init(_ libSessionValue: SESSION_PRO_BACKEND_GET_PRO_DETAILS_ERROR_REPORT) {
            switch libSessionValue {
                case SESSION_PRO_BACKEND_GET_PRO_DETAILS_ERROR_REPORT_SUCCESS: self = .success
                case SESSION_PRO_BACKEND_GET_PRO_DETAILS_ERROR_REPORT_GENERIC_ERROR: self = .genericError
                default: self = .genericError
            }
        }
    }
}

/// `status` (account user-status) is now a `char[64]` string field, read via the CAccessible helpers
extension session_pro_backend_get_pro_details_response: @retroactive CAccessible {}
