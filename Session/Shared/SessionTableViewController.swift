// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import Combine
import GRDB
import DifferenceKit
import SessionUIKit
import SessionUtilitiesKit
import SessionMessagingKit
import SignalUtilitiesKit

// MARK: - Log.Category

private extension Log.Category {
    static let cat: Log.Category = .create("SessionTableViewController", defaultLevel: .info)
}

// MARK: - SessionViewModelAccessible

protocol SessionViewModelAccessible {
    var viewModelType: AnyObject.Type { get }
}

// MARK: - SessionTableViewController

class SessionTableViewController<ViewModel>: BaseVC, UITableViewDataSource, UITableViewDelegate, UISearchBarDelegate, SessionViewModelAccessible where ViewModel: (SessionTableViewModel & ObservableTableSource) {
    typealias Section = ViewModel.Section
    typealias TableItem = ViewModel.TableItem
    typealias SectionModel = ViewModel.SectionModel
    
    private let viewModel: ViewModel
    private var hasLoadedInitialTableData: Bool = false
    private var isLoadingMore: Bool = false
    private var isAutoLoadingNextPage: Bool = false
    private var viewHasAppeared: Bool = false
    private var dataStreamJustFailed: Bool = false
    private var dataChangeCancellable: AnyCancellable?
    private var disposables: Set<AnyCancellable> = Set()
    private var onFooterTap: (() -> ())?
    
    public var viewModelType: AnyObject.Type { return type(of: viewModel) }
    
    private var searchText: String = ""
    private var filteredTableData: [SectionModel]
    private var tableData: [SectionModel] {
        return viewModel.searchable ? filteredTableData : viewModel.tableData
    }
    
    // MARK: - Components
    
    private lazy var titleView: SessionTableViewTitleView = SessionTableViewTitleView()
    
    private lazy var contentStackView: UIStackView = {
        let result: UIStackView = UIStackView(arrangedSubviews: [
            infoBanner,
            searchBar,
            tableView
        ])
        result.axis = .vertical
        result.alignment = .fill
        result.distribution = .fill
        
        return result
    }()
    
    private lazy var infoBanner: InfoBanner = {
        let result: InfoBanner = InfoBanner(info: .empty)
        result.isHidden = true
        
        return result
    }()
    
    private lazy var searchBar: ContactsSearchBar = {
        let result = ContactsSearchBar(searchBarThemeBackgroundColor: .backgroundSecondary)
        result.themeTintColor = .textPrimary
        result.themeBackgroundColor = .clear
        result.delegate = self
        result.searchTextField.accessibilityIdentifier = "Search contacts field"
        result.set(.height, to: (36 + (Values.mediumSpacing * 2)))

        return result
    }()
    
    private lazy var tableView: UITableView = {
        let result: UITableView = UITableView()
        result.translatesAutoresizingMaskIntoConstraints = false
        result.separatorStyle = .none
        result.themeBackgroundColor = .clear
        result.showsVerticalScrollIndicator = false
        result.showsHorizontalScrollIndicator = false
        result.register(view: SessionCell.self)
        result.register(view: FullConversationCell.self)
        result.registerHeaderFooterView(view: SessionHeaderView.self)
        result.registerHeaderFooterView(view: SessionFooterView.self)
        result.dataSource = self
        result.delegate = self
        result.sectionHeaderTopPadding = 0

        return result
    }()
    
    private lazy var initialLoadLabel: UILabel = {
        let result: UILabel = UILabel()
        result.translatesAutoresizingMaskIntoConstraints = false
        result.isUserInteractionEnabled = false
        result.font = .systemFont(ofSize: Values.smallFontSize)
        result.themeTextColor = .textSecondary
        result.text = viewModel.initialLoadMessage
        result.textAlignment = .center
        result.numberOfLines = 0
        result.isHidden = (viewModel.initialLoadMessage == nil)

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
    
    init(viewModel: ViewModel) {
        self.viewModel = viewModel
        self.filteredTableData = viewModel.tableData
        
        (viewModel as? (any PagedObservationSource))?.didInit(using: viewModel.dependencies)
        
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
        
        navigationItem.titleView = titleView
        titleView.update(title: self.viewModel.title, subtitle: self.viewModel.subtitle)
        
        view.themeBackgroundColor = .backgroundPrimary
        view.addSubview(contentStackView)
        view.addSubview(initialLoadLabel)
        view.addSubview(emptyStateLabel)
        view.addSubview(fadeView)
        view.addSubview(footerButton)
        
        searchBar.isHidden = !viewModel.searchable
        
        setupLayout()
        setupBinding()
        
        // Notifications
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidBecomeActive(_:)),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
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
        viewModel.onAppear(targetViewController: self)
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        
        stopObservingChanges()
    }
    
