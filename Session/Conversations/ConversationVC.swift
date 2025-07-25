// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import AVKit
import GRDB
import DifferenceKit
import Lucide
import SessionUIKit
import SessionMessagingKit
import SessionUtilitiesKit
import SignalUtilitiesKit

final class ConversationVC: BaseVC, LibSessionRespondingViewController, ConversationSearchControllerDelegate, UITableViewDataSource, UITableViewDelegate {
    private static let loadingHeaderHeight: CGFloat = 40
    
    internal let viewModel: ConversationViewModel
    private var dataChangeObservable: DatabaseCancellable? {
        didSet { oldValue?.cancel() }   // Cancel the old observable if there was one
    }
    private var hasLoadedInitialThreadData: Bool = false
    private var hasLoadedInitialInteractionData: Bool = false
    private var currentTargetOffset: CGPoint?
    private var isAutoLoadingNextPage: Bool = false
    private var isLoadingMore: Bool = false
    var isReplacingThread: Bool = false
    var isKeyboardVisible: Bool = false
    
    /// This flag indicates whether the thread data has been reloaded after a disappearance (it defaults to true as it will
    /// never have disappeared before - this is only needed for value observers since they run asynchronously)
    private var hasReloadedThreadDataAfterDisappearance: Bool = true
    
    var focusedInteractionInfo: Interaction.TimestampInfo?
    var focusBehaviour: ConversationViewModel.FocusBehaviour = .none
    
    // Search
    var isShowingSearchUI = false
    
    // Audio playback & recording
    var audioPlayer: OWSAudioPlayer?
    var audioRecorder: AVAudioRecorder?
    var audioTimer: Timer?
    
    // Context menu
    var contextMenuWindow: ContextMenuWindow?
    var contextMenuVC: ContextMenuVC?
    
    // Mentions
    var currentMentionStartIndex: String.Index?
    var mentions: [MentionInfo] = []
    
    // Scrolling & paging
    var isUserScrolling = false
    var hasPerformedInitialScroll = false
    var didFinishInitialLayout = false
    var scrollDistanceToBottomBeforeUpdate: CGFloat?
    var baselineKeyboardHeight: CGFloat = 0
    
    /// These flags are true between `viewDid/Will Appear/Disappear` and is used to prevent keyboard changes
    /// from trying to animate (as the animations can cause buggy transitions)
    var viewIsDisappearing = false
    var viewIsAppearing = false
    var lastPresentedViewController: UIViewController?
    
    // Reaction
    var currentReactionListSheet: ReactionListSheet?
    var reactionExpandedMessageIds: Set<String> = []

    /// This flag is used to temporarily prevent the ConversationVC from becoming the first responder (primarily used with
    /// custom transitions from preventing them from being buggy
    var delayFirstResponder: Bool = false
    override var canBecomeFirstResponder: Bool {
        !delayFirstResponder &&
        
        // Need to return false during the swap between threads to prevent keyboard dismissal
        !isReplacingThread
    }
    
    override var inputAccessoryView: UIView? {
        return (viewModel.threadData.threadCanWrite == true && isShowingSearchUI ?
            searchController.resultsBar :
            snInputView
        )
    }

    /// The height of the visible part of the table view, i.e. the distance from the navigation bar (where the table view's origin is)
    /// to the top of the input view (`tableView.adjustedContentInset.bottom`).
    var tableViewUnobscuredHeight: CGFloat {
        let bottomInset = tableView.adjustedContentInset.bottom
        return tableView.bounds.height - bottomInset
    }

    /// The offset at which the table view is exactly scrolled to the bottom.
    var lastPageTop: CGFloat {
        return tableView.contentSize.height - tableViewUnobscuredHeight
    }

    var isCloseToBottom: Bool {
        let margin = (self.lastPageTop - self.tableView.contentOffset.y)
        return margin <= ConversationVC.scrollToBottomMargin
    }

    lazy var mnemonic: String = { ((try? Identity.mnemonic(using: viewModel.dependencies)) ?? "") }()

    lazy var recordVoiceMessageActivity = AudioActivity(
        audioDescription: "Voice message",  // stringlint:ignore
        behavior: .playAndRecord
    )

    lazy var searchController: ConversationSearchController = {
        let result: ConversationSearchController = ConversationSearchController(
            threadId: self.viewModel.threadData.threadId
        )
        result.uiSearchController.obscuresBackgroundDuringPresentation = false
        result.delegate = self
        
        return result
    }()

    // MARK: - UI
    
    var lastKnownKeyboardFrame: CGRect?
    
    var scrollButtonBottomConstraint: NSLayoutConstraint?
    var scrollButtonMessageRequestsBottomConstraint: NSLayoutConstraint?
    var messageRequestsViewBotomConstraint: NSLayoutConstraint?
    var legacyGroupsFooterViewViewTopConstraint: NSLayoutConstraint?
    
    lazy var titleView: ConversationTitleView = {
        let result: ConversationTitleView = ConversationTitleView(using: viewModel.dependencies)
        let tapGestureRecognizer = UITapGestureRecognizer(
            target: self,
            action: #selector(handleTitleViewTapped)
        )
        result.addGestureRecognizer(tapGestureRecognizer)
        
        return result
    }()

    lazy var tableView: InsetLockableTableView = {
        let result: InsetLockableTableView = InsetLockableTableView()
        result.separatorStyle = .none
        result.themeBackgroundColor = .clear
        result.showsVerticalScrollIndicator = false
        result.keyboardDismissMode = .interactive
        result.contentInset = UIEdgeInsets(
            top: 0,
            leading: 0,
            bottom: (viewModel.threadData.threadCanWrite == true ?
                Values.mediumSpacing :
                (Values.mediumSpacing + (UIApplication.shared.keyWindow?.safeAreaInsets.bottom ?? 0))
            ),
            trailing: 0
        )
        result.registerHeaderFooterView(view: UITableViewHeaderFooterView.self)
        result.register(view: DateHeaderCell.self)
        result.register(view: UnreadMarkerCell.self)
        result.register(view: VisibleMessageCell.self)
        result.register(view: InfoMessageCell.self)
        result.register(view: TypingIndicatorCell.self)
        result.register(view: CallMessageCell.self)
        result.estimatedSectionHeaderHeight = ConversationVC.loadingHeaderHeight
        result.sectionFooterHeight = 0
        result.dataSource = self
        result.delegate = self
        result.contentInsetAdjustmentBehavior = .never  // We custom handle it to prevent bugs

        return result
    }()

    lazy var snInputView: InputView = InputView(
        threadVariant: self.viewModel.initialThreadVariant,
        delegate: self,
        using: self.viewModel.dependencies
    )

    lazy var unreadCountView: UIView = {
        let result: UIView = UIView()
        result.themeBackgroundColor = .backgroundSecondary
        result.layer.masksToBounds = true
        result.layer.cornerRadius = (ConversationVC.unreadCountViewSize / 2)
        result.set(.width, greaterThanOrEqualTo: ConversationVC.unreadCountViewSize)
        result.set(.height, to: ConversationVC.unreadCountViewSize)
        result.isHidden = true
        result.alpha = 0
        
        return result
    }()

    lazy var unreadCountLabel: UILabel = {
        let result: UILabel = UILabel()
        result.font = .boldSystemFont(ofSize: Values.verySmallFontSize)
        result.themeTextColor = .textPrimary
        result.textAlignment = .center
        
        return result
    }()
    
    lazy var stateStackView: UIStackView = {
        let result: UIStackView = UIStackView(arrangedSubviews: [
            outdatedClientBanner,
            legacyGroupsBanner,
            expiredGroupBanner,
            emptyStatePaddingView,
            emptyStateLabelContainer
        ])
        result.axis = .vertical
        result.spacing = Values.smallSpacing
        result.alignment = .fill
        
        return result
    }()
    
    lazy var outdatedClientBanner: InfoBanner = {
        let result: InfoBanner = InfoBanner(
            info: InfoBanner.Info(
                font: .systemFont(ofSize: Values.verySmallFontSize),
                message: "disappearingMessagesLegacy"
                    .put(key: "name", value: self.viewModel.threadData.displayName)
                    .localizedFormatted(baseFont: .systemFont(ofSize: Values.verySmallFontSize)),
                icon: .close,
                tintColor: .messageBubble_outgoingText,
                backgroundColor: .primary,
                labelAccessibility: Accessibility(identifier: "Outdated client banner"),
                height: 40,
                onTap: { [weak self] in self?.removeOutdatedClientBanner() }
            )
        )
        result.isHidden = true
        
        return result
    }()

    lazy var legacyGroupsBanner: InfoBanner = {
        let result: InfoBanner = InfoBanner(
            info: InfoBanner.Info(
                font: viewModel.legacyGroupsBannerFont,
                message: viewModel.legacyGroupsBannerMessage,
                icon: .none,
                tintColor: .messageBubble_outgoingText,
                backgroundColor: .primary,
                labelAccessibility: Accessibility(identifier: "Legacy group banner"),
                height: nil,
                onTap: { [weak self] in self?.openUrl(Features.legacyGroupDepricationUrl) }
            )
        )
        result.isHidden = (viewModel.threadData.threadVariant != .legacyGroup)
        
        return result
    }()
    
    lazy var expiredGroupBanner: InfoBanner = {
        let result: InfoBanner = InfoBanner(
            info: InfoBanner.Info(
                font: .systemFont(ofSize: Values.miniFontSize),
                message: "groupNotUpdatedWarning"
                    .localizedFormatted(baseFont: .systemFont(ofSize: Values.miniFontSize)),
                icon: .none,
                tintColor: .black,
                backgroundColor: .explicitPrimary(.orange),
                labelAccessibility: Accessibility(identifier: "Expired group banner"),
                height: nil
            )
        )
        result.isHidden = (
            viewModel.threadData.threadVariant != .group ||
            viewModel.threadData.closedGroupExpired != true
        )
        
        return result
    }()
    
    private lazy var emptyStatePaddingView: UIView = {
        let result: UIView = UIView()
        result.set(.height, to: Values.largeSpacing)
        
        return result
    }()
    
    private lazy var emptyStateLabelContainer: UIView = {
        let result: UIView = UIView()
        result.addSubview(emptyStateLabel)
        emptyStateLabel.pin(.top, to: .top, of: result)
        emptyStateLabel.pin(.leading, to: .leading, of: result, withInset: Values.largeSpacing)
        emptyStateLabel.pin(.trailing, to: .trailing, of: result, withInset: -Values.largeSpacing)
        emptyStateLabel.pin(.bottom, to: .bottom, of: result)
        
        return result
    }()
    
    private lazy var emptyStateLabel: UILabel = {
        let result: UILabel = UILabel()
        result.accessibilityIdentifier = "Control message"
        result.translatesAutoresizingMaskIntoConstraints = false
        result.font = .systemFont(ofSize: Values.verySmallFontSize)
        result.themeAttributedText = viewModel.emptyStateText(for: viewModel.threadData).formatted(in: result)
        result.themeTextColor = .textSecondary
        result.textAlignment = .center
        result.lineBreakMode = .byWordWrapping
        result.numberOfLines = 0

        return result
    }()

