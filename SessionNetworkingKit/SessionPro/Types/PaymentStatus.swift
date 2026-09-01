// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation

public extension Network.SessionPro {
    /// Per-payment consumption status. libsession now delivers this as an opaque string code (the
    /// `SESSION_PRO_BACKEND_PAYMENT_STATUS` enum was removed); an unrecognised value passes through
    /// via `.other`. This is currently informational only (not used for display/gating).
    enum PaymentStatus: Sendable, Equatable, Hashable {
        case none
        case redeemed
        case expired
        case revoked
        case other(String)

        /// Canonical wire status codes. `"unredeemed"` was dropped from the vocabulary upstream (a
        /// `get_pro_status` redeems any pending payment before returning); if it ever appeared it would now
        /// fall through to `.other` — graceful.
        static let redeemedCode: String = "redeemed"
        static let expiredCode: String = "expired"
        static let revokedCode: String = "revoked"

        init(code: String) {
            switch code {
                case "": self = .none
                case PaymentStatus.redeemedCode: self = .redeemed
                case PaymentStatus.expiredCode: self = .expired
                case PaymentStatus.revokedCode: self = .revoked
                default: self = .other(code)
            }
        }
    }
}
