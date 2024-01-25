// Copyright © 2024 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI
import SessionUIKit
import SessionMessagingKit
import SessionUtilitiesKit

struct NewMessageScreen: View {
    @EnvironmentObject var host: HostWrapper
    
    @State var tabIndex = 0
    @State private var accountIdOrONS: String = ""
    @State private var errorString: String? = nil
    
    var body: some View {
        ZStack(alignment: .topLeading) {
            VStack(
                spacing: 0
            ){
                CustomTopTabBar(
                    tabIndex: $tabIndex,
                    tabTitles: [
                        "new_message_screen_enter_account_id_tab_title".localized(),
                        "vc_create_private_chat_scan_qr_code_tab_title".localized()
                    ]
                ).frame(maxWidth: .infinity)
                    
                if tabIndex == 0 {
                    EnterAccountIdScreen(
                        accountIdOrONS: $accountIdOrONS,
                        error: $errorString
                    )
                }
                else {
                    ScanQRCodeScreen(
                        $accountIdOrONS,
                        error: $errorString,
                        continueAction: continueWithAccountId
                    )
                }
            }
        }
        .backgroundColor(themeColor: .backgroundSecondary)
    }
    
    fileprivate func startNewPrivateChatIfPossible(with hexEncodedPublicKey: String, onError: (() -> ())?) {
        if !KeyPair.isValidHexEncodedPublicKey(candidate: hexEncodedPublicKey) {
            errorString = "invalid_account_id_from_qr_code_message".localized()
        }
        else {
            SessionApp.presentConversationCreatingIfNeeded(
                for: hexEncodedPublicKey,
                variant: .contact,
                dismissing: self.host.controller,
                animated: false
            )
        }
    }
    
    func continueWithAccountId(onError: (() -> ())?) {
        let hexEncodedPublicKey = accountIdOrONS
        startNewPrivateChatIfPossible(with: hexEncodedPublicKey, onError: onError)
    }
}

struct EnterAccountIdScreen: View {
    @Binding var accountIdOrONS: String
    @Binding var error: String?
    
    var body: some View {
        VStack(
            alignment: .center,
            spacing: Values.mediumSpacing
        ) {
            SessionTextField(
                $accountIdOrONS,
                placeholder: "new_message_screen_enter_account_id_hint".localized(),
                error: $error
            )
            
            if error?.isEmpty != true {
                ZStack {
                    if #available(iOS 14.0, *) {
                        Text("\("new_message_screen_enter_account_id_explanation".localized())\(Image(systemName: "questionmark.circle"))")
                            .font(.system(size: Values.verySmallFontSize))
                            .foregroundColor(themeColor: .textSecondary)
                            .multilineTextAlignment(.center)
                    } else {
                        Text("new_message_screen_enter_account_id_explanation".localized())
                            .font(.system(size: Values.verySmallFontSize))
                            .foregroundColor(themeColor: .textSecondary)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(.horizontal, Values.smallSpacing)
                .padding(.top, -50)
                .onTapGesture {
                    if let url: URL = URL(string: "https://sessionapp.zendesk.com/hc/en-us/articles/4439132747033-How-do-Session-ID-usernames-work-") {
                        UIApplication.shared.open(url)
                    }
                }
            }
            
            if !accountIdOrONS.isEmpty {
                Button {
                    
                } label: {
                    Text("next".localized())
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
            }
            
            Spacer()
        }
        .padding(.all, Values.largeSpacing)
    }
}

#Preview {
    NewMessageScreen()
}
