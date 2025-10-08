// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI
import Lucide

// MARK: - Update Plan Originating Platform Content

struct UpdatePlanOriginatingPlatformContent: View {
    @Binding var currentSelection: Int
    @Binding var isShowingTooltip: Bool
    @Binding var suppressUntil: Date
    
    let currentPlan: SessionProPaymentScreenContent.SessionProPlanInfo
    let currentPlanExpiredOn: Date
    let isAutoRenewing: Bool
    let sessionProPlans: [SessionProPaymentScreenContent.SessionProPlanInfo]
    let updatePlanAction: () -> Void
    let openTosPrivacyAction: () -> Void
    
    var body: some View {
        VStack(spacing: Values.mediumSmallSpacing) {
            AttributedText(
                isAutoRenewing ?
                    "proPlanActivatedAuto"
                        .put(key: "app_pro", value: Constants.app_pro)
                        .put(key: "current_plan", value: currentPlan.durationString)
                        .put(key: "date", value: currentPlanExpiredOn.formatted("MMM dd, yyyy"))
                        .put(key: "pro", value: Constants.pro)
                        .localizedFormatted(Fonts.Body.baseRegular) :
                    "proPlanActivatedNotAuto"
                        .put(key: "app_pro", value: Constants.app_pro)
                        .put(key: "date", value: currentPlanExpiredOn.formatted("MMM dd, yyyy"))
                        .put(key: "pro", value: Constants.pro)
                        .localizedFormatted(Fonts.Body.baseRegular)
            )
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
                updatePlanAction()
            } label: {
                Text("updatePlan".localized())
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

// MARK: - Update Plan Non Originating Platform Content

struct UpdatePlanNonOriginatingPlatformContent: View {
    let currentPlan: SessionProPaymentScreenContent.SessionProPlanInfo
    let currentPlanExpiredOn: Date
    let isAutoRenewing: Bool
    let originatingPlatform: SessionProPaymentScreenContent.ClientPlatform
    let openPlatformStoreWebsiteAction: () -> Void

    var body: some View {
        VStack(spacing: Values.mediumSpacing) {
            AttributedText(
                isAutoRenewing ?
                    "proPlanActivatedAutoShort"
                        .put(key: "app_pro", value: Constants.app_pro)
                        .put(key: "current_plan", value: currentPlan.durationString)
                        .put(key: "date", value: currentPlanExpiredOn.formatted("MMM dd, yyyy"))
                        .localizedFormatted(Fonts.Body.baseRegular) :
                    "proPlanExpireDate"
                        .put(key: "app_pro", value: Constants.app_pro)
                        .put(key: "date", value: currentPlanExpiredOn.formatted("MMM dd, yyyy"))
                        .localizedFormatted(Fonts.Body.baseRegular)
            )
            .font(.Body.baseRegular)
            .foregroundColor(themeColor: .textPrimary)
            .multilineTextAlignment(.center)
            .padding(.vertical, Values.smallSpacing)
            
            VStack(
                alignment: .leading,
                spacing: Values.mediumSpacing
            ) {
                VStack(
                    alignment: .leading,
                    spacing: Values.verySmallSpacing
                ) {
                    Text("updatePlan".localized())
                        .font(.Headings.H7)
                        .foregroundColor(themeColor: .textPrimary)
                    
                    AttributedText(
                        "proPlanSignUp"
                            .put(key: "app_pro", value: Constants.app_pro)
                            .put(key: "platform_store", value: originatingPlatform.store)
                            .put(key: "platform_account", value: originatingPlatform.account)
                            .localizedFormatted(Fonts.Body.baseRegular)
                    )
                    .font(.Body.baseRegular)
                    .foregroundColor(themeColor: .textPrimary)
                    .multilineTextAlignment(.leading)
                }
                
                Text("updatePlanTwo".localized())
                    .font(.Body.baseRegular)
                    .foregroundColor(themeColor: .textSecondary)
                
                ApproachCell(
                    title: "onDevice"
                        .put(key: "device_type", value: originatingPlatform.deviceType)
                        .localized(),
                    description: "onDeviceDescription"
                        .put(key: "app_name", value: Constants.app_name)
                        .put(key: "device_type", value: originatingPlatform.deviceType)
                        .put(key: "platform_account", value: originatingPlatform.account)
                        .put(key: "app_pro", value: Constants.app_pro)
                        .localizedFormatted(),
                    variant: .device
                )
                
                ApproachCell(
                    title: "viaStoreWebsite"
                        .put(key: "platform", value: originatingPlatform.name)
                        .localized(),
                    description: "viaStoreWebsiteDescription"
                        .put(key: "platform_account", value: originatingPlatform.account)
                        .put(key: "platform_store", value: originatingPlatform.store)
                        .localizedFormatted(Fonts.Body.baseRegular),
                    variant: .website
                )
            }

            Button {
                openPlatformStoreWebsiteAction()
            } label: {
                Text("viaStoreWebsite".put(key: "platform", value: originatingPlatform.name).localized())
                    .font(.Body.largeRegular)
                    .foregroundColor(themeColor: .sessionButton_primaryFilledText)
                    .framing(
                        maxWidth: .infinity,
                        height: 50,
                        alignment: .center
                    )
                    .background(
                        RoundedRectangle(cornerRadius: 7)
                            .fill(themeColor: .sessionButton_primaryFilledBackground)
                    )
                    .padding(.vertical, Values.smallSpacing)
            }
        }
    }
}

