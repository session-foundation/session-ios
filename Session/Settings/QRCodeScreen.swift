// Copyright © 2024 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI
import SessionUIKit
import SignalUtilitiesKit
import SessionUtilitiesKit
import AVFoundation

struct QRCodeScreen: View {
    @EnvironmentObject var host: HostWrapper
    
    @State var tabIndex = 0
    @State private var accountId: String = ""
    @State private var errorString: String? = nil
    
    var body: some View {
        ZStack(alignment: .topLeading) {
            if #available(iOS 14.0, *) {
                ThemeManager.currentTheme.colorSwiftUI(for: .backgroundPrimary).ignoresSafeArea()
            } else {
                ThemeManager.currentTheme.colorSwiftUI(for: .backgroundPrimary)
            }
            VStack(
                spacing: 0
            ){
                CustomTopTabBar(
                    tabIndex: $tabIndex,
                    tabTitles: [
                        "settings_view_qr_code_tab_title".localized(),
                        "settings_scan_qr_code_tab_title".localized()
                    ]
                ).frame(maxWidth: .infinity)
                    
                if tabIndex == 0 {
                    MyQRCodeScreen()
                }
                else {
                    ScanQRCodeScreen(
                        $accountId,
                        error: $errorString,
                        continueAction: continueWithAccountId
                    )
                }
            }
        }
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
        let hexEncodedPublicKey = accountId
        startNewPrivateChatIfPossible(with: hexEncodedPublicKey, onError: onError)
    }
}

struct MyQRCodeScreen: View {
    var body: some View{
        VStack(
            spacing: Values.mediumSpacing
        ) {
            QRCodeView(
                string: getUserHexEncodedPublicKey(),
                hasBackground: false,
                logo: "SessionWhite40",
                themeStyle: ThemeManager.currentTheme.interfaceStyle
            )
            .aspectRatio(1, contentMode: .fit)
            
            Text("settings_view_my_qr_code_explanation".localized())
                .font(.system(size: Values.verySmallFontSize))
                .foregroundColor(themeColor: .textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, Values.mediumSpacing)
        .padding(.all, Values.veryLargeSpacing)
    }
}

#Preview {
    QRCodeScreen()
}
