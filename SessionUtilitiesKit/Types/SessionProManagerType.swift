// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine

public protocol SessionProManagerType: AnyObject {
    var sessionProStateSubject: CurrentValueSubject<SessionProPlanState, Never> { get }
    var sessionProStatePublisher: AnyPublisher<SessionProPlanState, Never> { get }
    var sessionProPlans: [SessionProPlan] { get }
    func upgradeToPro(plan: SessionProPlan, originatingPlatform: ClientPlatform, completion: ((_ result: Bool) -> Void)?) async
    func cancelPro(completion: ((_ result: Bool) -> Void)?) async
    func requestRefund(completion: ((_ result: Bool) -> Void)?) async
    func expirePro(completion: ((_ result: Bool) -> Void)?) async
    func recoverPro(completion: ((_ result: Bool) -> Void)?) async
    // These functions are only for QA purpose
    func updateOriginatingPlatform(_ newValue: ClientPlatform)
    func updateProExpiry(_ expiryInSeconds: TimeInterval?)
}

public enum SessionProPlanState: Equatable, Sendable {
    case none
    case active(
        currentPlan: SessionProPlan,
        expiredOn: Date,
        isAutoRenewing: Bool,
        originatingPlatform: ClientPlatform
    )
    case expired(
        expiredOn: Date,
        originatingPlatform: ClientPlatform
    )
    case refunding(
        originatingPlatform: ClientPlatform,
        requestedAt: Date?
    )
    
    public var originatingPlatform: ClientPlatform {
        return switch(self) {
            case .active(_, _, _, let originatingPlatform): originatingPlatform
            case .expired(_, let originatingPlatform): originatingPlatform
            case .refunding(let originatingPlatform, _): originatingPlatform
            default: .iOS // FIXME: get the real originating platform
        }
    }
    
    public func with(originatingPlatform: ClientPlatform) -> SessionProPlanState {
        switch self {
            case .active(let plan, let expiredOn, let isAutoRenewing, _):
                return .active(
                    currentPlan: plan,
                    expiredOn: expiredOn,
                    isAutoRenewing: isAutoRenewing,
                    originatingPlatform: originatingPlatform
                )
            case .refunding(_, let requestedAt):
                return .refunding(
                    originatingPlatform: originatingPlatform,
                    requestedAt: requestedAt
                )
            case .expired(let expiredOn, _):
                return .expired(
                    expiredOn: expiredOn,
                    originatingPlatform: originatingPlatform
                )
            default: return self
        }
    }
}

public struct SessionProPlan: Equatable, Sendable {
    public enum Variant: Sendable {
        case oneMonth, threeMonths, twelveMonths
        
        public static var allCases: [Variant] { [.twelveMonths, .threeMonths, .oneMonth] }
        
        public var duration: Int {
            switch self {
                case .oneMonth: return 1
                case .threeMonths: return 3
                case .twelveMonths: return 12
            }
        }
        
        // MARK: - Mock
        public var price: Double {
            switch self {
                case .oneMonth: return 5.99
                case .threeMonths: return 14.99
                case .twelveMonths: return 47.99
            }
        }
        
        public var discountPercent: Int? {
            switch self {
                case .oneMonth: return nil
                case .threeMonths: return 16
                case .twelveMonths: return 33
            }
        }
    }
    
    public let variant: Variant
    
    public init(variant: Variant) {
        self.variant = variant
    }
    
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.variant  == rhs.variant
    }
}

// TODO: [PRO] Move these strings

public enum ClientPlatform: String, Sendable {
    case iOS
    case Android
    
    public var store: String {
        switch self {
            case .iOS: return "Apple App"
            case .Android: return "Google Play"
        }
    }
    
    public var account: String {
        switch self {
            case .iOS: return "Apple Account"
            case .Android: return "Google Account"
        }
    }
    
    public var deviceType: String {
        switch self {
            case .iOS: return "iOS"
            case .Android: return "Android"
        }
    }
    
    public var name: String {
        switch self {
            case .iOS: return "Apple"
            case .Android: return "Google"
        }
    }
}

// MARK: - Developer Settings

public enum SessionProStateMock: String, Sendable, Codable, CaseIterable, FeatureOption {
    case none
    case active
    case expiring
    case expired
    case refunding
    
    public static var defaultOption: SessionProStateMock = .none
    
    // stringlint:ignore_contents
    public var title: String {
        switch self {
            case .none: return "None"
            case .active: return "Active"
            case .expiring: return "Expiring"
            case .expired: return "Expired"
            case .refunding: return "Refunding"
        }
    }
    
    // stringlint:ignore_contents
    public var subtitle: String? {
        switch self {
            case .expiring: return "Active, no auto-renewing"
            default: return nil
        }
    }
}

public enum SessionProStateExpiryMock: String, Sendable, Codable, CaseIterable, FeatureOption {
    case none
    case twentyFourDaysPlusFiveMinute
    case twentyFourHoursPlusFiveMinute
    case twentyFourHoursMinusOneMinute
    case tenSeconds
    
    public static var defaultOption: SessionProStateExpiryMock = .none
    
    // stringlint:ignore_contents
    public var title: String {
        switch self {
            case .none: return "None"
            case .twentyFourDaysPlusFiveMinute: return "24d+5m"
            case .twentyFourHoursPlusFiveMinute: return "24h+5m"
            case .twentyFourHoursMinusOneMinute: return "23h59m"
            case .tenSeconds: return "10s"
        }
    }
    
    public var subtitle: String? { return nil }
    
    public var durationInSeconds: TimeInterval? {
        switch self {
            case .none: return nil
            case .twentyFourDaysPlusFiveMinute: return 24 * 24 * 60 * 60 + 5 * 60
            case .twentyFourHoursPlusFiveMinute: return 24 * 60 * 60 + 5 * 60
            case .twentyFourHoursMinusOneMinute: return 24 * 60 * 60 - 60
            case .tenSeconds: return 10
        }
    }
}

public enum SessionProLoadingState: String, Sendable, Codable, CaseIterable, FeatureOption {
    case loading
    case error
    case success
    
    public static var defaultOption: SessionProLoadingState = .success
    
    // stringlint:ignore_contents
    public var title: String {
        switch self {
            case .loading: return "Loading"
            case .error: return "Error"
            case .success: return "Success"
        }
    }
    
    public var subtitle: String? { return nil }
}

extension ClientPlatform: FeatureOption {
    public static var defaultOption: ClientPlatform = .iOS
    public var title: String { deviceType }
    public var subtitle: String? { return nil }
}
