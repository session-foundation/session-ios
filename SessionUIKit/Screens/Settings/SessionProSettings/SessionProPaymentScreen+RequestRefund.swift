// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI
import Lucide

// MARK: - Request Refund Originating Platform Content

struct RequestRefundOriginatingPlatformContent: View {
    let requestRefundAction: @MainActor () -> Void
    
    var body: some View {
        VStack(spacing: Values.mediumSmallSpacing) {
            VStack(
                alignment: .leading,
                spacing: Values.verySmallSpacing
            ) {
                Text(
                    "proRefunding"
                        .put(key: "pro", value: Constants.pro)
                        .localized()
                )
                .font(.Headings.H7)
                .foregroundColor(themeColor: .textPrimary)
                
                AttributedText(
                    "proRefundingDescription"
                        .put(key: "app_pro", value: Constants.app_pro)
                        .put(key: "platform", value: SNUIKit.proClientPlatformStringProvider(for: .iOS).platform)
                        .put(key: "platform_store", value: SNUIKit.proClientPlatformStringProvider(for: .iOS).store)
                        .put(key: "app_name", value: Constants.app_name)
                        .localizedFormatted(Fonts.Body.baseRegular)
                )
                .font(.Body.baseRegular)
                .foregroundColor(themeColor: .textPrimary)
                .padding(.bottom, Values.mediumSmallSpacing)
                
                Text("important".localized())
                    .font(.Headings.H7)
                    .foregroundColor(themeColor: .textPrimary)
                
                AttributedText(
                    "proImportantDescription"
                        .put(key: "pro", value: Constants.pro)
                        .localizedFormatted(Fonts.Body.baseRegular)
                )
                .font(.Body.baseRegular)
                .foregroundColor(themeColor: .textPrimary)
                .padding(.bottom, Values.smallSpacing)
            }
            .padding(Values.mediumSpacing)
            .background(
                RoundedRectangle(cornerRadius: 11)
                    .fill(themeColor: .backgroundSecondary)
            )
            
            Button {
                requestRefundAction()
            } label: {
                Text("requestRefund".localized())
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

// MARK: - Native Refund Request Sheet Returns Success

struct RequestRefundSuccessContent: View {
    let returnAction: () -> Void
    let openRefundSupportAction: () -> Void
    
    var body: some View {
        VStack(spacing: Values.mediumSmallSpacing) {
            VStack(
                alignment: .leading,
                spacing: Values.mediumSpacing
            ) {
                Text("nextSteps".localized())
                    .font(.Headings.H7)
                    .foregroundColor(themeColor: .textPrimary)
                
                Text(
                    "proRefundNextSteps"
                        .put(key: "platform", value: SNUIKit.proClientPlatformStringProvider(for: .iOS).platform)
                        .put(key: "pro", value: Constants.pro)
                        .put(key: "app_name", value: Constants.app_name)
                        .localized()
                )
                .font(.Body.baseRegular)
                .foregroundColor(themeColor: .textPrimary)
                .multilineTextAlignment(.center)
                .padding(.vertical, Values.smallSpacing)
                
                Text("helpSupport".localized())
                    .font(.Headings.H7)
                    .foregroundColor(themeColor: .textPrimary)
                
                AttributedText(
                    "proRefundSupport"
                        .put(key: "platform", value: SNUIKit.proClientPlatformStringProvider(for: .iOS).platform)
                        .put(key: "app_name", value: Constants.app_name)
                        .localizedFormatted(Fonts.Body.baseRegular)
                )
                .font(.Body.baseRegular)
                .foregroundColor(themeColor: .textPrimary)
                .multilineTextAlignment(.center)
                .padding(.vertical, Values.smallSpacing)
                .onTapGesture {
                    openRefundSupportAction()
                }
            }
            .padding(Values.mediumSpacing)
            .background(
                RoundedRectangle(cornerRadius: 11)
                    .fill(themeColor: .backgroundSecondary)
            )
            
            Button {
                returnAction()
            } label: {
                Text("theReturn".localized())
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

// MARK: - Request Refund Non Originating Platform Content

struct RequestRefundNonOriginatorContent: View {
    let originatingPlatform: SessionProUI.ClientPlatform
    let isNonOriginatingAccount: Bool?
    let requestedAt: Date?
    var isLessThan48Hours: Bool { (requestedAt?.timeIntervalSinceNow ?? 0) <= 48 * 60 * 60 }
    let openPlatformStoreWebsiteAction: () -> Void
    var description: ThemedAttributedString {
        switch (isNonOriginatingAccount, isLessThan48Hours) {
            case (true, _):
                return "refundNonOriginatorApple"
                    .put(key: "app_pro", value: Constants.app_pro)
                    .put(key: "pro", value: Constants.pro)
                    .put(key: "platform_account", value: originatingPlatform.platformAccount)
                    .localizedFormatted(Fonts.Body.baseRegular)
            
            case (_, true):
                return "proPlanPlatformRefund"
                    .put(key: "app_pro", value: Constants.app_pro)
                    .put(key: "platform_store", value: originatingPlatform.store)
                    .put(key: "platform_account", value: originatingPlatform.platformAccount)
                    .localizedFormatted(Fonts.Body.baseRegular)
            
            case (_, false):
                return "proPlanPlatformRefundLong"
                    .put(key: "app_pro", value: Constants.app_pro)
                    .put(key: "platform_store", value: originatingPlatform.store)
                    .put(key: "app_name", value: Constants.app_name)
                    .localizedFormatted(Fonts.Body.baseRegular)
        }
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
                        "proRefunding"
                            .put(key: "pro", value: Constants.pro)
                            .localized()
                    )
                    .font(.Headings.H7)
                    .foregroundColor(themeColor: .textPrimary)
                    
                    AttributedText(description)
                        .font(.Body.baseRegular)
                        .foregroundColor(themeColor: .textPrimary)
                        .multilineTextAlignment(.leading)
                }
                
                if isLessThan48Hours || isNonOriginatingAccount == true {
                    Text("refundRequestOptions".localized())
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
                } else {
                    VStack(
                        alignment: .leading,
                        spacing: Values.verySmallSpacing
                    ) {
                        Text("important".localized())
                            .font(.Headings.H7)
                            .foregroundColor(themeColor: .textPrimary)
                        
                        AttributedText(
                            "proImportantDescription"
                                .put(key: "pro", value: Constants.pro)
                                .localizedFormatted(Fonts.Body.baseRegular)
                        )
                        .font(.Body.baseRegular)
                        .foregroundColor(themeColor: .textPrimary)
                        .multilineTextAlignment(.leading)
                    }
                }
                    
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
                    isLessThan48Hours ?
                        "openPlatformStoreWebsite"
                            .put(key: "platform_store", value: originatingPlatform.store)
                            .localized() :
                        "requestRefund"
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
    
