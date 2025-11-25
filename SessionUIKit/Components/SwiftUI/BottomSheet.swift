// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI
import Lucide
import Combine

private struct SizePreferenceKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

public struct BottomSheet<Content>: View where Content: View {
    @EnvironmentObject var host: HostWrapper
    @State private var disposables: Set<AnyCancellable> = Set()
    @StateObject private var toolbarManager: ToolbarManager
    
    let hasCloseButton: Bool
    let afterClosed: (() -> Void)?
    let content: () -> Content

    let cornerRadius: CGFloat = 11
    let shadowRadius: CGFloat = 10
    let shadowOpacity: Double = 0.4

    @State private var show: Bool = false
    @State private var topPadding: CGFloat = 80
    @State private var contentSize: CGSize = .zero
    @State private var dragOffset: CGFloat = 0
    
    public init(
        hasCloseButton: Bool,
        afterClosed: (() -> Void)? = nil,
        content: @escaping () -> Content)
    {
        self.hasCloseButton = hasCloseButton
        _toolbarManager = StateObject(wrappedValue: ToolbarManager(hasCloseButton: hasCloseButton))
        self.afterClosed = afterClosed
        self.content = content
    }

    public var body: some View {
        ZStack(alignment: .bottom) {
            // Background
            Rectangle()
                .fill(.ultraThinMaterial)
                .opacity(backgroundOpacity)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()
                .onTapGesture {
                    close()
                }
            
            if show {
                VStack(spacing: Values.verySmallSpacing) {
                    Capsule()
                        .fill(themeColor: .value(.textPrimary, alpha: 0.8))
                        .frame(width: 35, height: 3)
                    
                    ZStack(alignment: .topTrailing) {
                        NavigationView {
                            ZStack {
                                Rectangle()
                                    .fill(themeColor: .backgroundPrimary)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                                    .ignoresSafeArea()

                                content()
                                    .navigationTitle("")
                                    .persistentCloseToolbar()
                                    .environmentObject(toolbarManager)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                        .navigationViewStyle(.stack)
                    }
                    .cornerRadius(cornerRadius, corners: [.topLeft, .topRight])
                    .frame(maxWidth: .infinity, alignment: .topTrailing)
                }
                .background(
                    GeometryReader { proxy in
                        Color.clear
                            .preference(key: SizePreferenceKey.self, value: proxy.size)
                    }
                )
                .offset(y: max(0, dragOffset))
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .onPreferenceChange(SizePreferenceKey.self) { size in
                    contentSize = size
                    recomputeTopPadding()
                }
                .onAppear { recomputeTopPadding() }
                .padding(.top, topPadding)
            }
        }
        .ignoresSafeArea(edges: .bottom)
        .onAppear {
            toolbarManager.setCloseAction {
                close()
            }
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
            DragGesture(minimumDistance: 10, coordinateSpace: .global)
                .onChanged { value in
                    // Only allow downward movement; clamp upward drags to 0
                    let translation = value.translation.height
                    withAnimation {
                        dragOffset = max(0, translation)
                    }
                }
                .onEnded { value in
                    let translation = max(0, value.translation.height)
                    let velocity = value.velocity.height
                    let threshold: CGFloat = max(120, contentSize.height * 0.25)
                    if translation > threshold || velocity > 1200 {
                        close()
                    } else {
                        withAnimation {
                            dragOffset = 0
                        }
                    }
                }
        )
    }
    
    private var backgroundOpacity: Double {
        let fade = min(1.0, Double(dragOffset / 300))
        return max(0.2, 1.0 - fade * 0.8)
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
        let headerHeight: CGFloat = handleHeight + handleSpacing
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

private extension DragGesture.Value {
    var velocity: CGSize {
        let dt: CGFloat = 0.016
        let dx = (predictedEndLocation.x - location.x) / dt
        let dy = (predictedEndLocation.y - location.y) / dt
        return CGSize(width: dx, height: dy)
    }
}
