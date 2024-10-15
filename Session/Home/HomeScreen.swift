// Copyright © 2024 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI
import Combine
import GRDB
import DifferenceKit
import SessionUIKit
import SessionMessagingKit
import SessionUtilitiesKit
import SignalUtilitiesKit

struct HomeScreen: View {
    @EnvironmentObject var host: HostWrapper
    @StateObject private var viewModel: HomeScreenViewModel
    private var flow: Onboarding.Flow?
    
    init(flow: Onboarding.Flow? = nil, using dependencies: Dependencies, onReceivedInitialChange: (() -> ())? = nil) {
        self.flow = flow
        _viewModel = StateObject(
            wrappedValue: HomeScreenViewModel(
                using: dependencies,
                onReceivedInitialChange: onReceivedInitialChange
            )
        )
    }
    
    var body: some View {
        ZStack(
            alignment: .top,
            content: {
                if viewModel.state.showViewedSeedBanner {
                    SeedBanner(action: handleContinueButtonTapped)
                }
                
                if viewModel.threadData.isEmpty {
                    ZStack {
                        EmptyStateView(flow: self.flow)
                    }
                    .frame(
                        maxWidth: .infinity,
                        maxHeight: .infinity,
                        alignment: .center
                    )
                }
                
                ConversationList(threadData: $viewModel.threadData)
                
                NewConversationButton(action: createNewConversation)
            }
        )
        .backgroundColor(themeColor: .backgroundPrimary)
        .onReceive(Just(viewModel.dataModel), perform: { updatedDataModel in
            (self.host.controller as? SessionHostingViewController<HomeScreen>)?.setUpNavBarButton(
                leftItem: .profile(profile: updatedDataModel.state.userProfile),
                rightItem: .search,
                leftAction: openSettings,
                rightAction: showSearchUI
            )
        })
    }
        
    // MARK: - Interaction
    
    func handleContinueButtonTapped() {
        if let recoveryPasswordScreen: RecoveryPasswordScreen = try? RecoveryPasswordScreen() {
            let viewController: SessionHostingViewController = SessionHostingViewController(rootView: recoveryPasswordScreen)
            viewController.setNavBarTitle("sessionRecoveryPassword".localized())
            self.host.controller?.navigationController?.pushViewController(viewController, animated: true)
        } else {
            let targetViewController: UIViewController = ConfirmationModal(
                info: ConfirmationModal.Info(
                    title: "theError".localized(),
                    body: .text("recoveryPasswordErrorLoad".localized()),
                    cancelTitle: "okay".localized(),
                    cancelStyle: .alert_text
                )
            )
            self.host.controller?.present(targetViewController, animated: true, completion: nil)
        }
    }
    
    func show(
        _ threadId: String,
        variant: SessionThread.Variant,
        isMessageRequest: Bool,
        with action: ConversationViewModel.Action,
        focusedInteractionInfo: Interaction.TimestampInfo?,
        animated: Bool
    ) {
        if let presentedVC = self.host.controller?.presentedViewController {
            presentedVC.dismiss(animated: false, completion: nil)
        }
        
        let finalViewControllers: [UIViewController] = [
            self.host.controller,
            (
                (isMessageRequest && action != .compose) ?
                SessionTableViewController(
                    viewModel: MessageRequestsViewModel(
                        using: viewModel.dataModel.dependencies)
                ) : nil
            ),
            ConversationVC(
                threadId: threadId,
                threadVariant: variant,
                focusedInteractionInfo: focusedInteractionInfo, 
                using: viewModel.dataModel.dependencies
            )
        ].compactMap { $0 }
        
        self.host.controller?.navigationController?.setViewControllers(finalViewControllers, animated: animated)
    }
    
    private func openSettings() {
        let settingsViewController: SessionTableViewController = SessionTableViewController(
            viewModel: SettingsViewModel()
        )
        let navigationController = StyledNavigationController(rootViewController: settingsViewController)
        navigationController.modalPresentationStyle = .fullScreen
        self.host.controller?.present(navigationController, animated: true, completion: nil)
    }
    
