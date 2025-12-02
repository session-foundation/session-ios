// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import AVKit
import Combine
import GRDB
import DifferenceKit
import Lucide
import SessionUIKit
import SessionMessagingKit
import SessionUtilitiesKit
import SignalUtilitiesKit

final class ConversationVC: BaseVC, LibSessionRespondingViewController, ConversationSearchControllerDelegate, UITableViewDataSource, UITableViewDelegate {
    private static let loadingHeaderHeight: CGFloat = 40
    static let expandedAttachmentButtonSpacing: CGFloat = 4
    
    internal let viewModel: ConversationViewModel
    private var disposables: Set<AnyCancellable> = Set()
    
    /// Currently loaded version of the data for the `tableView`, will always match the value in the `viewModel` unless it's part way
    /// through updating it's state
    internal var sections: [ConversationViewModel.SectionModel] = []
    private var initialLoadComplete: Bool = false
    
    private var currentTargetOffset: CGPoint?
    private var isAutoLoadingNextPage: Bool = false
    private var isLoadingMore: Bool = false
    var isReplacingThread: Bool = false
    var isKeyboardVisible: Bool = false
    
    /// This flag indicates whether the thread data has been reloaded after a disappearance (it defaults to true as it will
    /// never have disappeared before - this is only needed for value observers since they run asynchronously)
    private var hasReloadedThreadDataAfterDisappearance: Bool = true
    
    /// This flag indicates that a need for inputview keyboard presentation is needed, this is in events
    /// where a delegate action is trigger before poping back into `ConversationVC`
    var hasPendingInputKeyboardPresentationEvent: Bool = false
    
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
    var documentHandler: DocumentPickerHandler?
    
    // Mentions
    @MainActor var currentMentionStartIndex: String.Index?
    @MainActor var mentions: [MentionSelectionView.ViewModel] = []
    
    // Scrolling & paging
    var isUserScrolling = false
    var hasPerformedInitialScroll = false
    var didFinishInitialLayout = false
    private var lastBottomInset: CGFloat = 0
    private var shouldUpdateInsets: Bool = true
    
    /// These flags are true between `viewDid/Will Appear/Disappear` and is used to prevent keyboard changes
    /// from trying to animate (as the animations can cause buggy transitions)
    var viewIsAppearing: Bool = false
    
