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
    
    var body: some View {
        ZStack(
            alignment: .topLeading,
            content: {
                ThemeManager.currentTheme.colorSwiftUI(for: .backgroundPrimary).ignoresSafeArea()
                
                if viewModel.state.showViewedSeedBanner {
                    SeedBanner()
                }
                
                List(content: {
                    viewModel.threadData.forEach { section in
                        switch section.model {
                            case .messageRequests:
                                
                            case .threads:
                            
                        }
                    }
                })
            }
        )
    }
}

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
