// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI
import SessionUIKit
import SignalUtilitiesKit
import SessionUtilitiesKit

struct LandingScreen: View {
    @EnvironmentObject var host: HostWrapper
    private let dependencies: Dependencies
    
    public init(using dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    var body: some View {
        ZStack(alignment: .center) {
            ThemeManager.currentTheme.colorSwiftUI(for: .backgroundPrimary).ignoresSafeArea()
            
            VStack(
                alignment: .center,
                spacing: 0
            ) {
                Spacer(minLength: 0)
                
                Text("onboardingBubblePrivacyInYourPocket".localized())
                    .bold()
                    .font(.system(size: Values.veryLargeFontSize))
                    .foregroundColor(themeColor: .textPrimary)
                
                Spacer(minLength: 0)
                    .frame(maxHeight: 2 * Values.mediumSpacing)
                
                FakeChat()
                
                Spacer(minLength: 0)
                    .frame(maxHeight: Values.massiveSpacing)
                
                Spacer(minLength: 0)
            }
            .padding(.vertical, Values.mediumSpacing)
            .padding(.bottom, 3 * Values.largeButtonHeight)
            
            VStack(
                alignment: .center,
                spacing: Values.mediumSpacing
            ) {
                Spacer()
                
                Button {
                    register()
                } label: {
                    Text("onboardingAccountCreate".localized())
                        .bold()
                        .font(.system(size: Values.smallFontSize))
                        .foregroundColor(themeColor: .sessionButton_primaryFilledText)
                        .frame(
                            maxWidth: .infinity,
                            maxHeight: Values.largeButtonHeight,
                            alignment: .center
                        )
                        .backgroundColor(themeColor: .sessionButton_primaryFilledBackground)
                        .cornerRadius(Values.largeButtonHeight / 2)
                }
                .accessibility(
                    Accessibility(
                        identifier: "Create account button",
                        label: "Create account button"
                    )
                )
                .padding(.horizontal, Values.massiveSpacing)
                
                Button {
                    restore()
                } label: {
                    Text("onboardingAccountExists".localized())
                        .bold()
                        .font(.system(size: Values.smallFontSize))
                        .foregroundColor(themeColor: .sessionButton_text)
                        .frame(
                            maxWidth: .infinity,
                            maxHeight: Values.largeButtonHeight,
                            alignment: .center
                        )
                        .overlay(
                            Capsule()
                                .stroke(themeColor: .sessionButton_border)
                        )
                }
                .accessibility(
                    Accessibility(
                        identifier: "Restore your session button",
                        label: "Restore your session button"
                    )
                )
                .padding(.horizontal, Values.massiveSpacing)
                
                Button {
                    openLegalUrl()
                } label: {
                    let attributedText: NSAttributedString = "onboardingTosPrivacy"
                        .localized()
                        .formatted(baseFont: .systemFont(ofSize: Values.verySmallFontSize))
                    AttributedText(attributedText)
                        .font(.system(size: Values.verySmallFontSize))
                        .foregroundColor(themeColor: .textPrimary)
                }
                .accessibility(
                    Accessibility(
                        identifier: "Open URL"
                    )
                )
                .padding(.horizontal, Values.massiveSpacing)
            }
        }
    }
    
    private func register() {
        let seed: Data! = try! Randomness.generateRandomBytes(numberBytes: 16)
        let (ed25519KeyPair, x25519KeyPair): (KeyPair, KeyPair) = try! Identity.generate(from: seed)
        Onboarding.Flow.register
            .preregister(
                with: seed,
                ed25519KeyPair: ed25519KeyPair,
                x25519KeyPair: x25519KeyPair,
                using: dependencies
            )
        
        let viewController: SessionHostingViewController = SessionHostingViewController(
            rootView: DisplayNameScreen(flow: .register, using: dependencies)
        )
        viewController.setUpNavBarSessionIcon()
        viewController.setUpClearDataBackButton(flow: .register)
        self.host.controller?.navigationController?.setViewControllers([viewController], animated: true)
    }
    
    private func restore() {
        Onboarding.Flow.register.unregister(using: dependencies)
        
        let viewController: SessionHostingViewController = SessionHostingViewController(
            rootView: LoadAccountScreen(using: dependencies)
        )
        viewController.setNavBarTitle("loadAccount".localized())
        self.host.controller?.navigationController?.pushViewController(viewController, animated: true)
    }
    
    private func openLegalUrl() {
        let modal: ConfirmationModal = ConfirmationModal(
            info: ConfirmationModal.Info(
                title: "urlOpen".localized(),
                body: .text("urlOpenBrowser".localized()),
                confirmTitle: "onboardingTos".localized(),
                confirmStyle: .textPrimary,
                cancelTitle: "onboardingPrivacy".localized(),
                cancelStyle: .textPrimary,
                hasCloseButton: true,
                onConfirm: { _ in
                    if let url: URL = URL(string: "https://getsession.org/terms-of-service") {
                        UIApplication.shared.open(url)
                    }
                },
                onCancel: { modal in
                    if let url: URL = URL(string: "https://getsession.org/privacy-policy") {
                        UIApplication.shared.open(url)
                    }
                    modal.close()
                }
            )
        )
        self.host.controller?.present(modal, animated: true)
    }
}

struct ChatBubble: View {
    let text: String
    let outgoing: Bool
    
