// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI
import Lucide

// MARK: - Update Plan Non Originating Platform Content

struct UpdatePlanNonOriginatingPlatformContent: View {
    let currentPlan: SessionProPaymentScreenContent.SessionProPlanInfo
    let currentPlanExpiredOn: Date
    let isAutoRenewing: Bool
    let originatingPlatform: SessionProPaymentScreenContent.ClientPlatform
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

