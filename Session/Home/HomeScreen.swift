// Copyright © 2024 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI
import GRDB
import DifferenceKit
import SessionUIKit
import SessionMessagingKit
import SessionUtilitiesKit
import SignalUtilitiesKit

struct HomeScreen: View {
    @EnvironmentObject var host: HostWrapper
    
    @State private var viewModel: HomeViewModel = HomeViewModel()
    @State private var flow: Onboarding.Flow?
    
    var body: some View {
        ZStack(
            alignment: .topLeading,
            content: {
                ThemeManager.currentTheme.colorSwiftUI(for: .backgroundPrimary).ignoresSafeArea()
                
                if viewModel.state.showViewedSeedBanner {
                    SeedBanner()
                }
                
                if viewModel.threadData.isEmpty {
                    EmptyStateView(flow: $flow)
                }
                
//                List(content: {
//                    viewModel.threadData.forEach { section in
//                        switch section.model {
//                            case .messageRequests:
//                                
//                            case .threads:
//                            
//                        }
//                    }
//                })
            }
        )
    }
}

// MARK: EmptyStateView

struct EmptyStateView: View {
    @Binding var flow: Onboarding.Flow?
    var body: some View {
        VStack(
            alignment: .center,
            spacing: Values.smallSpacing,
            content: {
                if flow == .register {
                    // Welcome state after account creation
                    Image("Hooray")
                        .frame(
                            height: 96,
                            alignment: .center
                        )
                    
                    Text("onboardingAccountCreated".localized())
                        .bold()
                        .font(.system(size: Values.veryLargeFontSize))
                        .foregroundColor(themeColor: .textPrimary)
                        
                } else {
                    // Normal empty state
                    Image("SessionGreen64")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(
                            height: 103,
                            alignment: .center
                        )
                    
                    Image("SessionHeading")
                        .resizable()
                        .renderingMode(.template)
                        .aspectRatio(contentMode: .fit)
                        .foregroundColor(themeColor: .textPrimary)
                        .frame(
                            height: 22,
                            alignment: .center
                        )
                }
                
                Text("conversationsNone".localized())
                    .bold()
                    .font(.system(size: Values.mediumFontSize))
                    .foregroundColor(themeColor: .textPrimary)
                
                Text("onboardingHitThePlusButton".localized())
                    .font(.system(size: Values.verySmallFontSize))
                    .foregroundColor(themeColor: .textPrimary)
                    .multilineTextAlignment(.center)
            }
        )
    }
}

// MARK: SeedBanner

struct SeedBanner: View {
    var body: some View {
        ZStack(
            alignment: .topLeading,
            content: {
                ThemeManager.currentTheme.colorSwiftUI(for: .conversationButton_background).ignoresSafeArea()
                
                Rectangle()
                    .fill(themeColor: .primary)
                    .frame(
                        width: .infinity,
                        height: 2
                    )
                
                HStack(
                    alignment: .center,
                    spacing: 0,
                    content: {
                        VStack(
                            alignment: .leading,
                            spacing: Values.smallSpacing,
                            content: {
                                HStack(
                                    alignment: .center,
                                    spacing: Values.verySmallSpacing,
                                    content: {
                                        Text("recoveryPasswordBannerTittle".localized())
                                            .font(.system(size: Values.smallFontSize))
                                            .bold()
                                            .foregroundColor(themeColor: .textPrimary)
                                        
                                        Image("SessionShieldFilled")
                                            .resizable()
                                            .renderingMode(.template)
                                            .foregroundColor(themeColor: .textPrimary)
                                            .scaledToFit()
                                            .frame(
                                                width: 14,
                                                height: 16
                                            )
                                    }
                                )
                                
                                Text("recoveryPasswordBannerDescription".localized())
                                    .font(.system(size: Values.verySmallFontSize))
                                    .foregroundColor(themeColor: .textSecondary)
                                    .lineLimit(2)
                            }
                        )
                        
                        Spacer()
                        
                        Button {
                            
                        } label: {
                            Text("theContinue".localized())
                                .bold()
                                .font(.system(size: Values.smallFontSize))
                                .foregroundColor(themeColor: .sessionButton_text)
                                .frame(
                                    minWidth: 80,
                                    maxHeight: Values.smallButtonHeight,
                                    alignment: .center
                                )
                                .overlay(
                                    Capsule()
                                        .stroke(themeColor: .sessionButton_border)
                                )
                        }
                        .accessibility(
                            Accessibility(
                                identifier: "Reveal recovery phrase button",
                                label: "Reveal recovery phrase button"
                            )
                        )
                    }
                )
                .padding(isIPhone5OrSmaller ? Values.smallSpacing : Values.mediumSpacing)
            }
        )
        .border(
            width: Values.separatorThickness,
            edges: [.bottom],
            color: .borderSeparator
        )
    }
}

#Preview {
    HomeScreen()
}
