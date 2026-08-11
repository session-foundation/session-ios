// Copyright © 2025 Session Technology Foundation. All rights reserved.

import Foundation
import SessionUtil
import SessionUtilitiesKit

public extension Network.SessionPro {
    /// Parsed `get_pro_status` response (spec §3.4). Carries the account-level Pro status plus the most
    /// recent payment (when present). The paginated payment history is a separate `get_payment_details`
    /// call that the client doesn't wire yet.
    struct GetProStatusResponse: Equatable {
        public let header: ResponseHeader
        public let status: BackendUserProStatus
        public let autoRenewing: Bool
        public let expiryTimestampSeconds: UInt64
        public let gracePeriodDurationSeconds: UInt64
        /// The most recent payment, or `nil` when the account has none (`has_latest_payment == false`).
        public let latestPaymentItem: PaymentItem?

        /// Parse the RAW response bytes via libsession — the client never inspects/assumes the wire.
        public init(parsing data: Data) {
            var result = data.withUnsafeBytes { bytes in
                session_pro_backend_get_pro_status_response_parse(
                    bytes.baseAddress?.assumingMemoryBound(to: CChar.self),
                    data.count
                )
            }
            defer { session_pro_backend_get_pro_status_response_free(&result) }

            self.header = ResponseHeader(result.header)
            /// `status` (the account user-status) is an opaque NUL-terminated `const char*` code.
            self.status = BackendUserProStatus(code: result.get(\.status))
            /// `error_report` is being dropped from the response (buggy-by-design: e.g. on Apple it can
            /// never clear once set, and a set value carries no actionable signal) — we stop reading it.
            self.autoRenewing = result.auto_renewing
            /// Whole unix seconds on the wire and in our domain — direct assigns, no conversion.
            self.expiryTimestampSeconds = UInt64(max(0, result.expiry_ts))
            /// 🔴 **The ROOT `grace_period_duration`, not `latest_payment.grace_period_duration`.** Both exist on
            /// this response and they are different quantities:
            ///
            /// | field | meaning |
            /// |---|---|
            /// | root (this one) | `coverage_end - user.expiry_at` — how much longer the ACCOUNT is served |
            /// | `latest_payment` | the raw value a store declared about one transaction |
            ///
            /// The payment-level one is **not** gated on `auto_renewing`, so a cancelled subscriber keeps a
            /// multi-week value in it; reading that would put coverage weeks late for an account that is about to
            /// lapse. Verified against `Session-Pro-Backend@1b22202` (`server.py`, `backend.py:523`).
            self.gracePeriodDurationSeconds = UInt64(max(0, result.grace_period_duration))
            /// `refund_requested_ts` is gone from the response — refund-pending is config-synced state now.
            self.latestPaymentItem = (result.has_latest_payment ? PaymentItem(result.latest_payment) : nil)
        }
    }
}

/// `status` is a NUL-terminated `const char*` field, read via the CAccessible helpers.
extension session_pro_backend_get_pro_status_response: @retroactive CAccessible {}
