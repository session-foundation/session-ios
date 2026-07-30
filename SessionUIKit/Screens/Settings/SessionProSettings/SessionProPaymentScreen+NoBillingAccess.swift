// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI
import Lucide

// MARK: - No Billing Access Content

struct NoBillingAccessContent: View {
    let isRenewingPro: Bool
    let originatingPlatform: SessionProUI.ClientPlatform
    let openProRoadmapAction: (() -> Void)?
    let openPlatformStoreWebsiteAction: (() -> Void)?
    
    public init(
        isRenewingPro: Bool,
        originatingPlatform: SessionProUI.ClientPlatform,
        openProRoadmapAction: (() -> Void)?,
        openPlatformStoreWebsiteAction: (() -> Void)? = nil
    ) {
        self.isRenewingPro = isRenewingPro
        self.originatingPlatform = originatingPlatform
        self.openProRoadmapAction = openProRoadmapAction
        self.openPlatformStoreWebsiteAction = openPlatformStoreWebsiteAction
    }
    
    /// The `{pro_stores}` bulleted list of purchasable stores (App Store first). `<br/>` is converted to
    /// `\n` at render by LocalizationHelper.
    private var proStoresList: String {
        SNUIKit.proVisiblePlatformStores().map { "<br/>• \($0)" }.joined()   // stringlint:ignore
    }

    var approaches: [ApproachCell.Info] {
        isRenewingPro ?
            [
                ApproachCell.Info(
                    title: "onLinkedDevice".localized(),
                    description: "proRenewDesktopLinked"
                        .put(key: "pro_stores", value: proStoresList)
                        .localizedFormatted(),
                    variant: .link
                ),
                ApproachCell.Info(
                    title: "proNewInstallation".localized(),
                    description: "proNewInstallationDescription"
                        .put(key: "platform_store", value: SNUIKit.proClientPlatformStringProvider(for: .iOS).store)
                        .localizedFormatted(),
                    variant: .device
                ),
                ApproachCell.Info(
                    title: "onPlatformWebsite"
                        .put(key: "platform", value: (originatingPlatform == .iOS ? originatingPlatform.platform : originatingPlatform.store))
                        .localized(),
                    description: "proAccessRenewPlatformWebsite"
                        .put(key: "platform_account", value: originatingPlatform.platformAccount)
                        .put(key: "platform", value: (originatingPlatform == .iOS ? originatingPlatform.platform : originatingPlatform.store))
                        .localizedFormatted(Fonts.Body.baseRegular),
                    variant: .website
                )
            ] :
            [
                ApproachCell.Info(
                    title: "onLinkedDevice".localized(),
                    description: "proUpgradeDesktopLinked"
                        .put(key: "pro_stores", value: proStoresList)
                        .localizedFormatted(),
                    variant: .link
                ),
                ApproachCell.Info(
                    title: "proNewInstallation".localized(),
                    description:  isRenewingPro ?
                        "proNewInstallationDescription"
                            .put(key: "platform_store", value: SNUIKit.proClientPlatformStringProvider(for: .iOS).store)
                            .localizedFormatted() :
                        "proNewInstallationUpgrade"
                            .put(key: "platform_store", value: SNUIKit.proClientPlatformStringProvider(for: .iOS).store)
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
                                .localized() :
                            "proUpgradingTo"
                                .localized()
                    )
                    .font(.Headings.H7)
                    .foregroundColor(themeColor: .textPrimary)
                    
                    AttributedText(
                        isRenewingPro ?
                            "proRenewingNoAccessBilling"
                                .put(key: "pro_stores", value: proStoresList)
                                .put(key: "build_variant", value: SNUIKit.buildVariantStringProvider().ipa)
                                .put(key: "icon", value: Lucide.Icon.squareArrowUpRight)
                                .localizedFormatted(Fonts.Body.baseRegular) :
                            "proUpgradeNoAccessBilling"
                                .put(key: "pro_stores", value: proStoresList)
                                .put(key: "build_variant", value: SNUIKit.buildVariantStringProvider().ipa)
                                .put(key: "icon", value: Lucide.Icon.squareArrowUpRight)
                                .localizedFormatted(Fonts.Body.baseRegular)
                    )
                    .font(.Body.baseRegular)
                    .foregroundColor(themeColor: .textPrimary)
                    .onTapGesture {
                        self.openProRoadmapAction?()
                    }
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
            }
        }
    }
}
