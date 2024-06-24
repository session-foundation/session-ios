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
    
    init(flow: Onboarding.Flow? = nil) {
        self.flow = flow
    }
    
    var body: some View {
        ZStack(
            alignment: .top,
            content: {
                ThemeManager.currentTheme.colorSwiftUI(for: .backgroundPrimary).ignoresSafeArea()
                
                if viewModel.state.showViewedSeedBanner {
                    SeedBanner()
                }
                
                if viewModel.threadData.isEmpty {
                    ZStack {
                        EmptyStateView(flow: $flow)
                    }
                    .frame(
                        maxWidth: .infinity,
                        maxHeight: .infinity,
                        alignment: .center
                    )
                    
                }
                

                
                
            }
        )
    }
}

// MARK: ConversationList

struct ConversationList: View {
    @Binding private var viewModel: HomeViewModel
    
    private static let mutePrefix: String = "\u{e067}  " // stringlint:disable
    private static let unreadCountViewSize: CGFloat = 20
    private static let statusIndicatorSize: CGFloat = 14
    
    var body: some View {
        List(viewModel.threadData) { sectionModel in
            switch sectionModel.model {
                case .messageRequests:
                    Section {
                        ForEach(sectionModel.elements) { threadViewModel in
                            HStack(
                                alignment: .center,
                                content: {
                                    Image("icon_msg_req")
                                        .renderingMode(.template)
                                        .resizable()
                                        .foregroundColor(themeColor: .conversationButton_unreadBubbleText)
                                        .overlay(
                                            Circle()
                                                .fill(themeColor: .conversationButton_unreadBubbleBackground)
                                                .frame(
                                                    width: ProfilePictureView.Size.list.viewSize,
                                                    height: ProfilePictureView.Size.list.viewSize
                                                )
                                        )
                                    
                                    Text("sessionMessageRequests".localized())
                                        .bold()
                                        .font(.system(size: Values.mediumFontSize))
                                        .foregroundColor(themeColor: .textPrimary)
                                        .padding(.leading, Values.mediumSpacing)
                                        .padding(.trailing, Values.verySmallSpacing)
                                    
                                    Text("\(threadViewModel.threadUnreadCount ?? 0)")
                                        .bold()
                                        .font(.system(size: Values.veryLargeFontSize))
                                        .foregroundColor(themeColor: .conversationButton_unreadBubbleText)
                                        .overlay(
                                            Circle()
                                                .fill(themeColor: .conversationButton_unreadBubbleBackground)
                                                .frame(
                                                    width: ConversationList.unreadCountViewSize,
                                                    height: ConversationList.unreadCountViewSize
                                                )
                                        )
                                }
                            )
                            .backgroundColor(themeColor: .conversationButton_unreadBackground)
                            .frame(
                                width: .infinity,
                                height: 68
                            )
                        }
                    }
                case .threads:
                    Section {
                        ForEach(sectionModel.elements) { threadViewModel in
                            let unreadCount: UInt = (threadViewModel.threadUnreadCount ?? 0)
                            let threadIsUnread: Bool = (
                                unreadCount > 0 ||
                                threadViewModel.threadWasMarkedUnread == true
                            )
                            let themeBackgroundColor: ThemeValue = (threadIsUnread ?
                                .conversationButton_unreadBackground :
                                .conversationButton_background
                            )
                            
                            HStack(
                                alignment: .center,
                                content: {
                                    if threadViewModel.threadIsBlocked == true {
                                        Rectangle()
                                            .fill(themeColor: .danger)
                                            .frame(
                                                width: Values.accentLineThickness,
                                                height: .infinity
                                            )
                                    } else if unreadCount > 0 {
                                        Rectangle()
                                            .fill(themeColor: .conversationButton_unreadStripBackground)
                                            .frame(
                                                width: Values.accentLineThickness,
                                                height: .infinity
                                            )
                                    }
                                    
                                    ProfilePictureSwiftUI(
                                        size: .list,
                                        publicKey: threadViewModel.threadId,
                                        threadVariant: threadViewModel.threadVariant,
                                        customImageData: threadViewModel.openGroupProfilePictureData,
                                        profile: threadViewModel.profile,
                                        additionalProfile: threadViewModel.additionalProfile
                                    )
                                    
                                    
                                    
                                    if threadViewModel.threadPinnedPriority > 0 {
                                        Image("Pin")
                                            .resizable()
                                            .renderingMode(.template)
                                            .foregroundColor(themeColor: .textSecondary)
                                            .scaledToFit()
                                            .frame(
                                                width: ConversationList.unreadCountViewSize,
                                                height: ConversationList.unreadCountViewSize
                                            )
                                    }
                                    
                                    if threadIsUnread {
                                        if unreadCount > 0 {
                                            
                                        }
                                    }
                                }
                            )
                            .backgroundColor(themeColor: themeBackgroundColor)
                            .frame(
                                width: .infinity,
                                height: 68
                            )
                        }
                    }
                default: preconditionFailure("Other sections should have no content")
            }
        }
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
                    
                    Text("onboardingBubbleWelcomeToSession".localized())
                        .font(.system(size: Values.smallFontSize))
                        .foregroundColor(themeColor: .sessionButton_text)
                        
                } else {
                    // Normal empty state
                    Image("SessionGreen64")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(
                            height: 103,
                            alignment: .center
                        )
                        .padding(.bottom, Values.mediumSpacing)
                    
                    Image("SessionHeading")
                        .resizable()
                        .renderingMode(.template)
                        .aspectRatio(contentMode: .fit)
                        .foregroundColor(themeColor: .textPrimary)
                        .frame(
                            height: 22,
                            alignment: .center
                        )
                        .padding(.bottom, Values.smallSpacing)
                }
                
                Line(color: .borderSeparator)
                    .padding(.vertical, Values.smallSpacing)
                
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
        .frame(
            width: 300,
            alignment: .center
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
    HomeScreen(flow: .register)
}
