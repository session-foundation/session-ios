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
                        .localized()
                )
                .font(.Headings.H7)
                .foregroundColor(themeColor: .textPrimary)
                
                AttributedText(
                    "proRefundingDescription"
                        .put(key: "platform", value: SNUIKit.proClientPlatformStringProvider(for: .iOS).platform)
                        .put(key: "platform_store", value: SNUIKit.proClientPlatformStringProvider(for: .iOS).store)
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
            
            Spacer(minLength: 0)
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
                spacing: Values.verySmallSpacing
            ) {
                Text("nextSteps".localized())
                    .font(.Headings.H7)
                    .foregroundColor(themeColor: .textPrimary)
                
                Text(
                    "proRefundNextSteps"
                        .put(key: "platform", value: SNUIKit.proClientPlatformStringProvider(for: .iOS).platform)
                        .localized()
                )
                .font(.Body.baseRegular)
                .foregroundColor(themeColor: .textPrimary)
                .padding(.bottom, Values.mediumSmallSpacing)
                
                Text("helpSupport".localized())
                    .font(.Headings.H7)
                    .foregroundColor(themeColor: .textPrimary)
                
                AttributedText(
                    "proRefundSupport"
                        .put(key: "platform", value: SNUIKit.proClientPlatformStringProvider(for: .iOS).platform)
                        .put(key: "icon", value: Lucide.Icon.squareArrowUpRight)
                        .localizedFormatted(Fonts.Body.baseRegular)
                )
                .font(.Body.baseRegular)
                .padding(.bottom, Values.smallSpacing)
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
            
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Request Refund Non Originator Content

struct RequestRefundNonOriginatorContent: View {
    let originatingPlatform: SessionProUI.ClientPlatform
    let isNonOriginatingAccount: Bool?
    /// Whether the store's own quick-refund window is still open, which decides both the copy below and which URL the
    /// button opens. Resolved by the caller from `platform_refund_expiry_ts` against network time — see
    /// `SessionPro.State.isWithinQuickRefundWindow(atTimestampSeconds:)` — because the window is the store's to define
    /// and this view has neither the payment item nor a trustworthy clock.
    let isWithinQuickRefundWindow: Bool
    let openPlatformStoreWebsiteAction: () -> Void
    var description: ThemedAttributedString {
        switch (originatingPlatform, isNonOriginatingAccount, isWithinQuickRefundWindow) {
            case (.iOS, true, _):
                return "refundNonOriginatorApple"
                    .put(key: "platform_account", value: originatingPlatform.platformAccount)
                    .localizedFormatted(Fonts.Body.baseRegular)
            
            case (_, _, true):
                return "proPlanPlatformRefund"
                    .put(key: "platform_store", value: originatingPlatform.store)
                    .put(key: "platform_account", value: originatingPlatform.platformAccount)
                    .localizedFormatted(Fonts.Body.baseRegular)
            
            case (_, _, false):
                return "proPlanPlatformRefundLong"
                    .put(key: "platform_store", value: originatingPlatform.store)
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
                            .localized()
                    )
                    .font(.Headings.H7)
                    .foregroundColor(themeColor: .textPrimary)
                    
                    AttributedText(description)
                        .font(.Body.baseRegular)
                        .foregroundColor(themeColor: .textPrimary)
                        .multilineTextAlignment(.leading)
                }
                
                if isWithinQuickRefundWindow || isNonOriginatingAccount == true {
                    Text("refundRequestOptions".localized())
                        .font(.Body.baseRegular)
                        .foregroundColor(themeColor: .textSecondary)
                    
                    ApproachCell(
                        info: ApproachCell.Info(
                            title: "onDevice"
                                .put(key: "device_type", value: originatingPlatform.device)
                                .localized(),
                            description: "proRefundAccountDevice"
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
                            description: "requestRefundPlatformWebsite"
                                .put(key: "platform_account", value: originatingPlatform.platformAccount)
                                .put(key: "platform", value: (originatingPlatform == .iOS ? originatingPlatform.platform : originatingPlatform.store))
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
                    isWithinQuickRefundWindow ?
                        "openPlatformStoreWebsite"
                            .put(key: "platform_store", value: (originatingPlatform == .iOS ? originatingPlatform.platform : originatingPlatform.store))
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
            
            Spacer(minLength: 0)
        }
    }
}
    
