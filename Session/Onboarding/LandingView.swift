// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI
import UIKit
import SessionUIKit

struct LandingView: View {
    @EnvironmentObject var host: HostWrapper
    
    var body: some View {
        NavigationView {
            ZStack(alignment: .center) {
                if #available(iOS 14.0, *) {
                    ThemeManager.currentTheme.colorSwiftUI(for: .backgroundPrimary).ignoresSafeArea()
                } else {
                    ThemeManager.currentTheme.colorSwiftUI(for: .backgroundPrimary)
                }
                
                VStack(
                    alignment: .center,
                    spacing: Values.mediumSpacing
                ) {
                    Spacer()
                    
                    Text("onboarding_landing_title".localized())
                        .bold()
                        .font(.system(size: Values.veryLargeFontSize))
                        .foregroundColor(themeColor: .textPrimary)
                        .padding(.vertical, Values.mediumSpacing)
                    
                    FakeChat()
                    
                    Spacer()
                }
                .padding(.vertical, Values.mediumSpacing)
                .padding(.bottom, Values.massiveSpacing + 3 * Values.largeButtonHeight)
                
                VStack(
                    alignment: .center,
                    spacing: Values.mediumSpacing)
                {
                    Spacer()
                    
                    Button {
                        register()
                    } label: {
                        Text("onboarding_landing_register_button_title".localized())
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
                    .padding(.horizontal, Values.massiveSpacing)
                    
                    Button {
                        restore()
                    } label: {
                        Text("onboarding_landing_restore_button_title".localized())
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
                    .padding(.horizontal, Values.massiveSpacing)
                    
                    Button {
                        
                    } label: {
                        let attributedText: NSAttributedString = {
                            let text = String(format: "onboarding_T&C".localized(), "terms_of_service".localized(), "privacy_policy".localized())
                            let result = NSMutableAttributedString(
                                string: text,
                                attributes: [ .font : UIFont.systemFont(ofSize: Values.verySmallFontSize)]
                            )
                            result.addAttribute(.font, value: UIFont.boldSystemFont(ofSize: Values.verySmallFontSize), range: (text as NSString).range(of: "terms_of_service".localized()))
                            result.addAttribute(.font, value: UIFont.boldSystemFont(ofSize: Values.verySmallFontSize), range: (text as NSString).range(of: "privacy_policy".localized()))
                            
                            return result
                        }()
                        AttributedText(attributedText)
                            .foregroundColor(themeColor: .textPrimary)
                    }
                    .padding(.horizontal, Values.massiveSpacing)
                }
            }
        }
    }
    
    private func register() {
        let viewController: SessionHostingViewController = SessionHostingViewController(rootView: DisplayNameView(flow: .register))
        viewController.setUpNavBarSessionIcon()
        self.host.controller?.navigationController?.pushViewController(viewController, animated: true)
    }
    
    private func restore() {
        
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
    let chatBubbles: [ChatBubble] = [
        ChatBubble(text: "onboarding_chat_bubble_1".localized(), outgoing: false),
        ChatBubble(text: "onboarding_chat_bubble_2".localized(), outgoing: true),
        ChatBubble(text: "onboarding_chat_bubble_3".localized(), outgoing: false),
        ChatBubble(text: "onboarding_chat_bubble_4".localized(), outgoing: true),
    ]
    
    var body: some View {
        VStack(
            alignment: .leading,
            spacing: 18
        ) {
            ForEach(
                0...(chatBubbles.count - 1),
                id: \.self
            ) { index in
                let chatBubble: ChatBubble = chatBubbles[index]
                chatBubble
                    .frame(
                        maxWidth: .infinity,
                        alignment: chatBubble.outgoing ? .trailing : .leading
                    )
            }
        }
        .padding(.horizontal, 36)
    }
}

struct LandingView_Previews: PreviewProvider {
    static var previews: some View {
        LandingView()
    }
}
