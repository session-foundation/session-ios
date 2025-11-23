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
        case renew(
            originatingPlatform: ClientPlatform
        )
        case refund(
            originatingPlatform: ClientPlatform,
            isNonOriginatingAccount: Bool?,
            requestedAt: Date?
        )
        case cancel(
            originatingPlatform: ClientPlatform
        )
        
        var description: ThemedAttributedString {
            switch self {
                case .purchase:
                    "proChooseAccess"
                        .put(key: "pro", value: Constants.pro)
                        .localizedFormatted(Fonts.Body.baseRegular)
                case .update(let currentPlan, let expiredOn, let isAutoRenewing, let originatingPlatform):
                    switch (originatingPlatform, isAutoRenewing) {
                        case (.Android, true):
                            "proAccessActivatedAutoShort"
                                .put(key: "current_plan_length", value: currentPlan.durationString)
                                .put(key: "date", value: expiredOn.formatted("MMM dd, yyyy"))
                                .put(key: "pro", value: Constants.pro)
                                .localizedFormatted(Fonts.Body.baseRegular)
                        case (.Android, false):
                            "proAccessExpireDate"
                                .put(key: "date", value: expiredOn.formatted("MMM dd, yyyy"))
                                .put(key: "pro", value: Constants.pro)
                                .localizedFormatted(Fonts.Body.baseRegular)
                        case (.iOS, true):
                            "proAccessActivatesAuto"
                                .put(key: "current_plan_length", value: currentPlan.durationString)
                                .put(key: "date", value: expiredOn.formatted("MMM dd, yyyy"))
                                .put(key: "pro", value: Constants.pro)
                                .localizedFormatted(Fonts.Body.baseRegular)
                        case (.iOS, false):
                            "proAccessActivatedNotAuto"
                                .put(key: "date", value: expiredOn.formatted("MMM dd, yyyy"))
                                .put(key: "pro", value: Constants.pro)
                                .localizedFormatted(Fonts.Body.baseRegular)
                    }
                case .renew:
                    "proAccessRenewStart"
                        .put(key: "app_pro", value: Constants.app_pro)
                        .put(key: "pro", value: Constants.pro)
                        .localizedFormatted(baseFont: Fonts.Body.baseRegular)
                case .refund:
                    "proRefundDescription"
                        .localizedFormatted(baseFont: Fonts.Body.baseRegular)
                case .cancel:
                    "proCancelSorry"
                        .put(key: "pro", value: Constants.pro)
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
                case .iOS: return Constants.platform
                case .Android: return Constants.android_platform_name
            }
        }
    }
    
    struct SessionProPlanInfo: Equatable {
        public let duration: Int
        var durationString: String {
            let formatter = DateComponentsFormatter()
            formatter.unitsStyle = .full
            formatter.allowedUnits = [.month]
            let components = DateComponents(month: self.duration)
            return (formatter.string(from: components) ?? "\(self.duration) Months")
        }
        var durationStringSingular: String {
            let formatter = DateComponentsFormatter()
            formatter.unitsStyle = .full
            formatter.allowedUnits = [.month]
            formatter.maximumUnitCount = 1
            let components = DateComponents(month: self.duration)
            return (formatter.string(from: components) ?? "\(self.duration) Month")
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
        func requestRefund(success: (() -> Void)?, failure: (() -> Void)?)
        func openURL(_ url: URL)
    }
}

