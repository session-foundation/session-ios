// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI

public struct Modal_SwiftUI<Content>: View where Content: View {
    let host: HostWrapper
    let dismissType: Modal.DismissType
    let afterClosed: (() -> Void)?
    let content: (@escaping @MainActor ((() -> Void)?) -> Void) -> Content

    let cornerRadius: CGFloat = 11
    let shadowRadius: CGFloat = 10
    let shadowOpacity: Double = 0.4

    @State private var show: Bool = true

    public var body: some View {
        ZStack {
            // Background
            Rectangle()
                .fill(.ultraThinMaterial)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()
                .onTapGesture { close() }
            
            // Modal
            VStack {
                Spacer()
                
                VStack(spacing: 0) {
                    content { internalAfterClosed in
                        close(internalAfterClosed)
                    }
                }
                .backgroundColor(themeColor: .alert_background)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .shadow(color: Color.black.opacity(shadowOpacity), radius: shadowRadius)
                .frame(
                    maxWidth: UIDevice.current.isIPad ? Values.iPadModalWidth : .infinity
                )
                .padding(.horizontal, UIDevice.current.isIPad ? 0 : Values.veryLargeSpacing)
                
                Spacer()
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .animation(.spring(), value: show)
            
        }
        .frame(
            maxWidth: .infinity,
            maxHeight: .infinity
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

    @MainActor private func close(_ internalAfterClosed: (() -> Void)? = nil) {
        // Recursively dismiss all modals (ie. find the first modal presented by a non-modal
        // and get that to dismiss it's presented view controller)
        var targetViewController: UIViewController? = host.controller
        
        switch dismissType {
            case .single: break
            case .recursive:
                while targetViewController?.presentingViewController is ModalHostIdentifiable {
                    targetViewController = targetViewController?.presentingViewController
                }
        }
        
        targetViewController?.presentingViewController?.dismiss(
            animated: true,
            completion: {
                afterClosed?()
                internalAfterClosed?()
            }
        )
    }
}

// MARK: - ModalHostIdentifiable

protocol ModalHostIdentifiable {}

// MARK: - ModalHostingViewController

open class ModalHostingViewController<Content>: UIHostingController<ModifiedContent<Content, _EnvironmentKeyWritingModifier<HostWrapper?>>>, ModalHostIdentifiable where Content: View {
    public init(modal: Content) {
        let container = HostWrapper()
        let modified = modal.environmentObject(container) as! ModifiedContent<Content, _EnvironmentKeyWritingModifier<HostWrapper?>>
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
