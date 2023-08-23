// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI
import SessionUIKit
import SignalUtilitiesKit
import SessionUtilitiesKit

struct LoadAccountView: View {
    @EnvironmentObject var host: HostWrapper
    
    @State var tabIndex = 0
    @State private var recoveryPassword: String = ""
    @State private var errorString: String? = nil
        
    var body: some View {
        NavigationView {
            ZStack(alignment: .topLeading) {
                if #available(iOS 14.0, *) {
                    ThemeManager.currentTheme.colorSwiftUI(for: .backgroundPrimary).ignoresSafeArea()
                } else {
                    ThemeManager.currentTheme.colorSwiftUI(for: .backgroundPrimary)
                }
                VStack(
                    spacing: 0
                ){
                    CustomTopTabBar(tabIndex: $tabIndex)
                        .frame(maxWidth: .infinity)
                        
                    if tabIndex == 0 {
                        EnterRecoveryPasswordView(
                            $recoveryPassword,
                            error: $errorString,
                            continueWithMnemonic: continueWithMnemonic
                        )
                    }
                    else {
                        ScanQRCodeView()
                    }
                }
            }
        }
    }
    
    func continueWithMnemonic() {
        let mnemonic = recoveryPassword.lowercased()
        let hexEncodedSeed: String
        do {
            hexEncodedSeed = try Mnemonic.decode(mnemonic: mnemonic)
        } catch {
            if let decodingError = error as? Mnemonic.DecodingError {
                switch decodingError {
                    case .inputTooShort:
                        errorString = "recovery_password_error_length".localized()
                    case .invalidWord:
                        errorString = "recovery_password_error_invalid".localized()
                    default:
                        errorString = "recovery_password_error_generic".localized()
                }
            } else {
                errorString = "recovery_password_error_generic".localized()
            }
            return
        }
        let seed = Data(hex: hexEncodedSeed)
        if (seed.count != 16) {
            //TODO: show error
            return
        }
        let (ed25519KeyPair, x25519KeyPair) = try! Identity.generate(from: seed)
        
        Onboarding.Flow.link
            .preregister(
                with: seed,
                ed25519KeyPair: ed25519KeyPair,
                x25519KeyPair: x25519KeyPair
            )
        
        // Otherwise continue on to request push notifications permissions
        let viewController: SessionHostingViewController = SessionHostingViewController(rootView: PNModeView(flow: .link))
        viewController.setUpNavBarSessionIcon()
        self.host.controller?.navigationController?.pushViewController(viewController, animated: true)
    }
}

struct TabBarButton: View {
    @Binding var isSelected: Bool
    
    let text: String
    
    var body: some View {
        ZStack(
            alignment: .bottom
        ) {
            Text(text)
                .bold()
                .font(.system(size: Values.mediumFontSize))
                .foregroundColor(themeColor: .textPrimary)
                .padding(.bottom, 5)
                .frame(
                    maxWidth: .infinity,
                    maxHeight: .infinity
                )
            if isSelected {
                Rectangle()
                    .foregroundColor(themeColor: .primary)
                    .frame(
                        maxWidth: .infinity,
                        maxHeight: 5
                    )
                    .padding(.horizontal, Values.verySmallSpacing)
            }
            
        }
    }
}

struct CustomTopTabBar: View {
    @Binding var tabIndex: Int
    
    private static let height = isIPhone5OrSmaller ? CGFloat(32) : CGFloat(48)
    
    var body: some View {
        HStack(spacing: 0) {
            TabBarButton(
                isSelected: .constant(tabIndex == 0),
                text: "onboarding_recovery_password_tab_title".localized()
            )
            .onTapGesture { onButtonTapped(index: 0) }
            
            TabBarButton(
                isSelected: .constant(tabIndex == 1),
                text: "vc_qr_code_view_scan_qr_code_tab_title".localized()
            )
            .onTapGesture { onButtonTapped(index: 1) }
        }
        .frame(
            maxWidth: .infinity,
            maxHeight: Self.height
        )
        .border(width: 1, edges: [.bottom], color: .borderSeparator)
    }
    
    private func onButtonTapped(index: Int) {
        withAnimation(.easeInOut(duration: 0.2)) {
            tabIndex = index
        }
    }
}

struct EnterRecoveryPasswordView: View{
    @Binding var recoveryPassword: String
    @Binding var error: String?
    
    var continueWithMnemonic: (() -> Void)?
    
    init(
        _ recoveryPassword: Binding<String>,
        error: Binding<String?>,
        continueWithMnemonic: (() -> Void)?
    ) {
        self._recoveryPassword = recoveryPassword
        self._error = error
        self.continueWithMnemonic = continueWithMnemonic
    }
    
    var body: some View{
        ZStack(alignment: .center) {
            VStack(
                alignment: .leading,
                spacing: Values.mediumSpacing
            ) {
                Spacer()
                
                Text("onboarding_recovery_password_tab_title".localized())
                    .bold()
                    .font(.system(size: Values.veryLargeFontSize))
                    .foregroundColor(themeColor: .textPrimary)
                
                Text("onboarding_recovery_password_tab_explanation".localized())
                    .font(.system(size: Values.smallFontSize))
                    .foregroundColor(themeColor: .textPrimary)
                    .padding(.vertical, Values.mediumSpacing)
                
                SessionTextField(
                    $recoveryPassword,
                    placeholder: "onboarding_recovery_password_hint".localized(),
                    error: $error
                )
                
                Spacer()
            }
            .padding(.horizontal, Values.veryLargeSpacing)
            .padding(.bottom, Values.massiveSpacing + Values.largeButtonHeight)
            
            VStack() {
                Spacer()
                
                Button {
                    continueWithMnemonic?()
                } label: {
                    Text("continue_2".localized())
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
            .padding(.vertical, Values.mediumSpacing)
        }
    }
}

struct ScanQRCodeView: View{
    var body: some View{
        ZStack{
        }
    }
}

struct LoadAccountView_Previews: PreviewProvider {
    static var previews: some View {
        LoadAccountView()
    }
}