    lazy var footerControlsStackView: UIStackView = {
        let result: UIStackView = UIStackView()
        result.translatesAutoresizingMaskIntoConstraints = false
        result.axis = .vertical
        result.alignment = .trailing
        result.distribution = .equalSpacing
        result.spacing = 10
        result.layoutMargins = UIEdgeInsets(top: 0, left: 20, bottom: 0, right: 20)
        result.isLayoutMarginsRelativeArrangement = true

        return result
    }()

    lazy var scrollButton: RoundIconButton = {
        let result: RoundIconButton = RoundIconButton(
            image: UIImage(named: "ic_chevron_down")?
                .withRenderingMode(.alwaysTemplate)
        ) { [weak self] in
            // The table view's content size is calculated by the estimated height of cells,
            // so the result may be inaccurate before all the cells are loaded. Use this
            // to scroll to the last row instead.
            self?.scrollToBottom(isAnimated: true)
        }
        result.alpha = 0
        result.accessibilityIdentifier = "Scroll button"
        result.isAccessibilityElement = true
        
        return result
    }()
    
    lazy var messageRequestFooterView: MessageRequestFooterView = MessageRequestFooterView(
        threadVariant: self.viewModel.threadData.threadVariant,
        canWrite: (self.viewModel.threadData.threadCanWrite == true),
        threadIsMessageRequest: (self.viewModel.threadData.threadIsMessageRequest == true),
        threadRequiresApproval: (self.viewModel.threadData.threadRequiresApproval == true),
        closedGroupAdminProfile: self.viewModel.threadData.closedGroupAdminProfile,
        onBlock: { [weak self] in self?.blockMessageRequest() },
        onAccept: { [weak self] in self?.acceptMessageRequest() },
        onDecline: { [weak self] in self?.declineMessageRequest() }
    )
    
    private lazy var legacyGroupsRecreateGroupView: UIView = {
        let result: UIView = UIView()
        result.isHidden = (
            viewModel.threadData.threadVariant != .legacyGroup ||
            viewModel.threadData.currentUserIsClosedGroupAdmin != true
        )
        
        return result
    }()
    
    private lazy var legacyGroupsFadeView: GradientView = {
        let result: GradientView = GradientView()
        result.themeBackgroundGradient = [
            .value(.backgroundPrimary, alpha: 0), // Want this to take up 20% (~20px)
            .backgroundPrimary,
            .backgroundPrimary,
            .backgroundPrimary
        ]
        result.set(.height, to: 92)
        
        return result
    }()
    
    private lazy var legacyGroupsInputBackgroundView: UIView = {
        let result: UIView = UIView()
        result.themeBackgroundColor = .backgroundPrimary
        
        return result
    }()
    
    private lazy var legacyGroupsFooterButton: SessionButton = {
        let result: SessionButton = SessionButton(style: .bordered, size: .large)
        result.translatesAutoresizingMaskIntoConstraints = false
        result.setTitle("recreateGroup".localized(), for: .normal)
        result.addTarget(self, action: #selector(recreateLegacyGroupTapped), for: .touchUpInside)
        result.accessibilityIdentifier = "Legacy Groups Recreate Button"
        
        return result
    }()

    // MARK: - Settings
    
    static let unreadCountViewSize: CGFloat = 20
    /// The table view's bottom inset (content will have this distance to the bottom if the table view is fully scrolled down).
    static let bottomInset = Values.mediumSpacing
    /// The table view will start loading more content when the content offset becomes less than this.
    static let loadMoreThreshold: CGFloat = 120
    /// The button will be fully visible once the user has scrolled this amount from the bottom of the table view.
    static let scrollButtonFullVisibilityThreshold: CGFloat = 80
    /// The button will be invisible until the user has scrolled at least this amount from the bottom of the table view.
    static let scrollButtonNoVisibilityThreshold: CGFloat = 20
    /// Automatically scroll to the bottom of the conversation when sending a message if the scroll distance from the bottom is less than this number.
    static let scrollToBottomMargin: CGFloat = 60

    // MARK: - Initialization
    
    init(
        threadId: String,
        threadVariant: SessionThread.Variant,
        focusedInteractionInfo: Interaction.TimestampInfo? = nil,
        using dependencies: Dependencies
    ) {
        self.viewModel = ConversationViewModel(
            threadId: threadId,
            threadVariant: threadVariant,
            focusedInteractionInfo: focusedInteractionInfo,
            using: dependencies
        )
        
        /// Dispatch adding the database observation to a background thread
        DispatchQueue.global(qos: .userInitiated).async { [weak viewModel] in
            dependencies[singleton: .storage].addObserver(viewModel?.pagedDataObserver)
        }
        
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        preconditionFailure("Use init(thread:) instead.")
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        
        navigationItem.titleView = titleView
        
        // Note: We need to update the nav bar buttons here (with invalid data) because if we don't the
        // nav will be offset incorrectly during the push animation (unfortunately the profile icon still
        // doesn't appear until after the animation, I assume it's taking a snapshot or something, but
        // there isn't much we can do about that unfortunately)
        updateNavBarButtons(
            threadData: nil,
            initialVariant: self.viewModel.initialThreadVariant,
            initialIsNoteToSelf: self.viewModel.threadData.threadIsNoteToSelf,
            initialIsBlocked: (self.viewModel.threadData.threadIsBlocked == true)
        )
        titleView.initialSetup(
            with: self.viewModel.initialThreadVariant,
            isNoteToSelf: self.viewModel.threadData.threadIsNoteToSelf,
            isMessageRequest: (self.viewModel.threadData.threadIsMessageRequest == true)
        )
        
        // Constraints
        view.addSubview(tableView)
        tableView.pin(to: view)

        // Message requests view & scroll to bottom
        view.addSubview(scrollButton)
        view.addSubview(stateStackView)
        view.addSubview(messageRequestFooterView)
        view.addSubview(legacyGroupsRecreateGroupView)
        
        legacyGroupsRecreateGroupView.addSubview(legacyGroupsInputBackgroundView)
        legacyGroupsRecreateGroupView.addSubview(legacyGroupsFadeView)
        legacyGroupsRecreateGroupView.addSubview(legacyGroupsFooterButton)
        
        stateStackView.pin(.top, to: .top, of: view, withInset: 0)
        stateStackView.pin(.leading, to: .leading, of: view, withInset: 0)
        stateStackView.pin(.trailing, to: .trailing, of: view, withInset: 0)
        
        scrollButton.pin(.trailing, to: .trailing, of: view, withInset: -20)
        messageRequestFooterView.pin(.leading, to: .leading, of: view, withInset: 16)
        messageRequestFooterView.pin(.trailing, to: .trailing, of: view, withInset: -16)
        self.messageRequestsViewBotomConstraint = messageRequestFooterView.pin(.bottom, to: .bottom, of: view, withInset: -16)
        self.scrollButtonBottomConstraint = scrollButton.pin(.bottom, to: .bottom, of: view, withInset: -16)
        self.scrollButtonBottomConstraint?.isActive = false // Note: Need to disable this to avoid a conflict with the other bottom constraint
        self.scrollButtonMessageRequestsBottomConstraint = scrollButton.pin(.bottom, to: .top, of: messageRequestFooterView, withInset: -4)
        
        legacyGroupsFooterViewViewTopConstraint = legacyGroupsRecreateGroupView
            .pin(.top, to: .bottom, of: view, withInset: -Values.footerGradientHeight(window: UIApplication.shared.keyWindow))
        legacyGroupsRecreateGroupView.pin(.leading, to: .leading, of: view)
        legacyGroupsRecreateGroupView.pin(.trailing, to: .trailing, of: view)
        legacyGroupsRecreateGroupView.pin(.bottom, to: .bottom, of: view)
        legacyGroupsFadeView.pin(.top, to: .top, of: legacyGroupsRecreateGroupView)
        legacyGroupsFadeView.pin(.leading, to: .leading, of: legacyGroupsRecreateGroupView)
        legacyGroupsFadeView.pin(.trailing, to: .trailing, of: legacyGroupsRecreateGroupView)
        legacyGroupsInputBackgroundView.pin(.top, to: .bottom, of: legacyGroupsFadeView)
        legacyGroupsInputBackgroundView.pin(.leading, to: .leading, of: legacyGroupsRecreateGroupView)
        legacyGroupsInputBackgroundView.pin(.trailing, to: .trailing, of: legacyGroupsRecreateGroupView)
        legacyGroupsInputBackgroundView.pin(.bottom, to: .bottom, of: legacyGroupsRecreateGroupView)
        legacyGroupsFooterButton.pin(.top, to: .top, of: legacyGroupsFadeView, withInset: 32)
        legacyGroupsFooterButton.pin(.leading, to: .leading, of: legacyGroupsFadeView, withInset: 16)
        legacyGroupsFooterButton.pin(.trailing, to: .trailing, of: legacyGroupsFadeView, withInset: -16)

        // Unread count view
        view.addSubview(unreadCountView)
        unreadCountView.addSubview(unreadCountLabel)
        unreadCountLabel.pin(.top, to: .top, of: unreadCountView)
        unreadCountLabel.pin(.bottom, to: .bottom, of: unreadCountView)
        unreadCountView.pin(.leading, to: .leading, of: unreadCountLabel, withInset: -4)
        unreadCountView.pin(.trailing, to: .trailing, of: unreadCountLabel, withInset: 4)
        unreadCountView.centerYAnchor.constraint(equalTo: scrollButton.topAnchor).isActive = true
        unreadCountView.center(.horizontal, in: scrollButton)

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
       
        // Observe keyboard notifications
        let keyboardNotifications: [Notification.Name] = [
            UIResponder.keyboardWillShowNotification,
            UIResponder.keyboardDidShowNotification,
            UIResponder.keyboardWillChangeFrameNotification,
            UIResponder.keyboardDidChangeFrameNotification,
            UIResponder.keyboardWillHideNotification,
            UIResponder.keyboardDidHideNotification
        ]
        keyboardNotifications.forEach { notification in
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleKeyboardNotification(_:)),
                name: notification,
                object: nil
            )
        }

        self.viewModel.navigatableState.setupBindings(viewController: self, disposables: &self.viewModel.disposables)
        
        // The first time the view loads we should mark the thread as read (in case it was manually
        // marked as unread) - doing this here means if we add a "mark as unread" action within the
        // conversation settings then we don't need to worry about the conversation getting marked as
        // when when the user returns back through this view controller
        self.viewModel.markAsRead(target: .thread, timestampMs: nil)
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        
        startObservingChanges()
        
