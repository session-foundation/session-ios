// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import Combine
import GRDB
import DifferenceKit
import SessionUIKit
import SessionMessagingKit
import SessionUtilitiesKit
import SignalUtilitiesKit

public final class HomeVC: BaseVC, LibSessionRespondingViewController, UITableViewDataSource, UITableViewDelegate, SeedReminderViewDelegate {
    private static let loadingHeaderHeight: CGFloat = 40
    public static let newConversationButtonSize: CGFloat = 60
    
    private let viewModel: HomeViewModel
    private var disposables: Set<AnyCancellable> = Set()
    
    /// Currently loaded version of the data for the `tableView`, will always match the value in the `viewModel` unless it's part way
    /// through updating it's state
    private var sections: [HomeViewModel.SectionModel] = []
    private var initialConversationLoadComplete: Bool = false
    public var afterInitialConversationsLoad: (() -> Void)?
    
    // MARK: - LibSessionRespondingViewController
    
    public let isConversationList: Bool = true
    
    // MARK: - Intialization
    
    init(using dependencies: Dependencies) {
        self.viewModel = HomeViewModel(using: dependencies)
        
        super.init(nibName: nil, bundle: nil)
    }
    
    required init?(coder: NSCoder) {
        preconditionFailure("Use init() instead.")
    }
    
    // MARK: - UI
    
    private var tableViewTopConstraint: NSLayoutConstraint?
    private var loadingConversationsLabelTopConstraint: NSLayoutConstraint?
    private var navBarProfileView: ProfilePictureView?
    
    private lazy var seedReminderView: SeedReminderView = {
        let result = SeedReminderView()
        result.accessibilityLabel = "Recovery phrase reminder"
        result.title = NSAttributedString(string: "recoveryPasswordBannerTitle".localized())
        result.subtitle = "recoveryPasswordBannerDescription".localized()
        result.setProgress(1, animated: false)
        result.delegate = self
        result.isHidden = !self.viewModel.state.showViewedSeedBanner
        
        return result
    }()
    
    private lazy var loadingConversationsLabel: UILabel = {
        let result: UILabel = UILabel()
        result.translatesAutoresizingMaskIntoConstraints = false
        result.font = .systemFont(ofSize: Values.smallFontSize)
        result.text = "loading".localized()
        result.themeTextColor = .textSecondary
        result.textAlignment = .center
        result.numberOfLines = 0
        
        return result
    }()
    
    private lazy var tableView: UITableView = {
        let result = UITableView()
        result.separatorStyle = .none
        result.themeBackgroundColor = .clear
        result.contentInset = UIEdgeInsets(
            top: 0,
            left: 0,
            bottom: (
                Values.largeSpacing +
                HomeVC.newConversationButtonSize +
                Values.smallSpacing +
                (UIApplication.shared.keyWindow?.safeAreaInsets.bottom ?? 0)
            ),
            right: 0
        )
        result.showsVerticalScrollIndicator = false
        result.register(view: MessageRequestsCell.self)
        result.register(view: FullConversationCell.self)
        result.dataSource = self
        result.delegate = self
        result.sectionHeaderTopPadding = 0
        
        return result
    }()
    
    private lazy var appReviewPrompt: AppReviewPromptDialog = {
        let prompt = AppReviewPromptDialog()
        prompt.delegate = self
        prompt.translatesAutoresizingMaskIntoConstraints = false
        
        // Layers
        prompt.themeBorderColor = .borderSeparator
        prompt.layer.borderWidth = 1
        prompt.layer.cornerRadius = 12
        prompt.themeBackgroundColor = .backgroundSecondary
        
        return prompt
    }()
    
