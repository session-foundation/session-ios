// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import Combine
import GRDB
import DifferenceKit
import SessionUIKit
import SessionUtilitiesKit
import SignalUtilitiesKit

protocol SessionViewModelAccessible {
    var viewModelType: AnyObject.Type { get }
}

class SessionTableViewController<NavItemId: Equatable, Section: SessionTableSection, SettingItem: Hashable & Differentiable>: BaseVC, UITableViewDataSource, UITableViewDelegate, SessionViewModelAccessible {
    typealias SectionModel = SessionTableViewModel<NavItemId, Section, SettingItem>.SectionModel
    
    private let viewModel: SessionTableViewModel<NavItemId, Section, SettingItem>
    private var hasLoadedInitialTableData: Bool = false
    private var isLoadingMore: Bool = false
    private var isAutoLoadingNextPage: Bool = false
    private var viewHasAppeared: Bool = false
    private var dataStreamJustFailed: Bool = false
    private var dataChangeCancellable: AnyCancellable?
    private var disposables: Set<AnyCancellable> = Set()
    private var onFooterTap: (() -> ())?
    
    public var viewModelType: AnyObject.Type { return type(of: viewModel) }
    
    // MARK: - Components
    
    private lazy var tableView: UITableView = {
        let result: UITableView = UITableView()
        result.translatesAutoresizingMaskIntoConstraints = false
        result.separatorStyle = .none
        result.themeBackgroundColor = .clear
        result.showsVerticalScrollIndicator = false
        result.showsHorizontalScrollIndicator = false
        result.register(view: SessionCell.self)
        result.registerHeaderFooterView(view: SessionHeaderView.self)
        result.dataSource = self
        result.delegate = self
        
        if #available(iOS 15.0, *) {
            result.sectionHeaderTopPadding = 0
        }
        
