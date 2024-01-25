// Copyright © 2024 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI
import SessionUIKit
import SessionMessagingKit
import SessionUtilitiesKit
import SignalUtilitiesKit
import SessionSnodeKit

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
    
    fileprivate func startNewPrivateChatIfPossible(with sessionId: String, onError: (() -> ())?) {
        if !KeyPair.isValidHexEncodedPublicKey(candidate: sessionId) {
            errorString = "invalid_account_id_from_qr_code_message".localized()
        }
        else {
            startNewDM(with: sessionId)
        }
    }
    
    func continueWithAccountId(onError: (() -> ())?) {
        startNewPrivateChatIfPossible(with: accountIdOrONS, onError: onError)
    }
    
    fileprivate func startNewDMIfPossible(with onsNameOrPublicKey: String, onError: (() -> ())?) {
        let maybeSessionId: SessionId? = SessionId(from: onsNameOrPublicKey)
        
        if KeyPair.isValidHexEncodedPublicKey(candidate: onsNameOrPublicKey) {
            switch maybeSessionId?.prefix {
                case .standard:
                    startNewDM(with: onsNameOrPublicKey)
                    
                case .blinded15, .blinded25:
                    errorString = "DM_ERROR_DIRECT_BLINDED_ID".localized()
                    
                default:
                    errorString = "DM_ERROR_INVALID".localized()
            }
            return
        }
        
        // This could be an ONS name
        ModalActivityIndicatorViewController
            .present(fromViewController: self.host.controller?.navigationController!, canCancel: false) { modalActivityIndicator in
            SnodeAPI
                .getSessionID(for: onsNameOrPublicKey)
                .subscribe(on: DispatchQueue.global(qos: .userInitiated))
                .receive(on: DispatchQueue.main)
                .sinkUntilComplete(
                    receiveCompletion: { result in
                        switch result {
                            case .finished: break
                            case .failure(let error):
                                modalActivityIndicator.dismiss {
                                    var messageOrNil: String?
                                    if let error = error as? SnodeAPIError {
                                        switch error {
                                            case .decryptionFailed, .hashingFailed, .validationFailed:
                                                messageOrNil = error.errorDescription
                                            default: break
                                        }
                                    }
                                    let message: String = {
                                        if let messageOrNil: String = messageOrNil {
                                            return messageOrNil
                                        }
                                        
                                        return (maybeSessionId?.prefix == .blinded15 || maybeSessionId?.prefix == .blinded25 ?
                                            "DM_ERROR_DIRECT_BLINDED_ID".localized() :
                                            "DM_ERROR_INVALID".localized()
                                        )
                                    }()
                                    
                                    errorString = message
                                }
                        }
                    },
                    receiveValue: { sessionId in
                        modalActivityIndicator.dismiss {
                            self.startNewDM(with: sessionId)
                        }
                    }
                )
        }
    }

    private func startNewDM(with sessionId: String) {
        SessionApp.presentConversationCreatingIfNeeded(
            for: sessionId,
            variant: .contact,
            dismissing: self.host.controller,
            animated: false
        )
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
            
            Spacer()
            
            if !accountIdOrONS.isEmpty {
                Button {
                    
                } label: {
                    Text("next".localized())
                        .bold()
                        .font(.system(size: Values.smallFontSize))
                        .foregroundColor(themeColor: .sessionButton_text)
                        .frame(
                            maxWidth: 160,
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
        }
        .padding(.all, Values.largeSpacing)
    }
}

#Preview {
    NewMessageScreen()
}
