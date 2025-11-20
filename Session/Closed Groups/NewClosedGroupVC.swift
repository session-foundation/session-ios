// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import Combine
import GRDB
import DifferenceKit
import SessionUIKit
import SessionMessagingKit
import SessionUtilitiesKit
import SignalUtilitiesKit

private protocol TableViewTouchDelegate {
    func tableViewWasTouched(_ tableView: TableView, withView hitView: UIView?)
}

private final class TableView: UITableView {
    var touchDelegate: TableViewTouchDelegate?

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let resultingView: UIView? = super.hitTest(point, with: event)
        touchDelegate?.tableViewWasTouched(self, withView: resultingView)
        
        return resultingView
    }
}

final class NewClosedGroupVC: BaseVC, UITableViewDataSource, UITableViewDelegate, TableViewTouchDelegate, UITextFieldDelegate, UIScrollViewDelegate {
    private enum Section: Int, Differentiable, Equatable, Hashable {
        case contacts
    }
    
    private let dependencies: Dependencies
    private let contacts: [WithProfile<Contact>]
    private let hideCloseButton: Bool
    private let prefilledName: String?
    private lazy var data: [ArraySection<Section, WithProfile<Contact>>] = [
        ArraySection(model: .contacts, elements: contacts)
    ]
    private var selectedProfileIds: Set<String> = []
    private var searchText: String = ""
    
    // MARK: - Initialization
    
