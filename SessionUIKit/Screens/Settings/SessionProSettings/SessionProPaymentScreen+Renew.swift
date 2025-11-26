// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI
import Lucide

// MARK: - Renew Plan No Billing Access Content

struct RenewPlanNoBillingAccessContent: View {
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
                        "renewingPro"
                            .put(key: "pro", value: Constants.pro)
                            .localized()
                    )
                    .font(.Headings.H7)
                    .foregroundColor(themeColor: .textPrimary)
                    
                    AttributedText(
                        "proRenewingNoAccessBilling"
                            .put(key: "pro", value: Constants.pro)
                            .put(key: "platform_store", value: SNUIKit.proClientPlatformStringProvider(for: .iOS).store)
                            .put(key: "platform_store_other", value: SNUIKit.proClientPlatformStringProvider(for: .android).store)
                            .put(key: "app_name", value: Constants.app_name)
                            .put(key: "build_variant", value: Constants.IPA)    // TODO: [PRO] source this from libSession?
                            .put(key: "icon", value: Lucide.Icon.squareArrowUpRight)
                            .localizedFormatted(Fonts.Body.baseRegular)
                    )
                    .font(.Body.baseRegular)
                    .foregroundColor(themeColor: .textPrimary)
                }
                
                Text("proOptionsRenewalSubtitle".localized())
                    .font(.Body.baseRegular)
                    .foregroundColor(themeColor: .textSecondary)
                
                ApproachCell(
                    title: "onLinkedDevice".localized(),
                    description: "proRenewDesktopLinked"
                        .put(key: "app_name", value: Constants.app_name)
                        .put(key: "app_pro", value: Constants.app_pro)
                        .put(key: "platform_store", value: SNUIKit.proClientPlatformStringProvider(for: .iOS).store)
                        .put(key: "platform_store_other", value: SNUIKit.proClientPlatformStringProvider(for: .android).store)
                        .put(key: "pro", value: Constants.pro)
                        .localizedFormatted(),
                    variant: .link
                )
                
                ApproachCell(
                    title: "proNewInstallation".localized(),
                    description: "proNewInstallationDescription"
                        .put(key: "app_name", value: Constants.app_name)
                        .put(key: "platform_store", value: SNUIKit.proClientPlatformStringProvider(for: .iOS).store)
                        .put(key: "app_pro", value: Constants.app_pro)
                        .put(key: "pro", value: Constants.pro)
                        .localizedFormatted(),
                    variant: .device
                )
                
                ApproachCell(
                    title: "onPlatformWebsite"
                        .put(key: "platform", value: originatingPlatform.platform)
                        .localized(),
                    description: "proAccessRenewPlatformWebsite"
                        .put(key: "platform_account", value: originatingPlatform.platformAccount)
                        .put(key: "platform", value: originatingPlatform.platform)
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
