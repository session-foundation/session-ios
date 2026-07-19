// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation

public extension Network.SessionPro {
    /// The user's account-level Pro status. libsession now delivers this as an opaque string code
    /// (the `SESSION_PRO_BACKEND_USER_PRO_STATUS` enum was removed). We fail closed: any unrecognised
    /// code (including a future one) maps to `.neverBeenPro` rather than granting Pro.
    enum BackendUserProStatus: Sendable, CaseIterable, Equatable, CustomStringConvertible {
        case neverBeenPro
        case active
        case expired

        /// Canonical wire status codes
        static let neverCode: String = "never"
        static let activeCode: String = "active"
        static let expiredCode: String = "expired"

        init(code: String) {
            switch code {
                case BackendUserProStatus.activeCode: self = .active
                case BackendUserProStatus.expiredCode: self = .expired
                default: self = .neverBeenPro    // "never" + any unrecognised/empty code
            }
        }

        public var description: String {
            switch self {
                case .neverBeenPro: return "Never been pro"
                case .active: return "Active"
                case .expired: return "Expired"
            }
        }
    }
}