    @objc func applicationDidBecomeActive(_ notification: Notification) {
        /// Some viewModel's may need to run custom logic after returning from the background so trigger that here
        ///
        /// **Note:** Need to dispatch to the next run loop to prevent a possible crash caused by the database resuming mid-query
        DispatchQueue.main.async { [weak self] in
            self?.viewModel.didReturnFromBackground()
        }
    }
    
    private func setupLayout() {
        contentStackView.pin(to: view)
        
        initialLoadLabel.pin(.top, to: .top, of: self.view, withInset: Values.massiveSpacing)
        initialLoadLabel.pin(.leading, to: .leading, of: self.view, withInset: Values.mediumSpacing)
        initialLoadLabel.pin(.trailing, to: .trailing, of: self.view, withInset: -Values.mediumSpacing)
        
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
        dataChangeCancellable = viewModel.tableDataPublisher
            .receive(on: DispatchQueue.main)
            .sink(
                receiveCompletion: { [weak self] result in
                    switch result {
                        case .failure(let error):
                            let title: String = (self?.viewModel.title ?? "unknown".localized())
                            
                            // If we got an error then try to restart the stream once, otherwise log the error
                            guard self?.dataStreamJustFailed == false else {
                                Log.error(.cat, "Unable to recover database stream in '\(title)' settings with error: \(error)")
                                return
                            }
                            
                            Log.info(.cat, "Atempting recovery for database stream in '\(title)' settings with error: \(error)")
                            self?.dataStreamJustFailed = true
                            self?.startObservingChanges()
                            
                        case .finished: break
                    }
                },
                receiveValue: { [weak self] updatedData in
                    self?.dataStreamJustFailed = false
                    self?.handleDataUpdates(updatedData)
                }
            )
    }
    
    private func stopObservingChanges() {
        // Stop observing database changes
        dataChangeCancellable?.cancel()
        dataChangeCancellable = nil
    }
    