    private lazy var newConversationButton: UIView = {
        let result: UIView = UIView()
        result.set(.width, to: HomeVC.newConversationButtonSize)
        result.set(.height, to: HomeVC.newConversationButtonSize)
        
        let button = UIButton()
        button.accessibilityLabel = "New conversation button"
        button.isAccessibilityElement = true
        button.clipsToBounds = true
        button.setImage(
            UIImage(named: "Plus")?
                .withRenderingMode(.alwaysTemplate),
            for: .normal
        )
        button.contentMode = .center
        button.adjustsImageWhenHighlighted = false
        button.themeTintColor = .menuButton_icon
        button.setThemeBackgroundColor(.menuButton_background, for: .normal)
        button.setThemeBackgroundColor(
            .highlighted(.menuButton_background, alwaysDarken: true),
            for: .highlighted
        )
        button.contentEdgeInsets = UIEdgeInsets(
            top: ((HomeVC.newConversationButtonSize - 24) / 2),
            leading: ((HomeVC.newConversationButtonSize - 24) / 2),
            bottom: ((HomeVC.newConversationButtonSize - 24) / 2),
            trailing: ((HomeVC.newConversationButtonSize - 24) / 2)
        )
        button.layer.cornerRadius = (HomeVC.newConversationButtonSize / 2)
        button.addTarget(self, action: #selector(createNewConversation), for: .touchUpInside)
        result.addSubview(button)
        button.pin(to: result)
        
        // Add the outer shadow
        result.themeShadowColor = .menuButton_outerShadow
        result.layer.shadowRadius = 15
        result.layer.shadowOpacity = 0.3
        result.layer.shadowOffset = .zero
        result.layer.cornerRadius = (HomeVC.newConversationButtonSize / 2)
        result.layer.shadowPath = UIBezierPath(
            ovalIn: CGRect(
                origin: CGPoint.zero,
                size: CGSize(
                    width: HomeVC.newConversationButtonSize,
                    height: HomeVC.newConversationButtonSize
                )
            )
        ).cgPath
        
        // Add the inner shadow
        let innerShadowLayer: CALayer = CALayer()
        innerShadowLayer.masksToBounds = true
        innerShadowLayer.themeShadowColor = .menuButton_innerShadow
        innerShadowLayer.position = CGPoint(
            x: (HomeVC.newConversationButtonSize / 2),
            y: (HomeVC.newConversationButtonSize / 2)
        )
        innerShadowLayer.bounds = CGRect(
            x: 0,
            y: 0,
            width: HomeVC.newConversationButtonSize,
            height: HomeVC.newConversationButtonSize
        )
        innerShadowLayer.cornerRadius = (HomeVC.newConversationButtonSize / 2)
        innerShadowLayer.shadowOffset = .zero
        innerShadowLayer.shadowOpacity = 0.4
        innerShadowLayer.shadowRadius = 2
        
        let cutout: UIBezierPath = UIBezierPath(
            roundedRect: innerShadowLayer.bounds
                .insetBy(dx: innerShadowLayer.shadowRadius, dy: innerShadowLayer.shadowRadius),
            cornerRadius: (HomeVC.newConversationButtonSize / 2)
        ).reversing()
        let path: UIBezierPath = UIBezierPath(
            roundedRect: innerShadowLayer.bounds,
            cornerRadius: (HomeVC.newConversationButtonSize / 2)
        )
        path.append(cutout)
        innerShadowLayer.shadowPath = path.cgPath
        result.layer.addSublayer(innerShadowLayer)
        
        return result
    }()
    
    private lazy var emptyStateView: UIView = {
        let emptyConvoLabel = UILabel()
        emptyConvoLabel.font = .boldSystemFont(ofSize: Values.mediumFontSize)
        emptyConvoLabel.text = "conversationsNone".localized()
        emptyConvoLabel.themeTextColor = .textPrimary
        emptyConvoLabel.textAlignment = .center
        
        let instructionLabel = UILabel()
        instructionLabel.font = .systemFont(ofSize: Values.verySmallFontSize)
        instructionLabel.text = "onboardingHitThePlusButton".localized()
        instructionLabel.themeTextColor = .textPrimary
        instructionLabel.textAlignment = .center
        instructionLabel.lineBreakMode = .byWordWrapping
        instructionLabel.numberOfLines = 0
        
        let result = UIStackView(arrangedSubviews: [
            emptyConvoLabel,
            UIView.vSpacer(Values.smallSpacing),
            instructionLabel
        ])
        result.axis = .vertical
        result.spacing = Values.verySmallSpacing
        result.alignment = .center
        
        return result
    }()
    
    private lazy var emptyStateLogoView: UIView = {
        let sessionLogoImage: UIImageView = UIImageView(image: UIImage(named: "SessionGreen64"))
        sessionLogoImage.contentMode = .scaleAspectFit
        sessionLogoImage.set(.height, to: 103)
        
        let sessionTitleImage: UIImageView = UIImageView(
            image: UIImage(named: "SessionHeading")?
                .withRenderingMode(.alwaysTemplate)
        )
        sessionTitleImage.themeTintColor = .textPrimary
        sessionTitleImage.contentMode = .scaleAspectFit
        sessionTitleImage.set(.height, to: 22)
        
        let result = UIStackView(arrangedSubviews: [
            sessionLogoImage,
            UIView.vSpacer(Values.smallSpacing + Values.verySmallSpacing),
            sessionTitleImage,
            UIView.vSpacer(Values.verySmallSpacing)
        ])
        result.axis = .vertical
        result.spacing = Values.verySmallSpacing
        result.alignment = .fill
        result.isHidden = true
        
        return result
    }()
    
    private lazy var accountCreatedView: UIView = {
        let image: UIImageView = UIImageView(image: UIImage(named: "Hooray"))
        image.contentMode = .center
        image.set(.height, to: 96)
        
        let accountCreatedLabel = UILabel()
        accountCreatedLabel.font = .boldSystemFont(ofSize: Values.veryLargeFontSize)
        accountCreatedLabel.text = "onboardingAccountCreated".localized()
        accountCreatedLabel.themeTextColor = .textPrimary
        accountCreatedLabel.textAlignment = .center
        
        let welcomeLabel = UILabel()
        welcomeLabel.font = .systemFont(ofSize: Values.smallFontSize)
        welcomeLabel.text = "onboardingBubbleWelcomeToSession"
            .put(key: "app_name", value: Constants.app_name)
            .put(key: "emoji", value: "")
            .localized()
        welcomeLabel.themeTextColor = .sessionButton_text
        welcomeLabel.textAlignment = .center
        
        let result = UIStackView(arrangedSubviews: [
            image,
            accountCreatedLabel,
            welcomeLabel,
            UIView.vSpacer(Values.verySmallSpacing)
        ])
        result.axis = .vertical
        result.spacing = Values.verySmallSpacing
        result.alignment = .fill
        result.isHidden = true
        
        return result
    }()
    
    private lazy var emptyStateStackView: UIStackView = {
        let result = UIStackView(arrangedSubviews: [
            accountCreatedView,
            emptyStateLogoView,
            UIView.vSpacer(Values.smallSpacing),
            UIView.line(),
            UIView.vSpacer(Values.smallSpacing),
            emptyStateView
        ])
        result.axis = .vertical
        result.spacing = Values.verySmallSpacing
        result.alignment = .fill
        result.isHidden = true
        
        return result
    }()
    
    // MARK: - Lifecycle
    
    public override func viewDidLoad() {
        super.viewDidLoad()
        
        // Preparation
        updateNavBarButtons(
            userProfile: self.viewModel.state.userProfile,
            serviceNetwork: self.viewModel.state.serviceNetwork,
            forceOffline: self.viewModel.state.forceOffline
        )
        setUpNavBarSessionHeading()
        
        // Recovery phrase reminder
        view.addSubview(seedReminderView)
        seedReminderView.pin(.leading, to: .leading, of: view)
        seedReminderView.pin(.top, to: .top, of: view)
        seedReminderView.pin(.trailing, to: .trailing, of: view)
        
        // Loading conversations label
        view.addSubview(loadingConversationsLabel)
        
        loadingConversationsLabel.pin(.leading, to: .leading, of: view, withInset: 50)
        loadingConversationsLabel.pin(.trailing, to: .trailing, of: view, withInset: -50)
        
        // Table view
        view.addSubview(tableView)
        tableView.pin(.leading, to: .leading, of: view)
        tableView.pin(.trailing, to: .trailing, of: view)
        tableView.pin(.bottom, to: .bottom, of: view)
        
        if self.viewModel.state.showViewedSeedBanner {
            loadingConversationsLabelTopConstraint = loadingConversationsLabel.pin(.top, to: .bottom, of: seedReminderView, withInset: Values.mediumSpacing)
            tableViewTopConstraint = tableView.pin(.top, to: .bottom, of: seedReminderView)
        }
        else {
            loadingConversationsLabelTopConstraint = loadingConversationsLabel.pin(.top, to: .top, of: view, withInset: Values.veryLargeSpacing)
            tableViewTopConstraint = tableView.pin(.top, to: .top, of: view)
        }
        
        // Empty state view
        view.addSubview(emptyStateStackView)
        emptyStateStackView.set(.width, to: 300)
        emptyStateStackView.center(.horizontal, in: view)
        let verticalCenteringConstraint2 = emptyStateStackView.center(.vertical, in: view)
        verticalCenteringConstraint2.constant = -Values.massiveSpacing // Makes things appear centered visually
        
        // New conversation button
        view.addSubview(newConversationButton)
        newConversationButton.center(.horizontal, in: view)
        newConversationButton.pin(.bottom, to: .bottom, of: view.safeAreaLayoutGuide, withInset: -Values.smallSpacing)
        
        appReviewPrompt.updatePrompt(.none)
        
        // Preview prompt
        view.addSubview(appReviewPrompt)
        
        appReviewPrompt.pin(.left, to: .left, of: view, withInset: 12)
        appReviewPrompt.pin(.right, to: .right, of: view, withInset: -12)
        appReviewPrompt.pin(.bottom, to: .top, of: newConversationButton, withInset: -10)
        
        // Start polling if needed (i.e. if the user just created or restored their Session ID)
        if
            viewModel.dependencies[cache: .general].userExists,
            let appDelegate: AppDelegate = UIApplication.shared.delegate as? AppDelegate,
            viewModel.dependencies[singleton: .appContext].isMainAppAndActive
        {
            appDelegate.startPollersIfNeeded()
        }
        
        // Onion request path countries cache
        viewModel.dependencies.warmCache(cache: .ip2Country)
        
        // Check app review for rating retry
        viewModel.dependencies[singleton: .appReviewManager].checkIfCanRetryAppReview()
        
        // Bind the UI to the view model
        bindViewModel()
    }
    
    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        
        viewModel.dependencies[singleton: .notificationsManager].scheduleSessionNetworkPageLocalNotifcation(force: false)
        
        // Show app review dialog when all flags are valid
        viewModel.dependencies[singleton: .appReviewManager].shouldShowReviewModalNextTime()
    }
    