        /// If the view is removed and readded to the view hierarchy then `viewWillDisappear` will be called but `viewDidDisappear`
        /// **won't**, as a result `viewIsDisappearing` would never get set to `false` - do so here to handle this case
        viewIsDisappearing = false
        viewIsAppearing = true
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        
        if delayFirstResponder || isShowingSearchUI {
            delayFirstResponder = false
            
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(50)) { [weak self] in
                (self?.isShowingSearchUI == false ?
                    self :
                    self?.searchController.uiSearchController.searchBar
                )?.becomeFirstResponder()
            }
        }
        else if !self.isFirstResponder && hasLoadedInitialThreadData && lastPresentedViewController == nil {
            // After we have loaded the initial data if the user starts and cancels the interactive pop
            // gesture the input view will disappear (but if we are returning from a presented view controller
            // the keyboard will automatically reappear and calling this will break the first responder state
            // so don't do it in that case)
            self.becomeFirstResponder()
        }
        
        recoverInputView { [weak self] in
            // Flag that the initial layout has been completed (the flag blocks and unblocks a number
            // of different behaviours)
            self?.didFinishInitialLayout = true
            self?.viewIsAppearing = false
            self?.lastPresentedViewController = nil
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        
        viewIsDisappearing = true
        lastPresentedViewController = self.presentedViewController
        
        // Don't set the draft or resign the first responder if we are replacing the thread (want the keyboard
        // to appear to remain focussed)
        guard !isReplacingThread else { return }
        
        stopObservingChanges()
        viewModel.updateDraft(to: snInputView.text)
        inputAccessoryView?.resignFirstResponder()        
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        
        hasReloadedThreadDataAfterDisappearance = false
        viewIsDisappearing = false
        
        /// If the user just created this thread but didn't send a message or the conversation is marked as hidden then we want to delete the
        /// "shadow" thread since it's not actually in use (this is to prevent it from taking up database space or unintentionally getting synced
        /// via `libSession` in the future)
        let threadId: String = viewModel.threadData.threadId
        
        if
            (
                self.navigationController == nil ||
                self.navigationController?.viewControllers.contains(self) == false
            ) &&
            viewModel.threadData.threadIsNoteToSelf == false &&
            viewModel.threadData.threadIsDraft == true
        {
            viewModel.dependencies[singleton: .storage].writeAsync { db in
                _ = try SessionThread   // Intentionally use `deleteAll` here instead of `deleteOrLeave`
                    .filter(id: threadId)
                    .deleteAll(db)
            }
        }
        
        /// Should only be `true` when the view controller is being removed from the stack
        if isMovingFromParent {
            DispatchQueue.global(qos: .userInitiated).async { [weak self, dependencies = viewModel.dependencies] in
                dependencies[singleton: .storage].removeObserver(self?.viewModel.pagedDataObserver)
            }
        }
    }
    
    @objc func applicationDidBecomeActive(_ notification: Notification) {
        /// **Note:** When returning from the background we could have received notifications but the `PagedDatabaseObserver`
        /// won't have them so we need to force a re-fetch of the current data to ensure everything is up to date
        DispatchQueue.global(qos: .background).async { [weak self] in
            self?.viewModel.pagedDataObserver?.resume()
        }
        
        recoverInputView()
        
        if !isShowingSearchUI && self.presentedViewController == nil {
            if !self.isFirstResponder {
                self.becomeFirstResponder()
            }
            else {
                self.reloadInputViews()
            }
        }
    }
    
    @objc func applicationDidResignActive(_ notification: Notification) {
        /// When going into the background we should stop listening to database changes (we will resume/reload after returning from
        /// the background)
        viewModel.pagedDataObserver?.suspend()
    }
    
    // MARK: - Updating
    
    private func startObservingChanges() {
        guard dataChangeObservable == nil else { return }
        
        dataChangeObservable = viewModel.dependencies[singleton: .storage].start(
            viewModel.observableThreadData,
            onError: { _ in },
            onChange: { [weak self, dependencies = viewModel.dependencies] maybeThreadData in
                guard let threadData: SessionThreadViewModel = maybeThreadData else {
                    // If the thread data is null and the id was blinded then we just unblinded the thread
                    // and need to swap over to the new one
                    guard
                        let sessionId: String = self?.viewModel.threadData.threadId,
                        (
                            (try? SessionId.Prefix(from: sessionId)) == .blinded15 ||
                            (try? SessionId.Prefix(from: sessionId)) == .blinded25
                        ),
                        let blindedLookup: BlindedIdLookup = dependencies[singleton: .storage].read({ db in
                            try BlindedIdLookup
                                .filter(id: sessionId)
                                .fetchOne(db)
                        }),
                        let unblindedId: String = blindedLookup.sessionId
                    else {
                        // If we don't have an unblinded id then something has gone very wrong so pop to the
                        // nearest conversation list
                        let maybeTargetViewController: UIViewController? = self?.navigationController?
                            .viewControllers
                            .last(where: { ($0 as? LibSessionRespondingViewController)?.isConversationList == true })
                        
                        if let targetViewController: UIViewController = maybeTargetViewController {
                            self?.navigationController?.popToViewController(targetViewController, animated: true)
                        }
                        else {
                            self?.navigationController?.popToRootViewController(animated: true)
                        }
                        return
                    }
                    
                    // Stop observing changes
                    self?.stopObservingChanges()
                    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                        dependencies[singleton: .storage].removeObserver(self?.viewModel.pagedDataObserver)
                    }
                    
                    // Swap the observing to the updated thread
                    let newestVisibleMessageId: Int64? = self?.fullyVisibleCellViewModels()?.last?.id
                    self?.viewModel.swapToThread(updatedThreadId: unblindedId, focussedMessageId: newestVisibleMessageId)
                    
                    /// Start observing changes again (on a background thread)
                    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                        dependencies[singleton: .storage].addObserver(self?.viewModel.pagedDataObserver)
                    }
                    self?.startObservingChanges()
                    return
                }
                
                // The default scheduler emits changes on the main thread
                self?.handleThreadUpdates(threadData)
                
                // Note: We want to load the interaction data into the UI after the initial thread data
                // has loaded to prevent an issue where the conversation loads with the wrong offset
                if self?.viewModel.onInteractionChange == nil {
                    self?.viewModel.onInteractionChange = { [weak self] updatedInteractionData, changeset in
                        self?.handleInteractionUpdates(updatedInteractionData, changeset: changeset)
                    }
                }
            }
        )
    }
    
    func stopObservingChanges() {
        self.dataChangeObservable?.cancel()
        self.dataChangeObservable = nil
        self.viewModel.onInteractionChange = nil
    }
    
    private func handleThreadUpdates(_ updatedThreadData: SessionThreadViewModel, initialLoad: Bool = false) {
        // Ensure the first load or a load when returning from a child screen runs without animations (if
        // we don't do this the cells will animate in from a frame of CGRect.zero or have a buggy transition)
        guard hasLoadedInitialThreadData && hasReloadedThreadDataAfterDisappearance else {
            // Need to correctly determine if it's the initial load otherwise we would be needlesly updating
            // extra UI elements
            let isInitialLoad: Bool = (
                !hasLoadedInitialThreadData &&
                hasReloadedThreadDataAfterDisappearance
            )
            hasLoadedInitialThreadData = true
            hasReloadedThreadDataAfterDisappearance = true
            
            UIView.performWithoutAnimation {
                handleThreadUpdates(updatedThreadData, initialLoad: isInitialLoad)
            }
            return
        }
        
        // Update general conversation UI
        
        if
            initialLoad ||
            viewModel.threadData.displayName != updatedThreadData.displayName ||
            viewModel.threadData.threadVariant != updatedThreadData.threadVariant ||
            viewModel.threadData.threadIsNoteToSelf != updatedThreadData.threadIsNoteToSelf ||
            viewModel.threadData.threadMutedUntilTimestamp != updatedThreadData.threadMutedUntilTimestamp ||
            viewModel.threadData.threadOnlyNotifyForMentions != updatedThreadData.threadOnlyNotifyForMentions ||
            viewModel.threadData.userCount != updatedThreadData.userCount ||
            viewModel.threadData.disappearingMessagesConfiguration != updatedThreadData.disappearingMessagesConfiguration
        {
            titleView.update(
                with: updatedThreadData.displayName,
                isNoteToSelf: updatedThreadData.threadIsNoteToSelf,
                isMessageRequest: (updatedThreadData.threadIsMessageRequest == true),
                threadVariant: updatedThreadData.threadVariant,
                mutedUntilTimestamp: updatedThreadData.threadMutedUntilTimestamp,
                onlyNotifyForMentions: (updatedThreadData.threadOnlyNotifyForMentions == true),
                userCount: updatedThreadData.userCount,
                disappearingMessagesConfig: updatedThreadData.disappearingMessagesConfiguration
            )
            
            // Update the empty state
            emptyStateLabel.themeAttributedText = viewModel
                .emptyStateText(for: updatedThreadData)
                .formatted(in: emptyStateLabel)
        }
        
        if
            initialLoad ||
            viewModel.threadData.threadVariant != updatedThreadData.threadVariant ||
            viewModel.threadData.threadIsNoteToSelf != updatedThreadData.threadIsNoteToSelf ||
            viewModel.threadData.threadIsBlocked != updatedThreadData.threadIsBlocked ||
            viewModel.threadData.threadIsMessageRequest != updatedThreadData.threadIsMessageRequest ||
            viewModel.threadData.threadRequiresApproval != updatedThreadData.threadRequiresApproval ||
            viewModel.threadData.profile != updatedThreadData.profile ||
            viewModel.threadData.additionalProfile != updatedThreadData.additionalProfile ||
            viewModel.threadData.displayPictureFilename != updatedThreadData.displayPictureFilename
        {
            updateNavBarButtons(
                threadData: updatedThreadData,
                initialVariant: viewModel.initialThreadVariant,
                initialIsNoteToSelf: viewModel.threadData.threadIsNoteToSelf,
                initialIsBlocked: (viewModel.threadData.threadIsBlocked == true)
            )
        }
        
        if
            initialLoad ||
            viewModel.threadData.threadCanWrite != updatedThreadData.threadCanWrite ||
            viewModel.threadData.threadVariant != updatedThreadData.threadVariant ||
            viewModel.threadData.threadIsMessageRequest != updatedThreadData.threadIsMessageRequest ||
            viewModel.threadData.threadRequiresApproval != updatedThreadData.threadRequiresApproval ||
            viewModel.threadData.closedGroupAdminProfile != updatedThreadData.closedGroupAdminProfile
        {
            if updatedThreadData.threadCanWrite == true {
                self.showInputAccessoryView()
            } else {
                self.hideInputAccessoryView()
            }
           
            let messageRequestsViewWasVisible: Bool = (self.messageRequestFooterView.isHidden == false)
            
            UIView.animate(withDuration: 0.3) { [weak self] in
                self?.messageRequestFooterView.update(
                    threadVariant: updatedThreadData.threadVariant,
                    canWrite: (updatedThreadData.threadCanWrite == true),
                    threadIsMessageRequest: (updatedThreadData.threadIsMessageRequest == true),
                    threadRequiresApproval: (updatedThreadData.threadRequiresApproval == true),
                    closedGroupAdminProfile: updatedThreadData.closedGroupAdminProfile
                )
                self?.scrollButtonMessageRequestsBottomConstraint?.isActive = (
                    self?.messageRequestFooterView.isHidden == false
                )
                self?.scrollButtonBottomConstraint?.isActive = (
                    self?.scrollButtonMessageRequestsBottomConstraint?.isActive == false
                )
                
                // Update the table content inset and offset to account for
                // the dissapearance of the messageRequestsView
                if messageRequestsViewWasVisible != (self?.messageRequestFooterView.isHidden == false) {
                    let messageRequestsOffset: CGFloat = (self?.messageRequestFooterView.bounds.height ?? 0)
                    let oldContentInset: UIEdgeInsets = (self?.tableView.contentInset ?? UIEdgeInsets.zero)
                    self?.tableView.contentInset = UIEdgeInsets(
                        top: 0,
                        leading: 0,
                        bottom: max(oldContentInset.bottom - messageRequestsOffset, 0),
                        trailing: 0
                    )
                }
            }
        }
        
        if
            initialLoad ||
            viewModel.threadData.outdatedMemberId != updatedThreadData.outdatedMemberId ||
            viewModel.threadData.disappearingMessagesConfiguration != updatedThreadData.disappearingMessagesConfiguration
        {
            addOrRemoveOutdatedClientBanner(
                outdatedMemberId: updatedThreadData.outdatedMemberId,
                disappearingMessagesConfiguration: updatedThreadData.disappearingMessagesConfiguration
            )
        }
        
        if
            initialLoad ||
            viewModel.threadData.threadVariant != updatedThreadData.threadVariant ||
            viewModel.threadData.currentUserIsClosedGroupAdmin != updatedThreadData.currentUserIsClosedGroupAdmin
        {
            legacyGroupsBanner.isHidden = (updatedThreadData.threadVariant != .legacyGroup)
        }
        
        if
            initialLoad ||
            viewModel.threadData.threadVariant != updatedThreadData.threadVariant ||
            viewModel.threadData.closedGroupExpired != updatedThreadData.closedGroupExpired
        {
            expiredGroupBanner.isHidden = (
                updatedThreadData.threadVariant != .group ||
                updatedThreadData.closedGroupExpired != true
            )
        }
        
        if initialLoad || viewModel.threadData.threadUnreadCount != updatedThreadData.threadUnreadCount {
            updateUnreadCountView(unreadCount: updatedThreadData.threadUnreadCount)
        }
        
        if initialLoad || viewModel.threadData.messageInputState != updatedThreadData.messageInputState {
            snInputView.setMessageInputState(updatedThreadData.messageInputState)
        }
        
        // Only set the draft content on the initial load
        if initialLoad, let draft: String = updatedThreadData.threadMessageDraft, !draft.isEmpty {
            snInputView.text = draft
        }
        
        // Now we have done all the needed diffs update the viewModel with the latest data
        self.viewModel.updateThreadData(updatedThreadData)
        
        /// **Note:** This needs to happen **after** we have update the viewModel's thread data (otherwise the `inputAccessoryView`
        /// won't be generated correctly)
        if initialLoad || viewModel.threadData.threadCanWrite != updatedThreadData.threadCanWrite {
            if !self.isFirstResponder {
                self.becomeFirstResponder()
            }
            else {
                self.reloadInputViews()
            }
        }
    }
    
    private func handleInteractionUpdates(
        _ updatedData: [ConversationViewModel.SectionModel],
        changeset: StagedChangeset<[ConversationViewModel.SectionModel]>,
        initialLoad: Bool = false
    ) {
        // Determine if we have any messages for the empty state
        let hasMessages: Bool = (updatedData
            .filter { $0.model == .messages }
            .first?
            .elements
            .isEmpty == false)
        
        // Ensure the first load or a load when returning from a child screen runs without
        // animations (if we don't do this the cells will animate in from a frame of
        // CGRect.zero or have a buggy transition)
        guard self.hasLoadedInitialInteractionData else {
            // Need to dispatch async to prevent this from causing glitches in the push animation
            DispatchQueue.main.async {
                self.viewModel.updateInteractionData(updatedData)
                
                // Update the empty state
                self.emptyStateLabelContainer.isHidden = hasMessages
                
                UIView.performWithoutAnimation {
                    self.tableView.reloadData()
                    self.hasLoadedInitialInteractionData = true
                    self.performInitialScrollIfNeeded()
                }
            }
            return
        }
        
        // Update the empty state
        self.emptyStateLabelContainer.isHidden = hasMessages
        
        // Update the ReactionListSheet (if one exists)
        if let messageUpdates: [MessageViewModel] = updatedData.first(where: { $0.model == .messages })?.elements {
            self.currentReactionListSheet?.handleInteractionUpdates(messageUpdates)
        }
        
        // Store the 'sentMessageBeforeUpdate' state locally
        let didSendMessageBeforeUpdate: Bool = self.viewModel.sentMessageBeforeUpdate
        let onlyReplacedOptimisticUpdate: Bool = {
            // Replacing an optimistic update means making a delete and an insert, which will be done
            // as separate changes at the same positions
            guard
                changeset.count > 1 &&
                changeset[changeset.count - 2].elementDeleted == changeset[changeset.count - 1].elementInserted
            else { return false }
            
            let deletedModels: [MessageViewModel] = changeset[changeset.count - 2]
                .elementDeleted
                .map { self.viewModel.interactionData[$0.section].elements[$0.element] }
            let insertedModels: [MessageViewModel] = changeset[changeset.count - 1]
                .elementInserted
                .map { updatedData[$0.section].elements[$0.element] }
            
            // Make sure all the deleted models were optimistic updates, the inserted models were not
            // optimistic updates and they have the same timestamps
            return (
                deletedModels.map { $0.id }.asSet() == [MessageViewModel.optimisticUpdateId] &&
                insertedModels.map { $0.id }.asSet() != [MessageViewModel.optimisticUpdateId] &&
                deletedModels.map { $0.timestampMs }.asSet() == insertedModels.map { $0.timestampMs }.asSet()
            )
        }()
        let wasOnlyUpdates: Bool = (
            onlyReplacedOptimisticUpdate || (
                changeset.count == 1 &&
                changeset[0].elementUpdated.count == changeset[0].changeCount
            )
        )
        self.viewModel.sentMessageBeforeUpdate = false
        
        // When sending a message, or if there were only cell updates (ie. read status changes) we want to
        // reload the UI instantly (with any form of animation the message sending feels somewhat unresponsive
        // but an instant update feels snappy and without the instant update there is some overlap of the read
        // status text change even though there shouldn't be any animations)
        guard !didSendMessageBeforeUpdate && !wasOnlyUpdates else {
            self.viewModel.updateInteractionData(updatedData)
            self.tableView.reloadData()
            
            // If we just sent a message then we want to jump to the bottom of the conversation instantly
            if didSendMessageBeforeUpdate {
                // We need to dispatch to the next run loop after a slight delay because it seems trying to scroll
                // immediately after triggering a 'reloadData' doesn't work and it's possible (eg. when uploading)
                // for two updates to come through in rapid succession which will result in two updates, the second
                // which stops the scroll from working
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(50)) { [weak self] in
                    self?.tableView.layoutIfNeeded()
                    self?.scrollToBottom(isAnimated: false)
                    
                    // Note: The scroll button alpha won't get set correctly in this case so we forcibly set it to
                    // have an alpha of 0 to stop it appearing buggy
                    self?.scrollButton.alpha = 0
                    self?.unreadCountView.alpha = 0
                }
            }
            return
        }
        
        // Reload the table content animating changes if they'll look good
        struct ItemChangeInfo {
            let isInsertAtTop: Bool
            let firstIndexIsVisible: Bool
            let visibleIndexPath: IndexPath?
            let oldVisibleIndexPath: IndexPath?
            
            init(
                isInsertAtTop: Bool = false,
                firstIndexIsVisible: Bool = false,
                visibleIndexPath: IndexPath? = nil,
                oldVisibleIndexPath: IndexPath? = nil
            ) {
                self.isInsertAtTop = isInsertAtTop
                self.firstIndexIsVisible = firstIndexIsVisible
                self.visibleIndexPath = visibleIndexPath
                self.oldVisibleIndexPath = oldVisibleIndexPath
            }
        }
        
        let numItemsInserted: Int = changeset.map { $0.elementInserted.count }.reduce(0, +)
        let isInsert: Bool = (numItemsInserted > 0)
        let wasLoadingMore: Bool = self.isLoadingMore
        let wasOffsetCloseToBottom: Bool = self.isCloseToBottom
        let numItemsInUpdatedData: [Int] = updatedData.map { $0.elements.count }
        let didSwapAllContent: Bool = {
            // The dynamic headers use negative id values so by using `compactMap` and returning
            // null in those cases allows us to exclude them without another iteration via `filter`
            let currentIds: Set<Int64> = (self.viewModel.interactionData
                .first { $0.model == .messages }?
                .elements
                .compactMap { $0.id > 0 ? $0.id : nil }
                .asSet())
                .defaulting(to: [])
            let updatedIds: Set<Int64> = (updatedData
                .first { $0.model == .messages }?
                .elements
                .compactMap { $0.id > 0 ? $0.id : nil }
                .asSet())
                .defaulting(to: [])
            
            return updatedIds.isDisjoint(with: currentIds)
        }()
        let itemChangeInfo: ItemChangeInfo = {
            guard
                isInsert,
                let oldSectionIndex: Int = self.viewModel.interactionData.firstIndex(where: { $0.model == .messages }),
                let newSectionIndex: Int = updatedData.firstIndex(where: { $0.model == .messages }),
                let firstVisibleIndexPath: IndexPath = self.tableView.indexPathsForVisibleRows?
                    .filter({
                        $0.section == oldSectionIndex &&
                        self.viewModel.interactionData[$0.section].elements[$0.row].cellType != .dateHeader
                    })
                    .sorted()
                    .first
            else { return ItemChangeInfo() }
            
            guard
                let newFirstItemIndex: Int = updatedData[newSectionIndex].elements
                    .firstIndex(where: { item -> Bool in
                        // Since the first item is probably a `DateHeaderCell` (which would likely
                        // be removed when inserting items above it) we check if the id matches
                        let messages: [MessageViewModel] = self.viewModel
                            .interactionData[oldSectionIndex]
                            .elements
                        
                        return (
                            item.id == messages[safe: 0]?.id ||
                            item.id == messages[safe: 1]?.id
                        )
                    }),
                let newVisibleIndex: Int = updatedData[newSectionIndex].elements
                    .firstIndex(where: { item in
                        item.id == self.viewModel.interactionData[oldSectionIndex]
                            .elements[firstVisibleIndexPath.row]
                            .id
                    })
            else {
                let oldTimestamps: [Int64] = self.viewModel.interactionData[oldSectionIndex]
                    .elements
                    .filter { $0.cellType != .dateHeader }
                    .map { $0.timestampMs }
                let newTimestamps: [Int64] = updatedData[newSectionIndex]
                    .elements
                    .filter { $0.cellType != .dateHeader }
                    .map { $0.timestampMs }
                
                return ItemChangeInfo(
                    isInsertAtTop: ((newTimestamps.max() ?? Int64.max) < (oldTimestamps.min() ?? Int64.min)),
                    firstIndexIsVisible: (firstVisibleIndexPath.row == 0),
                    oldVisibleIndexPath: firstVisibleIndexPath
                )
            }
            
            return ItemChangeInfo(
                isInsertAtTop: (
                    newSectionIndex > oldSectionIndex ||
                    // Note: Using `1` here instead of `0` as the first item will generally
                    // be a `DateHeaderCell` instead of a message
                    newFirstItemIndex > 1
                ),
                firstIndexIsVisible: (firstVisibleIndexPath.row == 0),
                visibleIndexPath: IndexPath(row: newVisibleIndex, section: newSectionIndex),
                oldVisibleIndexPath: firstVisibleIndexPath
            )
        }()
        
        guard !isInsert || (!didSwapAllContent && itemChangeInfo.isInsertAtTop) else {
            self.viewModel.updateInteractionData(updatedData)
            self.tableView.reloadData()
            
            // If we had a focusedInteractionInfo then scroll to it (and hide the search
            // result bar loading indicator)
            if let focusedInteractionInfo: Interaction.TimestampInfo = self.focusedInteractionInfo {
                self.tableView.afterNextLayoutSubviews(when: { _, _, _ in true }, then: { [weak self] in
                    self?.searchController.resultsBar.stopLoading()
                    self?.scrollToInteractionIfNeeded(
                        with: focusedInteractionInfo,
                        focusBehaviour: (self?.focusBehaviour ?? .none),
                        contentSwapLocation: {
                            switch (didSwapAllContent, itemChangeInfo.isInsertAtTop) {
                                case (true, true): return .earlier
                                case (true, false): return .later
                                default: return .none
                            }
                        }(),
                        isAnimated: true
                    )
                    
                    if wasLoadingMore {
                        // Complete page loading
                        self?.isLoadingMore = false
                        self?.autoLoadNextPageIfNeeded()
                    }
                })
            }
            else if wasOffsetCloseToBottom && !wasLoadingMore && numItemsInserted < 5 {
                /// Scroll to the bottom if an interaction was just inserted and we either just sent a message or are close enough to the
                /// bottom (wait a tiny fraction to avoid buggy animation behaviour)
                ///
                /// **Note:** We won't automatically scroll to the bottom if 5 or more messages were inserted (to avoid endlessly
                /// auto-scrolling to the bottom when fetching new pages of data within open groups
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(100)) { [weak self] in
                    self?.scrollToBottom(isAnimated: true)
                }
            }
            else if wasLoadingMore {
                // Complete page loading
                self.isLoadingMore = false
                self.autoLoadNextPageIfNeeded()
            }
            else {
                // Need to update the scroll button alpha in case new messages were added but we didn't scroll
                self.updateScrollToBottom()
            }
            return
        }
        
        /// UITableView doesn't really support bottom-aligned content very well and as such jumps around a lot when inserting content but
        /// we want to maintain the current offset from before the data was inserted (except when adding at the bottom while the user is at
        /// the bottom, in which case we want to scroll down)
        ///
        /// Unfortunately the UITableView also does some weird things when updating (where it won't have updated it's internal data until
        /// after it performs the next layout); the below code checks a condition on layout and if it passes it calls a closure
        if itemChangeInfo.isInsertAtTop, let visibleIndexPath: IndexPath = itemChangeInfo.visibleIndexPath, let oldVisibleIndexPath: IndexPath = itemChangeInfo.oldVisibleIndexPath {
            let oldCellRect: CGRect = self.tableView.rectForRow(at: oldVisibleIndexPath)
            let oldCellTopOffset: CGFloat = (self.tableView.frame.minY - self.tableView.convert(oldCellRect, to: self.tableView.superview).minY)
            
            // The the user triggered the 'scrollToTop' animation (by tapping in the nav bar) then we
            // need to stop the animation before attempting to lock the offset (otherwise things break)
            if itemChangeInfo.firstIndexIsVisible {
                self.tableView.setContentOffset(self.tableView.contentOffset, animated: false)
            }
            
            // Wait until the tableView has completed a layout and reported the correct number of
            // sections/rows and then update the contentOffset
            self.tableView.afterNextLayoutSubviews(
                when: { numSections, numRowsInSections, _ -> Bool in
                    numSections == updatedData.count &&
                    numRowsInSections == numItemsInUpdatedData
                },
                then: { [weak self] in
                    // Only recalculate the contentOffset when loading new data if the amount of data
                    // loaded was smaller than 2 pages (this will prevent calculating the frames of
                    // a large number of cells when getting search results which are very far away
                    // only to instantly start scrolling making the calculation redundant)
                    UIView.performWithoutAnimation {
                        self?.tableView.scrollToRow(at: visibleIndexPath, at: .top, animated: false)
                        self?.tableView.contentOffset.y += oldCellTopOffset
                    }
                    
                    if let focusedInteractionInfo: Interaction.TimestampInfo = self?.focusedInteractionInfo {
                        DispatchQueue.main.async { [weak self] in
                            // If we had a focusedInteractionInfo then scroll to it (and hide the search
                            // result bar loading indicator)
                            self?.searchController.resultsBar.stopLoading()
                            self?.scrollToInteractionIfNeeded(
                                with: focusedInteractionInfo,
                                focusBehaviour: (self?.focusBehaviour ?? .none),
                                isAnimated: true
                            )
                        }
                    }
                    
                    // Complete page loading
                    self?.isLoadingMore = false
                    self?.autoLoadNextPageIfNeeded()
                }
            )
        }
        else if wasLoadingMore {
            if let focusedInteractionInfo: Interaction.TimestampInfo = self.focusedInteractionInfo {
                DispatchQueue.main.async { [weak self] in
                    // If we had a focusedInteractionInfo then scroll to it (and hide the search
                    // result bar loading indicator)
                    self?.searchController.resultsBar.stopLoading()
                    self?.scrollToInteractionIfNeeded(
                        with: focusedInteractionInfo,
                        focusBehaviour: (self?.focusBehaviour ?? .none),
                        isAnimated: true
                    )
                    
                    // Complete page loading
                    self?.isLoadingMore = false
                    self?.autoLoadNextPageIfNeeded()
                }
            }
            else {
                // Complete page loading
                self.isLoadingMore = false
                self.autoLoadNextPageIfNeeded()
            }
        }
        
        // Update the messages
        self.tableView.reload(
            using: changeset,
            deleteSectionsAnimation: .none,
            insertSectionsAnimation: .none,
            reloadSectionsAnimation: .none,
            deleteRowsAnimation: .fade,
            insertRowsAnimation: .none,
            reloadRowsAnimation: .none,
            interrupt: { itemChangeInfo.isInsertAtTop || $0.changeCount > ConversationViewModel.pageSize }
        ) { [weak self] updatedData in
            self?.viewModel.updateInteractionData(updatedData)
        }
    }
    
    // MARK: Updating
    
    private func performInitialScrollIfNeeded() {
        guard !hasPerformedInitialScroll && hasLoadedInitialThreadData && hasLoadedInitialInteractionData else {
            return
        }
        
        // Scroll to the last unread message if possible; otherwise scroll to the bottom.
        // When the unread message count is more than the number of view items of a page,
        // the screen will scroll to the bottom instead of the first unread message
        if let focusedInteractionInfo: Interaction.TimestampInfo = self.viewModel.focusedInteractionInfo {
            self.scrollToInteractionIfNeeded(
                with: focusedInteractionInfo,
                focusBehaviour: self.viewModel.focusBehaviour,
                isAnimated: false
            )
        }
        else {
            self.scrollToBottom(isAnimated: false)
        }
        self.updateScrollToBottom()
        self.hasPerformedInitialScroll = true
        
        // Now that the data has loaded we need to check if either of the "load more" sections are
        // visible and trigger them if so
        //
        // Note: We do it this way as we want to trigger the load behaviour for the first section
        // if it has one before trying to trigger the load behaviour for the last section
        self.autoLoadNextPageIfNeeded()
    }
    
    private func autoLoadNextPageIfNeeded() {
        guard
            self.hasLoadedInitialInteractionData &&
            !self.isAutoLoadingNextPage &&
            !self.isLoadingMore
        else { return }
        
        self.isAutoLoadingNextPage = true
        
        DispatchQueue.main.asyncAfter(deadline: .now() + PagedData.autoLoadNextPageDelay) { [weak self] in
            self?.isAutoLoadingNextPage = false
            
            // Note: We sort the headers as we want to prioritise loading newer pages over older ones
            let sections: [(ConversationViewModel.Section, CGRect)] = (self?.viewModel.interactionData
                .enumerated()
                .map { index, section in (section.model, (self?.tableView.rectForHeader(inSection: index) ?? .zero)) })
                .defaulting(to: [])
            let shouldLoadOlder: Bool = sections
                .contains { section, headerRect in
                    section == .loadOlder &&
                    headerRect != .zero &&
                    (self?.tableView.bounds.contains(headerRect) == true)
                }
            let shouldLoadNewer: Bool = sections
                .contains { section, headerRect in
                    section == .loadNewer &&
                    headerRect != .zero &&
                    (self?.tableView.bounds.contains(headerRect) == true)
                }
            
            guard shouldLoadOlder || shouldLoadNewer else { return }
            
            self?.isLoadingMore = true
            
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                // Attachments are loaded in descending order so 'loadOlder' actually corresponds with
                // 'pageAfter' in this case
                self?.viewModel.pagedDataObserver?.load(shouldLoadOlder ?
                    .pageAfter :
                    .pageBefore
                )
            }
        }
    }
    
    func updateNavBarButtons(
        threadData: SessionThreadViewModel?,
        initialVariant: SessionThread.Variant,
        initialIsNoteToSelf: Bool,
        initialIsBlocked: Bool
    ) {
        navigationItem.hidesBackButton = isShowingSearchUI

        if isShowingSearchUI {
            navigationItem.leftBarButtonItem = nil
            navigationItem.rightBarButtonItems = []
        }
        else {
            let shouldHaveCallButton: Bool = (
                (threadData?.threadVariant ?? initialVariant) == .contact &&
                (threadData?.threadIsNoteToSelf ?? initialIsNoteToSelf) == false
            )
            
            guard
                let threadData: SessionThreadViewModel = threadData,
                threadData.canAccessSettings(using: viewModel.dependencies)
            else {
                // Note: Adding empty buttons because without it the title alignment is busted (Note: The size was
                // taken from the layout inspector for the back button in Xcode
                navigationItem.rightBarButtonItems = [
                    UIBarButtonItem(
                        customView: UIView(
                            frame: CGRect(
                                x: 0,
                                y: 0,
                                // Width of the standard back button minus an arbitrary amount to make the
                                // animation look good
                                width: (44 - 10),
                                height: 44
                            )
                        )
                    ),
                    (shouldHaveCallButton ?
                        UIBarButtonItem(customView: UIView(frame: CGRect(x: 0, y: 0, width: 44, height: 44))) :
                        nil
                    )
                ].compactMap { $0 }
                return
            }
            
            let profilePictureView = ProfilePictureView(
                size: .navigation,
                dataManager: viewModel.dependencies[singleton: .imageDataManager]
            )
            profilePictureView.update(
                publicKey: threadData.threadId,  // Contact thread uses the contactId
                threadVariant: threadData.threadVariant,
                displayPictureFilename: threadData.displayPictureFilename,
                profile: threadData.profile,
                additionalProfile: threadData.additionalProfile,
                using: viewModel.dependencies
            )
            profilePictureView.customWidth = (44 - 16)   // Width of the standard back button

            let tapGestureRecognizer = UITapGestureRecognizer(target: self, action: #selector(openSettings))
            profilePictureView.addGestureRecognizer(tapGestureRecognizer)

            let settingsButtonItem: UIBarButtonItem = UIBarButtonItem(customView: profilePictureView)
            settingsButtonItem.accessibilityLabel = "More options"
            settingsButtonItem.isAccessibilityElement = true
            
            if shouldHaveCallButton {
                let callButton = UIBarButtonItem(
                    image: UIImage(named: "Phone"),
                    style: .plain,
                    target: self,
                    action: #selector(startCall)
                )
                callButton.accessibilityLabel = "Call"
                callButton.isAccessibilityElement = true
                
                navigationItem.rightBarButtonItems = [settingsButtonItem, callButton]
            }
            else {
                navigationItem.rightBarButtonItems = [settingsButtonItem]
            }
        }
    }
    
    // MARK: - Keyboard Avoidance

    @objc func handleKeyboardNotification(_ notification: Notification) {
        guard
            !viewIsDisappearing,
            let userInfo: [AnyHashable: Any] = notification.userInfo,
            var keyboardEndFrame: CGRect = userInfo[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
        else { return }
        
        // If reduce motion+crossfade transitions is on, in iOS 14 UIKit sends out a keyboard end frame
        // of CGRect zero. This breaks the math below.
        //
        // If our keyboard end frame is CGRectZero, build a fake rect that's translated off the bottom edge.
        if keyboardEndFrame == .zero {
            keyboardEndFrame = CGRect(
                x: UIScreen.main.bounds.minX,
                y: UIScreen.main.bounds.maxY,
                width: UIScreen.main.bounds.width,
                height: 0
            )
        }
        
        // If we explicitly can't write to the thread then the input will be hidden but they keyboard
        // still reports that it takes up size, so just report 0 height in that case
        if viewModel.threadData.threadCanWrite == false {
            keyboardEndFrame = CGRect(
                x: UIScreen.main.bounds.minX,
                y: UIScreen.main.bounds.maxY,
                width: UIScreen.main.bounds.width,
                height: 0
            )
        }
        
        // No nothing if there was no change
        // Note: there is a bug on iOS 15.X for iPhone 6/6s where the converted frame is not accurate.
        // In iOS 16.1 and later, the keyboard notification object is the screen the keyboard appears on.
        // This is a workaround to fix the issue
        let fromCoordinateSpace: UICoordinateSpace? = {
            if let screen = (notification.object as? UIScreen) {
                return screen.coordinateSpace
            } else {
                var result: UIView? = self.view.superview
                while result != nil && result?.frame != UIScreen.main.bounds {
                    result = result?.superview
                }
                return result
            }
        }()
        let keyboardEndFrameConverted: CGRect = fromCoordinateSpace?.convert(keyboardEndFrame, to: self.view) ?? keyboardEndFrame
        guard keyboardEndFrameConverted != lastKnownKeyboardFrame else { return }
        
        self.lastKnownKeyboardFrame = keyboardEndFrameConverted
        
        // Please refer to https://github.com/mapbox/mapbox-navigation-ios/issues/1600
        // and https://stackoverflow.com/a/25260930 to better understand what we are
        // doing with the UIViewAnimationOptions
        let curveValue: Int = ((userInfo[UIResponder.keyboardAnimationCurveUserInfoKey] as? Int) ?? Int(UIView.AnimationOptions.curveEaseInOut.rawValue))
        let options: UIView.AnimationOptions = UIView.AnimationOptions(rawValue: UInt(curveValue << 16))
        let duration = ((userInfo[UIResponder.keyboardAnimationDurationUserInfoKey] as? TimeInterval) ?? 0)
        
        guard didFinishInitialLayout && !viewIsAppearing, duration > 0, !UIAccessibility.isReduceMotionEnabled else {
            // UIKit by default (sometimes? never?) animates all changes in response to keyboard events.
            // We want to suppress those animations if the view isn't visible,
            // otherwise presentation animations don't work properly.
            UIView.performWithoutAnimation {
                self.updateKeyboardAvoidance()
            }
            return
        }
        
        UIView.animate(
            withDuration: duration,
            delay: 0,
            options: options,
            animations: { [weak self] in
                self?.updateKeyboardAvoidance()
                self?.view.layoutIfNeeded()
            },
            completion: nil
        )
    }
    
    private func updateKeyboardAvoidance() {
        guard let lastKnownKeyboardFrame: CGRect = self.lastKnownKeyboardFrame else { return }
        
        let legacyGroupsFooterOffset: CGFloat = (legacyGroupsRecreateGroupView.isHidden ? 0 :
            legacyGroupsFadeView.bounds.height) // Intentionally want the height of 'legacyGroupsFadeView'
        let messageRequestsOffset: CGFloat = (messageRequestFooterView.isHidden ? 0 :
            messageRequestFooterView.bounds.height)
        let viewIntersection = view.bounds.intersection(lastKnownKeyboardFrame)
        let bottomOffset: CGFloat = (viewIntersection.isEmpty ? 0 : view.bounds.maxY - viewIntersection.minY)
        let additionalPadding: CGFloat = (viewIntersection.isEmpty || legacyGroupsRecreateGroupView.isHidden ? Values.mediumSpacing : 0)
        let contentInsets = UIEdgeInsets(
            top: 0,
            left: 0,
            bottom: bottomOffset + additionalPadding + legacyGroupsFooterOffset + messageRequestsOffset,
            right: 0
        )
        let insetDifference: CGFloat = (contentInsets.bottom - tableView.contentInset.bottom)
        scrollButtonBottomConstraint?.constant = -(bottomOffset + 12)
        messageRequestsViewBotomConstraint?.constant = -bottomOffset
        legacyGroupsFooterViewViewTopConstraint?.constant = -(legacyGroupsFooterOffset + bottomOffset + (viewModel.threadData.threadCanWrite == false ? 16 : 0))
        tableView.contentInset = contentInsets
        tableView.scrollIndicatorInsets = contentInsets
        
        // Only modify the contentOffset if we aren't at the bottom of the tableView, with a little
        // buffer (if we are at the bottom then it'll automatically scroll for us and modifying the
        // value will break things)
        let tableViewBottom: CGFloat = (tableView.contentSize.height - tableView.bounds.height + tableView.contentInset.bottom)
        
        if tableView.contentOffset.y < (tableViewBottom - 5) {
            tableView.contentOffset.y += insetDifference
        }
        
        updateScrollToBottom()
    }

    // MARK: - General
    
    func addOrRemoveOutdatedClientBanner(
        outdatedMemberId: String?,
        disappearingMessagesConfiguration: DisappearingMessagesConfiguration?
    ) {
        let currentDisappearingMessagesConfiguration: DisappearingMessagesConfiguration? = disappearingMessagesConfiguration ?? self.viewModel.threadData.disappearingMessagesConfiguration
        // Do not show the banner until the new disappearing messages is enabled
        guard currentDisappearingMessagesConfiguration?.isEnabled == true else {
            self.outdatedClientBanner.isHidden = true
            self.emptyStatePaddingView.isHidden = (stateStackView
                .arrangedSubviews
                .filter { !$0.isHidden }
                .count > 1)
            return
        }
        
        guard let outdatedMemberId: String = outdatedMemberId else {
            UIView.animate(
                withDuration: 0.25,
                animations: { [weak self] in
                    self?.outdatedClientBanner.alpha = 0
                },
                completion: { [weak self] _ in
                    self?.outdatedClientBanner.isHidden = true
                    self?.outdatedClientBanner.alpha = 1
                    self?.emptyStatePaddingView.isHidden = ((self?.stateStackView
                        .arrangedSubviews
                        .filter { !$0.isHidden })
                        .defaulting(to: [])
                        .count > 1)
                }
            )
            return
        }
        
        let profileDispalyName: String = Profile.displayName(
            id: outdatedMemberId,
            threadVariant: self.viewModel.threadData.threadVariant,
            using: viewModel.dependencies
        )
        self.outdatedClientBanner.update(
            message: "disappearingMessagesLegacy"
                .put(key: "name", value: profileDispalyName)
                .localizedFormatted(baseFont: self.outdatedClientBanner.font),
            onTap: { [weak self] in self?.removeOutdatedClientBanner() }
        )

        self.outdatedClientBanner.isHidden = false
        self.emptyStatePaddingView.isHidden = (stateStackView
            .arrangedSubviews
            .filter { !$0.isHidden }
            .count > 1)
    }
    
    private func removeOutdatedClientBanner() {
        guard let outdatedMemberId: String = self.viewModel.threadData.outdatedMemberId else { return }
        
        viewModel.dependencies[singleton: .storage].writeAsync { db in
            try Contact
                .filter(id: outdatedMemberId)
                .updateAll(db, Contact.Columns.lastKnownClientVersion.set(to: nil))
        }
    }
    
    func recoverInputView(completion: (() -> ())? = nil) {
        // This is a workaround for an issue where the textview is not scrollable
        // after the app goes into background and goes back in foreground.
        DispatchQueue.main.async {
            self.snInputView.text = self.snInputView.text
            completion?()
        }
    }

    // MARK: - UITableViewDataSource
    
    func numberOfSections(in tableView: UITableView) -> Int {
        return viewModel.interactionData.count
    }
    
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        let section: ConversationViewModel.SectionModel = viewModel.interactionData[section]
        
        return section.elements.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let section: ConversationViewModel.SectionModel = viewModel.interactionData[indexPath.section]
        
        switch section.model {
            case .messages:
                let cellViewModel: MessageViewModel = section.elements[indexPath.row]
                let cell: MessageCell = tableView.dequeue(type: MessageCell.cellType(for: cellViewModel), for: indexPath)
                cell.update(
                    with: cellViewModel,
                    playbackInfo: viewModel.playbackInfo(for: cellViewModel) { [weak self] updatedInfo, error in
                        DispatchQueue.main.async {
                            guard error == nil else {
                                let modal: ConfirmationModal = ConfirmationModal(
                                    targetView: self?.view,
                                    info: ConfirmationModal.Info(
                                        title: "theError".localized(),
                                        body: .text("audioUnableToPlay".localized()),
                                        cancelTitle: "okay".localized(),
                                        cancelStyle: .alert_text
                                    )
                                )
                                self?.present(modal, animated: true)
                                return
                            }
                            
                            cell.dynamicUpdate(with: cellViewModel, playbackInfo: updatedInfo)
                        }
                    },
                    showExpandedReactions: viewModel.reactionExpandedInteractionIds
                        .contains(cellViewModel.id),
                    lastSearchText: viewModel.lastSearchedText,
                    using: viewModel.dependencies
                )
                cell.delegate = self
                
                return cell
                
            default: preconditionFailure("Other sections should have no content")
        }
    }
    
    func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        let section: ConversationViewModel.SectionModel = viewModel.interactionData[section]
        
        switch section.model {
            case .loadOlder, .loadNewer:
                let loadingIndicator: UIActivityIndicatorView = UIActivityIndicatorView(style: .medium)
                loadingIndicator.themeTintColor = .textPrimary
                loadingIndicator.alpha = 0.5
                loadingIndicator.startAnimating()
                
                let view: UIView = UIView()
                view.addSubview(loadingIndicator)
                loadingIndicator.center(in: view)
                
                return view
            
            case .messages: return nil
        }
    }
    
    // MARK: - UITableViewDelegate
    
    func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        let section: ConversationViewModel.SectionModel = viewModel.interactionData[section]
        
        switch section.model {
            case .loadOlder, .loadNewer: return ConversationVC.loadingHeaderHeight
            case .messages: return 0
        }
    }
    
    func tableView(_ tableView: UITableView, willDisplayHeaderView view: UIView, forSection section: Int) {
        guard self.hasPerformedInitialScroll && !self.isLoadingMore else { return }
        
        let section: ConversationViewModel.SectionModel = self.viewModel.interactionData[section]
        
        switch section.model {
            case .loadOlder, .loadNewer:
                self.isLoadingMore = true
                
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    // Messages are loaded in descending order so 'loadOlder' actually corresponds with
                    // 'pageAfter' in this case
                    self?.viewModel.pagedDataObserver?.load(section.model == .loadOlder ?
                        .pageAfter :
                        .pageBefore
                    )
                }
                
            case .messages: break
        }
    }

    func scrollToBottom(isAnimated: Bool) {
        guard
            !self.isUserScrolling,
            let messagesSectionIndex: Int = self.viewModel.interactionData
                .firstIndex(where: { $0.model == .messages }),
            !self.viewModel.interactionData[messagesSectionIndex]
                .elements
                .isEmpty
        else { return }
        
        // If the last interaction isn't loaded then scroll to the final interactionId on
        // the thread data
        let hasNewerItems: Bool = self.viewModel.interactionData.contains(where: { $0.model == .loadNewer })
        
        guard !self.didFinishInitialLayout || !hasNewerItems else {
            let messages: [MessageViewModel] = self.viewModel.interactionData[messagesSectionIndex].elements
            let lastInteractionInfo: Interaction.TimestampInfo = {
                guard
                    let interactionId: Int64 = self.viewModel.threadData.interactionId,
                    let timestampMs: Int64 = self.viewModel.threadData.interactionTimestampMs
                else {
                    return Interaction.TimestampInfo(
                        id: messages[messages.count - 1].id,
                        timestampMs: messages[messages.count - 1].timestampMs
                    )
                }
                
                return Interaction.TimestampInfo(id: interactionId, timestampMs: timestampMs)
            }()
            
            self.scrollToInteractionIfNeeded(
                with: lastInteractionInfo,
                position: .bottom,
                isAnimated: true
            )
            return
        }
        
        let targetIndexPath: IndexPath = IndexPath(
            row: (self.viewModel.interactionData[messagesSectionIndex].elements.count - 1),
            section: messagesSectionIndex
        )
        self.tableView.scrollToRow(
            at: targetIndexPath,
            at: .bottom,
            animated: isAnimated
        )
        
        self.viewModel.markAsRead(
            target: .threadAndInteractions(interactionsBeforeInclusive: nil),
            timestampMs: nil
        )
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        isUserScrolling = true
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        isUserScrolling = false
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        self.updateScrollToBottom()
        
        // The initial scroll can trigger this logic but we already mark the initially focused message
        // as read so don't run the below until the user actually scrolls after the initial layout
        guard self.didFinishInitialLayout else { return }
        
        self.markFullyVisibleAndOlderCellsAsRead(interactionInfo: nil)
    }
    
    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        guard let focusedInteractionInfo: Interaction.TimestampInfo = self.focusedInteractionInfo else {
            self.focusedInteractionInfo = nil
            self.focusBehaviour = .none
            return
        }
        
        let behaviour: ConversationViewModel.FocusBehaviour = self.focusBehaviour
        self.focusedInteractionInfo = nil
        self.focusBehaviour = .none
        
        DispatchQueue.main.async { [weak self] in
            self?.markFullyVisibleAndOlderCellsAsRead(interactionInfo: focusedInteractionInfo)
            self?.highlightCellIfNeeded(interactionId: focusedInteractionInfo.id, behaviour: behaviour)
        }
    }

    func updateUnreadCountView(unreadCount: UInt?) {
        let unreadCount: Int = Int(unreadCount ?? 0)
        let fontSize: CGFloat = (unreadCount < 10000 ? Values.verySmallFontSize : 8)
        unreadCountLabel.text = (unreadCount < 10000 ? "\(unreadCount)" : "9999+") // stringlint:ignore
        unreadCountLabel.font = .boldSystemFont(ofSize: fontSize)
        unreadCountView.isHidden = (unreadCount == 0)
    }
    
    public func updateScrollToBottom(force: Bool = false) {
        // Don't update the scroll button until we have actually setup the initial scroll position to avoid
        // any odd flickering or incorrect appearance
        guard self.didFinishInitialLayout || force else { return }
        
        // If we have a 'loadNewer' item in the interaction data then there are subsequent pages and the
        // 'scrollToBottom' actions should always be visible to allow the user to jump to the bottom (without
        // this the button will fade out as the user gets close to the bottom of the current page)
        guard !self.viewModel.interactionData.contains(where: { $0.model == .loadNewer }) else {
            self.scrollButton.alpha = 1
            self.unreadCountView.alpha = 1
            return
        }
        
        // Calculate the target opacity for the scroll button
        let contentOffsetY: CGFloat = tableView.contentOffset.y
        let x = (lastPageTop - ConversationVC.bottomInset - contentOffsetY).clamp(0, .greatestFiniteMagnitude)
        let a = 1 / (ConversationVC.scrollButtonFullVisibilityThreshold - ConversationVC.scrollButtonNoVisibilityThreshold)
        let targetOpacity: CGFloat = max(0, min(1, a * x))
        
        self.scrollButton.alpha = targetOpacity
        self.unreadCountView.alpha = targetOpacity
    }

    // MARK: - Search
    
    func popAllConversationSettingsViews(completion completionBlock: (() -> Void)? = nil) {
        if presentedViewController != nil {
            dismiss(animated: true) { [weak self] in
                guard let strongSelf: UIViewController = self else { return }
                
                self?.navigationController?.popToViewController(strongSelf, animated: true, completion: completionBlock)
            }
        }
        else {
            navigationController?.popToViewController(self, animated: true, completion: completionBlock)
        }
    }
    
    func showSearchUI() {
        isShowingSearchUI = true
        
        // Search bar
        let searchBar = searchController.uiSearchController.searchBar
        searchBar.setUpSessionStyle()
        
        let searchBarContainer = UIView()
        searchBarContainer.layoutMargins = UIEdgeInsets.zero
        searchBar.sizeToFit()
        searchBar.layoutMargins = UIEdgeInsets.zero
        searchBarContainer.set(.height, to: 44)
        searchBarContainer.set(.width, to: UIScreen.main.bounds.width - 32)
        searchBarContainer.addSubview(searchBar)
        navigationItem.titleView = searchBarContainer
        
        // On iPad, the cancel button won't show
        // See more https://developer.apple.com/documentation/uikit/uisearchbar/1624283-showscancelbutton?language=objc
        if UIDevice.current.isIPad {
            let ipadCancelButton = UIButton()
            ipadCancelButton.setTitle("cancel".localized(), for: .normal)
            ipadCancelButton.addTarget(self, action: #selector(hideSearchUI), for: .touchUpInside)
            ipadCancelButton.setThemeTitleColor(.textPrimary, for: .normal)
            searchBarContainer.addSubview(ipadCancelButton)
            ipadCancelButton.pin(.trailing, to: .trailing, of: searchBarContainer)
            ipadCancelButton.center(.vertical, in: searchBarContainer)
            searchBar.pin(.top, to: .top, of: searchBar)
            searchBar.pin(.leading, to: .leading, of: searchBar)
            searchBar.pin(.trailing, to: .leading, of: ipadCancelButton, withInset: -Values.smallSpacing)
            searchBar.pin(.bottom, to: .bottom, of: searchBar)
        }
        else {
            searchBar.pin(toMarginsOf: searchBarContainer)
        }
        
        // Nav bar buttons
        updateNavBarButtons(
            threadData: viewModel.threadData,
            initialVariant: viewModel.initialThreadVariant,
            initialIsNoteToSelf: viewModel.threadData.threadIsNoteToSelf,
            initialIsBlocked: (viewModel.threadData.threadIsBlocked == true)
        )
        
        // Hack so that the ResultsBar stays on the screen when dismissing the search field
        // keyboard.
        //
        // Details:
        //
        // When the search UI is activated, both the SearchField and the ConversationVC
        // have the resultsBar as their inputAccessoryView.
        //
        // So when the SearchField is first responder, the ResultsBar is shown on top of the keyboard.
        // When the ConversationVC is first responder, the ResultsBar is shown at the bottom of the
        // screen.
        //
        // When the user swipes to dismiss the keyboard, trying to see more of the content while
        // searching, we want the ResultsBar to stay at the bottom of the screen - that is, we
        // want the ConversationVC to becomeFirstResponder.
        //
        // If the SearchField were a subview of ConversationVC.view, this would all be automatic,
        // as first responder status is percolated up the responder chain via `nextResponder`, which
        // basically travereses each superView, until you're at a rootView, at which point the next
        // responder is the ViewController which controls that View.
        //
        // However, because SearchField lives in the Navbar, it's "controlled" by the
        // NavigationController, not the ConversationVC.
        //
        // So here we stub the next responder on the navBar so that when the searchBar resigns
        // first responder, the ConversationVC will be in it's responder chain - keeeping the
        // ResultsBar on the bottom of the screen after dismissing the keyboard.
        searchController.uiSearchController.stubbableSearchBar.stubbedNextResponder = self
    }

    @objc func hideSearchUI() {
        isShowingSearchUI = false
        navigationItem.titleView = titleView
        updateNavBarButtons(
            threadData: viewModel.threadData,
            initialVariant: viewModel.initialThreadVariant,
            initialIsNoteToSelf: viewModel.threadData.threadIsNoteToSelf,
            initialIsBlocked: (viewModel.threadData.threadIsBlocked == true)
        )
        
        searchController.uiSearchController.stubbableSearchBar.stubbedNextResponder = nil
        becomeFirstResponder()
        reloadInputViews()
    }

    func didDismissSearchController(_ searchController: UISearchController) {
        hideSearchUI()
    }
    
    func conversationSearchControllerDependencies() -> Dependencies { return viewModel.dependencies }
    func currentVisibleIds() -> [Int64] { return (fullyVisibleCellViewModels() ?? []).map { $0.id } }
    
    func conversationSearchController(_ conversationSearchController: ConversationSearchController?, didUpdateSearchResults results: [Interaction.TimestampInfo]?, searchText: String?) {
        viewModel.lastSearchedText = searchText
        tableView.reloadRows(at: tableView.indexPathsForVisibleRows ?? [], with: UITableView.RowAnimation.none)
    }

    func conversationSearchController(_ conversationSearchController: ConversationSearchController?, didSelectInteractionInfo interactionInfo: Interaction.TimestampInfo) {
        scrollToInteractionIfNeeded(with: interactionInfo, focusBehaviour: .highlight)
    }

    func scrollToInteractionIfNeeded(
        with interactionInfo: Interaction.TimestampInfo,
        focusBehaviour: ConversationViewModel.FocusBehaviour = .none,
        position: UITableView.ScrollPosition = .middle,
        contentSwapLocation: ConversationViewModel.ContentSwapLocation = .none,
        originalIndexPath: IndexPath? = nil,
        isAnimated: Bool = true
    ) {
        // Store the info incase we need to load more data (call will be re-triggered)
        self.focusBehaviour = focusBehaviour
        self.focusedInteractionInfo = interactionInfo
        
        // Ensure the target interaction has been loaded
        guard
            let messageSectionIndex: Int = self.viewModel.interactionData
                .firstIndex(where: { $0.model == .messages }),
            let targetMessageIndex = self.viewModel.interactionData[messageSectionIndex]
                .elements
                .firstIndex(where: { $0.id == interactionInfo.id })
        else {
            // If not the make sure we have finished the initial layout before trying to
            // load the up until the specified interaction
            guard self.didFinishInitialLayout else { return }
            
            self.isLoadingMore = true
            self.searchController.resultsBar.startLoading()
            
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.viewModel.pagedDataObserver?.load(.jumpTo(
                    id: interactionInfo.id,
                    paddingForInclusive: 5
                ))
            }
            return
        }
        
        // If it's before the initial layout and the index before the target is an 'UnreadMarker' then
        // we should scroll to that instead (will be better UX)
        let targetIndexPath: IndexPath = {
            guard
                !self.didFinishInitialLayout &&
                targetMessageIndex > 0 &&
                self.viewModel.interactionData[messageSectionIndex]
                    .elements[targetMessageIndex - 1]
                    .cellType == .unreadMarker
            else {
                return IndexPath(
                    row: targetMessageIndex,
                    section: messageSectionIndex
                )
            }
            
            return IndexPath(
                row: (targetMessageIndex - 1),
                section: messageSectionIndex
            )
        }()
        let targetPosition: UITableView.ScrollPosition = {
            guard position == .middle else { return position }
            
            // Make sure the target cell isn't too large for the screen (if it is then we want to scroll
            // it to the top rather than the middle
            let cellSize: CGSize = self.tableView(
                tableView,
                cellForRowAt: targetIndexPath
            ).systemLayoutSizeFitting(view.bounds.size)
            
            guard cellSize.height > tableView.frame.size.height else { return position }
            
            return .top
        }()
        
        // If we aren't animating or aren't highlighting then everything can be run immediately
        guard isAnimated else {
            self.tableView.scrollToRow(
                at: targetIndexPath,
                at: targetPosition,
                animated: (self.didFinishInitialLayout && isAnimated)
            )
            
            // If we haven't finished the initial layout then we want to delay the highlight/markRead slightly
            // so it doesn't look buggy with the push transition and we know for sure the correct visible cells
            // have been loaded
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(self.didFinishInitialLayout ? 0 : 150)) { [weak self] in
                self?.markFullyVisibleAndOlderCellsAsRead(interactionInfo: interactionInfo)
                self?.highlightCellIfNeeded(interactionId: interactionInfo.id, behaviour: focusBehaviour)
                self?.updateScrollToBottom(force: true)
            }
            
            self.focusedInteractionInfo = nil
            self.focusBehaviour = .none
            return
        }
        
        // If we are animating and highlighting then determine if we want to scroll to the target
        // cell (if we try to trigger the `scrollToRow` call and the animation doesn't occur then
        // the highlight will not be triggered so if a cell is entirely on the screen then just
        // don't bother scrolling)
        let targetRect: CGRect = self.tableView.rectForRow(at: targetIndexPath)
        
        guard !self.tableView.bounds.contains(targetRect) else {
            self.markFullyVisibleAndOlderCellsAsRead(interactionInfo: interactionInfo)
            self.highlightCellIfNeeded(interactionId: interactionInfo.id, behaviour: focusBehaviour)
            self.focusedInteractionInfo = nil
            self.focusBehaviour = .none
            return
        }
        
        // As an optimisation if the target cell is too far away we just reload the entire table instead of loading
        // all intermediate messages, as a result the scroll animation can be buggy (as the contentOffset could
        // actually end up on the wrong side of the destination before the scroll animation starts)
        //
        // To get around this we immediately jump to a position 10 cells above/below the destination and then scroll
        // which appears as though the screen has properly scrolled between the messages
        switch contentSwapLocation {
            case .none:
                if let originalIndexPath: IndexPath = originalIndexPath {
                    // Since we use `estimatedRowHeight` instead of an explicit height there is an annoying issue
                    // where the cells won't have their heights calculated correctly so jumping between cells can
                    // result in a scroll animation going the wrong direction - by jumping to the destination and
                    // back to the current cell all of the relevant cells will have their frames calculated correctly
                    // and the animation will look correct
                    self.tableView.scrollToRow(at: targetIndexPath, at: targetPosition, animated: false)
                    self.tableView.scrollToRow(at: originalIndexPath, at: targetPosition, animated: false)
                }
                
            case .earlier:
                let targetRow: Int = min(targetIndexPath.row + 10, self.viewModel.interactionData[messageSectionIndex].elements.count - 1)
                
                self.tableView.contentOffset = CGPoint(x: 0, y: self.tableView.rectForRow(at: IndexPath(row: targetRow, section: targetIndexPath.section)).midY)
                
            case .later:
                let targetRow: Int = min(targetIndexPath.row - 10, 0)
                
                self.tableView.contentOffset = CGPoint(x: 0, y: self.tableView.rectForRow(at: IndexPath(row: targetRow, section: targetIndexPath.section)).midY)
        }
        
        self.tableView.scrollToRow(at: targetIndexPath, at: targetPosition, animated: true)
    }
    
    func fullyVisibleCellViewModels() -> [MessageViewModel]? {
        // We remove the 'Values.mediumSpacing' as that is the distance the table content appears above the input view
        let tableVisualTop: CGFloat = tableView.frame.minY
        let tableVisualBottom: CGFloat = (tableView.frame.maxY - (tableView.contentInset.bottom - Values.mediumSpacing))
        
        guard
            let visibleIndexPaths: [IndexPath] = self.tableView.indexPathsForVisibleRows,
            let messagesSection: Int = visibleIndexPaths
                .first(where: { self.viewModel.interactionData[$0.section].model == .messages })?
                .section
        else { return nil }
        
        return visibleIndexPaths
            .sorted()
            .filter({ $0.section == messagesSection })
            .compactMap({ indexPath -> (frame: CGRect, cellViewModel: MessageViewModel)? in
                guard let cell: UITableViewCell = tableView.cellForRow(at: indexPath) else { return nil }
                
                switch cell {
                    case is VisibleMessageCell, is CallMessageCell, is InfoMessageCell:
                        return (
                            view.convert(cell.frame, from: tableView),
                            self.viewModel.interactionData[indexPath.section].elements[indexPath.row]
                        )
                        
                    case is TypingIndicatorCell, is DateHeaderCell, is UnreadMarkerCell:
                        return nil
                    
                    default:
                        Log.warn(.conversation, "Processing unhandled cell type when marking as read, this could result in intermittent failures")
                        return nil
                }
            })
            // Exclude messages that are partially off the the screen
            .filter({ $0.frame.minY >= tableVisualTop && $0.frame.maxY <= tableVisualBottom })
            .map { $0.cellViewModel }
    }
    
    func markFullyVisibleAndOlderCellsAsRead(interactionInfo: Interaction.TimestampInfo?) {
        // Only retrieve the `fullyVisibleCellViewModels` if the viewModel things we should mark something as read
        guard self.viewModel.shouldTryMarkAsRead() else { return }
        
        // We want to mark messages as read on load and while we scroll, so grab the newest message and mark
        // everything older as read
        guard let newestCellViewModel: MessageViewModel = fullyVisibleCellViewModels()?.last else {
            // If we weren't able to get any visible cells for some reason then we should fall back to
            // marking the provided interactionInfo as read just in case
            if let interactionInfo: Interaction.TimestampInfo = interactionInfo {
                self.viewModel.markAsRead(
                    target: .threadAndInteractions(interactionsBeforeInclusive: interactionInfo.id),
                    timestampMs: interactionInfo.timestampMs
                )
            }
            return
        }
        
        // Mark all interactions before the newest entirely-visible one as read
        self.viewModel.markAsRead(
            target: .threadAndInteractions(interactionsBeforeInclusive: newestCellViewModel.id),
            timestampMs: newestCellViewModel.timestampMs
        )
    }
    
    func highlightCellIfNeeded(interactionId: Int64, behaviour: ConversationViewModel.FocusBehaviour) {
        self.focusedInteractionInfo = nil
        self.focusBehaviour = .none
        
        // Only trigger the highlight if that's the desired behaviour
        guard behaviour == .highlight else { return }
        
        // Trigger on the next run loop incase we are still finishing some other animation
        DispatchQueue.main.async {
            self.tableView
                .visibleCells
                .first(where: { ($0 as? VisibleMessageCell)?.viewModel?.id == interactionId })
                .asType(VisibleMessageCell.self)?
                .highlight()
        }
    }
    
    // MARK: - LibSessionRespondingViewController
    
    func isConversation(in threadIds: [String]) -> Bool {
        return threadIds.contains(self.viewModel.threadData.threadId)
    }
}
