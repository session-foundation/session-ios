// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation

public enum SessionProPaymentScreenContent {}

public extension SessionProPaymentScreenContent {
    enum SessionProPlanPaymentFlow: Equatable {
        case purchase
        case update(
            currentPlan: SessionProPlanInfo,
            expiredOn: Date,
            isAutoRenewing: Bool,
            originatingPlatform: ClientPlatform
        )
        case renew
        case refund(
            originatingPlatform: ClientPlatform,
            requestedAt: Date?
        )
        case cancel(
            originatingPlatform: ClientPlatform
        )
        
        var description: ThemedAttributedString {
            switch self {
            case .purchase:
                ThemedAttributedString(string: "Choose the plan that’s right for you, longer plans have bigger discounts.")
            case .update(let currentPlan, let expiredOn, let isAutoRenewing, _):
                isAutoRenewing ?
                    "proPlanActivatedAuto"
                        .put(key: "app_pro", value: Constants.app_pro)
                        .put(key: "current_plan", value: currentPlan.durationString)
                        .put(key: "date", value: expiredOn.formatted("MMM dd, yyyy"))
                        .put(key: "pro", value: Constants.pro)
                        .localizedFormatted(Fonts.Body.baseRegular) :
                    "proPlanActivatedNotAuto"
                        .put(key: "app_pro", value: Constants.app_pro)
                        .put(key: "date", value: expiredOn.formatted("MMM dd, yyyy"))
                        .put(key: "pro", value: Constants.pro)
                        .localizedFormatted(Fonts.Body.baseRegular)
            case .renew:
                "proPlanRenewStart"
                    .put(key: "app_pro", value: Constants.app_pro)
                    .localizedFormatted(baseFont: Fonts.Body.baseRegular)
            case .refund:
                "proRefundDescription"
                    .localizedFormatted(baseFont: Fonts.Body.baseRegular)
            case .cancel(let originatingPlatform):
                "proCancelSorry"
                    .put(key: "pro", value: Constants.pro)
                    .put(key: "app_pro", value: Constants.app_pro)
                    .localizedFormatted(baseFont: Fonts.Body.baseRegular)
            }
        }
    }
    
    enum ClientPlatform: Equatable {
        case iOS
        case Android
        
        public var store: String {
            switch self {
                case .iOS: return Constants.platform_store
                case .Android: return Constants.android_platform_store
            }
        }
        
        public var account: String {
            switch self {
                case .iOS: return Constants.platform_account
                case .Android: return Constants.android_platform_account
            }
        }
        
        public var deviceType: String {
            switch self {
                case .iOS: return Constants.platform
                case .Android: return Constants.android_platform
            }
        }
        
        public var name: String {
            switch self {
                case .iOS: return Constants.platform_name
                case .Android: return Constants.android_platform_name
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

