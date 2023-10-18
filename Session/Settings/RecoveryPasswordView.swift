// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI
import SessionUIKit
import SignalUtilitiesKit
import SessionUtilitiesKit

struct RecoveryPasswordView: View {
    @EnvironmentObject var host: HostWrapper
    
    @State private var copied: Bool = false
    @State private var showQRCode: Bool = true
    private let mnemonic: String
    private let flow: Onboarding.Flow
    
    static private let cornerRadius: CGFloat = 13
    static private let backgroundCornerRadius: CGFloat = 17
    static private let buttonWidth: CGFloat = 120
    
    public init(flow: Onboarding.Flow) throws {
        self.mnemonic = try Identity.mnemonic()
        self.flow = flow
    }
    
    public init(hardcode: String, flow: Onboarding.Flow) {
        self.mnemonic = hardcode
        self.flow = flow
    }
    
    var body: some View {
        ZStack(alignment: .center) {
            if #available(iOS 14.0, *) {
                ThemeManager.currentTheme.colorSwiftUI(for: .backgroundPrimary).ignoresSafeArea()
            } else {
                ThemeManager.currentTheme.colorSwiftUI(for: .backgroundPrimary)
            }
            
            ScrollView(.vertical, showsIndicators: false) {
                VStack(
                    alignment: .leading,
                    spacing: Values.mediumSpacing
                ) {
                    ZStack {
                        RoundedRectangle(cornerRadius: Self.backgroundCornerRadius)
                            .fill(themeColor: .backgroundSecondary)
                        
                        VStack(
                            alignment: .leading,
                            spacing: 0
                        ) {
                            HStack(
                                alignment: .center,
                                spacing: Values.smallSpacing
                            ) {
                                Text("recovery_password_title".localized())
                                    .bold()
                                    .font(.system(size: Values.mediumFontSize))
                                    .foregroundColor(themeColor: .textPrimary)
                                
                                Image("SessionShieldFilled")
                                    .resizable()
                                    .renderingMode(.template)
                                    .foregroundColor(themeColor: .textPrimary)
                                    .scaledToFit()
                                    .frame(
                                        maxWidth: Values.mediumFontSize,
                                        maxHeight: Values.mediumFontSize
                                    )
                            }
                            
                            Text("recovery_password_explanation_1".localized())
                                .font(.system(size: Values.smallFontSize))
                                .foregroundColor(themeColor: .textPrimary)
                                .padding(.bottom, Values.mediumSpacing)
                                .fixedSize(horizontal: false, vertical: true)
                            
                            Text("recovery_password_explanation_2".localized())
                                .font(.system(size: Values.smallFontSize))
                                .foregroundColor(themeColor: .textPrimary)
                                .padding(.bottom, Values.mediumSpacing)
                                .fixedSize(horizontal: false, vertical: true)
                            
                            if self.showQRCode {
                                QRCodeView(
                                    string: mnemonic,
                                    hasBackground: false,
                                    hasLogo: true,
                                    themeStyle: ThemeManager.currentTheme.interfaceStyle
                                )
                                .padding(.all, Values.smallSpacing)
                                
                                ZStack(alignment: .center) {
                                    Button {
                                        self.showQRCode.toggle()
                                    } label: {
                                        Text("view_mnemonic_button_title".localized())
                                            .bold()
                                            .font(.system(size: Values.verySmallFontSize))
                                            .foregroundColor(themeColor: .textPrimary)
                                            .frame(
                                                maxWidth: Self.buttonWidth,
                                                maxHeight: Values.mediumSmallButtonHeight,
                                                alignment: .center
                                            )
                                            .overlay(
                                                Capsule()
                                                    .stroke(themeColor: .textPrimary)
                                            )
                                    }
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.top, Values.mediumSpacing)
                            } else {
                                Text(mnemonic)
                                    .font(.spaceMono(size: Values.verySmallFontSize))
                                    .multilineTextAlignment(.center)
                                    .foregroundColor(themeColor: .primary)
                                    .frame(
                                        maxWidth: .infinity,
                                        maxHeight: .infinity
                                    )
                                    .fixedSize(horizontal: false, vertical: true)
                                    .padding(.all, Values.largeSpacing)
                                    .overlay(
                                        RoundedRectangle(
                                            cornerSize: CGSize(
                                                width: Self.cornerRadius,
                                                height: Self.cornerRadius
                                            )
                                        )
                                        .stroke(themeColor: .borderSeparator)
                                    )
                                    .padding(.bottom, Values.mediumSpacing)
                                
                                HStack(
                                    alignment: .center,
                                    spacing: 0
                                ) {
                                    Button {
                                        copyRecoveryPassword()
                                    } label: {
                                        let buttonTitle: String = self.copied ? "copied".localized() : "copy".localized()
                                        Text(buttonTitle)
                                            .bold()
                                            .font(.system(size: Values.verySmallFontSize))
                                            .foregroundColor(themeColor: .textPrimary)
                                            .frame(
                                                maxWidth: Self.buttonWidth,
                                                minHeight: Values.mediumSmallButtonHeight,
                                                alignment: .center
                                            )
                                            .overlay(
                                                Capsule()
                                                    .stroke(themeColor: .textPrimary)
                                            )
                                    }
                                    .frame(maxWidth: .infinity)
                                    
                                    Spacer(minLength: Values.veryLargeSpacing)
                                    
                                    Button {
                                        self.showQRCode.toggle()
                                    } label: {
                                        Text("view_qr_code_button_title".localized())
                                            .bold()
                                            .font(.system(size: Values.verySmallFontSize))
                                            .foregroundColor(themeColor: .textPrimary)
                                            .frame(
                                                maxWidth: Self.buttonWidth,
                                                minHeight: Values.mediumSmallButtonHeight,
                                                alignment: .center
                                            )
                                            .overlay(
                                                Capsule()
                                                    .stroke(themeColor: .textPrimary)
                                            )
                                    }
                                    .frame(maxWidth: .infinity)
                                }
                            }
                        }
                        .padding(.all, Values.mediumSpacing)
                    }
                    
                    ZStack {
                        RoundedRectangle(cornerRadius: Self.backgroundCornerRadius)
                            .fill(themeColor: .backgroundSecondary)
                        
                        HStack(
                            alignment: .center,
                            spacing: Values.mediumSpacing
                        ) {
                            VStack(
                                alignment: .leading,
                                spacing: 0
                            ) {
                                Text("hide_recovery_password_title".localized())
                                    .bold()
                                    .font(.system(size: Values.mediumFontSize))
                                    .foregroundColor(themeColor: .textPrimary)
                                
                                Text("hide_recovery_password_explanation".localized())
                                    .font(.system(size: Values.smallFontSize))
                                    .foregroundColor(themeColor: .textPrimary)
                            }
                            .frame(
                                maxWidth: .infinity,
                                alignment: .leading
                            )
                            
                            Button {
                                
                            } label: {
                                Text("hide_button_title".localized())
                                    .bold()
                                    .font(.system(size: Values.verySmallFontSize))
                                    .foregroundColor(themeColor: .danger)
                                    .frame(
                                        width: 55,
                                        height: Values.mediumSmallButtonHeight
                                    )
                                    .overlay(
                                        Capsule()
                                            .stroke(themeColor: .danger)
                                    )
                            }
                        }
                        .padding(.all, Values.mediumSpacing)
                    }
                }
                .padding(.horizontal, Values.largeSpacing)
            }
        }
    }
    
    private func copyRecoveryPassword() {
        UIPasteboard.general.string = self.mnemonic
        self.copied = true
    }
}

struct RecoveryPasswordView_Previews: PreviewProvider {
    static var previews: some View {
        RecoveryPasswordView(hardcode: "Voyage  urban  toyed  maverick peculiar  tuxedo penguin  tree grass  building  listen  speak withdraw  terminal  plane ", flow: .register)
    }
}
