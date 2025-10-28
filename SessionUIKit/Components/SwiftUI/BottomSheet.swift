// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI
import Lucide

public struct BottomSheet<Content>: View where Content: View {
    let host: HostWrapper
    let dismissType: Modal.DismissType
    let hasCloseButton: Bool
    let afterClosed: (() -> Void)?
    let content: (@escaping ((() -> Void)?) -> Void) -> Content

    let cornerRadius: CGFloat = 11
    let shadowRadius: CGFloat = 10
    let shadowOpacity: Double = 0.4

    @State private var show: Bool = true

    public var body: some View {
        ZStack(alignment: .bottom) {
            // Background
            Rectangle()
                .fill(.ultraThinMaterial)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()
                .onTapGesture { close() }
            
            // Bottom Sheet
            VStack {
                Spacer()
                
                ZStack(alignment: .topTrailing) {
                    content { internalAfterClosed in
                        close(internalAfterClosed)
                    }
                    
                    if hasCloseButton {
                        Button {
                            close(nil)
                        } label: {
                            AttributedText(Lucide.Icon.x.attributedString(size: 20))
                                .font(.system(size: 20))
                                .foregroundColor(themeColor: .textPrimary)
                        }
                        .frame(width: 24, height: 24)
                        .padding(Values.mediumSmallSpacing)
                    }
                }
                .backgroundColor(themeColor: .alert_background)
                .cornerRadius(cornerRadius, corners: [.topLeft, .topRight])
                .shadow(color: Color.black.opacity(shadowOpacity), radius: shadowRadius)
                .frame(
                    maxWidth: .infinity,
                    alignment: .topTrailing
                )
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .animation(.spring(), value: show)
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

    private func close(_ internalAfterClosed: (() -> Void)? = nil) {
        host.controller?.presentingViewController?.dismiss(
            animated: true,
            completion: {
                afterClosed?()
                internalAfterClosed?()
            }
        )
    }
}

// MARK: - ModalHostingViewController

open class BottomSheetHostingViewController<Content>: UIHostingController<ModifiedContent<Content, _EnvironmentKeyWritingModifier<HostWrapper?>>> where Content: View {
    public init(bottomSheet: Content) {
        let container = HostWrapper()
        let modified = bottomSheet.environmentObject(container) as! ModifiedContent<Content, _EnvironmentKeyWritingModifier<HostWrapper?>>
        super.init(rootView: modified)
        container.controller = self
        self.modalTransitionStyle = .coverVertical
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
