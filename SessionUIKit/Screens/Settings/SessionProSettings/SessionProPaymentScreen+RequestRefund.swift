// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI
import Lucide

// MARK: - Request Refund Originating Platform Content

struct RequestRefundOriginatingPlatformContent: View {
    let requestRefundAction: () -> Void
    
    var body: some View {
        VStack(spacing: Values.mediumSmallSpacing) {
            Text("proRefundDescription".localized())
                .font(.Body.baseRegular)
                .foregroundColor(themeColor: .textPrimary)
                .multilineTextAlignment(.center)
                .padding(.vertical, Values.smallSpacing)
            
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
                        .put(key: "platform_account", value: Constants.platform_account)
                        .put(key: "platform_store", value: Constants.platform_store)
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
            Text("proRequestedRefund".localized())
                .font(.Body.baseRegular)
                .foregroundColor(themeColor: .textPrimary)
                .multilineTextAlignment(.center)
                .padding(.vertical, Values.smallSpacing)
            
            VStack(
                alignment: .leading,
                spacing: Values.mediumSpacing
            ) {
                Text("nextSteps".localized())
                    .font(.Headings.H7)
                    .foregroundColor(themeColor: .textPrimary)
                
                Text(
                    "proRefundNextSteps"
                        .put(key: "platform_account", value: Constants.platform_account)
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
                        .put(key: "platform_account", value: Constants.platform_account)
                        .put(key: "app_name", value: Constants.app_name)
                        .put(key: "platform_store", value: Constants.platform_store)
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

struct RequestRefundNonOriginatingPlatformContent: View {
    let originatingPlatform: SessionProPaymentScreenContent.ClientPlatform
    let requestedAt: Date?
    var isLessThan48Hours: Bool { (requestedAt?.timeIntervalSinceNow ?? 0) <= 48 * 60 * 60 }
    let openPlatformStoreWebsiteAction: () -> Void
    
    var body: some View {
        VStack(spacing: Values.mediumSpacing) {
            Text("proRefundDescription".localized())
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
                        "proRefunding"
                            .put(key: "pro", value: Constants.pro)
                            .localized()
                    )
                    .font(.Headings.H7)
                    .foregroundColor(themeColor: .textPrimary)
                    
                    AttributedText(
                        isLessThan48Hours ?
                            "proPlanPlatformRefund"
                                .put(key: "app_pro", value: Constants.app_pro)
                                .put(key: "platform_store", value: originatingPlatform.store)
                                .put(key: "platform_account", value: originatingPlatform.account)
                                .localizedFormatted(Fonts.Body.baseRegular) :
                            "proPlanPlatformRefundLong"
                                .put(key: "app_pro", value: Constants.app_pro)
                                .put(key: "platform_store", value: originatingPlatform.store)
                                .put(key: "platform_account", value: originatingPlatform.account)
                                .put(key: "app_name", value: Constants.app_name)
                                .localizedFormatted(Fonts.Body.baseRegular)
                    )
                    .font(.Body.baseRegular)
                    .foregroundColor(themeColor: .textPrimary)
                    .multilineTextAlignment(.leading)
                }
                
                if isLessThan48Hours {
                    // TODO: Localised
                    Text("Two ways to request a refund:")
                        .font(.Body.baseRegular)
                        .foregroundColor(themeColor: .textSecondary)
                    
                    HStack(
                        alignment: .top,
                        spacing: Values.mediumSpacing
                    ) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(themeColor: .value(.primary, alpha: 0.1))
                            
                            AttributedText(Lucide.Icon.smartphone.attributedString(size: 24))
                                .foregroundColor(themeColor: .primary)
                        }
                        .frame(width: 34, height: 34)
                        
                        VStack(
                            alignment: .leading,
                            spacing: Values.verySmallSpacing
                        ) {
                            Text(
                                "onDevice"
                                    .put(key: "device_type", value: originatingPlatform.deviceType)
                                    .localized()
                            )
                            .font(.Body.baseBold)
                            .foregroundColor(themeColor: .textPrimary)
                            
                            Text(
                                "onDeviceDescription"
                                    .put(key: "app_name", value: Constants.app_name)
                                    .put(key: "device_type", value: originatingPlatform.deviceType)
                                    .put(key: "platform_account", value: originatingPlatform.account)
                                    .put(key: "app_pro", value: Constants.app_pro)
                                    .localized()
                            )
                            .font(.Body.baseRegular)
                            .foregroundColor(themeColor: .textPrimary)
                            .multilineTextAlignment(.leading)
                        }
                    }
                    .padding(Values.mediumSpacing)
                    .background(
                        RoundedRectangle(cornerRadius: 11)
                            .fill(themeColor: .inputButton_background)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 11)
                            .stroke(themeColor: .borderSeparator)
                    )
                    
                    HStack(
                        alignment: .top,
                        spacing: Values.mediumSpacing
                    ) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(themeColor: .value(.primary, alpha: 0.1))
                            
                            AttributedText(Lucide.Icon.globe.attributedString(size: 20))
                                .foregroundColor(themeColor: .primary)
                        }
                        .frame(width: 34, height: 34)
                        
                        VStack(
                            alignment: .leading,
                            spacing: Values.verySmallSpacing
                        ) {
                            Text(
                                "viaStoreWebsite"
                                    .put(key: "platform_store", value: originatingPlatform.store)
                                    .localized()
                            )
                            .font(.Body.baseBold)
                            .foregroundColor(themeColor: .textPrimary)
                            
                            AttributedText(
                                "viaStoreWebsiteDescription"
                                    .put(key: "platform_account", value: originatingPlatform.account)
                                    .put(key: "platform_store", value: originatingPlatform.store)
                                    .localizedFormatted(Fonts.Body.baseRegular)
                            )
                            .font(.Body.baseRegular)
                            .multilineTextAlignment(.leading)
                        }
                    }
                    .padding(Values.mediumSpacing)
                    .background(
                        RoundedRectangle(cornerRadius: 11)
                            .fill(themeColor: .inputButton_background)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 11)
                            .stroke(themeColor: .borderSeparator)
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
                        "openStoreWebsite"
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
    
