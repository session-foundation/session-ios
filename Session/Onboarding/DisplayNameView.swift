// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI
import SessionUIKit
import SessionMessagingKit
import SignalUtilitiesKit

struct DisplayNameView: View {
    @EnvironmentObject var host: HostWrapper
    
    @State private var displayName: String = ""
    
    private let flow: Onboarding.Flow
    
    public init(flow: Onboarding.Flow) {
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
                    
                    Text("vc_display_name_title_2".localized())
                        .bold()
                        .font(.system(size: Values.veryLargeFontSize))
                        .foregroundColor(themeColor: .textPrimary)
                        .padding(.vertical, Values.mediumSpacing)
                    
                    Text("onboarding_display_name_explanation".localized())
                        .font(.system(size: Values.smallFontSize))
                        .foregroundColor(themeColor: .textPrimary)
                        .padding(.vertical, Values.mediumSpacing)
                    
                    SessionTextField(
                        $displayName,
                        placeholder: "onboarding_display_name_hint".localized()
                    )
                    
                    Spacer()
                }
                .padding(.horizontal, Values.veryLargeSpacing)
                .padding(.bottom, Values.massiveSpacing + Values.largeButtonHeight)
                
                VStack() {
                    Spacer()
                    
                    Button {
                        register()
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
    
    private func register() {
        func showError(title: String, message: String = "") {
            let modal: ConfirmationModal = ConfirmationModal(
                targetView: self.host.controller?.view,
                info: ConfirmationModal.Info(
                    title: title,
                    body: .text(message),
                    cancelTitle: "BUTTON_OK".localized(),
                    cancelStyle: .alert_text
                )
            )
            self.host.controller?.present(modal, animated: true)
        }
        let displayName = self.displayName.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        guard !displayName.isEmpty else {
            return showError(title: "vc_display_name_display_name_missing_error".localized())
        }
        guard !ProfileManager.isToLong(profileName: displayName) else {
            return showError(title: "vc_display_name_display_name_too_long_error".localized())
        }
        
        // Try to save the user name but ignore the result
        ProfileManager.updateLocal(
            queue: .global(qos: .default),
            profileName: displayName
        )
        
        // If we are not in the registration flow then we are finished and should go straight
        // to the home screen
        guard self.flow == .register else {
            self.flow.completeRegistration()
            
            // Go to the home screen
            let homeVC: HomeVC = HomeVC()
            self.host.controller?.navigationController?.setViewControllers([ homeVC ], animated: true)
            return
        }
        
        // Need to get the PN mode if registering
        let viewController: SessionHostingViewController = SessionHostingViewController(rootView: PNModeView(flow: flow))
        viewController.setUpNavBarSessionIcon()
        self.host.controller?.navigationController?.pushViewController(viewController, animated: true)
    }
}

struct DisplayNameView_Previews: PreviewProvider {
    static var previews: some View {
        DisplayNameView(flow: .register)
    }
}
