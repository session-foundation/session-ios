// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import SessionUIKit
import SessionUtilitiesKit
import Combine

public extension SessionProPlanState {
    func toPaymentFlow() -> SessionProPaymentScreenContent.SessionProPlanPaymentFlow {
        switch self {
            case .none:
                return .purchase
            case .active(let currentPlan, let expiredOn, let isAutoRenewing, let originatingPlatform):
                return .update(
                    currentPlan: currentPlan.info(),
                    expiredOn: expiredOn,
                    isAutoRenewing: isAutoRenewing,
                    originatingPlatform: {
                        switch originatingPlatform {
                            case .iOS: return .iOS
                            case .Android: return .Android
                        }
                    }()
                )
            case .expired(let originatingPlatform):
                return .renew(
                    originatingPlatform: {
                        switch originatingPlatform {
                            case .iOS: return .iOS
                            case .Android: return .Android
                        }
                    }()
                )
            case .refunding(let originatingPlatform, let requestedAt):
                return .refund(
                    originatingPlatform: {
                        switch originatingPlatform {
                            case .iOS: return .iOS
                            case .Android: return .Android
                        }
                    }(),
                    requestedAt: requestedAt
                )
        }
    }
}

public extension SessionProPlan {
    func info() -> SessionProPaymentScreenContent.SessionProPlanInfo {
        let price: Double = self.variant.price
        let pricePerMonth: Double = (self.variant.price / Double(self.variant.duration))
        return .init(
            duration: self.variant.duration,
            totalPrice: price,
            pricePerMonth: pricePerMonth,
            discountPercent: self.variant.discountPercent,
            titleWithPrice: {
                switch self.variant {
                    case .oneMonth:
                        return "proPriceOneMonth"
                            .put(key: "monthly_price", value: pricePerMonth.formatted(format: .currency(decimal: true, withLocalSymbol: true)))
                            .localized()
                    case .threeMonths:
                        return "proPriceThreeMonths"
                            .put(key: "monthly_price", value: pricePerMonth.formatted(format: .currency(decimal: true, withLocalSymbol: true)))
                            .localized()
                    case .twelveMonths:
                        return "proPriceTwelveMonths"
                            .put(key: "monthly_price", value: pricePerMonth.formatted(format: .currency(decimal: true, withLocalSymbol: true)))
                            .localized()
                }
            }(),
            subtitleWithPrice: {
                switch self.variant {
                    case .oneMonth:
                        return "proBilledMonthly"
                            .put(key: "price", value: price.formatted(format: .currency(decimal: true, withLocalSymbol: true)))
                            .localized()
                    case .threeMonths:
                        return "proBilledQuarterly"
                            .put(key: "price", value: price.formatted(format: .currency(decimal: true, withLocalSymbol: true)))
                            .localized()
                    case .twelveMonths:
                        return "proBilledAnnually"
                            .put(key: "price", value: price.formatted(format: .currency(decimal: true, withLocalSymbol: true)))
                            .localized()
                }
            }()
        )
    }
    
    static func from(_ info: SessionProPaymentScreenContent.SessionProPlanInfo) -> SessionProPlan {
        let variant: SessionProPlan.Variant = {
            switch info.duration {
                case 1: return .oneMonth
                case 3: return .threeMonths
                case 12: return .twelveMonths
                default: fatalError("Unhandled SessionProPlan.Variant.Duration case")
            }
        }()
        
        return SessionProPlan(variant: variant)
    }
}
