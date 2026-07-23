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
            isNonOriginatingAccount: Bool,
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
            originatingPlatform: SessionProUI.ClientPlatform,
            isNonOriginatingAccount: Bool?
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
                    
                case .update(_, let expiredOn, .android, false, _, _), .update(_, let expiredOn, .iOS, false, true, _):
                    return "proAccessExpireDate"
                        .put(key: "date", value: expiredOn.formatted("MMM dd, yyyy"))
                        .put(key: "pro", value: Constants.pro)
                        .localizedFormatted(Fonts.Body.baseRegular)
                
                case .update(let currentPlan, let expiredOn, .iOS, true, false, _):
                    return "proAccessActivatesAuto"
                        .put(key: "current_plan_length", value: currentPlan.durationString)
                        .put(key: "date", value: expiredOn.formatted("MMM dd, yyyy"))
                        .put(key: "pro", value: Constants.pro)
                        .localizedFormatted(Fonts.Body.baseRegular)
                
                case .update(let currentPlan, let expiredOn, .iOS, true, true, _):
                    return "proAccessActivatedAutoShort"
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
                
                case .refund(originatingPlatform: .iOS, _, requestedAt: .some):
                    return "proRequestedRefund"
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
        /// Whole-month count, used ONLY for renewal-date arithmetic (`.date(byAdding: .month, …)`); an
        /// annual plan is 12 here. NOT for display — the label is `durationString`, formatted upstream
        /// from the plan's real `(count, unit)` (so "1 year" isn't shown as "12 months").
        public let duration: Int
        let discountPercent: Int?
        let titleWithPrice: String
        let subtitleWithPrice: String
        /// OS-formatted period label ("3 months", "1 year", …). Built upstream in `SessionMessagingKit`
        /// from the plan's raw `(count, unit)` — this module can't import `SessionNetworkingKit`, so the
        /// generic label is passed in pre-rendered rather than recomputed from `duration`.
        let durationString: String
        let durationStringSingular: String

        public init(
            id: String,
            duration: Int,
            discountPercent: Int?,
            titleWithPrice: String,
            subtitleWithPrice: String,
            durationString: String,
            durationStringSingular: String
        ) {
            self.id = id
            self.duration = duration
            self.discountPercent = discountPercent
            self.titleWithPrice = titleWithPrice
            self.subtitleWithPrice = subtitleWithPrice
            self.durationString = durationString
            self.durationStringSingular = durationStringSingular
        }
    }

    final class DataModel: Equatable {
        public let flow: SessionProPlanPaymentFlow
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
    
    enum PaymentStatus {
        case success(expirationTimestampSeconds: UInt64?)
        case pending
        case failed
        case cancelled
        case dev
    }
    
    protocol ViewModelType: ObservableObject {
        var dataModel: DataModel { get set }
        var dateNow: Date { get }
        var errorString: String? { get set }
        var isFromBottomSheet: Bool { get }
        
        @MainActor func purchase(planInfo: SessionProPlanInfo) async throws -> PaymentStatus
        @MainActor func cancelPro(scene: UIWindowScene?) async throws
        @MainActor func requestRefund(scene: UIWindowScene?) async throws
        func openURL(_ url: URL)
    }
}
