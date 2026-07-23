// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import SessionUtil

public extension Network.SessionPro {
    /// A billing plan, expressed as a period `count` + `unit` (Delta #14). libsession parses the wire
    /// plan into a structured `(plan_count, plan_unit)` pair; `unit` is a closed set. The common periods
    /// map to named cases for display/comparison; anything else passes through via `.other(count:unit:)`
    /// (so an unfamiliar period never breaks). `unit == .lifetime` has no meaningful count.
    enum Plan: Sendable, Equatable, Hashable {
        case none
        case oneMonth
        case threeMonths
        case twelveMonths
        case other(count: Int, unit: Unit)

        /// The billing-period unit, mirroring libsession's `SESSION_PRO_BACKEND_PLAN_UNIT` (closed set);
        /// `.unknown` covers any future unit this client doesn't recognise.
        public enum Unit: Sendable, Equatable, Hashable {
            case second
            case day
            case week
            case month
            case year
            case lifetime
            case unknown

            init(_ libSessionValue: SESSION_PRO_BACKEND_PLAN_UNIT) {
                switch libSessionValue {
                    case SESSION_PRO_BACKEND_PLAN_UNIT_SECOND: self = .second
                    case SESSION_PRO_BACKEND_PLAN_UNIT_DAY: self = .day
                    case SESSION_PRO_BACKEND_PLAN_UNIT_WEEK: self = .week
                    case SESSION_PRO_BACKEND_PLAN_UNIT_MONTH: self = .month
                    case SESSION_PRO_BACKEND_PLAN_UNIT_YEAR: self = .year
                    case SESSION_PRO_BACKEND_PLAN_UNIT_LIFETIME: self = .lifetime
                    default: self = .unknown
                }
            }
        }

        init(count: Int, unit: SESSION_PRO_BACKEND_PLAN_UNIT) {
            switch (count, unit) {
                case (1, SESSION_PRO_BACKEND_PLAN_UNIT_MONTH): self = .oneMonth
                case (3, SESSION_PRO_BACKEND_PLAN_UNIT_MONTH): self = .threeMonths
                case (12, SESSION_PRO_BACKEND_PLAN_UNIT_MONTH): self = .twelveMonths
                case (1, SESSION_PRO_BACKEND_PLAN_UNIT_YEAR): self = .twelveMonths
                default: self = .other(count: count, unit: Unit(unit))
            }
        }
    }
}
