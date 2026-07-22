// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation

public extension Network.SessionPro {
    /// The user's account-level Pro status. libsession now delivers this as an opaque string code
    /// (the `SESSION_PRO_BACKEND_USER_PRO_STATUS` enum was removed). An unrecognised/future code
    /// (`"grace"`, `"suspended"`, …) is preserved via `.unknown(code)` for display/telemetry.
    ///
    /// CRITICAL: `.unknown` must NEVER grant Pro — every entitlement/gating check treats it exactly
    /// like `.neverBeenPro` (fail closed). It is only surfaced informationally.
    enum BackendUserProStatus: Sendable, CaseIterable, Equatable, Hashable, CustomStringConvertible {
        case neverBeenPro
        case active
        case expired
        case unknown(String)

        /// Canonical wire status codes
        static let neverCode: String = "never"
        static let activeCode: String = "active"
        static let expiredCode: String = "expired"

        /// The finite, mockable/known cases. `.unknown` carries a free-form wire value so it is
        /// deliberately excluded (it's a real-backend value, not a dev-picker option).
        public static var allCases: [BackendUserProStatus] { [.neverBeenPro, .active, .expired] }

        init(code: String) {
            switch code {
                case "", BackendUserProStatus.neverCode: self = .neverBeenPro
                case BackendUserProStatus.activeCode: self = .active
                case BackendUserProStatus.expiredCode: self = .expired
                default: self = .unknown(code)
            }
        }

        public var description: String {
            switch self {
                case .neverBeenPro: return "Never been pro"
                case .active: return "Active"
                case .expired: return "Expired"
                case .unknown(let code): return "Unknown (\(code))"
            }
        }
    }
}
