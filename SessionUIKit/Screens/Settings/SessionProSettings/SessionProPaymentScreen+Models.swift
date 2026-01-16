// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import UIKit

public enum SessionProPaymentScreenContent {}

public extension SessionProPaymentScreenContent {
    enum SessionProPlanPaymentFlow: Equatable {
        case purchase(
            billingAccess: Bool
        )
        case update(
            currentPlan: SessionProPlanInfo,
            expiredOn: Date,
            originatingPlatform: SessionProUI.ClientPlatform,
            isAutoRenewing: Bool,
            isNonOriginatingAccount: Bool?,
            billingAccess: Bool
        )
        case renew(
            originatingPlatform: SessionProUI.ClientPlatform,
            billingAccess: Bool
        )
        case refund(
            originatingPlatform: SessionProUI.ClientPlatform,
            isNonOriginatingAccount: Bool?,
            requestedAt: Date?
        )
        case cancel(
            originatingPlatform: SessionProUI.ClientPlatform
        )
        
        var description: ThemedAttributedString {
            switch self {
                case .purchase(billingAccess: true):
                    return "proChooseAccess"
                        .put(key: "pro", value: Constants.pro)
                        .localizedFormatted(Fonts.Body.baseRegular)
                    
                case .purchase(billingAccess: false):
                    return "proUpgradeAccess"
                        .put(key: "app_pro", value: Constants.app_pro)
                        .localizedFormatted(Fonts.Body.baseRegular)
                
                case .update(let currentPlan, let expiredOn, .android, true, _, _):
                    return "proAccessActivatedAutoShort"
                        .put(key: "current_plan_length", value: currentPlan.durationString)
                        .put(key: "date", value: expiredOn.formatted("MMM dd, yyyy"))
                        .put(key: "pro", value: Constants.pro)
                        .localizedFormatted(Fonts.Body.baseRegular)
                    
                case .update(_, let expiredOn, .android, false, _, _):
                    return "proAccessExpireDate"
                        .put(key: "date", value: expiredOn.formatted("MMM dd, yyyy"))
                        .put(key: "pro", value: Constants.pro)
                        .localizedFormatted(Fonts.Body.baseRegular)
                
                case .update(let currentPlan, let expiredOn, .iOS, true, _, _):
                    return "proAccessActivatesAuto"
                        .put(key: "current_plan_length", value: currentPlan.durationString)
                        .put(key: "date", value: expiredOn.formatted("MMM dd, yyyy"))
                        .put(key: "pro", value: Constants.pro)
                        .localizedFormatted(Fonts.Body.baseRegular)
                    
                case .update(_, let expiredOn, .iOS, false, _, _):
                    return "proAccessActivatedNotAuto"
                        .put(key: "date", value: expiredOn.formatted("MMM dd, yyyy"))
                        .put(key: "pro", value: Constants.pro)
                        .localizedFormatted(Fonts.Body.baseRegular)
                
                case .renew(_, billingAccess: true):
                    return "proChooseAccess"
                        .put(key: "pro", value: Constants.pro)
                        .localizedFormatted(Fonts.Body.baseRegular)
                    
                case .renew(_, billingAccess: false):
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
        public let id: String
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
            id: String,
            duration: Int,
            totalPrice: Double,
            pricePerMonth: Double,
            discountPercent: Int?,
            titleWithPrice: String,
            subtitleWithPrice: String
        ) {
            self.id = id
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
        var dateNow: Date { get }
        var isRefreshing: Bool { get set }
        var errorString: String? { get set }
        var isFromBottomSheet: Bool { get }
        
        @MainActor func purchase(planInfo: SessionProPlanInfo) async throws
        @MainActor func cancelPro(scene: UIWindowScene?) async throws
        @MainActor func requestRefund(scene: UIWindowScene?) async throws
    }
}
