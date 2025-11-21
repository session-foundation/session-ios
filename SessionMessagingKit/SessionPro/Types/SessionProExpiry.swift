// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import SessionUtilitiesKit

public extension SessionPro {
    enum Expiry: Sendable, CaseIterable, Equatable, CustomStringConvertible {
        case tenSeconds
        case twentyFourHoursMinusOneMinute
        case twentyFourHoursPlusFiveMinute
        case twentyFourDaysPlusFiveMinute
        
        public var durationInSeconds: TimeInterval {
            switch self {
                case .tenSeconds: return 10
                case .twentyFourHoursMinusOneMinute: return 24 * 60 * 60 - 60
                case .twentyFourHoursPlusFiveMinute: return 24 * 60 * 60 + 5 * 60
                case .twentyFourDaysPlusFiveMinute: return 24 * 24 * 60 * 60 + 5 * 60
            }
        }
        
        public var description: String {
            switch self {
                case .tenSeconds: return "10s"
                case .twentyFourHoursMinusOneMinute: return "23h59m"
                case .twentyFourHoursPlusFiveMinute: return "24h+5m"
                case .twentyFourDaysPlusFiveMinute: return "24d+5m"
            }
        }
    }
}

// MARK: - MockableFeature

public extension FeatureStorage {
    static let mockCurrentUserSessionProExpiry: FeatureConfig<MockableFeature<SessionPro.Expiry>> = Dependencies.create(
        identifier: "mockCurrentUserSessionProExpiry"
    )
}

extension SessionPro.Expiry: MockableFeatureValue {
    public var title: String { "\(self)" }
    
    public var subtitle: String {
        switch self {
            case .tenSeconds: return "The state where the users Pro status will expire in 10s"
            case .twentyFourHoursMinusOneMinute: return "The state where the users Pro status will expire in 23h59m"
            case .twentyFourHoursPlusFiveMinute: return "The state where the users Pro status will expire in 24h+5m"
            case .twentyFourDaysPlusFiveMinute: return "The state where the users Pro status will expire in 24d+5m"
        }
    }
}
