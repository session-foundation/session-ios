// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import SessionUtil

public extension Network.SessionPro {
    /// A billing plan, identified by its opaque wire "period code" (e.g. "1m"/"3m"/"1y").
    ///
    /// libsession no longer ships a fixed plan enum — the plan is a free-form string on the wire, so
    /// an unrecognised code passes through via `.other`. Locale-aware duration formatting of the period
    /// code is the client's job (deferred display work).
    enum Plan: Sendable, Equatable, Hashable {
        case none
        case oneMonth
        case threeMonths
        case twelveMonths
        case other(String)

        /// Canonical wire period codes
        static let oneMonthCode: String = "1m"
        static let threeMonthsCode: String = "3m"
        static let twelveMonthsCode: String = "1y"

        var code: String {
            switch self {
                case .none: return ""
                case .oneMonth: return Plan.oneMonthCode
                case .threeMonths: return Plan.threeMonthsCode
                case .twelveMonths: return Plan.twelveMonthsCode
                case .other(let code): return code
            }
        }

        init(code: String) {
            switch code {
                case "": self = .none
                case Plan.oneMonthCode: self = .oneMonth
                case Plan.threeMonthsCode: self = .threeMonths
                case Plan.twelveMonthsCode: self = .twelveMonths
                default: self = .other(code)
            }
        }
    }
}
