// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI
import Lucide

// MARK: - Session Pro Plan Purchase Content

struct  SessionProPlanPurchaseContent: View {
    @Binding var currentSelection: Int
    @Binding var isShowingTooltip: Bool
    @Binding var suppressUntil: Date
    
    let title: ThemedAttributedString
    let currentPlan: SessionProPaymentScreenContent.SessionProPlanInfo?
    let sessionProPlans: [SessionProPaymentScreenContent.SessionProPlanInfo]
    let actionButtonTitle: String
    let purchaseAction: () -> Void
    let openTosPrivacyAction: () -> Void
    
    var body: some View {
        VStack(spacing: Values.mediumSmallSpacing) {
            AttributedText(title)
                .font(.Body.baseRegular)
                .foregroundColor(themeColor: .textPrimary)
                .multilineTextAlignment(.center)
                .padding(.vertical, Values.smallSpacing)
            
            ForEach(sessionProPlans.indices, id: \.self) { index in
                PlanCell(
                    currentSelection: $currentSelection,
                    isShowingTooltip: $isShowingTooltip,
                    suppressUntil: $suppressUntil,
                    plan: sessionProPlans[index],
                    index: index,
                    isCurrentPlan: (sessionProPlans[index] == currentPlan)
                )
            }
            
            Button {
                purchaseAction()
            } label: {
                Text(actionButtonTitle)
                    .font(.Body.largeRegular)
                    .foregroundColor(themeColor: .sessionButton_primaryFilledText)
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
                "proTosPrivacy"
                    .put(key: "app_pro", value: Constants.app_pro)
                    .put(key: "icon", value: Lucide.Icon.squareArrowUpRight)
                    .localizedFormatted(Fonts.Body.smallRegular)
            )
            .font(.Body.smallRegular)
            .foregroundColor(themeColor: .textSecondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, Values.smallSpacing)
            .onTapGesture { openTosPrivacyAction() }
        }
    }
}

