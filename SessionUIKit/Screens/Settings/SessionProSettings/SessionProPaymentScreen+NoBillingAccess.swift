// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI
import Lucide

// MARK: - No Billing Access Content

struct NoBillingAccessContent: View {
    let isRenewingPro: Bool
    let originatingPlatform: SessionProPaymentScreenContent.ClientPlatform
    let openPlatformStoreWebsiteAction: (() -> Void)?
    
    public init(
        isRenewingPro: Bool,
        originatingPlatform: SessionProPaymentScreenContent.ClientPlatform,
        openPlatformStoreWebsiteAction: (() -> Void)? = nil
    ) {
        self.isRenewingPro = isRenewingPro
        self.originatingPlatform = originatingPlatform
        self.openPlatformStoreWebsiteAction = openPlatformStoreWebsiteAction
    }
    
    var approaches: [ApproachCell.Info] {
        isRenewingPro ?
            [
                ApproachCell.Info(
                    title: "onLinkedDevice".localized(),
                    description: "proRenewDesktopLinked"
                        .put(key: "app_name", value: Constants.app_name)
                        .put(key: "app_pro", value: Constants.app_pro)
                        .put(key: "platform_store", value: Constants.platform_store)
                        .put(key: "platform_store_other", value: Constants.android_platform_store)
                        .put(key: "pro", value: Constants.pro)
                        .localizedFormatted(),
                    variant: .link
                ),
                ApproachCell.Info(
                    title: "proNewInstallation".localized(),
                    description: "proNewInstallationDescription"
                        .put(key: "app_name", value: Constants.app_name)
                        .put(key: "platform_store", value: Constants.platform_store)
                        .put(key: "app_pro", value: Constants.app_pro)
                        .put(key: "pro", value: Constants.pro)
                        .localizedFormatted(),
                    variant: .device
                ),
                ApproachCell.Info(
                    title: "onPlatformWebsite"
                        .put(key: "platform", value: originatingPlatform.store)
                        .localized(),
                    description: "proAccessRenewPlatformWebsite"
                        .put(key: "platform_account", value: originatingPlatform.account)
                        .put(key: "platform", value: originatingPlatform.name)
                        .put(key: "pro", value: Constants.pro)
                        .localizedFormatted(Fonts.Body.baseRegular),
                    variant: .website
                )
            ] :
            [
                ApproachCell.Info(
                    title: "onLinkedDevice".localized(),
                    description: "proUpgradeDesktopLinked"
                        .put(key: "app_name", value: Constants.app_name)
                        .put(key: "app_pro", value: Constants.app_pro)
                        .put(key: "platform_store", value: Constants.platform_store)
                        .put(key: "platform_store_other", value: Constants.android_platform_store)
                        .put(key: "pro", value: Constants.pro)
                        .localizedFormatted(),
                    variant: .link
                ),
                ApproachCell.Info(
                    title: "proNewInstallation".localized(),
                    description: "proNewInstallationDescription"
                        .put(key: "app_name", value: Constants.app_name)
                        .put(key: "platform_store", value: Constants.platform_store)
                        .put(key: "app_pro", value: Constants.app_pro)
                        .put(key: "pro", value: Constants.pro)
                        .localizedFormatted(),
                    variant: .device
                )
            ]
    }

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
                        isRenewingPro ?
                            "renewingPro"
                                .put(key: "pro", value: Constants.pro)
                                .localized() :
                            "proUpgradingTo"
                                .put(key: "pro", value: Constants.pro)
                                .localized()
                    )
                    .font(.Headings.H7)
                    .foregroundColor(themeColor: .textPrimary)
                    
                    AttributedText(
                        isRenewingPro ?
                            "proRenewingNoAccessBilling"
                                .put(key: "pro", value: Constants.pro)
                                .put(key: "platform_store", value: Constants.platform_store)
                                .put(key: "platform_store_other", value: Constants.android_platform_store)
                                .put(key: "app_name", value: Constants.app_name)
                                .put(key: "build_variant", value: Constants.IPA)
                                .put(key: "icon", value: Lucide.Icon.squareArrowUpRight)
                                .localizedFormatted(Fonts.Body.baseRegular) :
                            "proUpgradeNoAccessBilling"
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
                
                Text(isRenewingPro ? "proOptionsRenewalSubtitle".localized() : "proUpgradeOptionsTwo".localized())
                    .font(.Body.baseRegular)
                    .foregroundColor(themeColor: .textSecondary)
                
                ForEach(approaches.indices, id: \.self) { index in
                    ApproachCell(info: approaches[index])
                }
            }
            .padding(Values.mediumSpacing)
            .background(
                RoundedRectangle(cornerRadius: 11)
                    .fill(themeColor: .backgroundSecondary)
            )
            
            if isRenewingPro {
                Button {
                    openPlatformStoreWebsiteAction?()
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
}