    init(
        hideCloseButton: Bool = false,
        prefilledName: String? = nil,
        preselectedContactIds: [String] = [],
        using dependencies: Dependencies
    ) {
        self.dependencies = dependencies
        self.hideCloseButton = hideCloseButton
        self.prefilledName = prefilledName
        
        let currentUserSessionId: SessionId = dependencies[cache: .general].sessionId
        let finalPreselectedContactIds: Set<String> = Set(preselectedContactIds)
            .subtracting([currentUserSessionId.hexString])
        
        // FIXME: This should be changed to be an async process (ideally coming from a view model)
        self.contacts = dependencies[singleton: .storage]
            .read { db in
                let contact: TypedTableAlias<Contact> = TypedTableAlias()
                let request: SQLRequest<Contact> = """
                    SELECT \(contact.allColumns)
                    FROM \(contact)
                    WHERE (
                        \(SQL("\(contact[.id]) != \(currentUserSessionId.hexString)")) AND (
                            \(contact[.id]) IN \(Set(finalPreselectedContactIds)) OR (
                                \(contact[.isApproved]) = TRUE AND
                                \(contact[.didApproveMe]) = TRUE AND
                                \(contact[.isBlocked]) = FALSE
                            )
                        )
                    )
                """
                
                let fetchedResults: [WithProfile<Contact>] = try request.fetchAllWithProfiles(
                    db,
                    using: dependencies
                )
                let missingIds: Set<String> = finalPreselectedContactIds
                    .subtracting(fetchedResults.map { $0.profileId })
                
                return fetchedResults
                    .appending(contentsOf: missingIds.map {
                        WithProfile(
                            value: Contact(id: $0, currentUserSessionId: currentUserSessionId),
                            profile: nil,
                            currentUserSessionId: currentUserSessionId
                        )
                    })
            }
            .defaulting(to: [])
            .sorted()
        
        self.selectedProfileIds = finalPreselectedContactIds
        
        super.init(nibName: nil, bundle: nil)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    // MARK: - Components
    
    private static let textFieldHeight: CGFloat = 50
    private static let searchBarHeight: CGFloat = (36 + (Values.mediumSpacing * 2))
    
    private let contentStackView: UIStackView = {
        let result: UIStackView = UIStackView()
        result.axis = .vertical
        result.distribution = .fill
        
        return result
    }()
    
    private lazy var nameTextField: SNTextField = {
        let result = SNTextField(
            placeholder: "groupNameEnter".localized(),
            usesDefaultHeight: false,
            customHeight: NewClosedGroupVC.textFieldHeight
        )
        result.text = prefilledName
        result.set(.height, to: NewClosedGroupVC.textFieldHeight)
        result.themeBorderColor = .borderSeparator
        result.layer.cornerRadius = 13
        result.delegate = self
        result.accessibilityIdentifier = "Group name input"
        result.isAccessibilityElement = true
        
        return result
    }()
    
    private lazy var searchBar: ContactsSearchBar = {
        let result = ContactsSearchBar()
        result.themeTintColor = .textPrimary
        result.themeBackgroundColor = .clear
        result.delegate = self
        result.searchTextField.accessibilityIdentifier = "Search contacts field"
        result.set(.height, to: NewClosedGroupVC.searchBarHeight)

        return result
    }()
    
    private lazy var headerView: UIView = {
        let result: UIView = UIView(
            frame: CGRect(
                x: 0, y: 0,
                width: UIScreen.main.bounds.width,
                height: (
                    Values.mediumSpacing +
                    NewClosedGroupVC.textFieldHeight +
                    NewClosedGroupVC.searchBarHeight
                )
            )
        )
        result.addSubview(nameTextField)
        result.addSubview(searchBar)
        
        nameTextField.pin(.top, to: .top, of: result, withInset: Values.mediumSpacing)
        nameTextField.pin(.leading, to: .leading, of: result, withInset: Values.largeSpacing)
        nameTextField.pin(.trailing, to: .trailing, of: result, withInset: -Values.largeSpacing)
        
        // Note: The top & bottom padding is built into the search bar
        searchBar.pin(.top, to: .bottom, of: nameTextField)
        searchBar.pin(.leading, to: .leading, of: result, withInset: Values.largeSpacing)
        searchBar.pin(.trailing, to: .trailing, of: result, withInset: -Values.largeSpacing)
        searchBar.pin(.bottom, to: .bottom, of: result)
        
        return result
    }()

    private lazy var tableView: TableView = {
        let result: TableView = TableView()
        result.separatorStyle = .none
        result.themeBackgroundColor = .clear
        result.showsVerticalScrollIndicator = false
        result.tableHeaderView = headerView
        result.contentInset = UIEdgeInsets(
            top: 0,
            leading: 0,
            bottom: Values.footerGradientHeight(window: UIApplication.shared.keyWindow),
            trailing: 0
        )
        result.register(view: SessionCell.self)
        result.touchDelegate = self
        result.dataSource = self
        result.delegate = self
        result.sectionHeaderTopPadding = 0
        
        return result
    }()
    
    private lazy var fadeView: GradientView = {
        let result: GradientView = GradientView()
        result.themeBackgroundGradient = [
            .value(.backgroundSecondary, alpha: 0), // Want this to take up 20% (~25pt)
            .backgroundSecondary,
            .backgroundSecondary,
            .backgroundSecondary,
            .backgroundSecondary
        ]
        result.set(.height, to: Values.footerGradientHeight(window: UIApplication.shared.keyWindow))
        
        return result
    }()
    
    private lazy var createGroupButton: SessionButton = {
        let result = SessionButton(style: .bordered, size: .large)
        result.translatesAutoresizingMaskIntoConstraints = false
        result.setTitle("create".localized(), for: .normal)
        result.addTarget(self, action: #selector(createClosedGroup), for: .touchUpInside)
        result.accessibilityIdentifier = "Create group"
        result.isAccessibilityElement = true
        result.set(.width, to: 160)
        
        return result
    }()
    
    // MARK: - Lifecycle
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        view.themeBackgroundColor = .backgroundSecondary
        
        let customTitleFontSize = Values.largeFontSize
        setNavBarTitle("groupCreate".localized(), customFontSize: customTitleFontSize)
        
        if !hideCloseButton {
            let closeButton = UIBarButtonItem(image: #imageLiteral(resourceName: "X"), style: .plain, target: self, action: #selector(close))
            closeButton.themeTintColor = .textPrimary
            navigationItem.rightBarButtonItem = closeButton
            navigationItem.leftBarButtonItem?.accessibilityIdentifier = "Cancel"
            navigationItem.leftBarButtonItem?.isAccessibilityElement = true
        }
        
        // Set up content
        setUpViewHierarchy()
    }

    private func setUpViewHierarchy() {
        guard !contacts.isEmpty else {
            let explanationLabel: UILabel = UILabel()
            explanationLabel.font = .systemFont(ofSize: Values.smallFontSize)
            explanationLabel.text = "contactNone".localized()
            explanationLabel.themeTextColor = .textSecondary
            explanationLabel.textAlignment = .center
            explanationLabel.lineBreakMode = .byWordWrapping
            explanationLabel.numberOfLines = 0
            
            view.addSubview(explanationLabel)
            explanationLabel.pin(.top, to: .top, of: view, withInset: Values.largeSpacing)
            explanationLabel.center(.horizontal, in: view)
            return
        }
        
        view.addSubview(contentStackView)
        contentStackView.pin(.top, to: .top, of: view)
        contentStackView.pin(.leading, to: .leading, of: view)
        contentStackView.pin(.trailing, to: .trailing, of: view)
        contentStackView.pin(.bottom, to: .bottom, of: view)
        
        contentStackView.addArrangedSubview(tableView)
        
        view.addSubview(fadeView)
        fadeView.pin(.leading, to: .leading, of: view)
        fadeView.pin(.trailing, to: .trailing, of: view)
        fadeView.pin(.bottom, to: .bottom, of: view)
        
        view.addSubview(createGroupButton)
        createGroupButton.center(.horizontal, in: view)
        createGroupButton.pin(.bottom, to: .bottom, of: view.safeAreaLayoutGuide, withInset: -Values.smallSpacing)
    }
    
    // MARK: - Table View Data Source
    
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return data[section].elements.count
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell: SessionCell = tableView.dequeue(type: SessionCell.self, for: indexPath)
        let item: WithProfile<Contact> = data[indexPath.section].elements[indexPath.row]
        cell.update(
            with: SessionCell.Info(
                id: item.profileId,
                position: Position.with(indexPath.row, count: data[indexPath.section].elements.count),
                leadingAccessory: .profile(id: item.profileId, profile: item.profile),
                title: (item.profile?.displayName() ?? item.profileId.truncated()),
                trailingAccessory: .radio(isSelected: selectedProfileIds.contains(item.profileId)),
                styling: SessionCell.StyleInfo(backgroundStyle: .edgeToEdge),
                accessibility: Accessibility(
                    identifier: "Contact"
                )
            ),
            tableSize: tableView.bounds.size,
            using: dependencies
        )
        
        return cell
    }
    
    // MARK: - UITableViewDelegate
    
    func tableView(_ tableView: UITableView, estimatedHeightForRowAt indexPath: IndexPath) -> CGFloat {
        return UITableView.automaticDimension
    }

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        return UITableView.automaticDimension
    }
    
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let item: WithProfile<Contact> = data[indexPath.section].elements[indexPath.row]
        
