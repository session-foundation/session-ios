// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI
import SessionUIKit
import SessionMessagingKit
import SignalUtilitiesKit

struct LoadingView: View {
    @EnvironmentObject var host: HostWrapper
    
    @State var percentage: Double = 0.0
    
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
                    alignment: .center,
                    spacing: Values.mediumSpacing
                ) {
                    Spacer()
                    
                    CircularProgressView($percentage)
                        .padding(.horizontal, Values.massiveSpacing)
                        .padding(.bottom, Values.mediumSpacing)
                        .onAppear {
                            progress()
                        }
                    
                    Text("onboarding_load_account_waiting".localized())
                        .bold()
                        .font(.system(size: Values.mediumLargeFontSize))
                        .foregroundColor(themeColor: .textPrimary)
                    
                    Text("onboarding_loading_account".localized())
                        .font(.system(size: Values.smallFontSize))
                        .foregroundColor(themeColor: .textPrimary)
                    
                    Spacer()
                }
                .padding(.horizontal, Values.veryLargeSpacing)
                .padding(.bottom, Values.massiveSpacing + Values.largeButtonHeight)
            }
        }
    }
    
    private func progress() {
        Timer.scheduledTimerOnMainThread(
            withTimeInterval: 0.15,
            repeats: true
        ) { timer in
            self.percentage += 0.01
            if percentage >= 1 {
                self.percentage = 1
                timer.invalidate()
                finishLoading()
            }
        }
    }
    
    private func finishLoading() {
        let viewController: SessionHostingViewController = SessionHostingViewController(rootView: DisplayNameView(flow: flow))
        viewController.setUpNavBarSessionIcon()
        self.host.controller?.navigationController?.pushViewController(viewController, animated: true)
    }
}

struct CircularProgressView: View {
    @Binding var percentage: Double
    
    private var progress: Double {
        return $percentage.wrappedValue * 0.85
    }
    
    init(_ percentage: Binding<Double>) {
        self._percentage = percentage
    }
    
    var body: some View {
        ZStack {
            Circle()
                .trim(from: 0, to: 0.85)
                .stroke(
                    themeColor: .borderSeparator,
                    style: StrokeStyle(
                        lineWidth: 20,
                        lineCap: .round
                    )
                )
                .rotationEffect(.degrees(117))
            
            Circle()
                .trim(from: 0, to: progress)
                .stroke(
                    themeColor: .primary,
                    style: StrokeStyle(
                        lineWidth: 20,
                        lineCap: .round
                    )
                )
                .rotationEffect(.degrees(117))
                .animation(.easeOut, value: progress)
            
            Text(String(format: "%.0f%%", $percentage.wrappedValue * 100))
                .bold()
                .font(.system(size: Values.superLargeFontSize))
                .foregroundColor(themeColor: .textPrimary)
        }
    }
}

struct LoadingView_Previews: PreviewProvider {
    static var previews: some View {
        LoadingView(flow: .link)
    }
}
