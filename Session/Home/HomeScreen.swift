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
    @State private var dataChangeObservable: DatabaseCancellable? {
        didSet { oldValue?.cancel() }   // Cancel the old observable if there was one
    }
    @State private var hasLoadedInitialStateData: Bool = false
    @State private var hasLoadedInitialThreadData: Bool = false
    @State private var isLoadingMore: Bool = false
    @State private var isAutoLoadingNextPage: Bool = false
    @State private var viewHasAppeared: Bool = false
    
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
                
                ConversationList(viewModel: $viewModel)
                
                NewConversationButton(action: createNewConversation)
            }
        )
    }
    
    // MARK: - Updating
    
    public func startObservingChanges(didReturnFromBackground: Bool = false, onReceivedInitialChange: (() -> ())? = nil) {
        guard dataChangeObservable == nil else { return }
        
        var runAndClearInitialChangeCallback: (() -> ())? = nil
        
        runAndClearInitialChangeCallback = {
            guard self.hasLoadedInitialStateData == true && self.hasLoadedInitialThreadData == true else { return }
            
            onReceivedInitialChange?()
            runAndClearInitialChangeCallback = nil
        }
        
        dataChangeObservable = Storage.shared.start(
            viewModel.observableState,
            onError: { _ in },
            onChange: { state in
                // The default scheduler emits changes on the main thread
                self.handleUpdates(state)
                runAndClearInitialChangeCallback?()
            }
        )
        
        self.viewModel.onThreadChange = { updatedThreadData, changeset in
            self.handleThreadUpdates(updatedThreadData, changeset: changeset)
            runAndClearInitialChangeCallback?()
        }
        
        // Note: When returning from the background we could have received notifications but the
        // PagedDatabaseObserver won't have them so we need to force a re-fetch of the current
        // data to ensure everything is up to date
        if didReturnFromBackground {
            DispatchQueue.global(qos: .userInitiated).async {
                self.viewModel.pagedDataObserver?.reload()
            }
        }
    }
    
    private func stopObservingChanges() {
        // Stop observing database changes
        self.dataChangeObservable = nil
        self.viewModel.onThreadChange = nil
    }
    
    private func autoLoadNextPageIfNeeded() {
        guard
            self.hasLoadedInitialThreadData &&
            !self.isAutoLoadingNextPage &&
            !self.isLoadingMore
        else { return }
        
        self.isAutoLoadingNextPage = true
        
        DispatchQueue.main.asyncAfter(deadline: .now() + PagedData.autoLoadNextPageDelay) { [weak self] in
            self?.isAutoLoadingNextPage = false
            
            // Note: We sort the headers as we want to prioritise loading newer pages over older ones
            let sections: [(HomeViewModel.Section, CGRect)] = (self?.viewModel.threadData
                .enumerated()
                .map { index, section in (section.model, (self?.tableView.rectForHeader(inSection: index) ?? .zero)) })
                .defaulting(to: [])
            let shouldLoadMore: Bool = sections
                .contains { section, headerRect in
                    section == .loadMore &&
                    headerRect != .zero &&
                    (self?.tableView.bounds.contains(headerRect) == true)
                }
            
            guard shouldLoadMore else { return }
            
            self?.isLoadingMore = true
            
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.viewModel.pagedDataObserver?.load(.pageAfter)
            }
        }
    }
    
    // MARK: - Interaction
    
    func handleContinueButtonTapped(from seedReminderView: SeedReminderView) {
        if let recoveryPasswordView: RecoveryPasswordScreen = try? RecoveryPasswordScreen() {
            let viewController: SessionHostingViewController = SessionHostingViewController(rootView: recoveryPasswordView)
            viewController.setNavBarTitle("sessionRecoveryPassword".localized())
            self.host.controller?.navigationController?.pushViewController(viewController, animated: true)
        } else {
            let targetViewController: UIViewController = ConfirmationModal(
                info: ConfirmationModal.Info(
                    title: "theError".localized(),
                    body: .text("LOAD_RECOVERY_PASSWORD_ERROR".localized()),
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
                SessionTableViewController(viewModel: MessageRequestsViewModel()) :
                nil
            ),
            ConversationVC(
                threadId: threadId,
                threadVariant: variant,
                focusedInteractionInfo: focusedInteractionInfo
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
        let searchController = GlobalSearchViewController()
        self.host.controller?.navigationController?.setViewControllers(
            [ self.host.controller, searchController ].compactMap{ $0 },
            animated: true
        )
    }
    
    private func createNewConversation() {
        let viewController = SessionHostingViewController(
            rootView: StartConversationScreen(),
            customizedNavigationBackground: .backgroundSecondary
        )
        viewController.setNavBarTitle("conversationsStart".localized())
        viewController.setUpDismissingButton(on: .right)
        
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
