// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI
import Lucide

// MARK: - Update Plan Non Originating Platform Content

struct UpdatePlanNonOriginatingPlatformContent: View {
    let currentPlan: SessionProPaymentScreenContent.SessionProPlanInfo
    let currentPlanExpiredOn: Date
    let isAutoRenewing: Bool
    let originatingPlatform: SessionProUI.ClientPlatform
    let openPlatformStoreWebsiteAction: () -> Void

    var body: some View {
        VStack(spacing: Values.mediumSpacing) {
            VStack(
                alignment: .leading,
                spacing: Values.mediumSpacing
            ) {
                VStack(
                    alignment: .leading,
                    spacing: Values.verySmallSpacing
                ) {
                    Text(
                        "updateAccess"
                            .put(key: "pro", value: Constants.pro)
                            .localized()
                    )
                    .font(.Headings.H7)
                    .foregroundColor(themeColor: .textPrimary)
                    
                    AttributedText(
                        "proAccessSignUp"
                            .put(key: "app_pro", value: Constants.app_pro)
                            .put(key: "platform_store", value: originatingPlatform.store)
                            .put(key: "platform_account", value: originatingPlatform.platformAccount)
                            .put(key: "pro", value: Constants.pro)
                            .localizedFormatted(Fonts.Body.baseRegular)
                    )
                    .font(.Body.baseRegular)
                    .foregroundColor(themeColor: .textPrimary)
                    .multilineTextAlignment(.leading)
                }
                
                Text(
                    "updateAccessTwo"
                        .put(key: "pro", value: Constants.pro)
                        .localized()
                )
                .font(.Body.baseRegular)
                .foregroundColor(themeColor: .textSecondary)
                
                ApproachCell(
                    title: "onDevice"
                        .put(key: "device_type", value: originatingPlatform.device)
                        .localized(),
                    description: "onDeviceDescription"
                        .put(key: "app_name", value: Constants.app_name)
                        .put(key: "device_type", value: originatingPlatform.device)
                        .put(key: "platform_account", value: originatingPlatform.platformAccount)
                        .put(key: "app_pro", value: Constants.app_pro)
                        .put(key: "pro", value: Constants.pro)
                        .localizedFormatted(Fonts.Body.baseRegular),
                    variant: .device
                )
                
                ApproachCell(
                    title: "viaStoreWebsite"
                        .put(key: "platform", value: originatingPlatform.platform)
                        .localized(),
                    description: "viaStoreWebsiteDescription"
                        .put(key: "platform_account", value: originatingPlatform.platformAccount)
                        .put(key: "platform_store", value: originatingPlatform.store)
                        .put(key: "pro", value: Constants.pro)
                        .localizedFormatted(Fonts.Body.baseRegular),
                    variant: .website
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
                Text("openPlatformStoreWebsite".put(key: "platform_store", value: originatingPlatform.store).localized())
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

