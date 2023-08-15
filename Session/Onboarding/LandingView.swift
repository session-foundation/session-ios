// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI
import SessionUIKit

struct LandingView: View {
    var body: some View {
        NavigationView {
            ZStack (alignment: .topLeading) {
                if #available(iOS 14.0, *) {
                    ThemeManager.currentTheme.colorSwiftUI(for: .backgroundPrimary).ignoresSafeArea()
                } else {
                    ThemeManager.currentTheme.colorSwiftUI(for: .backgroundPrimary)
                }
                
                VStack(
                    alignment: .center,
                    spacing: 16
                ) {
                    Spacer()
                    
                    Text("onboarding_landing_title".localized())
                        .bold()
                        .font(.system(size: 26))
                        .foregroundColor(themeColor: .textPrimary)
                    
                    FakeChat()
                    
                    Spacer()
                    
                    Button {
                        
                    } label: {
                        Text("onboarding_landing_register_button_title".localized())
                            .bold()
                            .font(.system(size: 14))
                            .foregroundColor(themeColor: .sessionButton_filledText)
                            .frame(
                                width: 262,
                                height: 40,
                                alignment: .center
                            )
                            .background(ThemeManager.currentTheme.colorSwiftUI(for: .sessionButton_filledBackground))
                            .cornerRadius(20)
                    }
                    
                    Button {
                        
                    } label: {
                        Text("onboarding_landing_restore_button_title".localized())
                            .bold()
                            .font(.system(size: 14))
                            .foregroundColor(themeColor: .sessionButton_text)
                            .frame(
                                width: 262,
                                height: 40,
                                alignment: .center
                            )
                            .overlay(
                                Capsule()
                                    .stroke(ThemeManager.currentTheme.colorSwiftUI(for: .sessionButton_border)!)
                            )
                    }
                    
                    Button {
                        
                    } label: {
                        Text("")
                    }
                }
            }
        }
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
        ScrollView(
            .vertical,
            showsIndicators: false
        ) {
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
}

struct LandingView_Previews: PreviewProvider {
    static var previews: some View {
        LandingView()
    }
}
