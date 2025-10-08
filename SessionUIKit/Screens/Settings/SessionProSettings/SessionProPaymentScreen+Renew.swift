// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI
import Lucide

// MARK: - Renew Plan No Billing Access Content

struct RenewPlanNoBillingAccessContent: View {
    let openPlatformStoreWebsiteAction: () -> Void

    var body: some View {
        VStack(spacing: Values.mediumSpacing) {
            Text(
                "proPlanRenewStart"
                    .put(key: "app_pro", value: Constants.app_pro)
                    .localized()
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
                    Text(
                        "renewingPro"
                            .put(key: "pro", value: Constants.pro)
                            .localized()
                    )
                    .font(.Headings.H7)
                    .foregroundColor(themeColor: .textPrimary)
                    
                    AttributedText(
                        "proRenewingNoAccessBilling"
                            .put(key: "app_pro", value: Constants.app_pro)
                            .put(key: "pro", value: Constants.pro)
                            .put(key: "platform_store", value: Constants.platform_store)
                            .put(key: "platform_store_other", value: Constants.android_platform_store)
                            .put(key: "app_name", value: Constants.app_name)
                            .put(key: "build_variant", value: Constants.IPA)
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
                    description: "proPlanRenewDesktopLinked"
                        .put(key: "app_name", value: Constants.app_name)
                        .put(key: "app_pro", value: Constants.app_pro)
                        .put(key: "platform_store", value: Constants.platform_store)
                        .put(key: "platform_store_other", value: Constants.android_platform_store)
                        .localizedFormatted(),
                    variant: .link
                )
                
                ApproachCell(
                    title: "proNewInstallation".localized(),
                    description: "proNewInstallationDescription"
                        .put(key: "app_name", value: Constants.app_name)
                        .put(key: "platform_store", value: Constants.platform_store)
                        .put(key: "app_pro", value: Constants.app_pro)
                        .localizedFormatted(),
                    variant: .device
                )
                
                ApproachCell(
                    title: "viaStoreWebsite"
                        .put(key: "platform", value: Constants.platform)
                        .localized(),
                    description: "viaStoreWebsiteDescription"
                        .put(key: "platform_account", value: Constants.platform_name)
                        .put(key: "platform_store", value: Constants.platform_store)
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
                Text("viaStoreWebsite".put(key: "platform", value: Constants.platform).localized())
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
