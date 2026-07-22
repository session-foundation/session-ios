// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtil
import SessionUtilitiesKit

public extension Network.SessionPro {
    struct PaymentItem: Sendable, Equatable, Hashable {
        public let status: PaymentStatus
        public let plan: Plan
        public let paymentProvider: PaymentProvider?

        public let autoRenewing: Bool
        /// `purchased`/`revoked` are millisecond-precise (see `init`), so they stay integer milliseconds;
        /// every other Pro timestamp/duration is whole unix seconds (matching the wire and libsession).
        public let purchasedTimestampMs: UInt64
        public let redeemedTimestampSeconds: UInt64
        public let expiryTimestampSeconds: UInt64
        public let gracePeriodDurationSeconds: UInt64
        public let platformRefundExpiryTimestampSeconds: UInt64
        public let revokedTimestampMs: UInt64
        public let refundRequestedTimestampSeconds: UInt64

        /// Opaque payment identifier (the value passed at add-payment). Multi-part providers fold their
        /// parts into this one string per a backend-defined composite; libsession does not interpret it.
        public let paymentId: String

        /// The App Store transaction id, when this payment came from the App Store. For App Store payments
        /// the opaque `payment_id` *is* the StoreKit transaction id (single-part provider), so we expose it
        /// under the old name the refund flow expects. `nil` for any other provider.
        public var appleTransactionId: String? {
            guard paymentProvider == .appStore else { return nil }

            return paymentId
        }

        init(_ libSessionValue: session_pro_backend_pro_payment_item) {
            status = PaymentStatus(code: libSessionValue.get(\.status).substring(to: libSessionValue.status_count))
            plan = Plan(code: libSessionValue.get(\.plan).substring(to: libSessionValue.plan_count))

            let providerCode: String = libSessionValue.get(\.payment_provider)
                .substring(to: libSessionValue.payment_provider_count)
            paymentProvider = (providerCode.isEmpty ? nil : PaymentProvider(code: providerCode))

            autoRenewing = libSessionValue.auto_renewing
            /// All Pro quantities are epoch seconds. Most are whole seconds (`int64` on the C side) and our
            /// domain is seconds too, so they're direct assigns. `purchased_ts`/`revoked_ts` are `double`
            /// seconds carrying only millisecond precision (sys_ms-backed in libsession); we keep those two
            /// as integer milliseconds (×1000, truncated) to retain that precision.
            purchasedTimestampMs = UInt64(max(0, libSessionValue.purchased_ts) * 1000)
            redeemedTimestampSeconds = UInt64(max(0, libSessionValue.redeemed_ts))
            expiryTimestampSeconds = UInt64(max(0, libSessionValue.expiry_ts))
            gracePeriodDurationSeconds = UInt64(max(0, libSessionValue.grace_period_duration))
            platformRefundExpiryTimestampSeconds = UInt64(max(0, libSessionValue.platform_refund_expiry_ts))
            revokedTimestampMs = UInt64(max(0, libSessionValue.revoked_ts) * 1000)
            refundRequestedTimestampSeconds = UInt64(max(0, libSessionValue.refund_requested_ts))

            paymentId = libSessionValue.get(\.payment_id).substring(to: libSessionValue.payment_id_count)
        }
    }
}

extension session_pro_backend_pro_payment_item: @retroactive CAccessible {}