    private func handleDataUpdates(_ updatedData: [SectionModel]) {
        // Determine if we have any items for the empty state
        let itemCount: Int = updatedData
            .map { $0.elements.count }
            .reduce(0, +)
        
        // Ensure the reloads run without animations (if we don't do this the cells will animate
        // in from a frame of CGRect.zero on at least the first load)
        UIView.performWithoutAnimation {
            // Update the initial/empty state
            initialLoadLabel.isHidden = true
            emptyStateLabel.isHidden = (itemCount > 0)
            
            // Update the content
            viewModel.updateTableData(updatedData)
            filteredTableData = filterTableDataIfNeeded()
            tableView.reloadData()
            /// tableView.reloadData() won't trigger any layout refresh.
            /// Normally we want to perform the changes between tableView.beginUpdates() and tableView.endUpdates(),
            /// but if there is no changes, it will just trigger a layout refresh for the row height without reloading any data.
            tableView.beginUpdates()
            tableView.endUpdates()
            hasLoadedInitialTableData = true
            
            // Complete page loading
            isLoadingMore = false
            autoLoadNextPageIfNeeded()
        }
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
                (self?.viewModel as? (any PagedObservationSource))?.loadPageAfter()
            }
        }
    }
    
    // MARK: - Binding

    private func setupBinding() {
        (viewModel as? (any NavigationItemSource))?.setupBindings(
            viewController: self,
            disposables: &disposables
        )
        (viewModel as? (any NavigatableStateHolder))?.navigatableState.setupBindings(
            viewController: self,
            disposables: &disposables
        )
        
        viewModel.bannerInfo
            .receive(on: DispatchQueue.main)
            .sink { [weak self] info in
                switch info {
                    case .some(let info):
                        self?.infoBanner.update(with: info)
                        self?.infoBanner.isHidden = false
                        
                    case .none: self?.infoBanner.isHidden = true
                }
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
                    self?.footerButton.style = buttonInfo.style
                    self?.footerButton.isEnabled = buttonInfo.isEnabled
                    self?.footerButton.set(.width, greaterThanOrEqualTo: buttonInfo.minWidth)
                    self?.footerButton.accessibilityIdentifier = buttonInfo.accessibility?.identifier
                    self?.footerButton.accessibilityLabel = buttonInfo.accessibility?.label
                }
                
                self?.onFooterTap = buttonInfo?.onTap
                self?.fadeView.isHidden = (buttonInfo == nil)
                self?.footerButton.isHidden = (buttonInfo == nil)
                
                // If we have a footerButton then we want to manually control the contentInset
                let window: UIWindow? = UIApplication.shared.keyWindow
                self?.tableView.contentInsetAdjustmentBehavior = (buttonInfo == nil ? .automatic : .never)
                self?.tableView.contentInset = UIEdgeInsets(
                    top: 0,
                    left: 0,
                    bottom: {
                        switch (buttonInfo, window?.safeAreaInsets.bottom) {
                            case (.none, 0): return Values.largeSpacing
                            case (.none, _): return 0
                            case (.some, _): return Values.footerGradientHeight(window: window)
                        }
                    }(),
                    right: 0
                )
            }
            .store(in: &disposables)
    }
    
    @objc private func footerButtonTapped() {
        onFooterTap?()
    }
    
    // MARK: - UITableViewDataSource
    
    func numberOfSections(in tableView: UITableView) -> Int {
        return tableData.count
    }
    
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return tableData[section].elements.count
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let section: SectionModel = tableData[indexPath.section]
        let info: SessionCell.Info<TableItem> = section.elements[indexPath.row]
        let cell: UITableViewCell = tableView.dequeue(type: viewModel.cellType.viewType.self, for: indexPath)
        
        switch (cell, info) {
            case (let cell as SessionCell, _):
                cell.update(
                    with: info,
                    tableSize: tableView.bounds.size,
                    onToggleExpansion: { [dependencies = self.viewModel.dependencies] in
                        UIView.setAnimationsEnabled(false)
                        cell.setNeedsLayout()
                        cell.layoutIfNeeded()
                        tableView.beginUpdates()
                        tableView.endUpdates()
                        // Only re-enable animations if the feature flag isn't disabled
                        if dependencies[feature: .animationsEnabled] {
                            UIView.setAnimationsEnabled(true)
                        }
                    },
                    using: viewModel.dependencies
                )
                
            case (let cell as FullConversationCell, let threadInfo as SessionCell.Info<SessionThreadViewModel>):
                cell.accessibilityIdentifier = info.accessibility?.identifier
                cell.isAccessibilityElement = (info.accessibility != nil)
                cell.update(with: threadInfo.id, using: viewModel.dependencies)
                
            default:
                Log.error(.cat, "[SessionTableViewController] Got invalid combination of cellType: \(viewModel.cellType) and tableData: \(SessionCell.Info<TableItem>.self)")
        }
        
        return cell
    }
    
    func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        let section: SectionModel = tableData[section]
        let result: SessionHeaderView = tableView.dequeueHeaderFooterView(type: SessionHeaderView.self)
        result.update(
            title: section.model.title,
            style: section.model.style
        )
        
        return result
    }
    
    func tableView(_ tableView: UITableView, viewForFooterInSection section: Int) -> UIView? {
        let section: SectionModel = tableData[section]
        
        if let footerString = section.model.footer {
            let result: SessionFooterView = tableView.dequeueHeaderFooterView(type: SessionFooterView.self)
            result.update(title: footerString)
            
            return result
        }
        
        return UIView()
    }
    
    // MARK: - UITableViewDelegate
    
    func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        return tableData[section].model.style.height
    }
    
    func tableView(_ tableView: UITableView, heightForFooterInSection section: Int) -> CGFloat {
        let section: SectionModel = tableData[section]
        
        return (section.model.footer == nil ? 0 : UITableView.automaticDimension)
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
                    (self?.viewModel as? (any PagedObservationSource))?.loadPageAfter()
                }
                
            default: break
        }
    }
    
    func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        return viewModel.canEditRow(at: indexPath)
    }
    
    func tableView(_ tableView: UITableView, willBeginEditingRowAt indexPath: IndexPath) {
        UIContextualAction.willBeginEditing(indexPath: indexPath, tableView: tableView)
    }
    
    func tableView(_ tableView: UITableView, didEndEditingRowAt indexPath: IndexPath?) {
        UIContextualAction.didEndEditing(indexPath: indexPath, tableView: tableView)
    }
    
    func tableView(_ tableView: UITableView, leadingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        return viewModel.leadingSwipeActionsConfiguration(forRowAt: indexPath, in: tableView, of: self)
    }
    
    func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        return viewModel.trailingSwipeActionsConfiguration(forRowAt: indexPath, in: tableView, of: self)
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        
        let section: SectionModel = tableData[indexPath.section]
        let info: SessionCell.Info<TableItem> = section.elements[indexPath.row]
        
        // Do nothing if the item is disabled
        guard info.isEnabled else { return }
        
        // Get the view that was tapped (for presenting on iPad)
        let tappedView: UIView? = {
            guard let cell: SessionCell = tableView.cellForRow(at: indexPath) as? SessionCell else {
                return nil
            }
            
            // Retrieve the last touch location from the cell
            let touchLocation: UITouch? = cell.lastTouchLocation
            cell.lastTouchLocation = nil
            
            switch (info.leadingAccessory, info.trailingAccessory) {
                case (_, is SessionCell.AccessoryConfig.HighlightingBackgroundLabel):
                    return (!cell.trailingAccessoryView.isHidden ? cell.trailingAccessoryView : cell)
                    
                case (is SessionCell.AccessoryConfig.HighlightingBackgroundLabel, _):
                    return (!cell.leadingAccessoryView.isHidden ? cell.leadingAccessoryView : cell)
                    
                case (_, is SessionCell.AccessoryConfig.HighlightingBackgroundLabelAndRadio):
                    guard
                        let touchLocation: UITouch = touchLocation,
                        !cell.trailingAccessoryView.isHidden
                    else { return cell }
                    
                    return cell.trailingAccessoryView.touchedView(touchLocation)
                    
                case (is SessionCell.AccessoryConfig.HighlightingBackgroundLabelAndRadio, _):
                    guard
                        let touchLocation: UITouch = touchLocation,
                        !cell.leadingAccessoryView.isHidden
                    else { return cell }
                    
                    return cell.leadingAccessoryView.touchedView(touchLocation)
                
                default:
                    return cell
            }
        }()
        
        let performAction: () -> Void = { [weak tappedView] in
            info.onTap?()
            info.onTapView?(tappedView)
        }
        
        guard
            let confirmationInfo: ConfirmationModal.Info = info.confirmationInfo,
            confirmationInfo.showCondition.shouldShow(for: info.boolValue)
        else {
            performAction()
            return
        }

        // Show a confirmation modal before continuing
        let confirmationModal: ConfirmationModal = ConfirmationModal(
            targetView: tappedView,
            info: confirmationInfo
                .with(
                    onConfirm: { modal in
                        confirmationInfo.onConfirm?(modal)
                        performAction()
                        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Int(ContextMenuVC.dismissDurationPartOne * 1000))) {
                            UIView.performWithoutAnimation {
                                tableView.beginUpdates()
                                tableView.endUpdates()
                            }
                        }
                    }
                )
        )
        
        // If the viewModel is a NavigatableStateHolder then navigate using that (for testing
        // purposes), otherwise fallback to standard navigation
        if let navStateHolder: NavigatableStateHolder = viewModel as? NavigatableStateHolder {
            navStateHolder.transitionToScreen(confirmationModal, transitionType: .present)
        }
        else {
            present(confirmationModal, animated: true, completion: nil)
        }
    }
    
    // MARK: - Search Bar delegate
    func filterTableDataIfNeeded() -> [SectionModel] {
        return viewModel.tableData.map {
            SectionModel(
                model: $0.model,
                elements: (
                    searchText.isEmpty ? $0.elements : $0.elements.filter { $0.title?.text?.range(of: searchText, options: [.caseInsensitive]) != nil }
                )
            )
        }
    }
    
    func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
        self.searchText = searchText
        
        let changeset: StagedChangeset<[SectionModel]> = StagedChangeset(
            source: filteredTableData,
            target: filterTableDataIfNeeded()
        )
        
        self.tableView.reload(
            using: changeset,
            deleteSectionsAnimation: .none,
            insertSectionsAnimation: .none,
            reloadSectionsAnimation: .none,
            deleteRowsAnimation: .none,
            insertRowsAnimation: .none,
            reloadRowsAnimation: .none,
            interrupt: { $0.changeCount > 100 }
        ) { [weak self] filteredTableData in
            self?.filteredTableData = filteredTableData
        }
    }
    
    func searchBarShouldBeginEditing(_ searchBar: UISearchBar) -> Bool {
        searchBar.setShowsCancelButton(true, animated: true)
        return true
    }
    
    func searchBarShouldEndEditing(_ searchBar: UISearchBar) -> Bool {
        searchBar.setShowsCancelButton(false, animated: true)
        return true
    }
    
    func searchBarCancelButtonClicked(_ searchBar: UISearchBar) {
        searchBar.resignFirstResponder()
    }
}

