// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation

public enum SessionProPlanScreenContent {}

public extension SessionProPlanScreenContent {
    enum SessionProPlanPaymentFlow: Equatable {
        case purchase
        case update(
            currentPlan: SessionProPlanInfo,
            expiredOn: Date,
            isAutoRenewing: Bool,
            originatingPlatform: ClientPlatform
        )
        case renew
        case refund
        case cancel
    }
    
    enum ClientPlatform: Equatable {
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
    }
    
    struct SessionProPlanInfo: Equatable {
        let duration: Int
        var durationString: String {
            let formatter = DateComponentsFormatter()
            formatter.unitsStyle = .full
            formatter.allowedUnits = [.month]
            let components = DateComponents(month: self.duration)
            return (formatter.string(from: components) ?? "\(self.duration) Months").capitalized
        }
        let totalPrice: Double
        let pricePerMonth: Double
        let discountPercent: Int?
        let titleWithPrice: String
        let subtitleWithPrice: String
        
        public init(duration: Int, totalPrice: Double, pricePerMonth: Double, discountPercent: Int?, titleWithPrice: String, subtitleWithPrice: String) {
            self.duration = duration
            self.totalPrice = totalPrice
            self.pricePerMonth = pricePerMonth
            self.discountPercent = discountPercent
            self.titleWithPrice = titleWithPrice
            self.subtitleWithPrice = subtitleWithPrice
        }
    }

    final class DataModel: Equatable {
        let flow: SessionProPlanPaymentFlow
        let plans: [SessionProPlanInfo]
        
        public init(
            flow: SessionProPlanPaymentFlow,
            plans: [SessionProPlanInfo],
            
        ) {
            self.flow = flow
            self.plans = plans
        }
        
        public static func == (lhs: DataModel, rhs: DataModel) -> Bool {
            return lhs.flow == rhs.flow
        }
    }
}

