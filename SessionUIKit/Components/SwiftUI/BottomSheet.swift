// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI
import Lucide
import Combine

public struct BottomSheet<Content>: View where Content: View {
    @EnvironmentObject var host: HostWrapper
    let navigatableState: BottomSheetNavigatableState
    let hasCloseButton: Bool
    let content: () -> Content
    private var disposables: Set<AnyCancellable> = Set()

    let cornerRadius: CGFloat = 11
    let shadowRadius: CGFloat = 10
    let shadowOpacity: Double = 0.4

    @State private var show: Bool = true
    @State private var contentHeight: CGFloat = 80
    
    public init(
        navigatableState: BottomSheetNavigatableState,
        hasCloseButton: Bool,
        content: @escaping () -> Content)
    {
        self.navigatableState = navigatableState
        self.hasCloseButton = hasCloseButton
        self.content = content
        navigatableState.setupBindings(viewController: host.controller, disposables: &disposables)
    }

    public var body: some View {
        ZStack(alignment: .bottom) {
            // Background
            Rectangle()
                .fill(.ultraThinMaterial)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()
            
            // Bottom Sheet
            ZStack(alignment: .topTrailing) {
                content()
                
                if hasCloseButton {
                    Button {
                        close()
                    } label: {
                        AttributedText(Lucide.Icon.x.attributedString(size: 20))
                            .font(.system(size: 20))
                            .foregroundColor(themeColor: .textPrimary)
                    }
                    .frame(width: 24, height: 24)
                    .padding(Values.mediumSmallSpacing)
                }
            }
            .backgroundColor(themeColor: .backgroundPrimary)
            .cornerRadius(cornerRadius, corners: [.topLeft, .topRight])
            .shadow(color: Color.black.opacity(shadowOpacity), radius: shadowRadius)
            .frame(
                maxWidth: .infinity,
                alignment: .topTrailing
            )
            .padding(.top, 80)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .animation(.spring(), value: show)
        }
        .ignoresSafeArea(edges: .bottom)
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
        host.controller?.presentingViewController?.dismiss(animated: true)
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

// MARK: BottomSheetNavigatableStateHolder

public protocol BottomSheetNavigatableStateHolder {
    var navigatableState: BottomSheetNavigatableState { get }
}

public extension BottomSheetNavigatableStateHolder {
    func transitionToScreen(_ viewController: UIViewController, transitionType: TransitionType = .push) {
        navigatableState._transitionToScreen.send((viewController, transitionType))
    }
}

// MARK: BottomSheetNavigatableState

public struct BottomSheetNavigatableState {
    let transitionToScreen: AnyPublisher<(UIViewController, TransitionType), Never>
    
    // MARK: - Internal Variables
    
    fileprivate let _transitionToScreen: PassthroughSubject<(UIViewController, TransitionType), Never> = PassthroughSubject()
    
    // MARK: - Initialization
    
    init() {
        self.transitionToScreen = _transitionToScreen
            .subscribe(on: DispatchQueue.main)
            .eraseToAnyPublisher()
    }
    
    // MARK: - Functions
    
    public func setupBindings(
        viewController: UIViewController?,
        disposables: inout Set<AnyCancellable>
    ) {
        self.transitionToScreen
            .receive(on: DispatchQueue.main)
            .sink { [weak viewController] targetViewController, transitionType in
                switch transitionType {
                    case .push:
                        viewController?.navigationController?.pushViewController(targetViewController, animated: true)
                    
                    case .present:
                        let presenter: UIViewController? = (viewController?.presentedViewController ?? viewController)
                        
                        if UIDevice.current.isIPad {
                            targetViewController.popoverPresentationController?.permittedArrowDirections = []
                            targetViewController.popoverPresentationController?.sourceView = presenter?.view
                            targetViewController.popoverPresentationController?.sourceRect = (presenter?.view.bounds ?? UIScreen.main.bounds)
                        }
                        
                        presenter?.present(targetViewController, animated: true)
                }
            }
            .store(in: &disposables)
    }
}