    // MARK: - Updating
    
    @MainActor public func afterInitialConversationsLoaded(_ closure: @escaping () -> Void) {
        guard viewModel.state.viewState == .loading else { return closure() }
        
        afterInitialConversationsLoad = closure
        
        /// Since we wouldn't have added the `HomeVC` to the view hierarchy yet it's possible it hasn't loaded it's view yet
        /// so we should trigger it to do so now if needed
        loadViewIfNeeded()
    }
    
    private func bindViewModel() {
        viewModel.$state
            .receive(on: DispatchQueue.main)
            .removeDuplicates()
            .sink { [weak self] state in self?.render(state: state) }
            .store(in: &disposables)
        
        viewModel
            .dependencies[singleton: .appReviewManager]
            .$currentPrompToShow
            .receive(on: DispatchQueue.main)
            .removeDuplicates()
            .sink { [weak self] state in self?.appReviewPrompt.updatePrompt(state) }
            .store(in: &disposables)
    }
    
    @MainActor private func render(state: HomeViewModel.State) {
        // Update nav
        updateNavBarButtons(
            userProfile: state.userProfile,
            serviceNetwork: state.serviceNetwork,
            forceOffline: state.forceOffline
        )
        
        // Update the 'view seed' UI
        let shouldHideSeedReminderView: Bool = !state.showViewedSeedBanner
        
        if seedReminderView.isHidden != shouldHideSeedReminderView {
            tableViewTopConstraint?.isActive = false
            loadingConversationsLabelTopConstraint?.isActive = false
            seedReminderView.isHidden = !state.showViewedSeedBanner
            
            if state.showViewedSeedBanner {
                loadingConversationsLabelTopConstraint = loadingConversationsLabel.pin(.top, to: .bottom, of: seedReminderView, withInset: Values.mediumSpacing)
                tableViewTopConstraint = tableView.pin(.top, to: .bottom, of: seedReminderView)
            }
            else {
                loadingConversationsLabelTopConstraint = loadingConversationsLabel.pin(.top, to: .top, of: view, withInset: Values.veryLargeSpacing)
                tableViewTopConstraint = tableView.pin(.top, to: .top, of: view, withInset: Values.smallSpacing)
            }
            
            view.layoutIfNeeded()
        }
        
        // Update the overall view state (loading, empty, or loaded)
        switch state.viewState {
        case .loading:
            loadingConversationsLabel.isHidden = false
            emptyStateStackView.isHidden = true
            
        case .empty(let isNewUser):
            loadingConversationsLabel.isHidden = true
            emptyStateStackView.isHidden = false
            accountCreatedView.isHidden = !isNewUser
            emptyStateLogoView.isHidden = isNewUser
            
        case .loaded:
            loadingConversationsLabel.isHidden = true
            emptyStateStackView.isHidden = true
        }
        
        // If we are still loading then don't try to load the table content (it'll be empty and we
        // don't want to trigger the callbacks until a successful load)
        guard state.viewState != .loading else { return }
        
        // Reload the table content (update without animations on the first render)
        guard initialConversationLoadComplete else {
            sections = state.sections(viewModel: viewModel)
            
            UIView.performWithoutAnimation {
                tableView.reloadData()
                afterInitialConversationsLoad?()
                afterInitialConversationsLoad = nil
                initialConversationLoadComplete = true
            }
            return
        }
        
        tableView.reload(
            using: StagedChangeset(source: self.sections, target: state.sections(viewModel: viewModel)),
            deleteSectionsAnimation: .none,
            insertSectionsAnimation: .none,
            reloadSectionsAnimation: .none,
            deleteRowsAnimation: .bottom,
            insertRowsAnimation: .none,
            reloadRowsAnimation: .none,
            interrupt: { $0.changeCount > 100 }    // Prevent too many changes from causing performance issues
        ) { [weak self] updatedData in
            self?.sections = updatedData
        }
    }
    
