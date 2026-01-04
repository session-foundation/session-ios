// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUIKit
import SessionNetworkingKit

public extension SessionProPaymentScreenContent.SessionProPlanPaymentFlow {
    init(state: SessionPro.State) {
        let latestPlan: SessionPro.Plan? = state.plans.first { $0.variant == state.latestPaymentItem?.plan }
        let expiryDate: Date? = state.accessExpiryTimestampMs.map { Date(timeIntervalSince1970: floor(Double($0) / 1000)) }
        
        switch (state.status, latestPlan, state.refundingStatus) {
            case (.neverBeenPro, _, _), (.active, .none, _):
                self = .purchase(billingAccess: state.buildVariant == .appStore)
                
            case (.active, .some(let plan), .notRefunding):
                self = .update(
                    currentPlan: SessionProPaymentScreenContent.SessionProPlanInfo(plan: plan),
                    expiredOn: (expiryDate ?? Date.distantPast),
                    originatingPlatform: state.originatingPlatform,
                    isAutoRenewing: (state.autoRenewing == true),
                    isNonOriginatingAccount: (state.originatingAccount == .nonOriginatingAccount),
                    billingAccess: (state.buildVariant == .appStore)
                )
                
            case (.expired, _, _):
                self = .renew(
                    originatingPlatform: state.originatingPlatform,
                    billingAccess: (state.buildVariant == .appStore)
                )
                
            case (.active, .some, .refunding):
                self = .refund(
                    originatingPlatform: state.originatingPlatform,
                    isNonOriginatingAccount: (state.originatingAccount == .nonOriginatingAccount),
                    requestedAt: (state.latestPaymentItem?.refundRequestedTimestampMs).map {
                        Date(timeIntervalSince1970: (Double($0) / 1000))
                    }
                )
        }
    }
}

public extension SessionProPaymentScreenContent.SessionProPlanInfo {
    init(plan: SessionPro.Plan) {
        let price: Double = Double(truncating: plan.price as NSNumber)
        let pricePerMonth: Double = Double(truncating: plan.pricePerMonth as NSNumber)
        let formattedPrice: String = price.formatted(format: .currency(decimal: true, withLocalSymbol: true, roundingMode: .floor))
        let formattedPricePerMonth: String = pricePerMonth.formatted(format: .currency(decimal: true, withLocalSymbol: true, roundingMode: .floor))
        
        self = SessionProPaymentScreenContent.SessionProPlanInfo(
            id: plan.id,
            duration: plan.durationMonths,
            totalPrice: price,
            pricePerMonth: pricePerMonth,
            discountPercent: plan.discountPercent,
            titleWithPrice: {
                switch plan.variant {
                    case .none, .oneMonth:
                        return "proPriceOneMonth"
                            .put(key: "monthly_price", value: formattedPricePerMonth)
                            .localized()
                    
                    case .threeMonths:
                        return "proPriceThreeMonths"
                            .put(key: "monthly_price", value: formattedPricePerMonth)
                            .localized()
                    
                    case .twelveMonths:
                        return "proPriceTwelveMonths"
                            .put(key: "monthly_price", value: formattedPricePerMonth)
                            .localized()
                }
            }(),
            subtitleWithPrice: {
                switch plan.variant {
                    case .none, .oneMonth:
                        return "proBilledMonthly"
                            .put(key: "price", value: formattedPrice)
                            .localized()
                    
                    case .threeMonths:
                        return "proBilledQuarterly"
                            .put(key: "price", value: formattedPrice)
                            .localized()
                    
                    case .twelveMonths:
                        return "proBilledAnnually"
                            .put(key: "price", value: formattedPrice)
                            .localized()
                }
            }()
        )
    }
}
