// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtil

public extension Network.SessionPro {
    struct ResponseHeader: Equatable {
        /// Outcome category (Delta #12). Closed set — success is `.ok`.
        public enum Status: Equatable {
            case ok    /// Success; the payload fields are populated.
            case fail  /// Rejected on client input / a precondition.
            case error /// Backend fault; the same request may succeed later (retryable).

            init(_ libSessionValue: SESSION_PRO_BACKEND_RESPONSE_STATUS) {
                switch libSessionValue {
                    case SESSION_PRO_BACKEND_RESPONSE_STATUS_OK: self = .ok
                    case SESSION_PRO_BACKEND_RESPONSE_STATUS_FAIL: self = .fail
                    default: self = .error
                }
            }
        }

        public let status: Status

        /// On non-`.ok`, a stable machine-readable slug (spec §5.1). Map known ones to a localized string;
        /// an unknown slug is forward-compatible (fall back to `error`). `nil` on success.
        public let errorCode: String?

        /// On non-`.ok`, an English diagnostic — NOT user-facing text (that comes from mapping `errorCode`
        /// to a localized string; show this only when the slug has no translation). Always safe to log.
        /// `nil` on success.
        public let error: String?

        public var isSuccess: Bool { status == .ok }

        init(_ libSessionValue: session_pro_backend_response_header) {
            status = Status(libSessionValue.status)
            errorCode = ResponseHeader.optionalString(libSessionValue.error_code)
            error = ResponseHeader.optionalString(libSessionValue.error)
        }

        private static func optionalString(_ value: string8) -> String? {
            guard value.size > 0 else { return nil }
            return String(pointer: value.data, length: value.size, encoding: .utf8)
        }
    }
}