    private func updateNavBarButtons(
        userProfile: Profile,
        serviceNetwork: ServiceNetwork,
        forceOffline: Bool
    ) {
        // Profile picture view
        let profilePictureView = ProfilePictureView(
            size: .navigation,
            dataManager: viewModel.dependencies[singleton: .imageDataManager]
        )
        profilePictureView.accessibilityIdentifier = "User settings"
        profilePictureView.accessibilityLabel = "User settings"
        profilePictureView.isAccessibilityElement = true
        profilePictureView.update(
            publicKey: userProfile.id,
            threadVariant: .contact,
            displayPictureUrl: nil,
            profile: userProfile,
            profileIcon: {
                switch (serviceNetwork, forceOffline) {
                case (.testnet, false): return .letter("T", false)     // stringlint:ignore
                case (.testnet, true): return .letter("T", true)       // stringlint:ignore
                default: return .none
                }
            }(),
            additionalProfile: nil,
            using: viewModel.dependencies
        )
        navBarProfileView = profilePictureView
        
        let tapGestureRecognizer = UITapGestureRecognizer(target: self, action: #selector(openSettings))
        profilePictureView.addGestureRecognizer(tapGestureRecognizer)
        
        // Path status indicator
        let pathStatusView = PathStatusView(using: viewModel.dependencies)
        pathStatusView.accessibilityLabel = "Current onion routing path indicator"
        
        // Container view
        let profilePictureViewContainer = UIView()
        profilePictureViewContainer.addSubview(profilePictureView)
        profilePictureView.pin(to: profilePictureViewContainer)
        profilePictureViewContainer.addSubview(pathStatusView)
        pathStatusView.pin(.trailing, to: .trailing, of: profilePictureViewContainer)
        pathStatusView.pin(.bottom, to: .bottom, of: profilePictureViewContainer)
        
        // Left bar button item
        let leftBarButtonItem = UIBarButtonItem(customView: profilePictureViewContainer)
        leftBarButtonItem.isAccessibilityElement = true
        navigationItem.leftBarButtonItem = leftBarButtonItem
        
        // Right bar button item - search button
        let rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .search, target: self, action: #selector(showSearchUI))
        rightBarButtonItem.accessibilityLabel = "Search button"
        rightBarButtonItem.isAccessibilityElement  = true
        navigationItem.rightBarButtonItem = rightBarButtonItem
    }
    
    // MARK: - UITableViewDataSource
    
    public func numberOfSections(in tableView: UITableView) -> Int {
        return sections.count
    }
    
    public func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return sections[section].elements.count
    }
    
