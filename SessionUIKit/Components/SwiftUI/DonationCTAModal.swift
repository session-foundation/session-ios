// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI
import Lucide
import Combine

public struct DonationCTAModal: View {
    public enum Variant {
        case powerfulForces
        case appeal
    }
    
    @EnvironmentObject var host: HostWrapper
    
    private let variant: DonationCTAModal.Variant
    private let dataManager: ImageDataManagerType
    
    let dismissType: Modal.DismissType
    let donatePressed: (() -> Void)?
    let skipPressed: (() -> Void)?
    
    public init(
        variant: DonationCTAModal.Variant,
        dataManager: ImageDataManagerType,
        dismissType: Modal.DismissType = .recursive,
        donatePressed: (() -> Void)? = nil,
        skipPressed: (() -> Void)? = nil
    ) {
        self.variant = variant
        self.dataManager = dataManager
        self.dismissType = dismissType
        self.donatePressed = donatePressed
        self.skipPressed = skipPressed
    }
    
    public var body: some View {
        Modal_SwiftUI(
            host: host,
            dismissType: dismissType,
            afterClosed: skipPressed
        ) { close in
            VStack(spacing: 0) {
                ZStack(alignment: .topTrailing) {
                    // Background images
                    ZStack {
                        Image(uiImage: UIImage(named: variant.backgroundImageName) ?? UIImage())
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: .infinity)
                    }
                    .backgroundColor(themeColor: .primary)
                    .overlay(alignment: .bottom, content: {
                        ThemeLinearGradient(
                            themeColors: [
                                .clear,
                                .alert_background
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .framing(
                            maxWidth: .infinity,
                            height: 90
                        )
                    })
                    .frame(
                        maxWidth: .infinity,
                        alignment: .bottom
                    )
                    
                    if variant.hasCloseButton {
                        Button(action: { close(nil) }) {
                            LucideIcon(.x, size: IconSize.medium.size)
                                .foregroundColor(themeColor: .white)
                        }
                        .frame(
                            width: 32,
                            height: 32
                        )
                        .background(
                            RoundedRectangle(cornerRadius: 16)
                                .fill(themeColor: .value(.black, alpha: 0.5))
                        )
                        .padding(.top, 14)
                        .padding(.trailing, 14)
                    }
                }
                
                // Content
                VStack(spacing: Values.largeSpacing) {
                    VStack(spacing: 0) {
                        AttributedText(variant.title)
                            .font(.Headings.H4)
                            .foregroundColor(themeColor: .textPrimary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.bottom, 16)
                            .accessibility(
                                Accessibility(identifier: "cta-heading")
                            )
                        
                        AttributedText(variant.message)
                            .font(.Body.largeRegular)
                            .foregroundColor(themeColor: .textSecondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    
                    // Buttons
                    HStack(spacing: Values.smallSpacing) {
                        // Donate Button
                        Button(
                            action: {
                                self.donatePressed?()
                                close(nil)
                            },
                            label: {
                                Text(variant.confirmTitle)
                                    .font(.Body.baseRegular)
                                    .foregroundColor(themeColor: .sessionButton_primaryFilledText)
                                    .framing(
                                        maxWidth: .infinity,
                                        height: Values.largeButtonHeight
                                    )
                            }
                        )
                        .frame(height: Values.largeButtonHeight)
                        .backgroundColor(themeColor: .sessionButton_primaryFilledBackground)
                        .cornerRadius(6)
                        .clipped()
                        .buttonStyle(PlainButtonStyle()) // prevents default blue highlight

                        if variant.hasSkipButton {
                            Button(
                                action: { close(nil) },
                                label: {
                                    Text("maybeLater".localized())
                                        .font(.Body.baseRegular)
                                        .foregroundColor(themeColor: .textPrimary)
                                        .framing(
                                            maxWidth: .infinity,
                                            height: Values.largeButtonHeight
                                        )
                                }
                            )
                            .backgroundColor(themeColor: .inputButton_background)
                            .cornerRadius(6)
                            .clipped()
                            .buttonStyle(PlainButtonStyle())
                            .accessibility(
                                Accessibility(identifier: "cta-button-negative")
                            )
                        }
                    }
                }
                .padding(Values.mediumSpacing)
            }
        }
    }
}

// MARK: - Variant Content

public extension DonationCTAModal.Variant {
    // stringlint:ignore_contents
    var backgroundImageName: String {
        switch self {
            case .powerfulForces: return "DonationsCTA.webp"
            case .appeal: return "AppealCTA.webp"
        }
    }
    
    var title: ThemedAttributedString {
        switch self {
            case .powerfulForces:
                return "donateSessionHelp"
                    .put(key: "app_name", value: Constants.app_name)
                    .localizedFormatted(baseFont: Fonts.Headings.H4)
                
            case .appeal:
                return "donateSessionAppealTitle"
                    .put(key: "donate_appeal_name", value: Constants.donate_appeal_name)
                    .localizedFormatted(baseFont: Fonts.Headings.H4)
        }
    }
    
    var message: ThemedAttributedString {
        switch self {
            case .powerfulForces:
                return "donateSessionDescription"
                    .put(key: "app_name", value: Constants.app_name)
                    .localizedFormatted(baseFont: Fonts.Body.largeRegular)
                
            case .appeal:
                return "donateSessionAppealDescription"
                    .put(key: "app_name", value: Constants.app_name)
                    .localizedFormatted(baseFont: Fonts.Body.largeRegular)
        }
    }
    
    var confirmTitle: String {
        switch self {
            case .powerfulForces: return "donate".localized()
            case .appeal: return "donateSessionAppealReadMore".localized()
        }
    }
    
    var hasCloseButton: Bool {
        switch self {
            case .powerfulForces: return false
            case .appeal: return true
        }
    }
    
    var hasSkipButton: Bool {
        switch self {
            case .powerfulForces: return true
            case .appeal: return false
        }
    }
}

// MARK: - Previews

#Preview("Classic Dark") {
    let variant: DonationCTAModal.Variant = .powerfulForces
    
    PreviewThemeWrapper(theme: .classicDark) {
        DonationCTAModal(
            variant: variant,
            dataManager: ImageDataManager(),
            dismissType: .single,
            donatePressed: nil,
            skipPressed: nil
        )
        .environmentObject(HostWrapper())
        .environment(\.colorScheme, .dark)
    }
}

#Preview("Classic Light") {
    let variant: DonationCTAModal.Variant = .powerfulForces
    
    PreviewThemeWrapper(theme: .classicLight) {
        DonationCTAModal(
            variant: variant,
            dataManager: ImageDataManager(),
            dismissType: .single,
            donatePressed: nil,
            skipPressed: nil
        )
        .environmentObject(HostWrapper())
    }
}

#Preview("Ocean Dark") {
    let variant: DonationCTAModal.Variant = .powerfulForces
    
    PreviewThemeWrapper(theme: .oceanDark) {
        DonationCTAModal(
            variant: variant,
            dataManager: ImageDataManager(),
            dismissType: .single,
            donatePressed: nil,
            skipPressed: nil
        )
        .environmentObject(HostWrapper())
    }
}

#Preview("Ocean Light") {
    let variant: DonationCTAModal.Variant = .powerfulForces
    
    PreviewThemeWrapper(theme: .oceanLight) {
        DonationCTAModal(
            variant: variant,
            dataManager: ImageDataManager(),
            dismissType: .single,
            donatePressed: nil,
            skipPressed: nil
        )
        .environmentObject(HostWrapper())
    }
}

