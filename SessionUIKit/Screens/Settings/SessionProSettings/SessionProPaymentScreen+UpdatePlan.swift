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
                    .put(key: "icon", value: "<icon>\(Lucide.Icon.squareArrowUpRight)</icon>")
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

// MARK: - Non Originating Platform Content

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
                Text("updatePlan".localized())
                    .font(.Headings.H7)
                    .foregroundColor(themeColor: .textPrimary)
                
                Text(
                    "proPlanSignUp"
                        .put(key: "app_pro", value: Constants.app_pro)
                        .put(key: "platform_store", value: originatingPlatform.store)
                        .put(key: "platform_account", value: originatingPlatform.account)
                        .localized()
                )
                .font(.Body.baseRegular)
                .foregroundColor(themeColor: .textPrimary)
                .multilineTextAlignment(.leading)
                
                Text("updatePlanTwo".localized())
                    .font(.Body.baseRegular)
                    .foregroundColor(themeColor: .textSecondary)
                
                HStack(
                    alignment: .top,
                    spacing: Values.mediumSpacing
                ) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(themeColor: .value(.primary, alpha: 0.1))
                        
                        AttributedText(Lucide.Icon.smartphone.attributedString(size: 24))
                            .foregroundColor(themeColor: .primary)
                    }
                    .frame(width: 34, height: 34)
                    
                    VStack(
                        alignment: .leading,
                        spacing: Values.verySmallSpacing
                    ) {
                        Text(
                            "onDevice"
                                .put(key: "device_type", value: originatingPlatform.deviceType)
                                .localized()
                        )
                        .font(.Body.baseBold)
                        .foregroundColor(themeColor: .textPrimary)
                        
                        Text(
                            "onDeviceDescription"
                                .put(key: "app_name", value: Constants.app_name)
                                .put(key: "device_type", value: originatingPlatform.deviceType)
                                .put(key: "platform_account", value: originatingPlatform.account)
                                .put(key: "app_pro", value: Constants.app_pro)
                                .localized()
                        )
                        .font(.Body.baseRegular)
                        .foregroundColor(themeColor: .textPrimary)
                        .multilineTextAlignment(.leading)
                    }
                }
                .padding(Values.mediumSpacing)
                .background(
                    RoundedRectangle(cornerRadius: 11)
                        .fill(themeColor: .inputButton_background)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 11)
                        .stroke(themeColor: .borderSeparator)
                )
                
                HStack(
                    alignment: .top,
                    spacing: Values.mediumSpacing
                ) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(themeColor: .value(.primary, alpha: 0.1))
                        
                        AttributedText(Lucide.Icon.globe.attributedString(size: 20))
                            .foregroundColor(themeColor: .primary)
                    }
                    .frame(width: 34, height: 34)
                    
                    VStack(
                        alignment: .leading,
                        spacing: Values.verySmallSpacing
                    ) {
                        Text(
                            "viaStoreWebsite"
                                .put(key: "platform_store", value: originatingPlatform.store)
                                .localized()
                        )
                        .font(.Body.baseBold)
                        .foregroundColor(themeColor: .textPrimary)
                        
                        AttributedText(
                            "viaStoreWebsiteDescription"
                                .put(key: "platform_account", value: originatingPlatform.account)
                                .put(key: "platform_store", value: originatingPlatform.store)
                                .localizedFormatted(Fonts.Body.baseRegular)
                        )
                        .font(.Body.baseRegular)
                        .multilineTextAlignment(.leading)
                    }
                }
                .padding(Values.mediumSpacing)
                .background(
                    RoundedRectangle(cornerRadius: 11)
                        .fill(themeColor: .inputButton_background)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 11)
                        .stroke(themeColor: .borderSeparator)
                )
            }
            .padding(Values.mediumSpacing)
            .background(
                RoundedRectangle(cornerRadius: 11)
                    .fill(themeColor: .backgroundSecondary)
            )
            
            Button {
                openPlatformStoreWebsiteAction()
            } label: {
                Text("openStoreWebsite".put(key: "platform_store", value: originatingPlatform.store).localized())
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

// MARK: - Plan Cells

struct PlanCell: View {
    static let radioBorderSize: CGFloat = 22
    static let radioSelectionSize: CGFloat = 17
    
    @Binding var currentSelection: Int
    @Binding var isShowingTooltip: Bool
    @Binding var suppressUntil: Date
    
    let tooltipViewId: String = "SessionProPaymentScreenToolTip" // stringlint:ignore
    
    var isSelected: Bool { currentSelection == index }
    let plan: SessionProPaymentScreenContent.SessionProPlanInfo
    let index: Int
    let isCurrentPlan: Bool
    
    var body: some View {
        ZStack(alignment: .topLeading) {
            HStack {
                VStack(
                    alignment: .leading,
                    spacing: 0
                ) {
                    Text(plan.titleWithPrice)
                        .font(.Headings.H7)
                        .foregroundColor(themeColor: .textPrimary)
                        .multilineTextAlignment(.leading)
                        .frame(
                            maxWidth: .infinity,
                            alignment: .leading
                        )
                    
                    Text(plan.subtitleWithPrice)
                        .font(.Body.smallRegular)
                        .foregroundColor(themeColor: .textSecondary)
                        .frame(
                            maxWidth: .infinity,
                            alignment: .leading
                        )
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, Values.verySmallSpacing)
                
                Spacer()
                
                ZStack(alignment: .center) {
                    Circle()
                        .stroke(themeColor: currentSelection == index ? .sessionButton_primaryFilledBackground : .borderSeparator)
                        .frame(
                            width: Self.radioBorderSize,
                            height: Self.radioBorderSize
                        )
                    
                    if currentSelection == index {
                        Circle()
                            .fill(themeColor: .sessionButton_primaryFilledBackground)
                            .frame(
                                width: Self.radioSelectionSize,
                                height: Self.radioSelectionSize
                            )
                    }
                }
            }
            .padding(Values.mediumSpacing)
            .frame(
                maxWidth: .infinity
            )
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(themeColor: .backgroundSecondary)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(themeColor: isSelected ? .sessionButton_primaryFilledBackground : .borderSeparator)
            )
            .padding(.top, Values.smallSpacing)
            .contentShape(Rectangle())
            .onTapGesture {
                self.currentSelection = index
            }
            
            HStack (spacing: Values.smallSpacing) {
                if isCurrentPlan {
                    Text("currentPlan".localized())
                        .font(.Body.smallBold)
                        .foregroundColor(themeColor: .sessionButton_primaryFilledText)
                        .padding(.vertical, 2)
                        .padding(.horizontal, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(themeColor: .sessionButton_primaryFilledBackground)
                        )
                }
                
                if let discountPercent = plan.discountPercent {
                    HStack(spacing: Values.verySmallSpacing) {
                        Text(
                            "proPercentOff"
                                .put(key: "percent", value: discountPercent)
                                .localized()
                        )
                        .font(.Body.smallBold)
                        .foregroundColor(themeColor: .sessionButton_primaryFilledText)
                        
                        
                        if isCurrentPlan {
                            Image(systemName: "questionmark.circle")
                                .font(.Body.smallBold)
                                .foregroundColor(themeColor: .sessionButton_primaryFilledText)
                                .anchorView(viewId: tooltipViewId)
                        }
                    }
                    .padding(.vertical, 2)
                    .padding(.horizontal, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(themeColor: .sessionButton_primaryFilledBackground)
                    )
                    .onTapGesture {
                        guard isCurrentPlan else { return }
                        guard Date() >= suppressUntil else { return }
                        withAnimation {
                            isShowingTooltip.toggle()
                        }
                    }
                }
            }
            .padding(.leading, Values.mediumSpacing)
        }
    }
}

