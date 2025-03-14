// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import Combine
import SessionUIKit
import SessionUtilitiesKit
import SignalUtilitiesKit

// MARK: - NavigatableStateHolder

public protocol NavigatableStateHolder {
    var navigatableState: NavigatableState { get }
}

public extension NavigatableStateHolder {
    func showToast(text: String, backgroundColor: ThemeValue = .backgroundPrimary, inset: CGFloat = Values.largeSpacing) {
        navigatableState._showToast.send((NSAttributedString(string: text), backgroundColor, inset))
    }
    
    func showToast(text: NSAttributedString, backgroundColor: ThemeValue = .backgroundPrimary, inset: CGFloat = Values.largeSpacing) {
        navigatableState._showToast.send((text, backgroundColor, inset))
    }
    
    func dismissScreen(type: DismissType = .auto) {
        navigatableState._dismissScreen.send(type)
    }
    
    func transitionToScreen(_ viewController: UIViewController, transitionType: TransitionType = .push) {
        navigatableState._transitionToScreen.send((viewController, transitionType))
    }
}

// MARK: - NavigatableState

public struct NavigatableState {
    let showToast: AnyPublisher<(NSAttributedString, ThemeValue, CGFloat), Never>
    let transitionToScreen: AnyPublisher<(UIViewController, TransitionType), Never>
    let dismissScreen: AnyPublisher<DismissType, Never>
    
    // MARK: - Internal Variables
    
    fileprivate let _showToast: PassthroughSubject<(NSAttributedString, ThemeValue, CGFloat), Never> = PassthroughSubject()
    fileprivate let _transitionToScreen: PassthroughSubject<(UIViewController, TransitionType), Never> = PassthroughSubject()
    fileprivate let _dismissScreen: PassthroughSubject<DismissType, Never> = PassthroughSubject()
    
    // MARK: - Initialization
    
    init() {
        self.showToast = _showToast.shareReplay(0)
        self.transitionToScreen = _transitionToScreen.shareReplay(0)
        self.dismissScreen = _dismissScreen.shareReplay(0)
    }
    
    // MARK: - Functions
    
    public func setupBindings(
        viewController: UIViewController,
        disposables: inout Set<AnyCancellable>
    ) {
        self.showToast
            .receive(on: DispatchQueue.main)
            .sink { [weak viewController] text, color, inset in
                guard let presenter: UIViewController = (viewController?.presentedViewController ?? viewController) else {
                    return
                }
                
                let toastController: ToastController = ToastController(text: text, background: color)
                toastController.presentToastView(fromBottomOfView: presenter.view, inset: inset)
            }
            .store(in: &disposables)
        
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
        
        self.dismissScreen
            .receive(on: DispatchQueue.main)
            .sink { [weak viewController] dismissType in
                switch dismissType {
                    case .auto:
                        guard
                            let viewController: UIViewController = viewController,
                            (viewController.navigationController?.viewControllers
                                .firstIndex(of: viewController))
                                .defaulting(to: 0) > 0
                        else {
                            viewController?.dismiss(animated: true)
                            return
                        }
                        
                        viewController.navigationController?.popViewController(animated: true)
                        
                    case .dismiss: viewController?.dismiss(animated: true)
                    case .pop: viewController?.navigationController?.popViewController(animated: true)
                    case .popToRoot: viewController?.navigationController?.popToRootViewController(animated: true)
                }
            }
            .store(in: &disposables)
    }
}

public extension Publisher {
    func showingBlockingLoading(in navigatableState: NavigatableState?) -> AnyPublisher<Output, Failure> {
        guard let navigatableState: NavigatableState = navigatableState else {
            return self.eraseToAnyPublisher()
        }
        
        var modalActivityIndicator: ModalActivityIndicatorViewController?
        
        switch Thread.isMainThread {
            case true: modalActivityIndicator = ModalActivityIndicatorViewController(onAppear: { _ in })
            case false:
                DispatchQueue.main.sync {
                    modalActivityIndicator = ModalActivityIndicatorViewController(onAppear: { _ in })
                }
                
        }
        
        return self
            .handleEvents(
                receiveSubscription: { _ in
                    guard let indicator: ModalActivityIndicatorViewController = modalActivityIndicator else {
                        return
                    }
                    
                    navigatableState._transitionToScreen.send((indicator, .present))
                }
            )
            .asResult()
            .flatMap { result -> AnyPublisher<Output, Failure> in
                Deferred {
                    Future<Output, Failure> { resolver in
                        modalActivityIndicator?.dismiss(completion: {
                            resolver(result)
                        })
                    }
                }.eraseToAnyPublisher()
            }
            .eraseToAnyPublisher()
    }
}