        if selectedProfileIds.contains(item.profileId) {
            selectedProfileIds.remove(item.profileId)
        }
        else {
            selectedProfileIds.insert(item.profileId)
        }
        
        tableView.deselectRow(at: indexPath, animated: true)
        tableView.reloadRows(at: [indexPath], with: .none)
    }
    
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        let nameTextFieldCenterY = nameTextField.convert(
            CGPoint(x: nameTextField.bounds.midX, y: nameTextField.bounds.midY),
            to: scrollView
        ).y
        let shouldShowGroupNameInTitle: Bool = (scrollView.contentOffset.y > nameTextFieldCenterY)
        let groupNameLabelVisible: Bool = (crossfadeLabel.alpha >= 1)
        
        switch (shouldShowGroupNameInTitle, groupNameLabelVisible) {
            case (true, false):
                UIView.animate(withDuration: 0.2) {
                    self.navBarTitleLabel.alpha = 0
                    self.crossfadeLabel.alpha = 1
                }
                
            case (false, true):
                UIView.animate(withDuration: 0.2) {
                    self.navBarTitleLabel.alpha = 1
                    self.crossfadeLabel.alpha = 0
                }
                
            default: break
        }
    }
    
    // MARK: - Interaction
    
    func textFieldDidEndEditing(_ textField: UITextField) {
        crossfadeLabel.text = (textField.text?.isEmpty == true ?
            "groupCreate".localized() :
            textField.text
        )
    }
    
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        nameTextField.resignFirstResponder()
        return false
    }

    fileprivate func tableViewWasTouched(_ tableView: TableView, withView hitView: UIView?) {
        if nameTextField.isFirstResponder {
            nameTextField.resignFirstResponder()
        }
        else if searchBar.isFirstResponder {
            var hitSuperview: UIView? = hitView?.superview
            
            while hitSuperview != nil && hitSuperview != searchBar {
                hitSuperview = hitSuperview?.superview
            }
            
            // If the user hit the cancel button then do nothing (we want to let the cancel
            // button remove the focus or it will instantly refocus)
            if hitSuperview == searchBar { return }
            
            searchBar.resignFirstResponder()
        }
    }
    
    @objc private func close() {
        dismiss(animated: true, completion: nil)
    }
    
    @objc private func createClosedGroup() {
        func showError(title: String, message: String = "") {
            let modal: ConfirmationModal = ConfirmationModal(
                info: ConfirmationModal.Info(
                    title: title,
                    body: .text(message),
                    cancelTitle: "okay".localized(),
                    cancelStyle: .alert_text
                    
                )
            )
            present(modal, animated: true)
        }
        guard
            let name: String = nameTextField.text?.trimmingCharacters(in: .whitespacesAndNewlines),
            name.count > 0
        else {
            return showError(title: "groupNameEnterPlease".localized())
        }
        guard !LibSession.isTooLong(groupName: name) else {
            return showError(title: "groupNameEnterShorter".localized())
        }
        guard selectedProfileIds.count >= 1 else {
            return showError(title: "groupCreateErrorNoMembers".localized())
        }
        /// Minus one because we're going to include self later
        guard selectedProfileIds.count < (LibSession.sizeMaxGroupMemberCount - 1) else {
            return showError(title: "groupAddMemberMaximum".localized())
        }
        let selectedProfiles: [(String, Profile?)] = self.selectedProfileIds.map { id in
            (id, self.contacts.first { $0.profileId == id }?.profile)
        }
        
        let indicator: ModalActivityIndicatorViewController = ModalActivityIndicatorViewController()
        navigationController?.present(indicator, animated: false)
        
        Task(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }
            
            do {
                let thread: SessionThread = try await MessageSender.createGroup(
                    name: name,
                    description: nil,
                    displayPicture: nil,
                    displayPictureCropRect: nil,
                    members: selectedProfiles,
                    using: dependencies
                )
                
                /// When this is triggered via the "Recreate Group" action for Legacy Groups the screen will have been
                /// pushed instead of presented and, as a result, we need to dismiss the `activityIndicatorViewController`
                /// and want the transition to be animated in order to behave nicely
                await dependencies[singleton: .app].presentConversationCreatingIfNeeded(
                    for: thread.id,
                    variant: thread.variant,
                    action: .none,
                    dismissing: (self.presentingViewController ?? indicator),
                    animated: (self.presentingViewController == nil)
                )
            }
            catch {
                await MainActor.run { [weak self] in
                    self?.dismiss(animated: true, completion: nil) // Dismiss the loader
                    
                    let modal: ConfirmationModal = ConfirmationModal(
                        targetView: self?.view,
                        info: ConfirmationModal.Info(
                            title: "groupError".localized(),
                            body: .text("groupErrorCreate".localized()),
                            cancelTitle: "okay".localized(),
                            cancelStyle: .alert_text
                        )
                    )
                    self?.present(modal, animated: true)
                }
            }
        }
    }
}

extension NewClosedGroupVC: UISearchBarDelegate {
    func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
        self.searchText = searchText
        
        let changeset: StagedChangeset<[ArraySection<Section, WithProfile<Contact>>]> = StagedChangeset(
            source: data,
            target: [
                ArraySection(
                    model: .contacts,
                    elements: (searchText.isEmpty ?
                        contacts :
                        contacts.filter {
                            $0.profile?.displayName().range(of: searchText, options: [.caseInsensitive]) != nil
                        }
                    )
                )
            ]
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
        ) { [weak self] updatedData in
            self?.data = updatedData
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
