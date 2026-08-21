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
                            .localized()
                    )
                    .font(.Headings.H7)
                    .foregroundColor(themeColor: .textPrimary)
                    .accessibility(Accessibility(identifier: SessionProUI.AccessibilityIdentifier.screenChoosePlanNonOriginating))
                    
                    AttributedText(
                        "proAccessSignUp"
                            .put(key: "platform_store", value: originatingPlatform.store)
                            .put(key: "platform_account", value: originatingPlatform.platformAccount)
                            .localizedFormatted(Fonts.Body.baseRegular)
                    )
                    .font(.Body.baseRegular)
                    .foregroundColor(themeColor: .textPrimary)
                    .multilineTextAlignment(.leading)
                    .accessibility(Accessibility(identifier: SessionProUI.AccessibilityIdentifier.screenDescription))
                }
                
                Text(
                    "updateAccessTwo"
                        .localized()
                )
                .font(.Body.baseRegular)
                .foregroundColor(themeColor: .textSecondary)
                
                ApproachCell(
                    info: ApproachCell.Info(
                        title: "onDevice"
                            .put(key: "device_type", value: originatingPlatform.device)
                            .localized(),
                        description: "onDeviceDescription"
                            .put(key: "device_type", value: originatingPlatform.device)
                            .put(key: "platform_account", value: originatingPlatform.platformAccount)
                            .localizedFormatted(Fonts.Body.baseRegular),
                        variant: .device
                    )
                )
                
                ApproachCell(
                    info: ApproachCell.Info(
                        title: "viaStoreWebsite"
                            .put(key: "platform", value: (originatingPlatform == .iOS ? originatingPlatform.platform : originatingPlatform.store))
                            .localized(),
                        description: "viaStoreWebsiteDescription"
                            .put(key: "platform_account", value: originatingPlatform.platformAccount)
                            .put(key: "platform_store", value: (originatingPlatform == .iOS ? originatingPlatform.platform : originatingPlatform.store))
                            .localizedFormatted(Fonts.Body.baseRegular),
                        variant: .website
                    )
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
                Text(
                    "openPlatformStoreWebsite"
                        .put(key: "platform_store", value: (originatingPlatform == .iOS ? originatingPlatform.platform : originatingPlatform.store))
                        .localized()
                )
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
            .accessibility(Accessibility(identifier: SessionProUI.AccessibilityIdentifier.screenAction))
        }
    }
}

