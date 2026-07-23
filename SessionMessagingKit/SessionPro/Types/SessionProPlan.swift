// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import StoreKit
import SessionUIKit
import SessionNetworkingKit
import SessionUtilitiesKit

public extension SessionPro {
    struct Plan: Sendable, Equatable, Hashable {
        /// The store catalog: each StoreKit product id paired with its billing period `(count, unit)`.
        /// The productId drives StoreKit (we load `Product`s by id); the `(count, unit)` is used for display
        /// and — critically — for matching the ACTIVE plan libsession reports, so it MUST equal the backend's
        /// value for the SKU. In particular the annual SKU is **`(1, .year)`**, matching backend `1y` — NOT
        /// `(12, .month)`. Pinned explicitly (not derived from StoreKit's `subscriptionPeriod`) so a
        /// store-config quirk can't desync us from the backend, and never canonicalised.
        // stringlint:ignore_contents
        private static let catalog: [(id: String, period: Network.SessionPro.Plan)] = [
            ("com.getsession.org.pro_sub_1_month", .init(count: 1, unit: .month)),
            ("com.getsession.org.pro_sub_3_months", .init(count: 3, unit: .month)),
            ("com.getsession.org.pro_sub_12_months", .init(count: 1, unit: .year))
        ]
        private static var productIds: [String] { catalog.map { $0.id } }
        private static var periodsByProductId: [String: Network.SessionPro.Plan] {
            catalog.reduce(into: [:]) { $0[$1.id] = $1.period }
        }

        public let id: String
        public let variant: Network.SessionPro.Plan
        public let durationMonths: Int
        public let price: Decimal
        public let pricePerMonth: Decimal
        public let discountPercent: Int?
        public let priceFormatStyle: Decimal.FormatStyle.Currency
        
        public static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.variant  == rhs.variant
        }
        
        // MARK: - Functions
        
        public static func retrieveProductsAndPlans() async throws -> (products: [Product], plans: [Plan]) {
#if targetEnvironment(simulator)
            return (
                [],
                [
                    Plan(
                        id: "SimId3",   // stringlint:ignore
                        variant: .init(count: 1, unit: .year),
                        durationMonths: 12,
                        price: 111,
                        pricePerMonth: 9.25,
                        discountPercent: 75,
                        priceFormatStyle: .currency(code: "USD") // stringlint:ignore
                    ),
                    Plan(
                        id: "SimId2",   // stringlint:ignore
                        variant: .init(count: 3, unit: .month),
                        durationMonths: 3,
                        price: 222,
                        pricePerMonth: 74,
                        discountPercent: 50,
                        priceFormatStyle: .currency(code: "USD") // stringlint:ignore
                    ),
                    Plan(
                        id: "SimId1",   // stringlint:ignore
                        variant: .init(count: 1, unit: .month),
                        durationMonths: 1,
                        price: 444,
                        pricePerMonth: 444,
                        discountPercent: nil,
                        priceFormatStyle: .currency(code: "USD") // stringlint:ignore
                    )
                ]
            )
#else
            let periods: [String: Network.SessionPro.Plan] = periodsByProductId
            let products: [Product] = try await Product
                .products(for: productIds)
                .sorted()
                .reversed()

            /// Per-month price math derives its month count from OUR pinned `(count, unit)` (annual = 12
            /// months), NOT from StoreKit's period — so a store-config quirk can't skew the discount.
            func months(_ product: Product) -> Int? { periods[product.id]?.approximateMonths }

            /// Discounts are relative to the SMALLEST available plan (shortest duration ⇒ highest per-month
            /// price) — whatever that happens to be. We don't assume a 1-month SKU exists; the baseline is
            /// just `products.last` after the ascending-duration sort, and it's the one plan with no badge.
            guard
                let baselineProduct: Product = products.last,
                let baselineMonths: Int = months(baselineProduct)
            else { return ([], []) }

            let shortestMonthlyPrice: Decimal = (baselineProduct.price / Decimal(baselineMonths))

            let plans: [Plan] = products.compactMap { product in
                guard let variant: Network.SessionPro.Plan = periods[product.id], let durationMonths: Int = months(product) else {
                    Log.error("Received a subscription product with no catalog entry, product id: \(product.id)")
                    return nil
                }

                let thisMonthlyPrice: Decimal = (product.price / Decimal(durationMonths))
                let monthlySavings: Decimal = (shortestMonthlyPrice - thisMonthlyPrice)
                let discountDecimal: Decimal = ((monthlySavings / shortestMonthlyPrice) * 100)
                let discount: Int = NSDecimalNumber(decimal: discountDecimal)
                    .rounding(accordingToBehavior: NSDecimalNumberHandler(
                        roundingMode: .down,
                        scale: 0,
                        raiseOnExactness: false,
                        raiseOnOverflow: false,
                        raiseOnUnderflow: false,
                        raiseOnDivideByZero: false
                    ))
                    .intValue

                return Plan(
                    id: product.id,
                    variant: variant,
                    durationMonths: durationMonths,
                    price: product.price,
                    pricePerMonth: thisMonthlyPrice,
                    discountPercent: (product.id != baselineProduct.id ? discount : nil),
                    priceFormatStyle: product.priceFormatStyle
                )
            }

            return (products, plans)
#endif
        }
    }
}

// MARK: - Convenience

extension Product: @retroactive Comparable {
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
