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
                    .accessibility(Accessibility(identifier: SessionProUI.AccessibilityIdentifier.screenCancelPlan))
                
                AttributedText(
                    "proCancellationShortDescription"
                        .localizedFormatted(Fonts.Body.baseRegular)
                )
                .font(.Body.baseRegular)
                .foregroundColor(themeColor: .textPrimary)
                .padding(.vertical, Values.smallSpacing)
                .accessibility(Accessibility(identifier: SessionProUI.AccessibilityIdentifier.screenDescription))
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
            .accessibility(Accessibility(identifier: SessionProUI.AccessibilityIdentifier.screenAction))
            
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Cancel Plan Non riginator Content

struct CancelPlanNonOriginatorContent: View {
    let originatingPlatform: SessionProUI.ClientPlatform
    let isNonOriginatingAccount: Bool?
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
                        .accessibility(Accessibility(identifier: SessionProUI.AccessibilityIdentifier.screenCancelPlanNonOriginating))
                    
                    AttributedText(
                        "proCancellationDescription"
                            .put(key: "platform_account", value: originatingPlatform.platformAccount)
                            .localizedFormatted(Fonts.Body.baseRegular)
                    )
                    .font(.Body.baseRegular)
                    .foregroundColor(themeColor: .textPrimary)
                    .accessibility(Accessibility(identifier: SessionProUI.AccessibilityIdentifier.screenDescription))
                }
                
                Text(
                    "proCancellationOptions"
                        .localized()
                )
                .font(.Body.baseRegular)
                .foregroundColor(themeColor: .textSecondary)
                
                ApproachCell(
                    info: ApproachCell.Info(
                        title: "onDevice"
                            .put(key: "device_type", value: originatingPlatform.device)
                            .localized(),
                        description: "onDeviceCancelDescription"
                            .put(key: "device_type", value: originatingPlatform.device)
                            .put(key: "platform_account", value: originatingPlatform.platformAccount)
                            .localizedFormatted(),
                        variant: .device
                    )
                )
                
                ApproachCell(
                    info: ApproachCell.Info(
                        title: "onPlatformWebsite"
                            .put(key: "platform", value: (originatingPlatform == .iOS ? originatingPlatform.platform : originatingPlatform.store))
                            .localized(),
                        description: "cancelProPlatform"
                            .put(key: "platform_account", value: originatingPlatform.platformAccount)
                            .put(key: "platform", value: (originatingPlatform == .iOS ? originatingPlatform.platform : originatingPlatform.store))
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
                        .fill(themeColor: .danger)
                )
                .padding(.vertical, Values.smallSpacing)
            }
            .accessibility(Accessibility(identifier: SessionProUI.AccessibilityIdentifier.screenAction))
            
            Spacer(minLength: 0)
        }
    }
}
