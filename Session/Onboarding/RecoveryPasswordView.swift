// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI
import SessionUIKit
import SignalUtilitiesKit
import SessionUtilitiesKit

struct RecoveryPasswordView: View {
    @EnvironmentObject var host: HostWrapper
    
    private let mnemonic: String
    
    static let cornerRadius: CGFloat = 13
    
    public init() throws {
        self.mnemonic = try Identity.mnemonic()
    }
    
    public init(hardcode: String) {
        self.mnemonic = hardcode
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
                    
                    Text("onboarding_recovery_password_title".localized())
                        .bold()
                        .font(.system(size: Values.veryLargeFontSize))
                        .foregroundColor(themeColor: .textPrimary)
                        .padding(.vertical, Values.mediumSpacing)
                    
                    Text("onboarding_recovery_password_explanation".localized())
                        .font(.system(size: Values.smallFontSize))
                        .foregroundColor(themeColor: .textPrimary)
                        .padding(.vertical, Values.mediumSpacing)
                    
                    Text(mnemonic)
                        .font(.spaceMono(size: Values.verySmallFontSize))
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
                        
                    } label: {
                        Text("tap_to_copy".localized())
                            .font(.system(size: Values.verySmallFontSize))
                            .foregroundColor(themeColor: .textSecondary)
                    }
                    
                    Spacer()
                }
                .padding(.horizontal, Values.veryLargeSpacing)
                .padding(.bottom, Values.massiveSpacing + Values.largeButtonHeight)
                
                VStack() {
                    Spacer()
                    
                    Button {
                        
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
}

struct RecoveryPasswordView_Previews: PreviewProvider {
    static var previews: some View {
        RecoveryPasswordView(hardcode: "Voyage  urban  toyed  maverick peculiar  tuxedo  penguin  tree grass  building  listen  speak withdraw  terminal  plane ")
    }
}
