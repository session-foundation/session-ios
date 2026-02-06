// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI
import Lucide

// MARK: - Session Pro Plan Purchase Content

struct  SessionProPlanPurchaseContent: View {
    @Binding var currentSelection: Int
    @Binding var isShowingTooltip: Bool
    @Binding var suppressUntil: Date
    @Binding var isPendingPurchase: Bool
    
    let currentPlan: SessionProPaymentScreenContent.SessionProPlanInfo?
    let sessionProPlans: [SessionProPaymentScreenContent.SessionProPlanInfo]
    let actionButtonTitle: String
    let actionType: String
    let activationType: String
    let purchaseAction: () -> Void
    let openTosPrivacyAction: () -> Void
    
    var isCurrentPlanSelected: Bool {
        guard currentSelection < sessionProPlans.count else { return false }
        
        return (sessionProPlans[currentSelection] == currentPlan)
    }
    // TODO: [PRO] Do we need a loading state in case the plans aren't loaded yet?
    var body: some View {
        VStack(spacing: Values.mediumSmallSpacing) {
            ForEach(sessionProPlans.indices, id: \.self) { index in
                PlanCell(
                    currentSelection: $currentSelection,
                    isShowingTooltip: $isShowingTooltip,
                    suppressUntil: $suppressUntil,
                    plan: sessionProPlans[index],
                    index: index,
                    isCurrentPlan: (sessionProPlans[index] == currentPlan)
                )
                .disabled(isPendingPurchase)
            }
            
            Button {
                if !isPendingPurchase {
                    purchaseAction()
                }
            } label: {
                ZStack {
                    if isPendingPurchase {
                        ProgressView()
                            .tint(themeColor: .sessionButton_primaryFilledText)
                    } else {
                        Text(actionButtonTitle)
                            .font(.Body.largeRegular)
                            .foregroundColor(themeColor: .sessionButton_primaryFilledText)
                    }
                }
                .framing(
                    maxWidth: .infinity,
                    height: 50,
                    alignment: .center
                )
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(
                            themeColor: (isCurrentPlanSelected ?
                                .disabled :
                                .sessionButton_primaryFilledBackground
                             )
                        )
                )
                .padding(.vertical, Values.smallSpacing)
            }
            .disabled(isCurrentPlanSelected)
            
            AttributedText(
                "noteTosPrivacyPolicy"
                    .put(key: "action_type", value: actionType)
                    .put(key: "app_pro", value: Constants.app_pro)
                    .put(key: "icon", value: Lucide.Icon.squareArrowUpRight)
                    .localizedFormatted(Fonts.Body.smallRegular)
            )
            .font(.Body.smallRegular)
            .foregroundColor(themeColor: .textPrimary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, Values.smallSpacing)
            .fixedSize(horizontal: false, vertical: true)
            .onTapGesture { openTosPrivacyAction() }

            if currentPlan == nil {
                AttributedText(
                    "proTosDescription"
                        .put(key: "action_type", value: actionType)
                        .put(key: "activation_type", value: activationType)
                        .put(key: "app_pro", value: Constants.app_pro)
                        .put(key: "entity", value: Constants.entity_rangeproof)
                        .put(key: "app_name", value: Constants.app_name)
                        .localizedFormatted(Fonts.Body.smallRegular)
                )
                .font(.Body.smallRegular)
                .foregroundColor(themeColor: .textPrimary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Values.smallSpacing)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
