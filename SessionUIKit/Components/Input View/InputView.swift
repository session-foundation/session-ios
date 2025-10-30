// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import UniformTypeIdentifiers
import Combine

public final class InputView: UIView, InputViewButtonDelegate, InputTextViewDelegate, MentionSelectionViewDelegate {
    public enum InputTypes: Equatable {
        case all
        case textOnly
        case none
    }
    
    public struct InputState: Equatable {
        public let allowedInputTypes: InputTypes
        public let message: String?
        public let accessibility: Accessibility?
        public let messageAccessibility: Accessibility?
        
        public static var all: InputState = InputState(allowedInputTypes: .all)
        
        // MARK: - Initialization
        
        init(
            allowedInputTypes: InputTypes,
            message: String? = nil,
            accessibility: Accessibility? = nil,
            messageAccessibility: Accessibility? = nil
        ) {
            self.allowedInputTypes = allowedInputTypes
            self.message = message
            self.accessibility = accessibility
            self.messageAccessibility = messageAccessibility
        }
    }
    
    // MARK: - Variables
    
    private static let linkPreviewViewInset: CGFloat = 6
    private static let thresholdForCharacterLimit: Int = 200

    private var disposables: Set<AnyCancellable> = Set()
    private let dataManager: ImageDataManagerType
    private let displayNameRetriever: (String, Bool) -> String?
    private weak var delegate: InputViewDelegate?
    private var sessionProState: SessionProManagerType?
    
    public var quoteDraft: QuoteViewModel? { didSet { handleQuoteDraftChanged() } }
    public var linkPreviewInfo: (url: String, draft: LinkPreviewDraft?)?
    private var linkPreviewLoadTask: Task<Void, Never>?
    private var voiceMessageRecordingView: VoiceMessageRecordingView?
    private lazy var mentionsViewHeightConstraint = mentionsView.set(.height, to: 0)

    private lazy var linkPreviewContainerView: UIView = {
        let result: UIView = UIView()
        result.isHidden = true
        result.addSubview(linkPreviewView)
        linkPreviewView.pin(.top, to: .top, of: result, withInset: 10)
        linkPreviewView.pin(.leading, to: .leading, of: result, withInset: (12 + InputView.linkPreviewViewInset))
        linkPreviewView.pin(.trailing, to: .trailing, of: result, withInset: -14)
        linkPreviewView.pin(.bottom, to: .bottom, of: result, withInset: -4)
        
        return result
    }()
    
    private lazy var linkPreviewView: LinkPreviewView = LinkPreviewView { [weak self] in
        self?.linkPreviewInfo = nil
        self?.linkPreviewContainerView.isHidden = true
    }

    @MainActor public var text: String {
        get { inputTextView.text ?? "" }
        set { inputTextView.text = newValue }
    }
    
    @MainActor var selectedRange: NSRange {
        get { inputTextView.selectedRange }
        set { inputTextView.selectedRange = newValue }
    }
    
    @MainActor var inputState: InputState = .all {
        didSet { setMessageInputState(inputState) }
    }

    public override var intrinsicContentSize: CGSize { CGSize.zero }
    var lastSearchedText: String? { nil }
    
    public var isInputFirstResponder: Bool {
        inputTextView.isFirstResponder
    }

    // MARK: - UI
    
