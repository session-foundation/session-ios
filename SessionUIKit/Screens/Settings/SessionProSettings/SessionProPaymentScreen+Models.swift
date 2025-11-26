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
            originatingPlatform: SessionProUI.ClientPlatform
        )
        case renew(
            originatingPlatform: SessionProUI.ClientPlatform
        )
        case refund(
            originatingPlatform: SessionProUI.ClientPlatform,
            requestedAt: Date?
        )
        case cancel(
            originatingPlatform: SessionProUI.ClientPlatform
        )
        
        var description: ThemedAttributedString {
            switch self {
                case .purchase:
                    return "proChooseAccess"
                        .put(key: "pro", value: Constants.pro)
                        .localizedFormatted(Fonts.Body.baseRegular)
                
                case .update(let currentPlan, let expiredOn, let isAutoRenewing, _):
                    guard isAutoRenewing else {
                        return "proAccessActivatedNotAuto"
                            .put(key: "date", value: expiredOn.formatted("MMM dd, yyyy"))
                            .put(key: "pro", value: Constants.pro)
                            .localizedFormatted(Fonts.Body.baseRegular)
                    }
                    
                    return "proAccessActivatesAuto"
                        .put(key: "current_plan_length", value: currentPlan.durationString)
                        .put(key: "date", value: expiredOn.formatted("MMM dd, yyyy"))
                        .put(key: "pro", value: Constants.pro)
                        .localizedFormatted(Fonts.Body.baseRegular)
                
                case .renew:
                    return "proAccessRenewStart"
                        .put(key: "app_pro", value: Constants.app_pro)
                        .put(key: "pro", value: Constants.pro)
                        .localizedFormatted(baseFont: Fonts.Body.baseRegular)
                
                case .refund:
                    return "proRefundDescription"
                        .localizedFormatted(baseFont: Fonts.Body.baseRegular)
                
                case .cancel:
                    return "proCancelSorry"
                        .put(key: "pro", value: Constants.pro)
                        .localizedFormatted(baseFont: Fonts.Body.baseRegular)
            }
        }
    }
    
    struct SessionProPlanInfo: Equatable {
        public let duration: Int
        let totalPrice: Double
        let pricePerMonth: Double
        let discountPercent: Int?
        let titleWithPrice: String
        let subtitleWithPrice: String
        
        var durationString: String {
            let components = DateComponents(month: self.duration)
            let formatter = DateComponentsFormatter()
            formatter.unitsStyle = .full
            formatter.allowedUnits = [.month]
            
            return (formatter.string(from: components) ?? "\(self.duration) Months")
        }
        
        var durationStringSingular: String {
            let components = DateComponents(month: self.duration)
            let formatter = DateComponentsFormatter()
            formatter.unitsStyle = .full
            formatter.allowedUnits = [.month]
            formatter.maximumUnitCount = 1
            
            return (formatter.string(from: components) ?? "\(self.duration) Month")
        }
        
        public init(
            duration: Int,
            totalPrice: Double,
            pricePerMonth: Double,
            discountPercent: Int?,
            titleWithPrice: String,
            subtitleWithPrice: String
        ) {
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
            plans: [SessionProPlanInfo]
        ) {
            self.flow = flow
            self.plans = plans
        }
        
        public static func == (lhs: DataModel, rhs: DataModel) -> Bool {
            return lhs.flow == rhs.flow
        }
    }
    
    protocol ViewModelType: AnyObject {
        var dataModel: DataModel { get set }
        var isRefreshing: Bool { get set }
        var errorString: String? { get set }
        
        func purchase(planInfo: SessionProPlanInfo, success: (() -> Void)?, failure: (() -> Void)?)
        func cancelPro(success: (() -> Void)?, failure: (() -> Void)?)
        func openURL(_ url: URL)
    }
}

