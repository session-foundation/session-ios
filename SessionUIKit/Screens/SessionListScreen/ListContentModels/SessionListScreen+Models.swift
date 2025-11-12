// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import UIKit
import SwiftUI
import Combine

public enum SessionListScreenContent {}

// MARK: - ViewModelType

public extension SessionListScreenContent {
    protocol ViewModelType: ObservableObject, SectionedListItemData {
        var title: String { get }
        var state: ListItemDataState<Section, ListItem> { get }
    }
    
    struct TooltipInfo: Hashable, Equatable {
        let id: String
        let content: ThemedAttributedString
        let tintColor: ThemeValue
        let position: ViewPosition
        
        public init(
            id: String,
            content: ThemedAttributedString,
            tintColor: ThemeValue,
            position: ViewPosition
        ) {
            self.id = id
            self.content = content
            self.tintColor = tintColor
            self.position = position
            
        }
    }
    
    struct TextInfo: Hashable, Equatable {
        public enum Accessory: Hashable, Equatable {
            case proBadgeLeading(themeBackgroundColor: ThemeValue)
            case proBadgeTrailing(themeBackgroundColor: ThemeValue)
            case none
        }
        
        let text: String?
        let font: Font?
        let attributedString: ThemedAttributedString?
        let alignment: TextAlignment
        let color: ThemeValue
        let accessory: Accessory
        let accessibility: Accessibility?
        
        public init(
            _ text: String? = nil,
            font: Font? = nil,
            attributedString: ThemedAttributedString? = nil,
            alignment: TextAlignment = .leading,
            color: ThemeValue = .textPrimary,
            accessory: Accessory = .none,
            accessibility: Accessibility? = nil
        ) {
            self.text = text
            self.font = font
            self.attributedString = attributedString
            self.alignment = alignment
            self.color = color
            self.accessory = accessory
            self.accessibility = accessibility
        }
        
        // MARK: - Conformance
        
        public func hash(into hasher: inout Hasher) {
            text.hash(into: &hasher)
            font.hash(into: &hasher)
            attributedString.hash(into: &hasher)
            alignment.hash(into: &hasher)
            color.hash(into: &hasher)
            accessory.hash(into: &hasher)
            accessibility.hash(into: &hasher)
        }
        
        public static func == (lhs: TextInfo, rhs: TextInfo) -> Bool {
            return (
                lhs.text == rhs.text &&
                lhs.font == rhs.font &&
                lhs.attributedString == rhs.attributedString &&
                lhs.alignment == rhs.alignment &&
                lhs.color == rhs.color &&
                lhs.accessory == rhs.accessory &&
                lhs.accessibility == rhs.accessibility
            )
        }
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
        let transitionToViewController: AnyPublisher<(UIViewController, TransitionType), Never>
        let transitionToScreen: AnyPublisher<(NavigationDestination, TransitionType), Never>
        let dismissScreen: AnyPublisher<(DismissType, (() -> Void)?), Never>
        
        // MARK: - Internal Variables

        fileprivate let _transitionToViewController: PassthroughSubject<(UIViewController, TransitionType), Never> = PassthroughSubject()
        fileprivate let _transitionToScreen: PassthroughSubject<(NavigationDestination, TransitionType), Never> = PassthroughSubject()
        fileprivate let _dismissScreen: PassthroughSubject<(DismissType, (() -> Void)?), Never> = PassthroughSubject()
        
        // MARK: - Initialization
        
        public init() {
            self.transitionToViewController = _transitionToViewController.eraseToAnyPublisher()
            self.transitionToScreen = _transitionToScreen.eraseToAnyPublisher()
            self.dismissScreen = _dismissScreen.eraseToAnyPublisher()
        }
        
        // MARK: - Functions
        
        public func setupBindings(
            viewController: UIViewController,
            disposables: inout Set<AnyCancellable>
        ) {
            self.transitionToViewController
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
    
    func transitionToScreen(_ viewController: UIViewController, transitionType: TransitionType = .push) {
        navigatableState._transitionToViewController.send((viewController, transitionType))
    }
}

