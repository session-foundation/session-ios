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
        public let purchasedTimestampMs: UInt64
        public let redeemedTimestampMs: UInt64
        public let expiryTimestampMs: UInt64
        public let gracePeriodDurationMs: UInt64
        public let platformRefundExpiryTimestampMs: UInt64
        public let revokedTimestampMs: UInt64
        public let refundRequestedTimestampMs: UInt64

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
            status = PaymentStatus(libSessionValue.status)
            plan = Plan(code: libSessionValue.get(\.plan).substring(to: libSessionValue.plan_count))

            let providerCode: String = libSessionValue.get(\.payment_provider)
                .substring(to: libSessionValue.payment_provider_count)
            paymentProvider = (providerCode.isEmpty ? nil : PaymentProvider(code: providerCode))

            autoRenewing = libSessionValue.auto_renewing
            /// The wire is now whole/fractional seconds; we keep the Swift domain in milliseconds (boundary
            /// conversion). `purchased_ts`/`revoked_ts` are millisecond-precise `double` seconds.
            purchasedTimestampMs = UInt64(max(0, libSessionValue.purchased_ts) * 1000)
            redeemedTimestampMs = UInt64(max(0, libSessionValue.redeemed_ts)) * 1000
            expiryTimestampMs = UInt64(max(0, libSessionValue.expiry_ts)) * 1000
            gracePeriodDurationMs = UInt64(max(0, libSessionValue.grace_period_duration)) * 1000
            platformRefundExpiryTimestampMs = UInt64(max(0, libSessionValue.platform_refund_expiry_ts)) * 1000
            revokedTimestampMs = UInt64(max(0, libSessionValue.revoked_ts) * 1000)
            refundRequestedTimestampMs = UInt64(max(0, libSessionValue.refund_requested_ts)) * 1000

            paymentId = libSessionValue.get(\.payment_id).substring(to: libSessionValue.payment_id_count)
        }
    }
}

extension session_pro_backend_pro_payment_item: @retroactive CAccessible {}
