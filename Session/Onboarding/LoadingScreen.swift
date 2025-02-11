// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI
import SessionUIKit
import SessionMessagingKit
import SignalUtilitiesKit
import SessionUtilitiesKit

struct LoadingScreen: View {
    @EnvironmentObject var host: HostWrapper
    
    @State var percentage: Double = 0.0
    @State var animationTimer: Timer?
    
    private let dependencies: Dependencies
    private let flow: Onboarding.Flow
    private let preview: Bool
    
    public init(flow: Onboarding.Flow, preview: Bool = false, using dependencies: Dependencies) {
        self.dependencies = dependencies
        self.flow = flow
        self.preview = preview
    }
    
    var body: some View {
        ZStack(alignment: .center) {
            ThemeManager.currentTheme.colorSwiftUI(for: .backgroundPrimary).ignoresSafeArea()
            
            VStack(
                alignment: .center,
                spacing: Values.mediumSpacing
            ) {
                Spacer()
                
                CircularProgressView($percentage)
                    .accessibility(
                        Accessibility(
                            identifier: "Loading animation",
                            label: "Loading animation"
                        )
                    )
                    .padding(.horizontal, Values.massiveSpacing)
                    .padding(.bottom, Values.mediumSpacing)
                    .onAppear {
                        progress()
                        observeProfileRetrieving()
                    }
                
                Text("waitOneMoment".localized())
                    .bold()
                    .font(.system(size: Values.mediumLargeFontSize))
                    .foregroundColor(themeColor: .textPrimary)
                
                Text("loadAccountProgressMessage".localized())
                    .font(.system(size: Values.smallFontSize))
                    .foregroundColor(themeColor: .textPrimary)
                
                Spacer()
            }
            .padding(.horizontal, Values.veryLargeSpacing)
            .padding(.bottom, Values.massiveSpacing + Values.largeButtonHeight)
        }
    }
    
    private func progress() {
        animationTimer = Timer.scheduledTimerOnMainThread(
            withTimeInterval: 0.15,
            repeats: true
        ) { timer in
            self.percentage += 0.01
            if percentage >= 1 {
                self.percentage = 1
                timer.invalidate()
                if !self.preview { finishLoading(success: false) }
            }
        }
    }
    
    private func observeProfileRetrieving() {
        Onboarding.profileNamePublisher
            .subscribe(on: DispatchQueue.global(qos: .userInitiated))
            .receive(on: DispatchQueue.main)
            .sinkUntilComplete(
                receiveValue: { displayName in
                    if displayName?.isEmpty == false {
                        finishLoading(success: true)
                    }
                }
            )
    }
    
    private func finishLoading(success: Bool) {
        guard success else {
            let viewController: SessionHostingViewController = SessionHostingViewController(
                rootView: DisplayNameScreen(flow: flow, using: dependencies)
            )
            viewController.setUpNavBarSessionIcon()
            if let navigationController = self.host.controller?.navigationController {
                let index = navigationController.viewControllers.count - 1
                navigationController.pushViewController(viewController, animated: true)
                navigationController.viewControllers.remove(at: index)
            }
            return
        }
        self.animationTimer?.invalidate()
        self.animationTimer = nil
        withAnimation(.linear(duration: 0.3)) {
            self.percentage = 1
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [dependencies] in
            self.flow.completeRegistration(using: dependencies)
            
            let homeVC: HomeVC = HomeVC(flow: self.flow, using: dependencies)
            self.host.controller?.navigationController?.setViewControllers([ homeVC ], animated: true)
        }
        
    }
}

struct AnimatableNumberModifier: AnimatableModifier {
    var number: Double
    
    var animatableData: Double {
        get { number }
        set { number = newValue }
    }
    
    func body(content: Content) -> some View {
        content
            .overlay(
                Text(String(format: "%.0f%%", number))
                    .bold()
                    .font(.system(size: Values.superLargeFontSize))
                    .foregroundColor(themeColor: .textPrimary)
            )
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
        }
        .modifier(AnimatableNumberModifier(number: $percentage.wrappedValue * 100))
    }
}

struct LoadingView_Previews: PreviewProvider {
    static var previews: some View {
        LoadingScreen(flow: .recover, preview: true, using: Dependencies())
    }
}
