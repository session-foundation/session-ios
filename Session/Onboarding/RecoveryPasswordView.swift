// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI
import SessionUIKit
import SignalUtilitiesKit
import SessionUtilitiesKit

struct RecoveryPasswordView: View {
    @EnvironmentObject var host: HostWrapper
    
    @State private var copied: Bool = false
    private let mnemonic: String
    private let flow: Onboarding.Flow
    
    static let cornerRadius: CGFloat = 13
    
    public init(flow: Onboarding.Flow) throws {
        self.mnemonic = try Identity.mnemonic()
        self.flow = flow
    }
    
    public init(hardcode: String, flow: Onboarding.Flow) {
        self.mnemonic = hardcode
        self.flow = flow
    }
    
    var body: some View {
        NavigationView {
            ZStack(alignment: .center) {
                if #available(iOS 14.0, *) {
                    ThemeManager.currentTheme.colorSwiftUI(for: .backgroundPrimary).ignoresSafeArea()
                } else {
                    ThemeManager.currentTheme.colorSwiftUI(for: .backgroundPrimary)
                }
                
                VStack(
                    alignment: .leading,
                    spacing: Values.mediumSpacing
                ) {
                    Spacer()
                    
                    HStack(
                        alignment: .bottom,
                        spacing: Values.smallSpacing
                    ) {
                        Text("onboarding_recovery_password_title".localized())
                            .bold()
                            .font(.system(size: Values.veryLargeFontSize))
                            .foregroundColor(themeColor: .textPrimary)
                        
                        Image("SessionShield")
                            .resizable()
                            .renderingMode(.template)
                            .foregroundColor(themeColor: .textPrimary)
                            .scaledToFit()
                            .frame(
                                maxWidth: Values.largeFontSize,
                                maxHeight: Values.largeFontSize
                            )
                            .padding(.bottom, Values.verySmallSpacing)
                    }
                    
                    Text("onboarding_recovery_password_explanation".localized())
                        .font(.system(size: Values.smallFontSize))
                        .foregroundColor(themeColor: .textPrimary)
                    
                    Text(mnemonic)
                        .font(.spaceMono(size: Values.verySmallFontSize))
                        .multilineTextAlignment(.center)
                        .foregroundColor(themeColor: .primary)
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
                    
                    Button {
                        copyRecoveryPassword()
                    } label: {
                        let buttonTitle: String = self.copied ? "copied".localized() : "tap_to_copy".localized()
                        Text(buttonTitle)
                            .font(.system(size: Values.verySmallFontSize))
                            .foregroundColor(themeColor: .textSecondary)
                    }
                    .frame(maxWidth: .infinity)
                    
                    Spacer()
                }
                .padding(.horizontal, Values.veryLargeSpacing)
                .padding(.bottom, Values.massiveSpacing + Values.largeButtonHeight)
                
                VStack() {
                    Spacer()
                    
                    Button {
                        finishRegister()
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
    
    private func copyRecoveryPassword() {
        UIPasteboard.general.string = self.mnemonic
        self.copied = true
    }
    
    private func finishRegister() {
        let homeVC: HomeVC = HomeVC(flow: self.flow)
        self.host.controller?.navigationController?.setViewControllers([ homeVC ], animated: true)
        return
    }
}

struct RecoveryPasswordView_Previews: PreviewProvider {
    static var previews: some View {
        RecoveryPasswordView(hardcode: "Voyage  urban  toyed  maverick peculiar  tuxedo  penguin  tree grass  building  listen  speak", flow: .register)
    }
}
