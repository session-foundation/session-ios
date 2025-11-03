// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SwiftUI
import Combine

public enum SessionListScreenContent {}

// MARK: - ViewModelType

public extension SessionListScreenContent {
    protocol ViewModelType: ObservableObject, SectionedListItemData {
        var title: String { get }
        var state: ListItemDataState<Section, ListItem> { get }
    }
}

// MARK: - Navigatable

public extension SessionListScreenContent {
    struct NavigationDestination: Identifiable {
        public let id = UUID()
        public let view: AnyView
        
        public init<V: View>(_ view: V) {
            self.view = AnyView(view)
        }
    }
    
    protocol NavigatableStateHolder {
        var navigatableState: NavigatableState { get }
    }
    
    struct NavigatableState {
        let transitionToScreen: AnyPublisher<(NavigationDestination, TransitionType), Never>
        let dismissScreen: AnyPublisher<(DismissType, (() -> Void)?), Never>
        
        // MARK: - Internal Variables

        fileprivate let _transitionToScreen: PassthroughSubject<(NavigationDestination, TransitionType), Never> = PassthroughSubject()
        fileprivate let _dismissScreen: PassthroughSubject<(DismissType, (() -> Void)?), Never> = PassthroughSubject()
        
        // MARK: - Initialization
        
        public init() {
            self.transitionToScreen = _transitionToScreen.eraseToAnyPublisher()
            self.dismissScreen = _dismissScreen.eraseToAnyPublisher()
        }
        
        // MARK: - Functions
        
        public func setupBindings(
            viewController: UIViewController,
            disposables: inout Set<AnyCancellable>
        ) {
            self.transitionToScreen
                .receive(on: DispatchQueue.main)
                .sink { [weak viewController] destination, transitionType in
                    let targetViewController = SessionHostingViewController(rootView: destination.view)
                    
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
                .sink { [weak viewController] dismissType, completion in
                    switch dismissType {
                        case .auto:
                            guard
                                let viewController: UIViewController = viewController,
                                (viewController.navigationController?.viewControllers.firstIndex(of: viewController) ?? 0) > 0
                            else {
                                viewController?.dismiss(animated: true, completion: completion)
                                return
                            }
                            
                            viewController.navigationController?.popViewController(animated: true, completion: completion)
                            
                        case .dismiss: viewController?.dismiss(animated: true, completion: completion)
                        case .pop: viewController?.navigationController?.popViewController(animated: true, completion: completion)
                        case .popToRoot: viewController?.navigationController?.popToRootViewController(animated: true, completion: completion)
                    }
                }
                .store(in: &disposables)
        }
    }
}

public extension SessionListScreenContent.NavigatableStateHolder {
    func dismissScreen(type: DismissType = .auto, completion: (() -> Void)? = nil) {
        navigatableState._dismissScreen.send((type, completion))
    }
    
    func transitionToScreen<V: View>(_ view: V, transitionType: TransitionType = .push) {
        navigatableState._transitionToScreen.send((SessionListScreenContent.NavigationDestination(view), transitionType))
    }
}
