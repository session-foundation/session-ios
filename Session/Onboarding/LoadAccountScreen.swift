// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI
import SessionUIKit
import SignalUtilitiesKit
import SessionUtilitiesKit
import AVFoundation

struct LoadAccountScreen: View {
    @EnvironmentObject var host: HostWrapper
    private let dependencies: Dependencies
    
    @State var tabIndex = 0
    @State private var recoveryPassword: String = ""
    @State private var hexEncodedSeed: String = ""
    @State private var errorString: String? = nil
    
    public init(using dependencies: Dependencies) {
        self.dependencies = dependencies
    }
        
    var body: some View {
        ZStack(alignment: .topLeading) {
            ThemeColor(.backgroundPrimary).ignoresSafeArea()
            
            VStack(
                spacing: 0
            ){
                CustomTopTabBar(
                    tabIndex: $tabIndex,
                    tabTitles: [
                        "sessionRecoveryPassword".localized(),
                        "qrScan".localized()
                    ]
                ).frame(maxWidth: .infinity)
                    
                if tabIndex == 0 {
                    EnterRecoveryPasswordScreen(
                        $recoveryPassword,
                        error: $errorString,
                        continueWithMnemonic: continueWithMnemonic
                    )
                }
                else {
                    ScanQRCodeScreen(
                        $hexEncodedSeed,
                        error: $errorString,
                        continueAction: continueWithHexEncodedSeed,
                        using: dependencies
                    )
                }
            }
        }
    }
    
    private func continueWithSeed(seed: Data, from source: Onboarding.SeedSource, onSuccess: (() -> ())?, onError: (() -> ())?) {
        Task(priority: .userInitiated) {
            do {
                guard seed.count == 16 else { throw Mnemonic.DecodingError.generic }
                
                try await dependencies[singleton: .onboarding].setSeedData(seed)
            }
            catch {
                errorString = source.genericErrorMessage
                try await Task.sleep(for: .seconds(1))
                await MainActor.run { onError?() }
                return
            }
            
            Task {
                try await Task.sleep(for: .seconds(1))
                await MainActor.run { onSuccess?() }
            }
            
            await MainActor.run {
                // Otherwise continue on to request push notifications permissions
                let viewController: SessionHostingViewController = SessionHostingViewController(
                    rootView: PNModeScreen(using: dependencies)
                )
                viewController.setUpNavBarSessionIcon()
                self.host.controller?.navigationController?.pushViewController(viewController, animated: true)
            }
        }
    }
    
    func continueWithHexEncodedSeed(onSuccess: (() -> ())?, onError: (() -> ())?) {
        let seed = Data(hex: hexEncodedSeed)
        continueWithSeed(seed: seed, from: .qrCode, onSuccess: onSuccess, onError: onError)
    }
    
    func continueWithMnemonic() {
        do {
            let hexEncodedSeed: String = try Mnemonic.decode(mnemonic: recoveryPassword.lowercased())
            let seed: Data = Data(hex: hexEncodedSeed)
            continueWithSeed(seed: seed, from: .mnemonic, onSuccess: nil, onError: nil)
        } catch {
            switch error as? Mnemonic.DecodingError {
                case .some(.inputTooShort): errorString = "recoveryPasswordErrorMessageShort".localized()
                case .some(.invalidWord): errorString = "recoveryPasswordErrorMessageIncorrect".localized()
                default: errorString = "recoveryPasswordErrorMessageGeneric".localized()
            }
        }
    }
}

struct EnterRecoveryPasswordScreen: View{
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
                spacing: 0
            ) {
                Spacer(minLength: 0)
                
                HStack(
                    alignment: .bottom,
                    spacing: Values.smallSpacing
                ) {
                    Text("sessionRecoveryPassword".localized())
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
                
                Spacer(minLength: 0)
                    .frame(maxHeight: 2 * Values.mediumSpacing)
                
                Text("recoveryPasswordRestoreDescription".localized())
                    .font(.system(size: Values.smallFontSize))
                    .foregroundColor(themeColor: .textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                
                Spacer(minLength: 0)
                    .frame(maxHeight: 2 * Values.mediumSpacing)
                
                SessionTextField(
                    $recoveryPassword,
                    placeholder: "recoveryPasswordEnter".localized(),
                    error: $error, 
                    accessibility: Accessibility(identifier: "Recovery password input"),
                    inputChecker: { text in
                        let words: [String] = text
                            .components(separatedBy: .whitespacesAndNewlines)
                            .filter { !$0.isEmpty }
                        guard words.count < 14 else {
                            return "recoveryPasswordErrorMessageGeneric".localized()
                        }
                        return nil
                    }
                )
                
                Spacer(minLength: 0)
                    .frame(maxHeight: Values.massiveSpacing)
                
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Values.veryLargeSpacing)
            .padding(.bottom, Values.largeButtonHeight)
            
            VStack() {
                Spacer()
                
                Button {
                    continueWithMnemonic?()
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
}

struct LoadAccountView_Previews: PreviewProvider {
    static var previews: some View {
        LoadAccountScreen(using: Dependencies.createEmpty())
    }
}
