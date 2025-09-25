// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine

public protocol SessionProManagerType: AnyObject {
    var sessionProStateSubject: CurrentValueSubject<SessionProPlanState, Never> { get }
    var sessionProStatePublisher: AnyPublisher<SessionProPlanState, Never> { get }
    var sessionProPlans: [SessionProPlan] { get }
    func upgradeToPro(completion: ((_ result: Bool) -> Void)?)
}

public enum SessionProPlanState {
    case none
    case active(
        currentPlan: SessionProPlan,
        expiredOn: Date,
        isAutoRenewing: Bool,
        originatingPlatform: ClientPlatform
    )
    case expired
    case refunding(
        originatingPlatform: ClientPlatform
    )
    
    public var originatingPlatform: ClientPlatform {
        return switch(self) {
            case .active(_, _, _, let originatingPlatform): originatingPlatform
            case .refunding(let originatingPlatform): originatingPlatform
            default: .iOS // FIXME: get the real originating platform
        }
    }
}

public struct SessionProPlan: Equatable {
    public enum Variant {
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
    public let price: Double
    public let discountPercent: Int?
    
    public init(variant: Variant, price: Double, discountPercent: Int?) {
        self.variant = variant
        self.price = price
        self.discountPercent = discountPercent
    }
    
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.variant  == rhs.variant
    }
}

public enum ClientPlatform {
    case iOS
    case Android
}
