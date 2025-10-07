// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI
import Lucide

// MARK: - Cancel Plan Originating Platform Content

struct CancelPlanOriginatingPlatformContent: View {
    let cancelPlanAction: () -> Void
    
    var body: some View {
        VStack(spacing: Values.mediumSmallSpacing) {
            // TODO: Localised
            Text("We’re sorry to see you cancel Pro. Here's what you need to know before canceling your Session Pro plan.")
                .font(.Body.baseRegular)
                .foregroundColor(themeColor: .textPrimary)
                .multilineTextAlignment(.center)
                .padding(.vertical, Values.smallSpacing)
            
            VStack(
                alignment: .leading,
                spacing: 0
            ) {
                Text("proCancellation".localized())
                    .font(.Headings.H7)
                    .foregroundColor(themeColor: .textPrimary)
                
                AttributedText(
                    "proCancellationDescription"
                        .put(key: "app_pro", value: Constants.app_pro)
                        .put(key: "pro", value: Constants.pro)
                        .put(key: "platform", value: Constants.platform)
                        .localizedFormatted(Fonts.Body.baseRegular)
                )
                .font(.Body.baseRegular)
                .foregroundColor(themeColor: .textPrimary)
                .padding(.vertical, Values.smallSpacing)
            }
            .padding(Values.mediumSpacing)
            .background(
                RoundedRectangle(cornerRadius: 11)
                    .fill(themeColor: .backgroundSecondary)
            )
            
            Button {
                cancelPlanAction()
            } label: {
                Text("cancelPlan".localized())
                    .font(.Body.largeRegular)
                    .foregroundColor(themeColor: .sessionButton_primaryFilledText)
                    .framing(
                        maxWidth: .infinity,
                        height: 50,
                        alignment: .center
                    )
                    .background(
                        RoundedRectangle(cornerRadius: 7)
                            .fill(themeColor: .danger)
                    )
                    .padding(.vertical, Values.smallSpacing)
            }
        }
    }
}

// MARK: - Cancel Plan Non Originating Platform Content

struct CancelPlanNonOriginatingPlatformContent: View {
    let originatingPlatform: SessionProPaymentScreenContent.ClientPlatform
    let openPlatformStoreWebsiteAction: () -> Void

    var body: some View {
        VStack(spacing: Values.mediumSpacing) {
            // TODO: Localised
            Text("We’re sorry to see you cancel Pro. Here's what you need to know before canceling your Session Pro plan.")
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
                    Text("proCancellation".localized())
                        .font(.Headings.H7)
                        .foregroundColor(themeColor: .textPrimary)
                    
                    AttributedText(
                        "proCancellationDescription"
                            .put(key: "app_pro", value: Constants.app_pro)
                            .put(key: "pro", value: Constants.pro)
                            .put(key: "platform_account", value: originatingPlatform.account)
                            .localizedFormatted(Fonts.Body.baseRegular)
                    )
                    .font(.Body.baseRegular)
                    .foregroundColor(themeColor: .textPrimary)
                }
                
                Text("proCancellationOptions".localized())
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
                                .put(key: "platform", value: originatingPlatform.name)
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
                            .fill(themeColor: .danger)
                    )
                    .padding(.vertical, Values.smallSpacing)
            }
        }
    }
}