        return result
    }()
    
    private lazy var emptyStateLabel: UILabel = {
        let result: UILabel = UILabel()
        result.translatesAutoresizingMaskIntoConstraints = false
        result.isUserInteractionEnabled = false
        result.font = .systemFont(ofSize: Values.smallFontSize)
        result.themeTextColor = .textSecondary
        result.textAlignment = .center
        result.numberOfLines = 0
        result.isHidden = true

        return result
    }()
    
    private lazy var fadeView: GradientView = {
        let result: GradientView = GradientView()
        result.themeBackgroundGradient = [
            .value(.backgroundPrimary, alpha: 0), // Want this to take up 20% (~25pt)
            .backgroundPrimary,
            .backgroundPrimary,
            .backgroundPrimary,
            .backgroundPrimary
        ]
        result.set(.height, to: Values.footerGradientHeight(window: UIApplication.shared.keyWindow))
        result.isHidden = true
        
        return result
    }()
    
    private lazy var footerButton: SessionButton = {
        let result: SessionButton = SessionButton(style: .bordered, size: .medium)
        result.translatesAutoresizingMaskIntoConstraints = false
        result.addTarget(self, action: #selector(footerButtonTapped), for: .touchUpInside)
        result.isHidden = true

        return result
    }()
    
    // MARK: - Initialization
    
    init(viewModel: SessionTableViewModel<NavItemId, Section, SettingItem>) {
        self.viewModel = viewModel
        
        Storage.shared.addObserver(viewModel.pagedDataObserver)
        
        super.init(nibName: nil, bundle: nil)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    // MARK: - Lifecycle
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        ViewControllerUtilities.setUpDefaultSessionStyle(
            for: self,
            title: viewModel.title,
            hasCustomBackButton: false
        )
        
        view.themeBackgroundColor = .backgroundPrimary
        view.addSubview(tableView)
        view.addSubview(emptyStateLabel)
        view.addSubview(fadeView)
        view.addSubview(footerButton)
        
        setupLayout()
        setupBinding()
        
        // Notifications
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidBecomeActive(_:)),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidResignActive(_:)),
            name: UIApplication.didEnterBackgroundNotification, object: nil
        )
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        
        startObservingChanges()
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        
        viewHasAppeared = true
        autoLoadNextPageIfNeeded()
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        
        stopObservingChanges()
    }
    
    @objc func applicationDidBecomeActive(_ notification: Notification) {
        /// Need to dispatch to the next run loop to prevent a possible crash caused by the database resuming mid-query
        DispatchQueue.main.async { [weak self] in
            self?.startObservingChanges()
        }
    }
    
    @objc func applicationDidResignActive(_ notification: Notification) {
        stopObservingChanges()
    }
    
    private func setupLayout() {
        tableView.pin(to: view)
        
        emptyStateLabel.pin(.top, to: .top, of: self.view, withInset: Values.massiveSpacing)
        emptyStateLabel.pin(.leading, to: .leading, of: self.view, withInset: Values.mediumSpacing)
        emptyStateLabel.pin(.trailing, to: .trailing, of: self.view, withInset: -Values.mediumSpacing)
        
        fadeView.pin(.leading, to: .leading, of: self.view)
        fadeView.pin(.trailing, to: .trailing, of: self.view)
        fadeView.pin(.bottom, to: .bottom, of: self.view)
        
        footerButton.center(.horizontal, in: self.view)
        footerButton.pin(.bottom, to: .bottom, of: self.view.safeAreaLayoutGuide, withInset: -Values.smallSpacing)
    }
    
    // MARK: - Updating
    
    private func startObservingChanges() {
        // Start observing for data changes
        dataChangeCancellable = viewModel.observableTableData
            .receive(on: DispatchQueue.main)
            .sink(
                receiveCompletion: { [weak self] result in
                    switch result {
                        case .failure(let error):
                            let title: String = (self?.viewModel.title ?? "unknown")
                            
                            // If we got an error then try to restart the stream once, otherwise log the error
                            guard self?.dataStreamJustFailed == false else {
                                SNLog("Unable to recover database stream in '\(title)' settings with error: \(error)")
                                return
                            }
                            
                            SNLog("Atempting recovery for database stream in '\(title)' settings with error: \(error)")
                            self?.dataStreamJustFailed = true
                            self?.startObservingChanges()
                            
                        case .finished: break
                    }
                },
                receiveValue: { [weak self] updatedData, changeset in
                    self?.dataStreamJustFailed = false
                    self?.handleDataUpdates(updatedData, changeset: changeset)
                }
            )
    }
    
    private func stopObservingChanges() {
        // Stop observing database changes
        dataChangeCancellable?.cancel()
    }
    
    private func handleDataUpdates(
        _ updatedData: [SectionModel],
        changeset: StagedChangeset<[SectionModel]>,
        initialLoad: Bool = false
    ) {
        // Determine if we have any items for the empty state
        let itemCount: Int = updatedData
            .map { $0.elements.count }
            .reduce(0, +)
        
        // Ensure the first load runs without animations (if we don't do this the cells will animate
        // in from a frame of CGRect.zero)
        guard hasLoadedInitialTableData else {
            UIView.performWithoutAnimation {
                // Update the empty state
                emptyStateLabel.isHidden = (itemCount > 0)
                
                // Update the content
                viewModel.updateTableData(updatedData)
                tableView.reloadData()
                hasLoadedInitialTableData = true
            }
            return
        }
        
        // Update the empty state
        self.emptyStateLabel.isHidden = (itemCount > 0)
        
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            // Complete page loading
            self?.isLoadingMore = false
            self?.autoLoadNextPageIfNeeded()
        }
        
        // Reload the table content (animate changes after the first load)
        tableView.reload(
            using: changeset,
            deleteSectionsAnimation: .none,
            insertSectionsAnimation: .none,
            reloadSectionsAnimation: .none,
            deleteRowsAnimation: .fade,
            insertRowsAnimation: .fade,
            reloadRowsAnimation: .none,
            interrupt: { $0.changeCount > 100 }    // Prevent too many changes from causing performance issues
        ) { [weak self] updatedData in
            self?.viewModel.updateTableData(updatedData)
        }
        
        CATransaction.commit()
    }
    
    private func autoLoadNextPageIfNeeded() {
        guard
            self.hasLoadedInitialTableData &&
            !self.isAutoLoadingNextPage &&
            !self.isLoadingMore
        else { return }
        
        self.isAutoLoadingNextPage = true
        
        DispatchQueue.main.asyncAfter(deadline: .now() + PagedData.autoLoadNextPageDelay) { [weak self] in
            self?.isAutoLoadingNextPage = false
            
            // Note: We sort the headers as we want to prioritise loading newer pages over older ones
            let sections: [(Section, CGRect)] = (self?.viewModel.tableData
                .enumerated()
                .map { index, section in
                    (section.model, (self?.tableView.rectForHeader(inSection: index) ?? .zero))
                })
                .defaulting(to: [])
            let shouldLoadMore: Bool = sections
                .contains { section, headerRect in
                    section.style == .loadMore &&
                    headerRect != .zero &&
                    (self?.tableView.bounds.contains(headerRect) == true)
                }
            
            guard shouldLoadMore else { return }
            
            self?.isLoadingMore = true
            
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.viewModel.loadPageAfter()
            }
        }
    }
    
    // MARK: - Binding

    private func setupBinding() {
        viewModel.isEditing
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isEditing in
                UIView.animate(withDuration: 0.25) {
                    self?.setEditing(isEditing, animated: true)
                    
                    self?.tableView.visibleCells
                        .compactMap { $0 as? SessionCell }
                        .filter { $0.interactionMode == .editable || $0.interactionMode == .alwaysEditing }
                        .enumerated()
                        .forEach { index, cell in
                            cell.update(
                                isEditing: (isEditing || cell.interactionMode == .alwaysEditing),
                                becomeFirstResponder: (
                                    isEditing &&
                                    index == 0 &&
                                    cell.interactionMode != .alwaysEditing
                                ),
                                animated: true
                            )
                        }
                    
                    self?.tableView.beginUpdates()
                    self?.tableView.endUpdates()
                }
            }
            .store(in: &disposables)
        
        viewModel.leftNavItems
            .receive(on: DispatchQueue.main)
            .sink { [weak self] maybeItems in
                self?.navigationItem.setLeftBarButtonItems(
                    maybeItems.map { items in
                        items.map { item -> DisposableBarButtonItem in
                            let buttonItem: DisposableBarButtonItem = item.createBarButtonItem()
                            buttonItem.themeTintColor = .textPrimary

                            buttonItem.tapPublisher
                                .map { _ in item.id }
                                .sink(receiveValue: { _ in item.action?() })
                                .store(in: &buttonItem.disposables)

                            return buttonItem
                        }
                    },
                    animated: true
                )
            }
            .store(in: &disposables)

        viewModel.rightNavItems
            .receive(on: DispatchQueue.main)
            .sink { [weak self] maybeItems in
                self?.navigationItem.setRightBarButtonItems(
                    maybeItems.map { items in
                        items.map { item -> DisposableBarButtonItem in
                            let buttonItem: DisposableBarButtonItem = item.createBarButtonItem()
                            buttonItem.themeTintColor = .textPrimary

                            buttonItem.tapPublisher
                                .map { _ in item.id }
                                .sink(receiveValue: { _ in item.action?() })
                                .store(in: &buttonItem.disposables)

                            return buttonItem
                        }
                    },
                    animated: true
                )
            }
            .store(in: &disposables)
        
        viewModel.emptyStateTextPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] text in
                self?.emptyStateLabel.text = text
            }
            .store(in: &disposables)
        
        viewModel.footerView
            .receive(on: DispatchQueue.main)
            .sink { [weak self] footerView in
                self?.tableView.tableFooterView = footerView
            }
            .store(in: &disposables)
        
        viewModel.footerButtonInfo
            .receive(on: DispatchQueue.main)
            .sink { [weak self] buttonInfo in
                if let buttonInfo: SessionButton.Info = buttonInfo {
                    self?.footerButton.setTitle(buttonInfo.title, for: .normal)
                    self?.footerButton.setStyle(buttonInfo.style)
                    self?.footerButton.isEnabled = buttonInfo.isEnabled
                }
                
                self?.onFooterTap = buttonInfo?.onTap
                self?.fadeView.isHidden = (buttonInfo == nil)
                self?.footerButton.isHidden = (buttonInfo == nil)
                
                // If we have a footerButton then we want to manually control the contentInset
                self?.tableView.contentInsetAdjustmentBehavior = (buttonInfo == nil ? .automatic : .never)
                self?.tableView.contentInset = UIEdgeInsets(
                    top: 0,
                    left: 0,
                    bottom: (buttonInfo == nil ?
                        0 :
                        Values.footerGradientHeight(window: UIApplication.shared.keyWindow)
                    ),
                    right: 0
                )
            }
            .store(in: &disposables)
        
        viewModel.showToast
            .receive(on: DispatchQueue.main)
            .sink { [weak self] text, color in
                guard let view: UIView = self?.view else { return }
                
                let toastController: ToastController = ToastController(text: text, background: color)
                toastController.presentToastView(fromBottomOfView: view, inset: Values.largeSpacing)
            }
            .store(in: &disposables)
        
        viewModel.transitionToScreen
            .receive(on: DispatchQueue.main)
            .sink { [weak self] viewController, transitionType in
                switch transitionType {
                    case .push:
                        self?.navigationController?.pushViewController(viewController, animated: true)
                    
                    case .present:
                        let presenter: UIViewController? = (self?.presentedViewController ?? self)
                        
                        if UIDevice.current.isIPad {
                            viewController.popoverPresentationController?.permittedArrowDirections = []
                            viewController.popoverPresentationController?.sourceView = presenter?.view
                            viewController.popoverPresentationController?.sourceRect = (presenter?.view.bounds ?? UIScreen.main.bounds)
                        }
                        
                        presenter?.present(viewController, animated: true)
                }
            }
            .store(in: &disposables)
        
        viewModel.dismissScreen
            .receive(on: DispatchQueue.main)
            .sink { [weak self] dismissType in
                switch dismissType {
                    case .auto:
                        guard
                            let viewController: UIViewController = self,
                            (self?.navigationController?.viewControllers
                                .firstIndex(of: viewController))
                                .defaulting(to: 0) > 0
                        else {
                            self?.dismiss(animated: true)
                            return
                        }
                        
                        self?.navigationController?.popViewController(animated: true)
                        
                    case .dismiss: self?.dismiss(animated: true)
                    case .pop: self?.navigationController?.popViewController(animated: true)
                    case .popToRoot: self?.navigationController?.popToRootViewController(animated: true)
                }
            }
            .store(in: &disposables)
    }
    
    @objc private func footerButtonTapped() {
        onFooterTap?()
    }
    
    // MARK: - UITableViewDataSource
    
    func numberOfSections(in tableView: UITableView) -> Int {
        return self.viewModel.tableData.count
    }
    
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return self.viewModel.tableData[section].elements.count
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let section: SectionModel = viewModel.tableData[indexPath.section]
        let info: SessionCell.Info<SettingItem> = section.elements[indexPath.row]
        let cell: SessionCell = tableView.dequeue(type: SessionCell.self, for: indexPath)
        cell.update(with: info)
        cell.update(
            isEditing: (self.isEditing || (info.title?.interaction == .alwaysEditing)),
            becomeFirstResponder: false,
            animated: false
        )
        cell.textPublisher
            .sink(receiveValue: { [weak self] text in
                self?.viewModel.textChanged(text, for: info.id)
            })
            .store(in: &cell.disposables)
        
        return cell
    }
    
    func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        let section: SectionModel = viewModel.tableData[section]
        let result: SessionHeaderView = tableView.dequeueHeaderFooterView(type: SessionHeaderView.self)
        result.update(
            title: section.model.title,
            style: section.model.style
        )
        
        return result
    }
    
    // MARK: - UITableViewDelegate
    
    func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        return viewModel.tableData[section].model.style.height
    }
    
    func tableView(_ tableView: UITableView, estimatedHeightForRowAt indexPath: IndexPath) -> CGFloat {
        return UITableView.automaticDimension
    }
    
    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        return UITableView.automaticDimension
    }
    
    func tableView(_ tableView: UITableView, willDisplayHeaderView view: UIView, forSection section: Int) {
        guard self.hasLoadedInitialTableData && self.viewHasAppeared && !self.isLoadingMore else { return }
        
        let section: SectionModel = self.viewModel.tableData[section]
        
        switch section.model.style {
            case .loadMore:
                self.isLoadingMore = true
                
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    self?.viewModel.loadPageAfter()
                }
                
            default: break
        }
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        
        let section: SectionModel = self.viewModel.tableData[indexPath.section]
        let info: SessionCell.Info<SettingItem> = section.elements[indexPath.row]
        
        // Do nothing if the item is disabled
        guard info.isEnabled else { return }
        
        // Get the view that was tapped (for presenting on iPad)
        let tappedView: UIView? = {
            guard let cell: SessionCell = tableView.cellForRow(at: indexPath) as? SessionCell else {
                return nil
            }
            
            switch (info.leftAccessory, info.rightAccessory) {
                case (_, .highlightingBackgroundLabel(_, _)):
                    return (!cell.rightAccessoryView.isHidden ? cell.rightAccessoryView : cell)
                    
                case (.highlightingBackgroundLabel(_, _), _):
                    return (!cell.leftAccessoryView.isHidden ? cell.leftAccessoryView : cell)
                
                default:
                    return cell
            }
        }()
        let maybeOldSelection: (Int, SessionCell.Info<SettingItem>)? = section.elements
            .enumerated()
            .first(where: { index, info in
                switch (info.leftAccessory, info.rightAccessory) {
                    case (_, .radio(_, let isSelected, _, _)): return isSelected()
                    case (.radio(_, let isSelected, _, _), _): return isSelected()
                    default: return false
                }
            })
        
        let performAction: () -> Void = { [weak self, weak tappedView] in
            info.onTap?()
            info.onTapView?(tappedView)
            self?.manuallyReload(indexPath: indexPath, section: section, info: info)
            
            // Update the old selection as well
            if let oldSelection: (index: Int, info: SessionCell.Info<SettingItem>) = maybeOldSelection {
                self?.manuallyReload(
                    indexPath: IndexPath(
                        row: oldSelection.index,
                        section: indexPath.section
                    ),
                    section: section,
                    info: oldSelection.info
                )
            }
        }
        
        guard
            let confirmationInfo: ConfirmationModal.Info = info.confirmationInfo,
            confirmationInfo.showCondition.shouldShow(for: info.currentBoolValue)
        else {
            performAction()
            return
        }

        // Show a confirmation modal before continuing
        let confirmationModal: ConfirmationModal = ConfirmationModal(
            targetView: tappedView,
            info: confirmationInfo
                .with(onConfirm: { _ in performAction() })
        )
        present(confirmationModal, animated: true, completion: nil)
    }
    
    private func manuallyReload(
        indexPath: IndexPath,
        section: SectionModel,
        info: SessionCell.Info<SettingItem>
    ) {
        // Try update the existing cell to have a nice animation instead of reloading the cell
        if let existingCell: SessionCell = tableView.cellForRow(at: indexPath) as? SessionCell {
            existingCell.update(with: info, isManualReload: true)
        }
        else {
            tableView.reloadRows(at: [indexPath], with: .none)
        }
    }
}