    private func showSearchUI() {
        if let presentedVC = self.host.controller?.presentedViewController {
            presentedVC.dismiss(animated: false, completion: nil)
        }
        let searchController = GlobalSearchViewController(using: viewModel.dataModel.dependencies)
        self.host.controller?.navigationController?.setViewControllers(
            [ self.host.controller, searchController ].compactMap{ $0 },
            animated: true
        )
    }
    
    func createNewConversation() {
        let viewController = SessionHostingViewController(
            rootView: StartConversationScreen(),
            customizedNavigationBackground: .backgroundSecondary
        )
        viewController.setNavBarTitle("conversationsStart".localized())
        viewController.setUpNavBarButton(rightItem: .close)
        
        let navigationController = StyledNavigationController(rootViewController: viewController)
        if UIDevice.current.isIPad {
            navigationController.modalPresentationStyle = .fullScreen
        }
        navigationController.modalPresentationCapturesStatusBarAppearance = true
        self.host.controller?.present(navigationController, animated: true, completion: nil)
    }
    
    func createNewDMFromDeepLink(sessionId: String) {
        let viewController: SessionHostingViewController = SessionHostingViewController(rootView: NewMessageScreen(accountId: sessionId))
        viewController.setNavBarTitle("messageNew".localized())
        let navigationController = StyledNavigationController(rootViewController: viewController)
        if UIDevice.current.isIPad {
            navigationController.modalPresentationStyle = .fullScreen
        }
        navigationController.modalPresentationCapturesStatusBarAppearance = true
        self.host.controller?.present(navigationController, animated: true, completion: nil)
    }
}

// MARK: NewConversationButton

extension HomeScreen {
    struct NewConversationButton: View {
        
        struct NewConversationButtonStyle: ButtonStyle {
            func makeBody(configuration: Self.Configuration) -> some View {
                configuration.label
                    .background(
                        configuration.isPressed ?
                        Circle()
                            .fill(themeColor: .highlighted(.menuButton_background, alwaysDarken: true))
                            .frame(
                                width: NewConversationButton.size,
                                height: NewConversationButton.size
                            )
                            .shadow(
                                themeColor: .menuButton_outerShadow,
                                opacity: 0.3,
                                radius: 15
                            ) :
                        Circle()
                            .fill(themeColor: .menuButton_background)
                            .frame(
                                width: NewConversationButton.size,
                                height: NewConversationButton.size
                            )
                            .shadow(
                                themeColor: .menuButton_outerShadow,
                                opacity: 0.3,
                                radius: 15
                            )
                    )
            }
        }
        
        private static let size: CGFloat = 60
        private var action: () -> ()
        
        init(action: @escaping () -> Void) {
            self.action = action
        }
        
        var body: some View {
            ZStack {
                Button {
                    action()
                } label: {
                    Image("Plus")
                        .renderingMode(.template)
                        .foregroundColor(themeColor: .menuButton_icon)
                }
                .buttonStyle(NewConversationButtonStyle())
                .accessibility(
                    Accessibility(
                        identifier: "New conversation button",
                        label: "New conversation button"
                    )
                )
                .padding(.bottom, Values.smallSpacing)
            }
            .frame(
                maxWidth: .infinity,
                maxHeight: .infinity,
                alignment: .bottom
            )
        }
    }
}

// MARK: EmptyStateView

extension HomeScreen {
    struct EmptyStateView: View {
        var flow: Onboarding.Flow?
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
                        
                        Text(
                            "onboardingBubbleWelcomeToSession"
                                .put(key: "emoji", value: "")
                                .localized()
                        )
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
}

// MARK: SeedBanner

extension HomeScreen {
    struct SeedBanner: View {
        private var action: () -> ()
        
        init(action: @escaping () -> Void) {
            self.action = action
        }
        
        var body: some View {
            ZStack(
                alignment: .topLeading,
                content: {
                    Rectangle()
                        .fill(themeColor: .primary)
                        .frame(height: 2)
                        .frame(maxWidth: .infinity)
                    
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
                                            Text("recoveryPasswordBannerTitle".localized())
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
                                action()
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
            .backgroundColor(themeColor: .conversationButton_background)
            .border(
                width: Values.separatorThickness,
                edges: [.bottom],
                color: .borderSeparator
            )
        }
    }
}

//#Preview {
//    HomeScreen(flow: .register, using: Dependencies())
//}