    private lazy var tapGestureRecognizer: UITapGestureRecognizer = {
        let result: UITapGestureRecognizer = UITapGestureRecognizer()
        result.addTarget(self, action: #selector(disabledInputTapped))
        result.isEnabled = false
        
        return result
    }()

    private lazy var swipeGestureRecognizer: UISwipeGestureRecognizer = {
        let result: UISwipeGestureRecognizer = UISwipeGestureRecognizer()
        result.direction = .down
        result.addTarget(self, action: #selector(didSwipeDown))
        result.cancelsTouchesInView = false
        
        return result
    }()
    
    public lazy var attachmentsButton: InputViewButton = {
        let result = InputViewButton(icon: #imageLiteral(resourceName: "ic_plus_24"), delegate: self)
        result.accessibilityLabel = "Attachments button"
        result.accessibilityIdentifier = "Attachments button"
        result.isAccessibilityElement = true
        
        return result
    }()
    public lazy var attachmentsButtonContainer = InputViewButton.container(for: attachmentsButton)

    public lazy var voiceMessageButton: InputViewButton = {
        let result = InputViewButton(icon: #imageLiteral(resourceName: "Microphone"), delegate: self)
        result.accessibilityLabel = "New voice message"
        result.accessibilityIdentifier = "New voice message"
        result.isAccessibilityElement = true
        
        return result
    }()

    public lazy var sendButton: InputViewButton = {
        let result = InputViewButton(icon: #imageLiteral(resourceName: "ArrowUp"), isSendButton: true, delegate: self)
        result.isHidden = true
        result.accessibilityIdentifier = "Send message button"
        result.accessibilityLabel = "Send message button"
        result.isAccessibilityElement = true
        
        return result
    }()
    private lazy var voiceMessageButtonContainer = InputViewButton.container(for: voiceMessageButton)
    
    private lazy var bottomStackView: UIStackView = {
        let result: UIStackView = UIStackView(arrangedSubviews: [
            attachmentsButtonContainer,
            inputTextView,
            InputViewButton.container(for: sendButton)
        ])
        result.axis = .horizontal
        result.spacing = Values.smallSpacing
        result.alignment = .center
        result.isLayoutMarginsRelativeArrangement = true
        
        let adjustment: CGFloat = (InputViewButton.expandedSize - InputViewButton.size) / 2
        result.layoutMargins = UIEdgeInsets(
            top: 2,
            leading: Values.mediumSpacing - adjustment,
            bottom: 2,
            trailing: Values.mediumSpacing - adjustment
        )
        
        return result
    }()

    private lazy var mentionsView: MentionSelectionView = {
        let result: MentionSelectionView = MentionSelectionView(dataManager: dataManager)
        result.delegate = self
        
        return result
    }()

    private lazy var mentionsViewContainer: UIView = {
        let result: UIView = UIView()
        result.accessibilityLabel = "Mentions list"
        result.accessibilityIdentifier = "Mentions list"
        result.alpha = 0
        result.isHidden = true
        
        let backgroundView = UIView()
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
        
        result.addSubview(mentionsView)
        mentionsView.pin(to: result)
        
        return result
    }()
    
    private lazy var separator: UIView = {
        let result: UIView = UIView()
        result.themeBackgroundColor = .borderSeparator
        result.set(.height, to: Values.separatorThickness)
        
        return result
    }()
    
    private lazy var quoteViewContainerView: UIView = {
        let result: UIView = UIView()
        result.isHidden = true
        
        result.addSubview(quoteView)
        quoteView.pin(.top, to: .top, of: result, withInset: 12)
        quoteView.pin(.leading, to: .leading, of: result, withInset: (12 + 6))
        quoteView.pin(.trailing, to: .trailing, of: result, withInset: -11)
        quoteView.pin(.bottom, to: .bottom, of: result, withInset: -6)
        
        return result
    }()
    
    private lazy var quoteView: QuoteView = QuoteView(
        viewModel: QuoteViewModel(
            mode: .draft,
            direction: .outgoing,
            currentUserSessionIds: [],
            rowId: 0,
            interactionId: nil,
            authorId: "",
            timestampMs: 0,
            quotedInteractionId: 0,
            quotedInteractionIsDeleted: false,
            quotedText: nil,
            quotedAttachmentInfo: nil,
            displayNameRetriever: displayNameRetriever
        ),
        dataManager: dataManager,
        onCancel: { [weak self] in
           self?.quoteDraft = nil
           self?.quoteViewContainerView.isHidden = true
        }
    )

    private lazy var inputTextView: InputTextView = {
        // HACK: When restoring a draft the input text view won't have a frame yet, and therefore it won't
        // be able to calculate what size it should be to accommodate the draft text. As a workaround, we
        // just calculate the max width that the input text view is allowed to be and pass it in. See
        // setUpViewHierarchy() for why these values are the way they are.
        let adjustment = (InputViewButton.expandedSize - InputViewButton.size) / 2
        let maxWidth = UIScreen.main.bounds.width - 2 * InputViewButton.expandedSize - 2 * Values.smallSpacing - 2 * (Values.mediumSpacing - adjustment)
        let result = InputTextView(delegate: self, maxWidth: maxWidth)
        result.accessibilityLabel = "contentDescriptionMessageComposition".localized()
        result.accessibilityIdentifier = "Message input box"
        result.isAccessibilityElement = true
        
        return result
    }()

    private lazy var disabledInputLabel: UILabel = {
        let label: UILabel = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: Values.smallFontSize)
        label.themeTextColor = .textPrimary
        label.textAlignment = .center
        label.alpha = 0
        label.numberOfLines = 0
        label.lineBreakMode = .byWordWrapping

        return label
    }()
    
    private lazy var proStackView: UIStackView = {
        let result = UIStackView(arrangedSubviews: [ characterLimitLabel, sessionProBadge ])
        result.axis = .vertical
        result.spacing = Values.verySmallSpacing
        result.alignment = .center
        result.addGestureRecognizer(characterLimitLabelTapGestureRecognizer)
        result.alpha = 0
        
        return result
    }()
    private lazy var characterLimitLabelTapGestureRecognizer: UITapGestureRecognizer = {
        let result: UITapGestureRecognizer = UITapGestureRecognizer()
        result.addTarget(self, action: #selector(characterLimitLabelTapped))
        result.isEnabled = false
        
        return result
    }()
    
    private lazy var characterLimitLabel: UILabel = {
        let label: UILabel = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: Values.smallFontSize)
        label.themeTextColor = .textPrimary
        label.textAlignment = .center
        
        return label
    }()
    
    private lazy var sessionProBadge: SessionProBadge = {
        let result: SessionProBadge = SessionProBadge(size: .small)
        // TODO: Need to add this back
//        result.isHidden = !dependencies[feature: .sessionProEnabled] || dependencies[cache: .libSession].isSessionPro
        
        return result
    }()
    
    private lazy var mainStackView: UIStackView = {
        let result: UIStackView = UIStackView(arrangedSubviews: [
            mentionsViewContainer,
            separator,
            linkPreviewContainerView,
            quoteViewContainerView,
            bottomStackView
        ])
        result.axis = .vertical
        result.alignment = .fill
        result.distribution = .fill
        
        return result
    }()
    
    public var inputContainerForBackground: UIView { mainStackView }
    
    private lazy var extraStackView: UIStackView = {
        let result: UIStackView = UIStackView(arrangedSubviews: [
            mentionsViewContainer,
            mainStackView
        ])
        result.axis = .vertical
        result.alignment = .fill
        result.distribution = .fill
        
        return result
    }()

    // MARK: - Initialization
    
    public init(
        delegate: InputViewDelegate,
        displayNameRetriever: @escaping (String, Bool) -> String?,
        dataManager: ImageDataManagerType,
        sessionProState: SessionProManagerType?
    ) {
        self.dataManager = dataManager
        self.delegate = delegate
        self.displayNameRetriever = displayNameRetriever
        self.sessionProState = sessionProState
        
        super.init(frame: CGRect.zero)
        
        setUpViewHierarchy()
        
        self.sessionProState?.isSessionProPublisher
            .subscribe(on: DispatchQueue.main)
            .receive(on: DispatchQueue.main)
            .sink(
                receiveValue: { [weak self] isPro in
                    self?.sessionProBadge.isHidden = isPro
                    self?.updateNumberOfCharactersLeft((self?.inputTextView.text ?? ""))
                }
            )
            .store(in: &disposables)
    }

    override init(frame: CGRect) {
        preconditionFailure("Use init(delegate:) instead.")
    }

    required init?(coder: NSCoder) {
        preconditionFailure("Use init(delegate:) instead.")
    }
    
    deinit {
        linkPreviewLoadTask?.cancel()
    }

    private func setUpViewHierarchy() {
        autoresizingMask = .flexibleHeight
        
        addGestureRecognizer(tapGestureRecognizer)
        addGestureRecognizer(swipeGestureRecognizer)
        
        // Main stack view
        addSubview(extraStackView)
        extraStackView.pin(to: self)
        mentionsViewHeightConstraint.isActive = true
        
        // Pro stack view
        addSubview(proStackView)
        proStackView.pin(.bottom, to: .bottom, of: inputTextView)
        proStackView.center(.horizontal, in: sendButton)

        addSubview(disabledInputLabel)

        disabledInputLabel.pin(.top, to: .top, of: attachmentsButton)
        disabledInputLabel.pin(.leading, to: .leading, of: inputTextView)
        disabledInputLabel.pin(.trailing, to: .trailing, of: inputTextView)
        disabledInputLabel.set(.height, to: InputViewButton.expandedSize)
        
        // Voice message button
        addSubview(voiceMessageButtonContainer)
        voiceMessageButtonContainer.center(in: sendButton)
    }

    // MARK: - Updating
    
    @MainActor public func inputTextViewDidChangeSize(_ inputTextView: InputTextView) {
        invalidateIntrinsicContentSize()
        self.bottomStackView.alignment = (inputTextView.contentSize.height > inputTextView.minHeight) ? .top : .center
    }

    @MainActor public func inputTextViewDidChangeContent(_ inputTextView: InputTextView) {
        let hasText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        sendButton.isHidden = !hasText
        voiceMessageButtonContainer.isHidden = hasText
        autoGenerateLinkPreviewIfPossible()

        delegate?.inputTextViewDidChangeContent(inputTextView)
    }
    
    @MainActor func updateNumberOfCharactersLeft(_ text: String) {
        let numberOfCharactersLeft: Int = LibSession.numberOfCharactersLeft(
            for: text.trimmingCharacters(in: .whitespacesAndNewlines),
            // TODO: Need to add this back
            isSessionPro: false
//            isSessionPro: dependencies[cache: .libSession].isSessionPro
        )
        characterLimitLabel.text = "\(numberOfCharactersLeft.formatted(format: .abbreviated(decimalPlaces: 1)))"
        characterLimitLabel.themeTextColor = (numberOfCharactersLeft < 0) ? .danger : .textPrimary
        proStackView.alpha = (numberOfCharactersLeft <= Self.thresholdForCharacterLimit) ? 1 : 0
        characterLimitLabelTapGestureRecognizer.isEnabled = (numberOfCharactersLeft < Self.thresholdForCharacterLimit)
    }

    @MainActor public func didPasteImageDataFromPasteboard(_ inputTextView: InputTextView, imageData: Data) {
        delegate?.didPasteImageDataFromPasteboard(imageData)
    }

    // We want to show either a link preview or a quote draft, but never both at the same time. When trying to
    // generate a link preview, wait until we're sure that we'll be able to build a link preview from the given
    // URL before removing the quote draft.

    private func handleQuoteDraftChanged() {
        linkPreviewInfo = nil
        linkPreviewContainerView.isHidden = true
        
        guard let quoteDraft: QuoteViewModel = quoteDraft else {
            quoteViewContainerView.isHidden = true
            return
        }
        
        quoteView.update(viewModel: quoteDraft)
        quoteViewContainerView.isHidden = false
    }

    private func autoGenerateLinkPreviewIfPossible() {
        // Don't allow link previews on 'none' or 'textOnly' input
        guard inputState.allowedInputTypes == .all else { return }

        // Suggest that the user enable link previews if they haven't already and we haven't
        // told them about link previews yet
        let text = inputTextView.text!
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let areLinkPreviewsEnabled: Bool = dependencies.mutate(cache: .libSession) { cache in
                cache.get(.areLinkPreviewsEnabled)
            }
            
            if
                !LinkPreview.allPreviewUrls(forMessageBodyText: text).isEmpty &&
                !areLinkPreviewsEnabled &&
                !dependencies[defaults: .standard, key: .hasSeenLinkPreviewSuggestion]
            {
                DispatchQueue.main.async {
                    self?.delegate?.showLinkPreviewSuggestionModal()
                }
                dependencies[defaults: .standard, key: .hasSeenLinkPreviewSuggestion] = true
                return
            }
            // Check that link previews are enabled
            guard areLinkPreviewsEnabled else { return }
            
            // Proceed
            DispatchQueue.main.async {
                self?.autoGenerateLinkPreview()
            }
        }
    }

    @MainActor func autoGenerateLinkPreview() {
        // Check that a valid URL is present
        guard let linkPreviewURL = LinkPreview.previewUrl(for: text, selectedRange: inputTextView.selectedRange, using: dependencies) else {
            return
        }
        
        // Guard against obsolete updates
        guard linkPreviewURL != self.linkPreviewInfo?.url else { return }
        
        // Clear content container
        quoteDraft = nil
        quoteViewContainerView.isHidden = true
        
        // Set the state to loading (but don't show yet)
        linkPreviewInfo = (url: linkPreviewURL, draft: nil)
        linkPreviewView.update(
            with: LinkPreview.LoadingState(),
            maxWidth: (mainStackView.bounds.width - InputView.linkPreviewViewInset),
            isOutgoing: false,
            using: dependencies
        )
        
        // Build the link preview
        linkPreviewLoadTask?.cancel()
        linkPreviewLoadTask = Task.detached(priority: .userInitiated) { [weak self, allowedInputTypes = inputState.allowedInputTypes, dependencies] in
            await withThrowingTaskGroup(of: Void.self) { [weak self] group in
                /// Wait for a short period before showing the link preview UI (this is to avoid a situation where an invalid URL shows
                /// the loading state very briefly before it disappears
                group.addTask { [weak self] in
                    try await Task.sleep(for: .milliseconds(50))
                    
                    await MainActor.run { [weak self] in
                        guard let self else { return }
                        guard linkPreviewInfo?.url == linkPreviewURL else { return } /// Obsolete
                        
                        linkPreviewContainerView.isHidden = false
                    }
                }
                group.addTask { [weak self] in
                    do {
                        /// Load the draft
                        let draft: LinkPreviewDraft = try await LinkPreview.tryToBuildPreviewInfo(
                            previewUrl: linkPreviewURL,
                            skipImageDownload: (allowedInputTypes != .all),  /// Disable if attachments are disabled
                            using: dependencies
                        )
                        try Task.checkCancellation()
                        
                        await MainActor.run { [weak self] in
                            guard let self else { return }
                            guard linkPreviewInfo?.url == linkPreviewURL else { return } /// Obsolete
                            
                            linkPreviewInfo = (url: linkPreviewURL, draft: draft)
                            linkPreviewView.update(
                                with: LinkPreview.DraftState(linkPreviewDraft: draft),
                                maxWidth: (mainStackView.bounds.width - InputView.linkPreviewViewInset),
                                isOutgoing: false,
                                using: dependencies
                            )
                            linkPreviewContainerView.isHidden = false
                            setNeedsLayout()
                            layoutIfNeeded()
                        }
                    }
                    catch {
                        await MainActor.run { [weak self] in
                            guard let self else { return }
                            guard linkPreviewInfo?.url == linkPreviewURL else { return } /// Obsolete
                            
                            linkPreviewInfo = nil
                            linkPreviewContainerView.isHidden = true
                            setNeedsLayout()
                            layoutIfNeeded()
                        }
                    }
                }
                
                try? await group.waitForAll()
            }
        }
    }

    @MainActor func setMessageInputState(_ updatedInputState: InputState) {
        guard inputState != updatedInputState else { return }

        self.accessibilityIdentifier = updatedInputState.accessibility?.identifier
        self.accessibilityLabel = updatedInputState.accessibility?.label
        tapGestureRecognizer.isEnabled = (updatedInputState.allowedInputTypes == .none)
        
        inputState = updatedInputState
        disabledInputLabel.text = (updatedInputState.message ?? "")
        disabledInputLabel.accessibilityIdentifier = updatedInputState.messageAccessibility?.identifier
        disabledInputLabel.accessibilityLabel = updatedInputState.messageAccessibility?.label
        
        attachmentsButton.isSoftDisabled = (updatedInputState.allowedInputTypes != .all)
        voiceMessageButton.isSoftDisabled = (updatedInputState.allowedInputTypes != .all)

        UIView.animate(withDuration: 0.3) { [weak self] in
            self?.bottomStackView.arrangedSubviews.forEach { $0.alpha = (updatedInputState.allowedInputTypes != .none ? 1 : 0) }
            
            self?.attachmentsButton.alpha = (updatedInputState.allowedInputTypes == .all ? 1 : 0.4)
            self?.attachmentsButton.updateAppearance(isEnabled: updatedInputState.allowedInputTypes == .all)
            
            self?.voiceMessageButton.alpha =  (updatedInputState.allowedInputTypes == .all ? 1 : 0.4)
            self?.voiceMessageButton.updateAppearance(isEnabled: updatedInputState.allowedInputTypes == .all)
            
            self?.disabledInputLabel.alpha = (updatedInputState.allowedInputTypes != .none ? 0 : Values.mediumOpacity)
        }
    }

    // MARK: - Interaction

    @MainActor public func handleInputViewButtonTapped(_ inputViewButton: InputViewButton) {
        if inputViewButton == attachmentsButton {
            if inputState.allowedInputTypes != .all {
                delegate?.handleDisabledAttachmentButtonTapped()
            }
            else {
                delegate?.handleAttachmentButtonTapped()
            }
        }
        if inputViewButton == sendButton { delegate?.handleSendButtonTapped() }
        if inputViewButton == voiceMessageButton && inputState.allowedInputTypes != .all {
            delegate?.handleDisabledVoiceMessageButtonTapped()
        }
    }

    @MainActor public func handleInputViewButtonLongPressBegan(_ inputViewButton: InputViewButton?) {
        guard inputViewButton == voiceMessageButton else { return }
        guard inputState.allowedInputTypes == .all else { return }
        
        // Note: The 'showVoiceMessageUI' call MUST come before triggering 'startVoiceMessageRecording'
        // because if something goes wrong it'll trigger `hideVoiceMessageUI` and we don't want it to
        // end up in a state with the input content hidden
        showVoiceMessageUI()
        delegate?.startVoiceMessageRecording()
    }

    @MainActor public func handleInputViewButtonLongPressMoved(_ inputViewButton: InputViewButton, with touch: UITouch?) {
        guard
            let voiceMessageRecordingView: VoiceMessageRecordingView = voiceMessageRecordingView,
            inputViewButton == voiceMessageButton,
            let location = touch?.location(in: voiceMessageRecordingView)
        else { return }
        
        voiceMessageRecordingView.handleLongPressMoved(to: location)
    }

    @MainActor public func handleInputViewButtonLongPressEnded(_ inputViewButton: InputViewButton, with touch: UITouch?) {
        guard
            let voiceMessageRecordingView: VoiceMessageRecordingView = voiceMessageRecordingView,
            inputViewButton == voiceMessageButton,
            let location = touch?.location(in: voiceMessageRecordingView)
        else { return }
        
        voiceMessageRecordingView.handleLongPressEnded(at: location)
    }

    public override func resignFirstResponder() -> Bool {
        inputTextView.resignFirstResponder()
    }
    
    @discardableResult
    public override func becomeFirstResponder() -> Bool {
        inputTextView.becomeFirstResponder()
    }

    func handleLongPress(_ gestureRecognizer: UITapGestureRecognizer) {
        // Not relevant in this case
    }

    @objc private func showVoiceMessageUI() {
        guard let targetSuperview: UIView = voiceMessageButton.superview else { return }
        
        voiceMessageRecordingView?.removeFromSuperview()
        let voiceMessageButtonFrame = targetSuperview.convert(voiceMessageButton.frame, to: self)
        let voiceMessageRecordingView = VoiceMessageRecordingView(
            voiceMessageButtonFrame: voiceMessageButtonFrame,
            delegate: delegate
        )
        voiceMessageRecordingView.alpha = 0
        addSubview(voiceMessageRecordingView)
        
        voiceMessageRecordingView.pin(to: self)
        self.voiceMessageRecordingView = voiceMessageRecordingView
        voiceMessageRecordingView.animate()
        let allOtherViews = [ attachmentsButton, sendButton, inputTextView ]
        UIView.animate(withDuration: 0.25) {
            allOtherViews.forEach { $0.alpha = 0 }
        }
    }

    func hideVoiceMessageUI() {
        let allOtherViews = [ attachmentsButton, sendButton, inputTextView ]
        UIView.animate(
            withDuration: 0.25,
            animations: {
                allOtherViews.forEach { $0.alpha = 1 }
                self.voiceMessageRecordingView?.alpha = 0
            },
            completion: { [weak self] _ in
                self?.voiceMessageRecordingView?.removeFromSuperview()
                self?.voiceMessageRecordingView = nil
            }
        )
    }

    @MainActor func showMentionsUI(for candidates: [MentionSelectionView.ViewModel]) {
        mentionsView.candidates = candidates
        
        let mentionCellHeight = (ProfilePictureView.Info.Size.message.viewSize + 2 * Values.smallSpacing)
        mentionsViewHeightConstraint.constant = CGFloat(min(3, candidates.count)) * mentionCellHeight
        self.mentionsViewContainer.alpha = 0
        self.mentionsViewContainer.isHidden = false
        layoutIfNeeded()
        
        UIView.animate(withDuration: 0.15) { [weak self] in
            self?.mentionsViewContainer.alpha = 1
        }
    }
    
    @MainActor func hideMentionsUI() {
        UIView.animate(
            withDuration: 0.15,
            animations: { [weak self] in
                self?.mentionsViewContainer.alpha = 0
            },
            completion: { [weak self] _ in
                self?.mentionsViewContainer.isHidden = true
                self?.mentionsViewHeightConstraint.constant = 0
                self?.mentionsView.contentOffset = CGPoint.zero
            }
        )
    }

    @MainActor public func handleMentionSelected(_ viewModel: MentionSelectionView.ViewModel, from view: MentionSelectionView) {
        delegate?.handleMentionSelected(viewModel, from: view)
    }
    
    func tapableLabel(_ label: TappableLabel, didTapUrl url: String, atRange range: NSRange) {
        // Do nothing
    }
    
    @objc private func disabledInputTapped() {
        delegate?.handleDisabledInputTapped()
    }
    
    @objc private func characterLimitLabelTapped() {
        delegate?.handleCharacterLimitLabelTapped()
    }
    
    @objc private func didSwipeDown() {
        inputTextView.resignFirstResponder()
    }
}

// MARK: - Delegate

public protocol InputViewDelegate: VoiceMessageRecordingViewDelegate, AnyObject {
    @MainActor func showLinkPreviewSuggestionModal()
    @MainActor func handleSendButtonTapped()
    @MainActor func handleDisabledInputTapped()
    @MainActor func handleAttachmentButtonTapped()
    @MainActor func handleDisabledAttachmentButtonTapped()
    @MainActor func handleDisabledVoiceMessageButtonTapped()
    @MainActor func handleCharacterLimitLabelTapped()
    @MainActor func inputTextViewDidChangeContent(_ inputTextView: InputTextView)
    @MainActor func handleMentionSelected(_ viewModel: MentionSelectionView.ViewModel, from view: MentionSelectionView)
    @MainActor func didPasteImageDataFromPasteboard(_ imageData: Data)
}