    public func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let section: HomeViewModel.SectionModel = sections[indexPath.section]
        
        switch section.model {
        case .messageRequests:
            let threadViewModel: SessionThreadViewModel = section.elements[indexPath.row]
            let cell: MessageRequestsCell = tableView.dequeue(type: MessageRequestsCell.self, for: indexPath)
            cell.accessibilityIdentifier = "Message requests banner"
            cell.isAccessibilityElement = true
            cell.update(with: Int(threadViewModel.threadUnreadCount ?? 0))
            return cell
            
        case .threads:
            let threadViewModel: SessionThreadViewModel = section.elements[indexPath.row]
            let cell: FullConversationCell = tableView.dequeue(type: FullConversationCell.self, for: indexPath)
            cell.update(with: threadViewModel, using: viewModel.dependencies)
            cell.accessibilityIdentifier = "Conversation list item"
            cell.accessibilityLabel = threadViewModel.displayName
            return cell
            
        default: preconditionFailure("Other sections should have no content")
        }
    }
    
    public func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        let section: HomeViewModel.SectionModel = sections[section]
        
        switch section.model {
        case .loadMore:
            let loadingIndicator: UIActivityIndicatorView = UIActivityIndicatorView(style: .medium)
            loadingIndicator.themeTintColor = .textPrimary
            loadingIndicator.alpha = 0.5
            loadingIndicator.startAnimating()
            
            let view: UIView = UIView()
            view.addSubview(loadingIndicator)
            loadingIndicator.center(in: view)
            
            return view
            
        default: return nil
        }
    }
    
    // MARK: - UITableViewDelegate
    
    public func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        let section: HomeViewModel.SectionModel = sections[section]
        
        switch section.model {
        case .loadMore: return HomeVC.loadingHeaderHeight
        default: return 0
        }
    }
    
    public func tableView(_ tableView: UITableView, willDisplayHeaderView view: UIView, forSection section: Int) {
        switch sections[section].model {
        case .loadMore: self.viewModel.loadNextPage()
        default: break
        }
    }
    
    public func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        
        let section: HomeViewModel.SectionModel = sections[indexPath.section]
        
        switch section.model {
        case .messageRequests:
            let viewController: SessionTableViewController = SessionTableViewController(
                viewModel: MessageRequestsViewModel(using: viewModel.dependencies)
            )
            self.navigationController?.pushViewController(viewController, animated: true)
            
        case .threads:
            let threadViewModel: SessionThreadViewModel = section.elements[indexPath.row]
            let viewController: ConversationVC = ConversationVC(
                threadId: threadViewModel.threadId,
                threadVariant: threadViewModel.threadVariant,
                focusedInteractionInfo: nil,
                using: viewModel.dependencies
            )
            self.navigationController?.pushViewController(viewController, animated: true)
            
        default: break
        }
    }
    
    public func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        return true
    }
    
    public func tableView(_ tableView: UITableView, willBeginEditingRowAt indexPath: IndexPath) {
        UIContextualAction.willBeginEditing(indexPath: indexPath, tableView: tableView)
    }
    
    public func tableView(_ tableView: UITableView, didEndEditingRowAt indexPath: IndexPath?) {
        UIContextualAction.didEndEditing(indexPath: indexPath, tableView: tableView)
    }
    
    public func tableView(_ tableView: UITableView, leadingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        let section: HomeViewModel.SectionModel = sections[indexPath.section]
        let threadViewModel: SessionThreadViewModel = section.elements[indexPath.row]
        
        switch section.model {
        case .threads:
            // Cannot properly sync outgoing blinded message requests so don't provide the option,
            // the 'Note to Self' conversation also doesn't support 'mark as unread' so don't
            // provide it there either
            guard
                threadViewModel.threadVariant != .legacyGroup &&
                    threadViewModel.threadId != threadViewModel.currentUserSessionId && (
                        threadViewModel.threadVariant != .contact ||
                        (try? SessionId(from: section.elements[indexPath.row].threadId))?.prefix == .standard
                    )
            else { return nil }
            
            return UIContextualAction.configuration(
                for: UIContextualAction.generateSwipeActions(
                    [.toggleReadStatus],
                    for: .leading,
                    indexPath: indexPath,
                    tableView: tableView,
                    threadViewModel: threadViewModel,
                    viewController: self,
                    navigatableStateHolder: viewModel,
                    using: viewModel.dependencies
                )
            )
            
        default: return nil
        }
    }
    
    public func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        let section: HomeViewModel.SectionModel = sections[indexPath.section]
        let threadViewModel: SessionThreadViewModel = section.elements[indexPath.row]
        
        switch section.model {
        case .messageRequests:
            return UIContextualAction.configuration(
                for: UIContextualAction.generateSwipeActions(
                    [.hide],
                    for: .trailing,
                    indexPath: indexPath,
                    tableView: tableView,
                    threadViewModel: threadViewModel,
                    viewController: self,
                    navigatableStateHolder: viewModel,
                    using: viewModel.dependencies
                )
            )
            
        case .threads:
            let sessionIdPrefix: SessionId.Prefix? = try? SessionId.Prefix(from: threadViewModel.threadId)
            
            // Cannot properly sync outgoing blinded message requests so only provide valid options
            let shouldHavePinAction: Bool = {
                switch threadViewModel.threadVariant {
                    // Only allow unpin for legacy groups
                case .legacyGroup: return threadViewModel.threadPinnedPriority > 0
                    
                default:
                    return (
                        sessionIdPrefix != .blinded15 &&
                        sessionIdPrefix != .blinded25
                    )
                }
            }()
            let shouldHaveMuteAction: Bool = {
                switch threadViewModel.threadVariant {
                case .contact: return (
                    !threadViewModel.threadIsNoteToSelf &&
                    sessionIdPrefix != .blinded15 &&
                    sessionIdPrefix != .blinded25
                )
                    
                case .group: return (threadViewModel.currentUserIsClosedGroupMember == true)
                    
                case .legacyGroup: return false
                case .community: return true
                }
            }()
            let destructiveAction: UIContextualAction.SwipeAction = {
                switch (threadViewModel.threadVariant, threadViewModel.threadIsNoteToSelf, threadViewModel.currentUserIsClosedGroupMember, threadViewModel.currentUserIsClosedGroupAdmin) {
                case (.contact, true, _, _): return .hide
                case (.group, _, true, false), (.community, _, _, _): return .leave
                default: return .delete
                }
            }()
            
            return UIContextualAction.configuration(
                for: UIContextualAction.generateSwipeActions(
                    [
                        (!shouldHavePinAction ? nil : .pin),
                        (!shouldHaveMuteAction ? nil : .mute),
                        destructiveAction
                    ].compactMap { $0 },
                    for: .trailing,
                    indexPath: indexPath,
                    tableView: tableView,
                    threadViewModel: threadViewModel,
                    viewController: self,
                    navigatableStateHolder: viewModel,
                    using: viewModel.dependencies
                )
            )
            
        default: return nil
        }
    }
    
    // MARK: - Interaction
    
    func handleContinueButtonTapped(from seedReminderView: SeedReminderView) {
        guard let recoveryPasswordView: RecoveryPasswordScreen = try? RecoveryPasswordScreen(using: viewModel.dependencies) else {
            let targetViewController: UIViewController = ConfirmationModal(
                info: ConfirmationModal.Info(
                    title: "theError".localized(),
                    body: .text("recoveryPasswordErrorLoad".localized()),
                    cancelTitle: "okay".localized(),
                    cancelStyle: .alert_text
                )
            )
            present(targetViewController, animated: true, completion: nil)
            return
        }
        
        let viewController: SessionHostingViewController = SessionHostingViewController(rootView: recoveryPasswordView)
        viewController.setNavBarTitle("sessionRecoveryPassword".localized())
        self.navigationController?.pushViewController(viewController, animated: true)
    }
    
    @objc private func openSettings() {
        let settingsViewController: SessionTableViewController = SessionTableViewController(
            viewModel: SettingsViewModel(using: viewModel.dependencies)
        )
        let navigationController = StyledNavigationController(rootViewController: settingsViewController)
        navigationController.modalPresentationStyle = .fullScreen
        present(navigationController, animated: true, completion: nil)
    }
    
    @objc private func showSearchUI() {
        if let presentedVC = self.presentedViewController {
            presentedVC.dismiss(animated: false, completion: nil)
        }
        let searchController = GlobalSearchViewController(using: viewModel.dependencies)
        self.navigationController?.setViewControllers([ self, searchController ], animated: true)
    }
    
    @objc private func createNewConversation() {
        viewModel.dependencies[singleton: .app].createNewConversation()
    }
    
    func createNewDMFromDeepLink(sessionId: String) {
        let viewController: SessionHostingViewController = SessionHostingViewController(
            rootView: NewMessageScreen(accountId: sessionId, using: viewModel.dependencies)
        )
        viewController.setNavBarTitle(
            "messageNew"
                .putNumber(1)
                .localized()
        )
        let navigationController = StyledNavigationController(rootViewController: viewController)
        if UIDevice.current.isIPad {
            navigationController.modalPresentationStyle = .fullScreen
        }
        navigationController.modalPresentationCapturesStatusBarAppearance = true
        present(navigationController, animated: true, completion: nil)
    }
}