    var body: some View {
        let backgroundColor: Color? = ThemeManager.currentTheme.colorSwiftUI(for: (outgoing ? .messageBubble_outgoingBackground : .messageBubble_incomingBackground))
        Text(text)
            .foregroundColor(themeColor: (outgoing ? .messageBubble_outgoingText : .messageBubble_incomingText))
            .font(.system(size: 16))
            .padding(.all, 12)
            .background(backgroundColor)
            .cornerRadius(13)
            .frame(
                maxWidth: 230,
                alignment: (outgoing ? .trailing : .leading)
            )
    }
}

struct FakeChat: View {
    @State var numberOfBubblesShown: Int = 0
    
    let chatBubbles: [ChatBubble] = [
        ChatBubble(
            text: "onboardingBubbleWelcomeToSession"
                .put(key: "app_name", value: Constants.app_name)
                .put(key: "emoji", value: "👋")
                .localized(),
            outgoing: false
        ),
        ChatBubble(
            text: "onboardingBubbleSessionIsEngineered"
                .put(key: "app_name", value: Constants.app_name)
                .localized(),
            outgoing: true
        ),
        ChatBubble(
            text: "onboardingBubbleNoPhoneNumber".localized(),
            outgoing: false
        ),
        ChatBubble(
            text: "onboardingBubbleCreatingAnAccountIsEasy"
                .put(key: "emoji", value: "👇")
                .localized(),
            outgoing: true
        )
    ]
    
    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(
                alignment: .leading,
                spacing: 18
            ) {
                ForEach(
                    0...(chatBubbles.count - 1),
                    id: \.self
                ) { index in
                    let chatBubble: ChatBubble = chatBubbles[index]
                    let bubble = chatBubble
                        .frame(
                            maxWidth: .infinity,
                            alignment: chatBubble.outgoing ? .trailing : .leading
                        )
                    if index < numberOfBubblesShown {
                        bubble
                            .transition(
                                AnyTransition
                                    .move(edge: .bottom)
                                    .combined(with:.opacity.animation(.easeIn(duration: 0.68)))
                            )
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .frame(
                height: 320,
                alignment: .bottom
            )
            .padding(.horizontal, 36)
        }
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            guard numberOfBubblesShown < 4 else { return }
            
            Timer.scheduledTimerOnMainThread(withTimeInterval: 0.2, repeats: false) { _ in
                withAnimation(.spring().speed(0.68)) {
                    numberOfBubblesShown = 1
                }
                Timer.scheduledTimerOnMainThread(withTimeInterval: 1.5, repeats: true) { timer in
                    withAnimation(.spring().speed(0.68)) {
                        numberOfBubblesShown += 1
                        if numberOfBubblesShown >= 4 {
                            timer.invalidate()
                        }
                    }
                }
            }
        }
    }
}

struct LandingView_Previews: PreviewProvider {
    static var previews: some View {
        LandingScreen(using: Dependencies())
    }
}
