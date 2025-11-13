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
    let activationType: String
    let purchaseAction: () -> Void
    let openTosPrivacyAction: () -> Void
    
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
                purchaseAction()
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
                            themeColor: (sessionProPlans[currentSelection] == currentPlan) ?
                                .disabled :
                                .sessionButton_primaryFilledBackground
                        )
                )
                .padding(.vertical, Values.smallSpacing)
            }
            .disabled((sessionProPlans[currentSelection] == currentPlan))
            
            AttributedText(
                "noteTosPrivacyPolicy"
                    .put(key: "action_type", value: "proUpdatingAction".localized())
                    .put(key: "app_pro", value: Constants.app_pro)
                    .put(key: "icon", value: Lucide.Icon.squareArrowUpRight)
                    .localizedFormatted(Fonts.Body.smallRegular)
            )
            .font(.Body.smallRegular)
            .foregroundColor(themeColor: .textSecondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, Values.smallSpacing)
            .fixedSize(horizontal: false, vertical: true)
            .onTapGesture { openTosPrivacyAction() }
            
            if currentPlan == nil {
                AttributedText(
                    "proTosDescription"
                        .put(key: "action_type", value: "proUpdatingAction".localized())
                        .put(key: "activation_type", value: activationType)
                        .put(key: "app_pro", value: Constants.app_pro)
                        .put(key: "entity", value: Constants.entity_stf)
                        .put(key: "app_name", value: Constants.app_name)
                        .localizedFormatted(Fonts.Body.smallRegular)
                )
                .font(.Body.smallRegular)
                .foregroundColor(themeColor: .textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Values.smallSpacing)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

