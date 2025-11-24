// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI
import Lucide
import Combine

private struct SizePreferenceKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        // Use the last non-zero size reported
        if next != .zero { value = next }
    }
}

public struct BottomSheet<Content>: View where Content: View {
    @EnvironmentObject var host: HostWrapper
    @State private var disposables: Set<AnyCancellable> = Set()
    
    let hasCloseButton: Bool
    let afterClosed: (() -> Void)?
    let content: () -> Content

    let cornerRadius: CGFloat = 11
    let shadowRadius: CGFloat = 10
    let shadowOpacity: Double = 0.4

    @State private var show: Bool = false
    @State private var topPadding: CGFloat = 80
    @State private var contentSize: CGSize = .zero
    
    public init(
        hasCloseButton: Bool,
        afterClosed: (() -> Void)? = nil,
        content: @escaping () -> Content)
    {
        self.hasCloseButton = hasCloseButton
        self.afterClosed = afterClosed
        self.content = content
    }

    public var body: some View {
        ZStack(alignment: .bottom) {
            // Background
            Rectangle()
                .fill(.ultraThinMaterial)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()
            
            if show {
                VStack(spacing: Values.verySmallSpacing) {
                    Capsule()
                        .fill(themeColor: .value(.textPrimary, alpha: 0.8))
                        .frame(width: 35, height: 3)
                    
                    // Bottom Sheet
                    ZStack(alignment: .topTrailing) {
                        NavigationView {
                            // Important: no top-level GeometryReader here that would expand.
                            content()
                                .navigationTitle("")
                                .padding(.top, 44)
                                .background(
                                    GeometryReader { proxy in
                                        Color.clear
                                            .preference(key: SizePreferenceKey.self, value: proxy.size)
                                    }
                                    .backgroundColor(themeColor: .backgroundPrimary)
                                )
                        }
                        .navigationViewStyle(.stack)
                        
                        if hasCloseButton {
                            Button {
                                close()
                            } label: {
                                AttributedText(Lucide.Icon.x.attributedString(size: 28))
                                    .font(.system(size: 28, weight: .bold))
                                    .foregroundColor(themeColor: .textPrimary)
                            }
                            .frame(width: 28, height: 28)
                            .padding(Values.smallSpacing)
                        }
                    }
                    .backgroundColor(themeColor: .backgroundPrimary)
                    .cornerRadius(cornerRadius, corners: [.topLeft, .topRight])
                    .frame(
                        maxWidth: .infinity,
                        alignment: .topTrailing
                    )
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .onPreferenceChange(SizePreferenceKey.self) { size in
                    contentSize = size
                    recomputeTopPadding()
                }
                .onAppear {
                    recomputeTopPadding()
                }
                .padding(.top, topPadding)
            }
        }
        .ignoresSafeArea(edges: .bottom)
        .onAppear {
            withAnimation {
                show.toggle()
            }
        }
        .frame(
            maxWidth: .infinity,
            maxHeight: .infinity,
            alignment: .bottom
        )
        .gesture(
            DragGesture(minimumDistance: 20, coordinateSpace: .global)
                .onEnded { value in
                    if value.translation.height > 40 {
                        close()
                    }
                }
        )
    }

    // MARK: - Dismiss Logic

    private func close() {
        withAnimation {
            show.toggle()
        }
        host.controller?.presentingViewController?.dismiss(animated: true)
        afterClosed?()
    }
    
    // MARK: - Layout helpers
    
    private func recomputeTopPadding() {
        let screenHeight = UIScreen.main.bounds.height
        let bottomSafeInset = host.controller?.view.safeAreaInsets.bottom ?? 0
        
        let handleHeight: CGFloat = 3
        let handleSpacing: CGFloat = Values.verySmallSpacing
        let headerHeight: CGFloat = handleHeight + handleSpacing + 44
        
        let totalSheetHeight = headerHeight + contentSize.height + Values.veryLargeSpacing
        
        let computed = screenHeight - bottomSafeInset - totalSheetHeight
        topPadding = max(bottomSafeInset, computed)
    }
}

// MARK: - BottomSheetHostingViewController

open class BottomSheetHostingViewController<Content>: UIHostingController<ModifiedContent<Content, _EnvironmentKeyWritingModifier<HostWrapper?>>> where Content: View {
    public init(bottomSheet: Content) {
        let container = HostWrapper()
        let modified = bottomSheet.environmentObject(container) as! ModifiedContent<Content, _EnvironmentKeyWritingModifier<HostWrapper?>>
        super.init(rootView: modified)
        container.controller = self
        self.modalTransitionStyle = .crossDissolve
        self.modalPresentationStyle = .overFullScreen
    }
    
    required public init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    public override func viewDidLoad() {
        super.viewDidLoad()
        
        navigationItem.backButtonTitle = ""
        view.themeBackgroundColor = .clear
        ThemeManager.applyNavigationStylingIfNeeded(to: self)

        setNeedsStatusBarAppearanceUpdate()
    }
}

