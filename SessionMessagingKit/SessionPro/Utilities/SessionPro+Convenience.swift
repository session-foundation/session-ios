// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUIKit
import SessionNetworkingKit

public extension SessionProPaymentScreenContent.SessionProPlanPaymentFlow {
    init(state: SessionPro.State) {
        let latestPlan: SessionPro.Plan? = state.plans.first { $0.variant == state.latestPaymentItem?.plan }
        let expiryDate: Date? = state.accessExpiryTimestampSeconds.map { Date(timeIntervalSince1970: Double($0)) }
        
        switch (state.status, latestPlan, state.refundingStatus) {
            // Fail closed: an unrecognised backend status is treated exactly like `.never`
            // (offer purchase, grant no Pro) — an unknown value must NEVER unlock Pro.
            case (.never, _, _), (.unknown, _, _):
                self = .purchase(billingAccess: state.buildVariant.billingAccess)
                
            case (.active, .some(let plan), .notRefunding):
                self = .update(
                    currentPlan: SessionProPaymentScreenContent.SessionProPlanInfo(plan: plan),
                    expiredOn: (expiryDate ?? Date.distantPast),
                    originatingPlatform: state.originatingPlatform,
                    isAutoRenewing: (state.autoRenewing == true),
                    isNonOriginatingAccount: (state.originatingAccount == .nonOriginatingAccount),
                    billingAccess: state.buildVariant.billingAccess
                )
                
            case (.expired, _, _):
                self = .renew(
                    originatingPlatform: state.originatingPlatform,
                    billingAccess: state.buildVariant.billingAccess
                )
                
            case (.active, .some, .refunding):
                self = .refund(
                    originatingPlatform: state.originatingPlatform,
                    isNonOriginatingAccount: (state.originatingAccount == .nonOriginatingAccount),
                    requestedAt: (state.latestPaymentItem?.refundRequestedTimestampSeconds).map {
                        Date(timeIntervalSince1970: Double($0))
                    }
                )
            
            // This should only happen when the pro status is mocking
            case (.active, .none, _):
                self = .update(
                    currentPlan: SessionProPaymentScreenContent.SessionProPlanInfo(
                        plan: .init(
                            id: "SimId3",   // stringlint:ignore
                            variant: .init(count: 1, unit: .year),
                            durationMonths: 12,
                            price: 111,
                            pricePerMonth: 9.25,
                            discountPercent: 75,
                            priceFormatStyle: .currency(code: "USD") // stringlint:ignore
                        )
                    ),
                    expiredOn: (expiryDate ?? Date.distantPast),
                    originatingPlatform: state.originatingPlatform,
                    isAutoRenewing: false,
                    isNonOriginatingAccount: (state.originatingAccount == .nonOriginatingAccount),
                    billingAccess: state.buildVariant.billingAccess
                )
        }
    }
}

public extension SessionProPaymentScreenContent.SessionProPlanInfo {
    init(plan: SessionPro.Plan) {
        let formattedPrice: String = plan.price.formatted(plan.priceFormatStyle)
        let formattedPricePerMonth: String = plan.pricePerMonth.formatted(plan.priceFormatStyle.rounded(rule: .down))
        /// The OS-formatted period label ("3 months", "1 year", …), rendered generically from the plan's
        /// raw `(count, unit)` — no per-duration switch, so a new period needs no code change.
        let planLength: String = plan.variant.durationString()

        self = SessionProPaymentScreenContent.SessionProPlanInfo(
            id: plan.id,
            duration: plan.durationMonths,
            discountPercent: plan.discountPercent,
            // Generic price cards (task13): two shared keys replace the old per-duration ones.
            //   proPlanPricePerMonth = "{plan_length} - {monthly_price} / month"
            //   proPlanBilledEvery   = "{price} billed every {plan_length}"
            // Both are new shared Crowdin keys that may not be synced yet; until they are, `.localized()`
            // returns the key verbatim, so gate on that and fall back to the English template.
            titleWithPrice: {
                let key: String = "proPlanPricePerMonth"      // stringlint:ignore
                let localized: String = key
                    .put(key: "plan_length", value: planLength)
                    .put(key: "monthly_price", value: formattedPricePerMonth)
                    .localized()

                return (localized != key ? localized : "\(planLength) - \(formattedPricePerMonth) / month")
            }(),
            subtitleWithPrice: {
                let key: String = "proPlanBilledEvery"        // stringlint:ignore
                let localized: String = key
                    .put(key: "price", value: formattedPrice)
                    .put(key: "plan_length", value: planLength)
                    .localized()

                return (localized != key ? localized : "\(formattedPrice) billed every \(planLength)")
            }(),
            durationString: planLength,
            durationStringSingular: plan.variant.durationString(singular: true)
        )
    }
}
