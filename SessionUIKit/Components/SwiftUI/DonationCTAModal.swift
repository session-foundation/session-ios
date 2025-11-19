// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI
import Lucide
import Combine

public struct DonationCTAModal: View {
    private static let backgroundImageName: String = "GenericCTA.webp"
    
    @EnvironmentObject var host: HostWrapper
    
    private let dataManager: ImageDataManagerType
    
    let dismissType: Modal.DismissType
    let donatePressed: (() -> Void)?
    let skipPressed: (() -> Void)?
    
    public init(
        dataManager: ImageDataManagerType,
        dismissType: Modal.DismissType = .recursive,
        donatePressed: (() -> Void)? = nil,
        skipPressed: (() -> Void)? = nil
    ) {
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
                // Background images
                ZStack {
                    Image(uiImage: UIImage(named: DonationCTAModal.backgroundImageName) ?? UIImage())
                        .resizable()
                        .aspectRatio((1522.0/1258.0), contentMode: .fit)
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
                // Content
                VStack(spacing: Values.largeSpacing) {
                    VStack(spacing: 0) {
                        Text("Session Needs Your Help")  // TODO: [Donations] Localize
                            .font(.Headings.H4)
                            .foregroundColor(themeColor: .textPrimary)
                        
                        Text("Session is fighting powerful forces trying to weaken privacy, but we can’t continue this fight alone.\n\nDonating keeps Session secure, independent, and online.")  // TODO: [Donations] Localize
                            .font(.Body.largeRegular)
                            .foregroundColor(themeColor: .textSecondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    
                    // Buttons
                    HStack(spacing: Values.smallSpacing) {
                        // Donate Button
                        Button(
                            action: { self.donatePressed?() },
                            label: {
                                Text("donate".localized())
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

                        // Skip Button
                        Button(
                            action: { close(nil) },
                            label: {
                                Text("Skip")      // TODO: [Donations] Localize
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
                    }
                }
                .padding(Values.mediumSpacing)
            }
        }
    }
}

// MARK: - Previews

struct DonationCTAModal_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            PreviewThemeWrapper(theme: .classicDark) {
                DonationCTAModal(
                    dataManager: ImageDataManager(),
                    dismissType: .single,
                    donatePressed: nil,
                    skipPressed: nil
                )
                .environmentObject(HostWrapper())
                .previewDisplayName("Classic Dark")
            }
            
            PreviewThemeWrapper(theme: .classicLight) {
                DonationCTAModal(
                    dataManager: ImageDataManager(),
                    dismissType: .single,
                    donatePressed: nil,
                    skipPressed: nil
                )
                .environmentObject(HostWrapper())
                .previewDisplayName("Classic Light")
            }
            
            PreviewThemeWrapper(theme: .oceanDark) {
                DonationCTAModal(
                    dataManager: ImageDataManager(),
                    dismissType: .single,
                    donatePressed: nil,
                    skipPressed: nil
                )
                .environmentObject(HostWrapper())
                .previewDisplayName("Ocean Dark")
            }
            
            PreviewThemeWrapper(theme: .oceanLight) {
                DonationCTAModal(
                    dataManager: ImageDataManager(),
                    dismissType: .single,
                    donatePressed: nil,
                    skipPressed: nil
                )
                .environmentObject(HostWrapper())
                .previewDisplayName("Ocean Light")
            }
        }
    }
}
