// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI
import Lucide

// MARK: - Cancel Plan Originating Platform Content

struct CancelPlanOriginatingPlatformContent: View {
    let cancelPlanAction: @MainActor () -> Void
    
    var body: some View {
        VStack(spacing: Values.mediumSmallSpacing) {
            VStack(
                alignment: .leading,
                spacing: 0
            ) {
                Text("proCancellation".localized())
                    .font(.Headings.H7)
                    .foregroundColor(themeColor: .textPrimary)
                
                AttributedText(
                    "proCancellationShortDescription"
                        .put(key: "app_pro", value: Constants.app_pro)
                        .put(key: "pro", value: Constants.pro)
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
                Text(
                    "cancelAccess"
                        .put(key: "pro", value: Constants.pro)
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
                        .fill(themeColor: .danger)
                )
                .padding(.vertical, Values.smallSpacing)
            }
        }
    }
}

// MARK: - Cancel Plan Non Originating Platform Content

struct CancelPlanNonOriginatingPlatformContent: View {
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
                    Text("proCancellation".localized())
                        .font(.Headings.H7)
                        .foregroundColor(themeColor: .textPrimary)
                    
                    AttributedText(
                        "proCancellationDescription"
                            .put(key: "app_pro", value: Constants.app_pro)
                            .put(key: "pro", value: Constants.pro)
                            .put(key: "platform_account", value: originatingPlatform.platformAccount)
                            .localizedFormatted(Fonts.Body.baseRegular)
                    )
                    .font(.Body.baseRegular)
                    .foregroundColor(themeColor: .textPrimary)
                }
                
                Text(
                    "proCancellationOptions"
                        .put(key: "pro", value: Constants.pro)
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
                            .put(key: "app_name", value: Constants.app_name)
                            .put(key: "device_type", value: originatingPlatform.device)
                            .put(key: "platform_account", value: originatingPlatform.platformAccount)
                            .put(key: "app_pro", value: Constants.app_pro)
                            .put(key: "pro", value: Constants.pro)
                            .localizedFormatted(),
                        variant: .device
                    )
                )
                
                ApproachCell(
                    info: ApproachCell.Info(
                        title: "onPlatformWebsite"
                            .put(key: "platform", value: originatingPlatform.platform)
                            .localized(),
                        description: "viaStoreWebsiteDescription"
                            .put(key: "platform_account", value: originatingPlatform.platformAccount)
                            .put(key: "platform_store", value: originatingPlatform.store)
                            .put(key: "pro", value: Constants.pro)
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
                            .fill(themeColor: .danger)
                    )
                    .padding(.vertical, Values.smallSpacing)
            }
        }
    }
}
