// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import StoreKit
import SessionUIKit
import SessionNetworkingKit
import SessionUtilitiesKit

public extension SessionPro {
    struct Plan: Equatable, Sendable {
        // stringlint:ignore_contents
        private static let productIds: [String] = [
            "com.getsession.org.pro_sub_1_month",
            "com.getsession.org.pro_sub_3_months",
            "com.getsession.org.pro_sub_12_months"
        ]
        
        public let id: String
        public let variant: Network.SessionPro.Plan
        public let durationMonths: Int
        public let price: Decimal
        public let pricePerMonth: Decimal
        public let discountPercent: Int?
        
        public static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.variant  == rhs.variant
        }
        
        // MARK: - Functions
        
        public static func retrievePlans() async throws -> [Plan] {
#if targetEnvironment(simulator)
            return [
                Plan(
                    id: "SimId3",   // stringlint:ignore
                    variant: .twelveMonths,
                    durationMonths: 12,
                    price: 111,
                    pricePerMonth: 9.25,
                    discountPercent: 75
                ),
                Plan(
                    id: "SimId2",   // stringlint:ignore
                    variant: .threeMonths,
                    durationMonths: 3,
                    price: 222,
                    pricePerMonth: 74,
                    discountPercent: 50
                ),
                Plan(
                    id: "SimId1",   // stringlint:ignore
                    variant: .oneMonth,
                    durationMonths: 1,
                    price: 444,
                    pricePerMonth: 444,
                    discountPercent: nil
                )
            ]
#endif
            let products: [Product] = try await Product
                .products(for: productIds)
                .sorted()
                .reversed()
            
            guard let shortestProductPrice: Decimal = products.last?.price else {
                return []
            }
            
            return products.map { product in
                let durationMonths: Int = product.durationMonths
                let priceDiff: Decimal = (shortestProductPrice - product.price)
                let discountDecimal: Decimal = ((priceDiff / shortestProductPrice) * 100)
                let discount: Int = Int(truncating: discountDecimal as NSNumber)
                let variant: Network.SessionPro.Plan = {
                    switch durationMonths {
                        case 1: return .oneMonth
                        case 3: return .threeMonths
                        case 12: return .twelveMonths
                        default:
                            Log.error("Received a subscription product with an invalid duration: \(durationMonths), product id: \(product.id)")
                            return .none
                    }
                }()
                
                return Plan(
                    id: product.id,
                    variant: variant,
                    durationMonths: durationMonths,
                    price: product.price,
                    pricePerMonth: (product.price / Decimal(durationMonths)),
                    discountPercent: (variant != .oneMonth ? discount : nil)
                )
            }
        }
    }
}

// MARK: - Convenience

extension Product: @retroactive Comparable {
    var durationMonths: Int {
        guard let subscription: SubscriptionInfo = subscription else { return -1 }
        
        switch subscription.subscriptionPeriod.unit {
            case .day: return (subscription.subscriptionPeriod.value / 30)
            case .week: return (subscription.subscriptionPeriod.value / 4)
            case .month: return subscription.subscriptionPeriod.value
            case .year: return (subscription.subscriptionPeriod.value * 12)
            @unknown default: return subscription.subscriptionPeriod.value
        }
    }
    
    public static func < (lhs: Product, rhs: Product) -> Bool {
        guard
            let lhsSubscription: SubscriptionInfo = lhs.subscription,
            let rhsSubscription: SubscriptionInfo = rhs.subscription, (
                lhsSubscription.subscriptionPeriod.unit != rhsSubscription.subscriptionPeriod.unit ||
                lhsSubscription.subscriptionPeriod.value != rhsSubscription.subscriptionPeriod.value
            )
        else { return lhs.id < rhs.id }
        
        func approximateDurationDays(_ subscription: SubscriptionInfo) -> Int {
            switch subscription.subscriptionPeriod.unit {
                case .day: return subscription.subscriptionPeriod.value
                case .week: return subscription.subscriptionPeriod.value * 7
                case .month: return subscription.subscriptionPeriod.value * 30
                case .year: return subscription.subscriptionPeriod.value * 365
                @unknown default: return subscription.subscriptionPeriod.value
            }
        }
        
        let lhsApproxDays: Int = approximateDurationDays(lhsSubscription)
        let rhsApproxDays: Int = approximateDurationDays(rhsSubscription)
        
        guard lhsApproxDays != rhsApproxDays else { return lhs.id < rhs.id }
        
        return (lhsApproxDays < rhsApproxDays)
    }
}
