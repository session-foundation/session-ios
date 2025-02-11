// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI
import Combine
import SessionUIKit
import SessionSnodeKit
import SignalUtilitiesKit
import SessionUtilitiesKit

enum PNMode {
    case fast
    case slow
}

struct PNModeScreen: View {
    @EnvironmentObject var host: HostWrapper
    
    @State private var currentSelection: PNMode = .fast
    
    private let dependencies: Dependencies
    private let flow: Onboarding.Flow
    
    public init(flow: Onboarding.Flow, using dependencies: Dependencies) {
        self.dependencies = dependencies
        self.flow = flow
    }
    
    let options: [PNOptionView.Info] = [
        PNOptionView.Info(
            mode: .fast,
            title: "notificationsFastMode".localized(),
            explanation: "notificationsFastModeDescriptionIos".localized(),
            isRecommended: true,
            accessibility: Accessibility(
                identifier: "Fast mode notifications button",
                label: "Fast mode notifications button"
            )
        ),
        PNOptionView.Info(
            mode: .slow,
            title: "notificationsSlowMode".localized(),
            explanation: "notificationsSlowModeDescription"
                .put(key: "app_name", value: Constants.app_name)
                .localized(),
            isRecommended: false,
            accessibility: Accessibility(
                identifier: "Slow mode notifications button",
                label: "Slow mode notifications button"
            )
        )
    ]
    
    var body: some View {
        ZStack(alignment: .center) {
            ThemeManager.currentTheme.colorSwiftUI(for: .backgroundPrimary).ignoresSafeArea()
            
            VStack(
                alignment: .leading,
                spacing: Values.mediumSpacing
            ) {
                Spacer()
                
                Text("notificationsMessage".localized())
                    .bold()
                    .font(.system(size: Values.veryLargeFontSize))
                    .foregroundColor(themeColor: .textPrimary)
                
                Text(
                    "onboardingMessageNotificationExplanation"
                        .put(key: "app_name", value: Constants.app_name)
                        .localized()
                )
                .font(.system(size: Values.smallFontSize))
                .foregroundColor(themeColor: .textPrimary)
                .padding(.vertical, Values.mediumSpacing)
                
                VStack(
                    alignment: .leading,
                    spacing: Values.mediumSpacing)
                {
                    ForEach(
                        0...(options.count - 1),
                        id: \.self
                    ) { index in
                        PNOptionView(
                            currentSelection: $currentSelection,
                            info: options[index]
                        )
                        .accessibility(options[index].accessibility)
                    }
                }
                
                Spacer()
            }
            .padding(.horizontal, Values.veryLargeSpacing)
            .padding(.bottom, Values.massiveSpacing + Values.largeButtonHeight)
            
            VStack() {
                Spacer()
                
                Button {
                    register()
                } label: {
                    Text("theContinue".localized())
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
                .accessibility(
                    Accessibility(
                        identifier: "Continue",
                        label: "Continue"
                    )
                )
                .padding(.horizontal, Values.massiveSpacing)
            }
            .padding(.vertical, Values.mediumSpacing)
        }
    }
    
    private func register() {
        UserDefaults.standard[.isUsingFullAPNs] = (currentSelection == .fast)
        
        // If we are registering then we can just continue on
        guard flow != .register else {
            return finishRegister()
        }
        
        // Check if we already have a profile name (ie. profile retrieval completed while waiting on
        // this screen)
        let existingProfileName: String? = Storage.shared
            .read { db in
                try Profile
                    .filter(id: getUserHexEncodedPublicKey(db))
                    .select(.name)
                    .asRequest(of: String.self)
                    .fetchOne(db)
            }
        
        guard existingProfileName?.isEmpty != false else {
            // If we have one then we can go straight to the home screen
            return finishRegister()
        }
        
        // If we don't have one then show a loading indicator and try to retrieve the existing name
        let viewController: SessionHostingViewController = SessionHostingViewController(
            rootView: LoadingScreen(flow: flow, using: dependencies)
        )
        viewController.setUpNavBarSessionIcon()
        self.host.controller?.navigationController?.pushViewController(viewController, animated: true)
    }
    
    private func finishRegister() {
        self.flow.completeRegistration(using: dependencies)
        
        let homeVC: HomeVC = HomeVC(flow: self.flow, using: dependencies)
        self.host.controller?.navigationController?.setViewControllers([ homeVC ], animated: true)
        return
    }
}

struct PNOptionView: View {
    
    struct Info {
        let mode: PNMode
        let title: String
        let explanation: String
        let isRecommended: Bool
        let accessibility: Accessibility
    }
    
    @Binding var currentSelection: PNMode
    
    let info: Info
    
    static let cornerRadius: CGFloat = 8
    static let radioBorderSize: CGFloat = 22
    static let radioSelectionSize: CGFloat = 17
    
    var body: some View {
        HStack(
            spacing: Values.largeSpacing
        ) {
            VStack(
                alignment: .leading,
                spacing: Values.smallSpacing
            ) {
                Text(info.title)
                    .bold()
                    .font(.system(size: Values.mediumFontSize))
                    .foregroundColor(themeColor: .textPrimary)
                
                Text(info.explanation)
                    .font(.system(size: Values.verySmallFontSize))
                    .foregroundColor(themeColor: .textPrimary)
                    .frame(
                        maxWidth: .infinity,
                        alignment: .leading
                    )
                
                if info.isRecommended {
                    Text("recommended".localized())
                        .bold()
                        .font(.system(size: Values.smallFontSize))
                        .foregroundColor(themeColor: .primary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.all, Values.mediumSpacing)
            .overlay(
                RoundedRectangle(
                    cornerSize: CGSize(
                        width: Self.cornerRadius,
                        height: Self.cornerRadius
                    )
                )
                .stroke(themeColor: .borderSeparator)
            )
            
            ZStack(alignment: .center) {
                Circle()
                    .stroke(themeColor: .textPrimary)
                    .frame(
                        width: Self.radioBorderSize,
                        height: Self.radioBorderSize
                    )
                
                if currentSelection == info.mode {
                    Circle()
                        .fill(themeColor: .primary)
                        .frame(
                            width: Self.radioSelectionSize,
                            height: Self.radioSelectionSize
                        )
                }
            }
            .accessibility(info.accessibility)
        }
        .frame(
            maxWidth: .infinity
        )
        .contentShape(Rectangle())
        .onTapGesture {
            currentSelection = info.mode
        }
    }
}

struct PNModeView_Previews: PreviewProvider {
    static var previews: some View {
        PNModeScreen(flow: .register, using: Dependencies())
    }
}
