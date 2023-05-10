// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit.UIImage
import Combine
import GRDB
import DifferenceKit
import SessionUIKit
import SessionMessagingKit
import SessionUtilitiesKit

class SessionTableViewModel<NavItemId: Equatable, Section: SessionTableSection, SettingItem: Hashable & Differentiable> {
    typealias SectionModel = ArraySection<Section, SessionCell.Info<SettingItem>>
    typealias ObservableData = AnyPublisher<([SectionModel], StagedChangeset<[SectionModel]>), Error>
    
    // MARK: - Input
    
    private let _isEditing: CurrentValueSubject<Bool, Never> = CurrentValueSubject(false)
    lazy var isEditing: AnyPublisher<Bool, Never> = _isEditing
        .removeDuplicates()
        .shareReplay(1)
    private let _textChanged: PassthroughSubject<(text: String?, item: SettingItem), Never> = PassthroughSubject()
    lazy var textChanged: AnyPublisher<(text: String?, item: SettingItem), Never> = _textChanged
        .eraseToAnyPublisher()
    
    // MARK: - Navigation
    
    open var leftNavItems: AnyPublisher<[NavItem]?, Never> { Just(nil).eraseToAnyPublisher() }
    open var rightNavItems: AnyPublisher<[NavItem]?, Never> { Just(nil).eraseToAnyPublisher() }
    
    private let _showToast: PassthroughSubject<(String, ThemeValue), Never> = PassthroughSubject()
    lazy var showToast: AnyPublisher<(String, ThemeValue), Never> = _showToast
        .shareReplay(0)
    private let _transitionToScreen: PassthroughSubject<(UIViewController, TransitionType), Never> = PassthroughSubject()
    lazy var transitionToScreen: AnyPublisher<(UIViewController, TransitionType), Never> = _transitionToScreen
        .shareReplay(0)
    private let _dismissScreen: PassthroughSubject<DismissType, Never> = PassthroughSubject()
    lazy var dismissScreen: AnyPublisher<DismissType, Never> = _dismissScreen
        .shareReplay(0)
    
    // MARK: - Content
    
    open var title: String { preconditionFailure("abstract class - override in subclass") }
    open var emptyStateTextPublisher: AnyPublisher<String?, Never> { Just(nil).eraseToAnyPublisher() }
    open var footerView: AnyPublisher<UIView?, Never> { Just(nil).eraseToAnyPublisher() }
    open var footerButtonInfo: AnyPublisher<SessionButton.Info?, Never> {
        Just(nil).eraseToAnyPublisher()
    }
    
    fileprivate var hasEmittedInitialData: Bool = false
    public private(set) var tableData: [SectionModel] = []
    open var observableTableData: ObservableData {
        preconditionFailure("abstract class - override in subclass")
    }
    open var pagedDataObserver: TransactionObserver? { nil }
    
    func updateTableData(_ updatedData: [SectionModel]) {
        self.tableData = updatedData
    }
    
    func loadPageBefore() { preconditionFailure("abstract class - override in subclass") }
    func loadPageAfter() { preconditionFailure("abstract class - override in subclass") }
    
    // MARK: - Functions
    
    func setIsEditing(_ isEditing: Bool) {
        _isEditing.send(isEditing)
    }
    
    func textChanged(_ text: String?, for item: SettingItem) {
        _textChanged.send((text, item))
    }
    
    func showToast(text: String, backgroundColor: ThemeValue = .backgroundPrimary) {
        _showToast.send((text, backgroundColor))
    }
    
    func dismissScreen(type: DismissType = .auto) {
        _dismissScreen.send(type)
    }
    
    func transitionToScreen(_ viewController: UIViewController, transitionType: TransitionType = .push) {
        _transitionToScreen.send((viewController, transitionType))
    }
}

// MARK: - Convenience

extension Array {
    func mapToSessionTableViewData<Nav, Section, Item>(
        for viewModel: SessionTableViewModel<Nav, Section, Item>?
    ) -> [ArraySection<Section, SessionCell.Info<Item>>] where Element == ArraySection<Section, SessionCell.Info<Item>> {
        // Update the data to include the proper position for each element
        return self.map { section in
            ArraySection(
                model: section.model,
                elements: section.elements.enumerated().map { index, element in
                    element.updatedPosition(for: index, count: section.elements.count)
                }
            )
        }
    }
}

extension AnyPublisher {
    func mapToSessionTableViewData<Nav, Section, Item>(
        for viewModel: SessionTableViewModel<Nav, Section, Item>
    ) -> AnyPublisher<(Output, StagedChangeset<Output>), Failure> where Output == [ArraySection<Section, SessionCell.Info<Item>>] {
        return self
            .map { [weak viewModel] updatedData -> (Output, StagedChangeset<Output>) in
                let updatedDataWithPositions: Output = updatedData
                    .mapToSessionTableViewData(for: viewModel)
                
                // Generate an updated changeset
                let changeset = StagedChangeset(
                    source: (viewModel?.tableData ?? []),
                    target: updatedDataWithPositions
                )
                
                return (updatedDataWithPositions, changeset)
            }
            .filter { [weak viewModel] _, changeset in
                viewModel?.hasEmittedInitialData == false ||    // Always emit at least once
                !changeset.isEmpty                              // Do nothing if there were no changes
            }
            .handleEvents(receiveOutput: { [weak viewModel] _ in
                viewModel?.hasEmittedInitialData = true
            })
            .eraseToAnyPublisher()
    }
}
