// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import SessionUtil
import SessionUIKit

public extension Network.SessionPro {
    /// A billing plan as the raw parsed period `count` + `unit` (Delta #14). libsession parses the wire
    /// plan into `(plan_count, plan_unit)` and the unit is preserved EXACTLY — there is NO canonicalisation
    /// (an annual plan is `(1, .year)`, never rewritten to `(12, .month)`). Display renders generically
    /// from `(count, unit)` via the OS formatter, so a new period (`"6m"`, `"1w"`, `"2y"`) needs no code
    /// change. This value is compared for equality against the store catalog to identify the active plan,
    /// so the catalog's `(count, unit)` per SKU MUST match what the backend reports (see `SessionPro.Plan`).
    struct Plan: Sendable, Equatable, Hashable {
        public let count: Int
        public let unit: Unit

        /// Billing-period unit, mirroring libsession's `SESSION_PRO_BACKEND_PLAN_UNIT` (a closed set; also
        /// android's `ProPlanUnit`). `.unknown` covers any future unit this client doesn't recognise.
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

            /// The `DateComponentsFormatter` unit this maps to (`nil` for `.lifetime`, which isn't a
            /// duration, and `.unknown`, which has no OS unit).
            var calendarUnit: NSCalendar.Unit? {
                switch self {
                    case .second: return .second
                    case .day: return .day
                    case .week: return .weekOfMonth
                    case .month: return .month
                    case .year: return .year
                    case .lifetime, .unknown: return nil
                }
            }
        }

        /// From libsession's structured value — stored verbatim, no canonicalisation.
        public init(count: Int, unit: SESSION_PRO_BACKEND_PLAN_UNIT) {
            self.count = count
            self.unit = Unit(unit)
        }

        /// For the client's own store-catalog entries.
        public init(count: Int, unit: Unit) {
            self.count = count
            self.unit = unit
        }

        public var isLifetime: Bool { (unit == .lifetime) }

        /// Approximate whole months for per-month price math (`.month` → count, `.year` → count × 12).
        /// Only meaningful for the catalog's month/year SKUs; other units fall back to the raw count.
        public var approximateMonths: Int {
            switch unit {
                case .year: return (count * 12)
                default: return count
            }
        }

        /// A localised, OS-formatted period label ("3 months", "1 year", …) — locale + plural handled by
        /// `DateComponentsFormatter`, rendering the unit exactly as given (no canonicalisation). `.lifetime`
        /// isn't a duration, so it resolves `proPlanLifetime` (English "Lifetime" fallback until the
        /// Crowdin key syncs, same gate as `pro_provider_*`).
        public func durationString(singular: Bool = false) -> String {
            guard unit != .lifetime else {
                let key: String = "proPlanLifetime"
                let localized: String = LocalizationHelper(template: key).localized()
                return (localized != key ? localized : "Lifetime")
            }

            var components: DateComponents = DateComponents()
            switch unit {
                case .second: components.second = count
                case .day: components.day = count
                case .week: components.weekOfMonth = count
                case .month: components.month = count
                case .year: components.year = count
                case .lifetime, .unknown: components.month = count   // `.lifetime` handled above
            }

            let formatter: DateComponentsFormatter = DateComponentsFormatter()
            formatter.unitsStyle = .full
            if let allowed: NSCalendar.Unit = unit.calendarUnit { formatter.allowedUnits = [allowed] }
            if singular { formatter.maximumUnitCount = 1 }

            return (formatter.string(from: components) ?? "\(count)")
        }
    }
}