    // Reaction
    var currentReactionListSheet: ReactionListSheet?
    var reactionExpandedMessageIds: Set<String> = []

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
        behavior: .playAndRecord,
        using: viewModel.dependencies
    )

    lazy var searchController: ConversationSearchController = {
        let result: ConversationSearchController = ConversationSearchController(
            threadId: self.viewModel.state.threadId
        )
        result.uiSearchController.obscuresBackgroundDuringPresentation = false
        result.delegate = self
        
        return result
    }()

    // MARK: - UI
    
    var lastKnownKeyboardFrame: CGRect?
    
    lazy var titleView: ConversationTitleView = {
        let result: ConversationTitleView = ConversationTitleView(using: viewModel.dependencies)
        let tapGestureRecognizer = UITapGestureRecognizer(
            target: self,
            action: #selector(handleTitleViewTapped)
        )
        result.addGestureRecognizer(tapGestureRecognizer)
        
        return result
    }()

    lazy var tableView: AfterLayoutCallbackTableView = {
        let result: AfterLayoutCallbackTableView = AfterLayoutCallbackTableView()
        result.separatorStyle = .none
        result.themeBackgroundColor = .clear
        result.showsVerticalScrollIndicator = false
        result.keyboardDismissMode = .interactive
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
        result.contentInsetAdjustmentBehavior = .never  /// We custom handle it

        return result
    }()

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
                    .put(key: "name", value: self.viewModel.state.threadViewModel.displayName)
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
                font: ConversationViewModel.legacyGroupsBannerFont,
                message: viewModel.state.legacyGroupsBannerMessage,
                icon: .none,
                tintColor: .messageBubble_outgoingText,
                backgroundColor: .primary,
                labelAccessibility: Accessibility(identifier: "Legacy group banner"),
                height: nil,
                onTap: { [weak self] in self?.openUrl(Features.legacyGroupDepricationUrl) }
            )
        )
        result.isHidden = (viewModel.state.threadVariant != .legacyGroup)
        
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
            viewModel.state.threadVariant != .group ||
            viewModel.state.threadViewModel.closedGroupExpired != true
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
        result.themeAttributedText = viewModel.state.emptyStateText.formatted(in: result)
        result.themeTextColor = .textSecondary
        result.textAlignment = .center
        result.lineBreakMode = .byWordWrapping
        result.numberOfLines = 0

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

    lazy var footerControlsStackView: UIStackView = {
        let result: UIStackView = UIStackView(arrangedSubviews: [
            legacyGroupsRecreateGroupView,
            messageRequestFooterView,
            snInputView
        ])
        result.axis = .vertical
        result.alignment = .fill
        result.distribution = .fill
        
        return result
    }()
    
    lazy var messageRequestFooterView: MessageRequestFooterView = MessageRequestFooterView(
        threadVariant: self.viewModel.state.threadVariant,
        canWrite: (self.viewModel.state.threadViewModel.threadCanWrite == true),
        threadIsMessageRequest: (self.viewModel.state.threadViewModel.threadIsMessageRequest == true),
        threadRequiresApproval: (self.viewModel.state.threadViewModel.threadRequiresApproval == true),
        closedGroupAdminProfile: self.viewModel.state.threadViewModel.closedGroupAdminProfile,
        onBlock: { [weak self] in self?.blockMessageRequest() },
        onAccept: { [weak self] in self?.acceptMessageRequest() },
        onDecline: { [weak self] in self?.declineMessageRequest() }
    )
    
    private lazy var legacyGroupsRecreateGroupView: UIView = {
        let result: UIView = UIView()
        result.isHidden = (
            viewModel.state.threadVariant != .legacyGroup ||
            viewModel.state.threadViewModel.currentUserIsClosedGroupAdmin != true
        )
        
        result.addSubview(legacyGroupsFooterButton)
        
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
        result.isHidden = legacyGroupsRecreateGroupView.isHidden
        
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
    
    lazy var snInputView: InputView = InputView(
        delegate: self,
        imageDataManager: self.viewModel.dependencies[singleton: .imageDataManager],
        linkPreviewManager: self.viewModel.dependencies[singleton: .linkPreviewManager],
        sessionProManager: self.viewModel.dependencies[singleton: .sessionProManager],
        didLoadLinkPreview: nil
    )
    
    lazy var inputBackgroundView: UIView = {
        let result: UIView = UIView()
        
        let backgroundView: UIView = UIView()
        backgroundView.themeBackgroundColor = .backgroundSecondary
        backgroundView.alpha = Values.lowOpacity
        result.addSubview(backgroundView)
        backgroundView.pin(to: result)
        
        let blurView: UIVisualEffectView = UIVisualEffectView()
        result.addSubview(blurView)
        blurView.pin(to: result)
        
        ThemeManager.onThemeChange(observer: blurView) { [weak blurView] theme, _, _ in
            blurView?.effect = UIBlurEffect(style: theme.blurStyle)
        }
        
        return result
    }()
    
    lazy var attachmentButtonStackView: UIStackView = {
        let result: UIStackView = UIStackView(arrangedSubviews: [
            gifButton,
            documentButton,
            libraryButton,
            cameraButton
        ])
        result.axis = .vertical
        result.spacing = 4
        result.alignment = .fill
        result.distribution = .fill
        result.alpha = 0
        result.isHidden = true  /// Alpha for animation, hidden to avoid noisy UI hierarchy
        
        return result
    }()
    
    lazy var gifButton: UIView = {
        let button: InputViewButton = InputViewButton(icon: #imageLiteral(resourceName: "actionsheet_gif_black"), hasOpaqueBackground: true) { [weak self] in
            self?.handleGIFButtonTapped()
            self?.collapseAttachmentButtons()
        }
        button.accessibilityIdentifier = "GIF button"
        button.isAccessibilityElement = true
        
        let result: UIView = InputViewButton.container(for: button)
        result.isHidden = true
        
        return result
    }()
    lazy var documentButton: UIView = {
        let button: InputViewButton = InputViewButton(icon: #imageLiteral(resourceName: "actionsheet_document_black"), hasOpaqueBackground: true) { [weak self] in
            self?.handleDocumentButtonTapped()
            self?.collapseAttachmentButtons()
        }
        button.accessibilityIdentifier = "Documents folder"
        button.accessibilityLabel = "Files"
        button.isAccessibilityElement = true
        
        let result: UIView = InputViewButton.container(for: button)
        result.isHidden = true
        
        return result
    }()
    lazy var libraryButton: UIView = {
        let button: InputViewButton = InputViewButton(icon: #imageLiteral(resourceName: "actionsheet_camera_roll_black"), hasOpaqueBackground: true) { [weak self] in
            self?.handleLibraryButtonTapped()
            self?.collapseAttachmentButtons()
        }
        button.accessibilityIdentifier = "Images folder"
        button.accessibilityLabel = "Photo library"
        button.isAccessibilityElement = true
        
        let result: UIView = InputViewButton.container(for: button)
        result.isHidden = true
        
        return result
    }()
    lazy var cameraButton: UIView = {
        let button: InputViewButton = InputViewButton(icon: #imageLiteral(resourceName: "actionsheet_camera_black"), hasOpaqueBackground: true) { [weak self] in
            self?.handleCameraButtonTapped()
            self?.collapseAttachmentButtons()
        }
        button.accessibilityIdentifier = "Select camera button"
        button.accessibilityLabel = "Camera"
        button.isAccessibilityElement = true
        
        let result: UIView = InputViewButton.container(for: button)
        result.isHidden = true
        
        return result
    }()
    
    // Handle taps outside of tableview cell
    private lazy var tableViewTapGesture: UITapGestureRecognizer = {
        let result: UITapGestureRecognizer = UITapGestureRecognizer()
        result.delegate = self
        result.addTarget(self, action: #selector(dismissKeyboardOnTap))
        result.cancelsTouchesInView = false
        
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
        threadViewModel: SessionThreadViewModel,
        focusedInteractionInfo: Interaction.TimestampInfo? = nil,
        using dependencies: Dependencies
    ) {
        self.viewModel = ConversationViewModel(
            threadViewModel: threadViewModel,
            focusedInteractionInfo: focusedInteractionInfo,
            currentUserMentionImage: MentionUtilities.generateCurrentUserMentionImage(
                textColor: MessageViewModel.bodyTextColor(isOutgoing: false)    /// Outgoing messages don't use the image
            ),
            using: dependencies
        )
        
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        preconditionFailure("Use init(thread:) instead.")
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
            initialVariant: self.viewModel.state.threadVariant,
            initialIsNoteToSelf: self.viewModel.state.threadViewModel.threadIsNoteToSelf,
            initialIsBlocked: (self.viewModel.state.threadViewModel.threadIsBlocked == true)
        )
        titleView.update(with: self.viewModel.state.titleViewModel)
        
        // Constraints
        view.addSubview(tableView)
        tableView.pin(to: view)

        // Message requests view & scroll to bottom
        view.addSubview(inputBackgroundView)
        view.addSubview(legacyGroupsFadeView)
        view.addSubview(footerControlsStackView)
        view.addSubview(scrollButton)
        view.addSubview(stateStackView)
        view.addSubview(attachmentButtonStackView)
        
        stateStackView.pin(.top, to: .top, of: view, withInset: 0)
        stateStackView.pin(.leading, to: .leading, of: view, withInset: 0)
        stateStackView.pin(.trailing, to: .trailing, of: view, withInset: 0)

        // Unread count view
        view.addSubview(unreadCountView)
        unreadCountView.addSubview(unreadCountLabel)
        unreadCountLabel.pin(.top, to: .top, of: unreadCountView)
        unreadCountLabel.pin(.bottom, to: .bottom, of: unreadCountView)
        unreadCountView.pin(.leading, to: .leading, of: unreadCountLabel, withInset: -4)
        unreadCountView.pin(.trailing, to: .trailing, of: unreadCountLabel, withInset: 4)
        unreadCountView.centerYAnchor.constraint(equalTo: scrollButton.topAnchor).isActive = true
        unreadCountView.center(.horizontal, in: scrollButton)
        
        footerControlsStackView.pin(.leading, to: .leading, of: view)
        footerControlsStackView.pin(.trailing, to: .trailing, of: view)
        footerControlsStackView.pin(.bottom, to: .top, of: view.keyboardLayoutGuide)
        
        legacyGroupsFooterButton.pin(.top, to: .top, of: legacyGroupsRecreateGroupView, withInset: 32)
        legacyGroupsFooterButton.pin(.leading, to: .leading, of: legacyGroupsRecreateGroupView, withInset: 16)
        legacyGroupsFooterButton.pin(.trailing, to: .trailing, of: legacyGroupsRecreateGroupView, withInset: -16)
        legacyGroupsFooterButton.pin(.bottom, to: .bottom, of: legacyGroupsRecreateGroupView, withInset: -16)
        
        inputBackgroundView.pin(.top, to: .top, of: snInputView.inputContainerForBackground)
        inputBackgroundView.pin(.leading, to: .leading, of: view)
        inputBackgroundView.pin(.trailing, to: .trailing, of: view)
        inputBackgroundView.pin(.bottom, to: .bottom, of: view)
        
        legacyGroupsFadeView.pin(.top, to: .top, of: legacyGroupsRecreateGroupView)
        legacyGroupsFadeView.pin(.leading, to: .leading, of: legacyGroupsRecreateGroupView)
        legacyGroupsFadeView.pin(.trailing, to: .trailing, of: legacyGroupsRecreateGroupView)
        legacyGroupsFadeView.pin(.bottom, to: .bottom, of: view)
        
        scrollButton.center(.horizontal, in: snInputView.sendButton)
        scrollButton.pin(.bottom, to: .top, of: footerControlsStackView, withInset: -12)
        
        attachmentButtonStackView.pin(.leading, to: .leading, of: snInputView.attachmentsButtonContainer)
        attachmentButtonStackView.pin(.trailing, to: .trailing, of: snInputView.attachmentsButtonContainer)
        attachmentButtonStackView.pin(.bottom, to: .top, of: snInputView.attachmentsButtonContainer, withInset: -attachmentButtonStackView.spacing)
        
        // Gesture
        view.addGestureRecognizer(tableViewTapGesture)

        self.viewModel.navigatableState.setupBindings(viewController: self, disposables: &self.viewModel.disposables)
        
        // Bind the UI to the view model
        bindViewModel()
        
        // The first time the view loads we should mark the thread as read (in case it was manually
        // marked as unread) - doing this here means if we add a "mark as unread" action within the
        // conversation settings then we don't need to worry about the conversation getting marked as
        // when when the user returns back through this view controller
        Task { await self.viewModel.markThreadAsRead() }
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        
        /// If the view is removed and readded to the view hierarchy then `viewWillDisappear` will be called but `viewDidDisappear`
        /// **won't**, as a result `viewIsDisappearing` would never get set to `false` - do so here to handle this case
        viewIsAppearing = true
        shouldUpdateInsets = true
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        
        // Reset to current state to avoid adjustments when returning to this VC
        lastBottomInset = tableView.contentInset.bottom
        
        // Flag that the initial layout has been completed (the flag blocks and unblocks a number
        // of different behaviours)
        self.didFinishInitialLayout = true
        self.viewIsAppearing = false

        // Show inputview keyboard
        if self.hasPendingInputKeyboardPresentationEvent {
            // Added 0.1 delay to remove inputview stutter animation glitch while keyboard is animating up
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                if self?.isShowingSearchUI == false {
                    _ = self?.snInputView.becomeFirstResponder()
                }
                else {
                    self?.searchController.uiSearchController.searchBar.becomeFirstResponder()
                }
            }
            self.hasPendingInputKeyboardPresentationEvent = false
        }
    }
    
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        
        /// Don't update insets while view is transitioning/hidden
        guard shouldUpdateInsets, footerControlsStackView.frame != .zero else { return }
        
        let bottomInset: CGFloat = (
            (tableView.frame.height - footerControlsStackView.frame.minY) +
            Values.smallSpacing
        )
        
        /// Only proceed if the insert actually changed
        guard abs(bottomInset - lastBottomInset) > 0.5 else { return }
        
        tableView.contentInset.bottom = bottomInset
        tableView.verticalScrollIndicatorInsets.bottom = bottomInset
        
        lastBottomInset = bottomInset
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        
        shouldUpdateInsets = false
        
        // Don't set the draft or resign the first responder if we are replacing the thread (want the keyboard
        // to appear to remain focussed)
        guard !isReplacingThread else { return }
        
        viewModel.updateDraft(to: mentions.update(snInputView.text))
        inputAccessoryView?.resignFirstResponder()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        
        hasReloadedThreadDataAfterDisappearance = false
        
        /// If the user just created this thread but didn't send a message or the conversation is marked as hidden then we want to delete the
        /// "shadow" thread since it's not actually in use (this is to prevent it from taking up database space or unintentionally getting synced
        /// via `libSession` in the future)
        let threadId: String = viewModel.state.threadId
        
        if
            (
                self.navigationController == nil ||
                self.navigationController?.viewControllers.contains(self) == false
            ) &&
            viewModel.state.threadViewModel.threadIsNoteToSelf == false &&
            viewModel.state.threadViewModel.threadIsDraft == true
        {
            viewModel.dependencies[singleton: .storage].writeAsync { db in
                _ = try SessionThread   // Intentionally use `deleteAll` here instead of `deleteOrLeave`
                    .filter(id: threadId)
                    .deleteAll(db)
            }
        }
    }
    
    // MARK: - Updating
    
    private func bindViewModel() {
        viewModel.$state
            .receive(on: DispatchQueue.main)
            .removeDuplicates()
            .sink { [weak self] state in
                /// Don't animate the changes if it's the first load
                if self?.initialLoadComplete == false {
                    return UIView.performWithoutAnimation { self?.render(state: state) }
                }
                
                self?.render(state: state)
            }
            .store(in: &disposables)
    }
    
    @MainActor private func render(state: ConversationViewModel.State) {
        /// If we just unblinded the contact then we should remove the message requests screen from the back stack (if it's there)
        if state.wasPreviouslyBlindedContact && !state.isBlindedContact {
            removeMessageRequestsFromBackStackIfNeeded()
        }
        
        // Update general conversation UI
        titleView.update(with: state.titleViewModel)
        updateNavBarButtons(
            threadData: state.threadViewModel,
            initialVariant: state.threadVariant,
            initialIsNoteToSelf: state.threadViewModel.threadIsNoteToSelf,
            initialIsBlocked: (state.threadViewModel.threadIsBlocked == true)
        )
        
        addOrRemoveOutdatedClientBanner(
            outdatedMemberId: state.threadViewModel.outdatedMemberId,
            disappearingMessagesConfiguration: state.threadViewModel.disappearingMessagesConfiguration
        )
        
        legacyGroupsBanner.isHidden = (state.threadVariant != .legacyGroup)
        expiredGroupBanner.isHidden = (
            state.threadVariant != .group ||
            state.threadViewModel.closedGroupExpired != true
        )
        updateUnreadCountView(unreadCount: state.threadViewModel.threadUnreadCount)
        snInputView.setMessageInputState(state.messageInputState)

        messageRequestFooterView.update(
            threadVariant: state.threadVariant,
            canWrite: (state.threadViewModel.threadCanWrite == true),
            threadIsMessageRequest: (state.threadViewModel.threadIsMessageRequest == true),
            threadRequiresApproval: (state.threadViewModel.threadRequiresApproval == true),
            closedGroupAdminProfile: state.threadViewModel.closedGroupAdminProfile
        )
        
        // Only set the draft content on the initial load (once we have data)
        if !initialLoadComplete, let draft: String = state.threadViewModel.threadMessageDraft, !draft.isEmpty {
            let (string, _) = MentionUtilities.getMentions(
                in: draft,
                currentUserSessionIds: state.currentUserSessionIds,
                displayNameRetriever: { [weak self] sessionId, inMessageBody in
                    // TODO: [PRO] Replicate this behaviour everywhere
                    self?.viewModel.displayName(for: sessionId, inMessageBody: inMessageBody)
                }
            )
            
            snInputView.text = string
            snInputView.updateNumberOfCharactersLeft(draft)
        }
        
        // Update the table content
        let updatedSections: [ConversationViewModel.SectionModel] = state.sections(viewModel: viewModel)
        
        // Update the empty state
        emptyStateLabel.themeAttributedText = state.emptyStateText.formatted(in: emptyStateLabel)
        emptyStateLabelContainer.isHidden = (state.viewState != .empty)
        
        // If this is the initial load then just do a full table refresh
        guard state.viewState == .loaded && initialLoadComplete else {
            if state.viewState == .loaded {
                sections = updatedSections
                tableView.reloadData()
                initialLoadComplete = true
                performInitialScrollIfNeeded()  /// Need to call after updating `initialLoadComplete`
            }
            return
        }
        
        // Update the ReactionListSheet (if one exists)
        if let messageUpdates: [MessageViewModel] = sections.first(where: { $0.model == .messages })?.elements {
            self.currentReactionListSheet?.handleInteractionUpdates(messageUpdates)
        }
        
        // It's not the initial load so we should get a diff and may need to animate the change
        let changeset: StagedChangeset = StagedChangeset(
            source: sections,
            target: updatedSections
        )
        
        // If there were no changes then no need to make changes to the table view
        if changeset.isEmpty { return }
        
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
                .map { self.sections[$0.section].elements[$0.element] }
            let insertedModels: [MessageViewModel] = changeset[changeset.count - 1]
                .elementInserted
                .map { updatedSections[$0.section].elements[$0.element] }
            
            /// Make sure all the deleted models were optimistic updates, the inserted models were not optimistic updates and they
            /// have the same `receivedAtTimestampMs` values
            ///
            /// **Note:** When sending a message to a Community conversation we replace the `timestampMs` with the server
            /// timestamp so can't use that one as the "identifier", luckily the `receivedAtTimestampMs` is set at the time of creation
            /// so it can be used
            return (
                !deletedModels.contains { $0.optimisticMessageId == nil } &&
                !insertedModels.contains { $0.optimisticMessageId != nil } &&
                deletedModels.map { $0.receivedAtTimestampMs }.asSet() == insertedModels.map { $0.receivedAtTimestampMs }.asSet()
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
            sections = updatedSections
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
        let numItemsInUpdatedData: [Int] = updatedSections.map { $0.elements.count }
        let didSwapAllContent: Bool = {
            // The dynamic headers use negative id values so by using `compactMap` and returning
            // null in those cases allows us to exclude them without another iteration via `filter`
            let currentIds: Set<Int64> = (self.sections
                .first { $0.model == .messages }?
                .elements
                .compactMap { $0.id > 0 ? $0.id : nil }
                .asSet())
                .defaulting(to: [])
            let updatedIds: Set<Int64> = (updatedSections
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
                let oldSectionIndex: Int = self.sections.firstIndex(where: { $0.model == .messages }),
                let newSectionIndex: Int = updatedSections.firstIndex(where: { $0.model == .messages }),
                let firstVisibleIndexPath: IndexPath = self.tableView.indexPathsForVisibleRows?
                    .filter({
                        $0.section == oldSectionIndex &&
                        self.sections[$0.section].elements[$0.row].cellType != .dateHeader
                    })
                    .sorted()
                    .first
            else { return ItemChangeInfo() }
            
            guard
                let newFirstItemIndex: Int = updatedSections[newSectionIndex].elements
                    .firstIndex(where: { item -> Bool in
                        // Since the first item is probably a `DateHeaderCell` (which would likely
                        // be removed when inserting items above it) we check if the id matches
                        let messages: [MessageViewModel] = self.sections[oldSectionIndex].elements
                        
                        return (
                            item.id == messages[safe: 0]?.id ||
                            item.id == messages[safe: 1]?.id
                        )
                    }),
                let newVisibleIndex: Int = updatedSections[newSectionIndex].elements
                    .firstIndex(where: { item in
                        item.id == self.sections[oldSectionIndex]
                            .elements[firstVisibleIndexPath.row]
                            .id
                    })
            else {
                let oldTimestamps: [Int64] = self.sections[oldSectionIndex]
                    .elements
                    .filter { $0.cellType != .dateHeader }
                    .map { $0.timestampMs }
                let newTimestamps: [Int64] = updatedSections[newSectionIndex]
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
            sections = updatedSections
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
                    numSections == updatedSections.count &&
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
            self?.sections = updatedData
        }
    }
    
    // MARK: Updating
    
    private func performInitialScrollIfNeeded() {
        guard !hasPerformedInitialScroll && initialLoadComplete else { return }
        
        // Scroll to the last unread message if possible; otherwise scroll to the bottom.
        // When the unread message count is more than the number of view items of a page,
        // the screen will scroll to the bottom instead of the first unread message
        if let focusedInteractionInfo: Interaction.TimestampInfo = self.viewModel.state.focusedInteractionInfo {
            self.scrollToInteractionIfNeeded(
                with: focusedInteractionInfo,
                focusBehaviour: self.viewModel.state.focusBehaviour,
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
            self.initialLoadComplete &&
            !self.isAutoLoadingNextPage &&
            !self.isLoadingMore
        else { return }
        
        self.isAutoLoadingNextPage = true
        
        DispatchQueue.main.asyncAfter(deadline: .now() + PagedData.autoLoadNextPageDelay) { [weak self] in
            self?.isAutoLoadingNextPage = false
            
            // Note: We sort the headers as we want to prioritise loading newer pages over older ones
            let sections: [(ConversationViewModel.Section, CGRect)] = (self?.sections
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
            
            // Messages are loaded in descending order so 'loadOlder' actually corresponds with
            // 'loadPageAfter' in this case
            if shouldLoadOlder {
                self?.viewModel.loadPageAfter()
            }
            else {
                self?.viewModel.loadPageBefore()
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
                displayPictureUrl: threadData.threadDisplayPictureUrl,
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

    // MARK: - General
    
    func addOrRemoveOutdatedClientBanner(
        outdatedMemberId: String?,
        disappearingMessagesConfiguration: DisappearingMessagesConfiguration?
    ) {
        let currentDisappearingMessagesConfiguration: DisappearingMessagesConfiguration? = disappearingMessagesConfiguration ?? self.viewModel.state.threadViewModel.disappearingMessagesConfiguration
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
        
        self.outdatedClientBanner.update(
            message: "disappearingMessagesLegacy"
                .put(key: "name", value: (viewModel.displayName(for: outdatedMemberId, inMessageBody: true) ?? outdatedMemberId.truncated()))
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
        guard let outdatedMemberId: String = self.viewModel.state.threadViewModel.outdatedMemberId else { return }
        
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
        return sections.count
    }
    
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return sections[section].elements.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let section: ConversationViewModel.SectionModel = sections[indexPath.section]
        
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
                    shouldExpanded: viewModel.messageExpandedInteractionIds
                        .contains(cellViewModel.id),
                    lastSearchText: viewModel.lastSearchedText,
                    tableSize: tableView.bounds.size,
                    displayNameRetriever: { [weak self] sessionId, inMessageBody in
                        self?.viewModel.displayName(for: sessionId, inMessageBody: inMessageBody)
                    },
                    using: viewModel.dependencies
                )
                cell.delegate = self
                
                return cell
                
            default: preconditionFailure("Other sections should have no content")
        }
    }
    
    func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        let section: ConversationViewModel.SectionModel = sections[section]
        
        switch section.model {
            case .loadOlder, .loadNewer:
                let loadingIndicator: UIActivityIndicatorView = UIActivityIndicatorView(style: .medium)
                loadingIndicator.themeColor = .textPrimary
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
        let section: ConversationViewModel.SectionModel = sections[section]
        
        switch section.model {
            case .loadOlder, .loadNewer: return ConversationVC.loadingHeaderHeight
            case .messages: return 0
        }
    }
    
    func tableView(_ tableView: UITableView, willDisplayHeaderView view: UIView, forSection section: Int) {
        guard self.hasPerformedInitialScroll && !self.isLoadingMore else { return }
        
        let section: ConversationViewModel.SectionModel = sections[section]
        
        switch section.model {
            case .messages: break
            case .loadOlder:
                self.isLoadingMore = true
                self.viewModel.loadPageBefore()
                
            case .loadNewer:
                self.isLoadingMore = true
                self.viewModel.loadPageAfter()
        }
    }
    
    func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        /// Don't mark anything as read until after the initial layout because we already mark the "initially focussed" message as read
        guard self.didFinishInitialLayout else { return }
        
        self.markFullyVisibleAndOlderCellsAsRead(interactionInfo: nil)
    }

    func scrollToBottom(isAnimated: Bool) {
        guard
            !self.isUserScrolling,
            let messagesSectionIndex: Int = self.sections.firstIndex(where: { $0.model == .messages }),
            !self.sections[messagesSectionIndex].elements.isEmpty
        else { return }
        
        // If the last interaction isn't loaded then scroll to the final interactionId on
        // the thread data
        let hasNewerItems: Bool = self.sections.contains(where: { $0.model == .loadNewer })
        let messages: [MessageViewModel] = self.sections[messagesSectionIndex].elements
        let lastInteractionInfo: Interaction.TimestampInfo = {
            guard
                let interactionId: Int64 = self.viewModel.state.threadViewModel.interactionId,
                let timestampMs: Int64 = self.viewModel.state.threadViewModel.interactionTimestampMs
            else {
                return Interaction.TimestampInfo(
                    id: messages[messages.count - 1].id,
                    timestampMs: messages[messages.count - 1].timestampMs
                )
            }
            
            return Interaction.TimestampInfo(id: interactionId, timestampMs: timestampMs)
        }()
        
        guard !self.didFinishInitialLayout || !hasNewerItems else {
            self.scrollToInteractionIfNeeded(
                with: lastInteractionInfo,
                position: .bottom,
                isAnimated: true
            )
            return
        }
        
        let targetIndexPath: IndexPath = IndexPath(
            row: (sections[messagesSectionIndex].elements.count - 1),
            section: messagesSectionIndex
        )
        self.tableView.scrollToRow(
            at: targetIndexPath,
            at: .bottom,
            animated: isAnimated
        )
        
        Task.detached(priority: .userInitiated) { [weak self] in
            await self?.viewModel.markAsReadIfNeeded(
                interactionInfo: lastInteractionInfo,
                visibleViewModelRetriever: nil
            )
        }
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        isUserScrolling = true
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        isUserScrolling = false
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        self.updateScrollToBottom()
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
        guard !self.sections.contains(where: { $0.model == .loadNewer }) else {
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
    
    func popAllConversationSettingsViews() {
        if presentedViewController != nil {
            dismiss(animated: true) { [weak self] in
                guard let self else { return }
                
                navigationController?.popToViewController(self, animated: true, completion: nil)
            }
        }
        else {
            navigationController?.popToViewController(self, animated: true, completion: nil)
        }
    }
    
    func showSearchUI() {
        isShowingSearchUI = true
        
        UIView.animate(withDuration: 0.3) {
            self.footerControlsStackView.alpha = 0
            self.inputBackgroundView.alpha = 0
        }
        
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
            threadData: viewModel.state.threadViewModel,
            initialVariant: viewModel.state.threadVariant,
            initialIsNoteToSelf: viewModel.state.threadViewModel.threadIsNoteToSelf,
            initialIsBlocked: (viewModel.state.threadViewModel.threadIsBlocked == true)
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
            threadData: viewModel.state.threadViewModel,
            initialVariant: viewModel.state.threadVariant,
            initialIsNoteToSelf: viewModel.state.threadViewModel.threadIsNoteToSelf,
            initialIsBlocked: (viewModel.state.threadViewModel.threadIsBlocked == true)
        )
        
        searchController.uiSearchController.stubbableSearchBar.stubbedNextResponder = nil
        UIView.animate(withDuration: 0.3) {
            self.footerControlsStackView.alpha = 1
            self.inputBackgroundView.alpha = 1
        }
    }
    
    // Manually cancel the search and clear the text to remove hightlights
    func willManuallyCancelSearchUI() {
        searchController.uiSearchController.isActive = false
        searchController.uiSearchController.searchBar.text = ""
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
            let messageSectionIndex: Int = self.sections.firstIndex(where: { $0.model == .messages }),
            let targetMessageIndex = self.sections[messageSectionIndex]
                .elements
                .firstIndex(where: { $0.id == interactionInfo.id })
        else {
            // If not the make sure we have finished the initial layout before trying to
            // load the up until the specified interaction
            guard self.didFinishInitialLayout else { return }
            
            self.isLoadingMore = true
            self.searchController.resultsBar.startLoading()
            self.viewModel.jumpToPage(for: interactionInfo.id, padding: 5)
            return
        }
        
        // If it's before the initial layout and the index before the target is an 'UnreadMarker' then
        // we should scroll to that instead (will be better UX)
        let targetIndexPath: IndexPath = {
            guard
                !self.didFinishInitialLayout &&
                targetMessageIndex > 0 &&
                self.sections[messageSectionIndex]
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
            
            // Check if the last known keyboard frame exists,
            // if it does not intersect with the target rectangle (the cell to be scrolled to),
            if let keyboardFrame = lastKnownKeyboardFrame, !keyboardFrame.intersects(targetRect) {
                // If all conditions are met, scroll the table view to make the target rectangle visible.
                // This is to ensure a cell is not covered by the keyboard.
                self.tableView.scrollRectToVisible(targetRect, animated: true)
            }
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
                let targetRow: Int = min(targetIndexPath.row + 10, self.sections[messageSectionIndex].elements.count - 1)
                
                self.tableView.contentOffset = CGPoint(x: 0, y: self.tableView.rectForRow(at: IndexPath(row: targetRow, section: targetIndexPath.section)).midY)
                
            case .later:
                let targetRow: Int = min(targetIndexPath.row - 10, 0)
                
                self.tableView.contentOffset = CGPoint(x: 0, y: self.tableView.rectForRow(at: IndexPath(row: targetRow, section: targetIndexPath.section)).midY)
        }
        
        self.tableView.scrollToRow(at: targetIndexPath, at: targetPosition, animated: true)
    }
    
    @MainActor func fullyVisibleCellViewModels() -> [MessageViewModel]? {
        // We remove the 'Values.mediumSpacing' as that is the distance the table content appears above the input view
        let tableVisualTop: CGFloat = tableView.frame.minY
        let tableVisualBottom: CGFloat = (tableView.frame.maxY - (tableView.contentInset.bottom - Values.mediumSpacing))
        
        guard
            let visibleIndexPaths: [IndexPath] = self.tableView.indexPathsForVisibleRows,
            let messagesSection: Int = visibleIndexPaths
                .first(where: { self.sections[$0.section].model == .messages })?
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
                            self.sections[indexPath.section].elements[indexPath.row]
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
        Task { [weak self] in
            await self?.viewModel.markAsReadIfNeeded(interactionInfo: interactionInfo) {
                self?.fullyVisibleCellViewModels()
            }
        }
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
        return threadIds.contains(self.viewModel.state.threadId)
    }
}
