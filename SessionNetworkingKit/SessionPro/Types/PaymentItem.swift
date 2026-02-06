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
        public let unredeemedTimestampMs: UInt64
        public let redeemedTimestampMs: UInt64
        public let expiryTimestampMs: UInt64
        public let gracePeriodDurationMs: UInt64
        public let platformRefundExpiryTimestampMs: UInt64
        public let revokedTimestampMs: UInt64
        public let refundRequestedTimestampMs: UInt64
        
        public let googlePaymentToken: String?
        public let googleOrderId: String?
        public let appleOriginalTransactionId: String?
        public let appleTransactionId: String?
        public let appleWebLineOrderId: String?
        
        init(_ libSessionValue: session_pro_backend_pro_payment_item) {
            status = PaymentStatus(libSessionValue.status)
            plan = Plan(libSessionValue.plan)
            paymentProvider = PaymentProvider(libSessionValue.payment_provider)
            
            autoRenewing = libSessionValue.auto_renewing
            unredeemedTimestampMs = libSessionValue.unredeemed_unix_ts_ms
            redeemedTimestampMs = libSessionValue.redeemed_unix_ts_ms
            expiryTimestampMs = libSessionValue.expiry_unix_ts_ms
            gracePeriodDurationMs = libSessionValue.grace_period_duration_ms
            platformRefundExpiryTimestampMs = libSessionValue.platform_refund_expiry_unix_ts_ms
            revokedTimestampMs = libSessionValue.revoked_unix_ts_ms
            refundRequestedTimestampMs = libSessionValue.refund_requested_unix_ts_ms
            
            googlePaymentToken = libSessionValue.get(
                \.google_payment_token,
                 nullIfEmpty: true,
                 explicitLength: libSessionValue.google_payment_token_count
            )
            googleOrderId = libSessionValue.get(
                \.google_order_id,
                 nullIfEmpty: true,
                 explicitLength: libSessionValue.google_order_id_count
            )
            appleOriginalTransactionId = libSessionValue.get(
                \.apple_original_tx_id,
                 nullIfEmpty: true,
                 explicitLength: libSessionValue.apple_original_tx_id_count
            )
            appleTransactionId = libSessionValue.get(
                \.apple_tx_id,
                 nullIfEmpty: true,
                 explicitLength: libSessionValue.apple_tx_id_count
            )
            appleWebLineOrderId = libSessionValue.get(
                \.apple_web_line_order_id,
                 nullIfEmpty: true,
                 explicitLength: libSessionValue.apple_web_line_order_id_count
            )
        }
    }
}

extension session_pro_backend_pro_payment_item: @retroactive CAccessible {}