extension HomeVC: AppReviewPromptDialogDelegate {
    func willHandlePromptState(_ state: AppReviewPromptState, isPrimary: Bool) {
        guard state != .enjoyingSession else {
            if isPrimary { viewModel.dependencies[singleton: .appReviewManager].scheduleAppReviewRetry() }

            return
        }
        
        appReviewPrompt.updatePrompt(.none)
        
        if isPrimary {
            switch state {
            case .feedback: showSurveyAlert()
            case .rateSession: viewModel.dependencies[singleton: .appReviewManager].willSubmitAppReview()
            default:  break
            }
        }
    }
    
    func didChangePromptState(_ state: AppReviewPromptState) {
        // Adjust insents so tableview can still be scrolled to bottom
        let originalBottomInsets = (
            Values.largeSpacing +
            HomeVC.newConversationButtonSize +
            Values.smallSpacing +
            (UIApplication.shared.keyWindow?.safeAreaInsets.bottom ?? 0)
        )
        
        if state == .none {
            tableView.contentInset.bottom = originalBottomInsets
        } else {
            tableView.contentInset.bottom = originalBottomInsets + (appReviewPrompt.frame.size.height + 24)
        }
    }
}

// MARK: - Alert for survey
private extension HomeVC {
    func showSurveyAlert() {
        guard let url: URL = URL(string: Constants.feedback_url) else { return }
        
        var surverUrl: URL {
            guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
                return url
            }
            
            // stringlint:ignore_contents
            components.queryItems = [
                .init(name: "platform", value: "iOS"),
                .init(name: "version", value: viewModel.dependencies[cache: .appVersion].appVersion)
            ]
            
            guard let finalURL = components.url else { return url }
            
            return finalURL
        }
        let modal: ConfirmationModal = ConfirmationModal(
            info: ConfirmationModal.Info(
                title: "urlOpen".localized(),
                body: .attributedText(
                    "urlOpenDescription"
                        .put(key: "url", value: url.absoluteString)
                        .localizedFormatted(baseFont: .systemFont(ofSize: Values.smallFontSize))
                ),
                confirmTitle: "open".localized(),
                confirmStyle: .danger,
                cancelTitle: "urlCopy".localized(),
                cancelStyle: .alert_text,
                hasCloseButton: true,
                onConfirm: { modal in
                    UIApplication.shared.open(surverUrl, options: [:], completionHandler: nil)
                    modal.dismiss(animated: true)
                },
                onCancel: { modal in
                    UIPasteboard.general.string = surverUrl.absoluteString
                    
                    modal.dismiss(animated: true)
                }
            )
        )
        
        present(modal, animated: true)
    }
}
