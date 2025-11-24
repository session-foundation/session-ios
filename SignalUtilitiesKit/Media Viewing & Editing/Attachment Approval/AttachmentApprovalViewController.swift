//
//  Copyright (c) 2019 Open Whisper Systems. All rights reserved.
//

import UIKit
import AVFoundation
import MediaPlayer
import CoreServices
import SessionUIKit
import SessionMessagingKit
import SessionUtilitiesKit

// MARK: - Log.Category

private extension Log.Category {
    static let cat: Log.Category = .create("AttachmentApprovalViewController", defaultLevel: .info)
}

// MARK: - AttachmentApprovalViewControllerDelegate

public protocol AttachmentApprovalViewControllerDelegate: AnyObject {
    func attachmentApproval(
        _ attachmentApproval: AttachmentApprovalViewController,
        didApproveAttachments attachments: [PendingAttachment],
        forThreadId threadId: String,
        threadVariant: SessionThread.Variant,
        messageText: String?,
        quoteViewModel: QuoteViewModel?
    )

    func attachmentApprovalDidCancel(_ attachmentApproval: AttachmentApprovalViewController)

    func attachmentApproval(
        _ attachmentApproval: AttachmentApprovalViewController,
        didChangeMessageText newMessageText: String?
    )

    func attachmentApproval(
        _ attachmentApproval: AttachmentApprovalViewController,
        didRemoveAttachment attachment: PendingAttachment
    )

    func attachmentApprovalDidTapAddMore(_ attachmentApproval: AttachmentApprovalViewController)
}

// MARK: -

@objc
public enum AttachmentApprovalViewControllerMode: UInt {
    case modal
    case sharedNavigation
}

// MARK: -

public class AttachmentApprovalViewController: UIPageViewController, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
    public override var preferredStatusBarStyle: UIStatusBarStyle {
        return ThemeManager.currentTheme.statusBarStyle
    }
    
    public enum Mode: UInt {
        case modal
        case sharedNavigation
    }

    // MARK: - Properties

    private let dependencies: Dependencies
    private let mode: Mode
    private let threadId: String
    private let threadVariant: SessionThread.Variant
    private let isAddMoreVisible: Bool
    private let initialMessageText: String
    private var quoteViewModel: QuoteViewModel?
    private let onQuoteCancelled: (() -> Void)?
    private var isSessionPro: Bool {
        dependencies[cache: .libSession].isSessionPro
    }
    
    var isKeyboardVisible: Bool = false
    private let disableLinkPreviewImageDownload: Bool
    private let didLoadLinkPreview: ((LinkPreviewViewModel.LoadResult) -> Void)?

    public weak var approvalDelegate: AttachmentApprovalViewControllerDelegate?
    
    let attachmentRailItemCollection: PendingAttachmentRailItemCollection

    var attachmentItems: [PendingAttachmentRailItem] {
        return attachmentRailItemCollection.attachmentItems
    }

    var attachments: [PendingAttachment] {
        return attachmentItems.map { (attachmentItem) in
            autoreleasepool {
                return self.processedAttachment(forAttachmentItem: attachmentItem)
            }
        }
    }
    
    public var pageViewControllers: [AttachmentPrepViewController]? {
        return viewControllers?.compactMap { $0 as? AttachmentPrepViewController }
    }
    
    public var currentPageViewController: AttachmentPrepViewController? {
        return pageViewControllers?.first
    }
    
    var currentItem: PendingAttachmentRailItem? {
        get { return currentPageViewController?.attachmentItem }
        set { setCurrentItem(newValue, direction: .forward, animated: false) }
    }
    
    private var cachedPages: [UUID: AttachmentPrepViewController] = [:]

    public var shouldHideControls: Bool {
        guard let pageViewController: AttachmentPrepViewController = pageViewControllers?.first else {
            return false
        }
        
        return pageViewController.shouldHideControls
    }

    override public var canBecomeFirstResponder: Bool {
        return !shouldHideControls
    }
    
    public var messageText: String? {
        get { return snInputView.text }
        set { snInputView.text = (newValue ?? "") }
    }

    // MARK: - Initializers

    required public init(
        mode: Mode,
        delegate: AttachmentApprovalViewControllerDelegate?,
        threadId: String,
        threadVariant: SessionThread.Variant,
        attachments: [PendingAttachment],
        messageText: String?,
        quoteViewModel: QuoteViewModel?,
        disableLinkPreviewImageDownload: Bool,
        didLoadLinkPreview: ((LinkPreviewViewModel.LoadResult) -> Void)?,
        onQuoteCancelled: (() -> Void)?,
        using dependencies: Dependencies
    ) {
        self.dependencies = dependencies
        self.mode = mode
        self.approvalDelegate = delegate
        self.threadId = threadId
        self.threadVariant = threadVariant
        let attachmentItems = attachments.map {
            PendingAttachmentRailItem(attachment: $0, using: dependencies)
        }
        self.initialMessageText = (messageText ?? "")
        self.quoteViewModel = quoteViewModel
        self.isAddMoreVisible = (mode == .sharedNavigation)
        self.disableLinkPreviewImageDownload = disableLinkPreviewImageDownload
        self.didLoadLinkPreview = didLoadLinkPreview
        self.attachmentRailItemCollection = PendingAttachmentRailItemCollection(
            attachmentItems: attachmentItems,
            isAddMoreVisible: isAddMoreVisible
        )
        self.onQuoteCancelled = onQuoteCancelled

        super.init(
            transitionStyle: .scroll,
            navigationOrientation: .horizontal,
            options: [
                .interPageSpacing: kSpacingBetweenItems
            ]
        )
        self.dataSource = self
        self.delegate = self

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(didBecomeActive),
            name: .sessionDidBecomeActive,
            object: nil
        )
    }
    
    @available(*, unavailable, message:"use attachment: constructor instead.")
    required public init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - UI
    
    private let kSpacingBetweenItems: CGFloat = 20
    
    lazy var footerControlsStackView: UIStackView = {
        let result: UIStackView = UIStackView(arrangedSubviews: [
            galleryRailTopSeparator,
            galleryRailView,
            snInputView
        ])
        result.axis = .vertical
        result.alignment = .fill
        result.distribution = .fill
        
        return result
    }()
    
    private lazy var galleryRailTopSeparator: UIView = {
        let result: UIView = UIView()
        result.themeBackgroundColor = .borderSeparator
        result.set(.height, to: Values.separatorThickness)
        
        return result
    }()

    private lazy var galleryRailView: GalleryRailView = {
        let result: GalleryRailView = GalleryRailView()
        result.scrollFocusMode = .keepWithinBounds
        result.delegate = self
        result.set(.height, to: 72)
        
        return result
    }()
    
    private lazy var snInputView: InputView = {
        let result: InputView = InputView(
            delegate: self,
            displayNameRetriever: Profile.defaultDisplayNameRetriever(
                threadVariant: threadVariant,
                using: dependencies
            ),
            imageDataManager: dependencies[singleton: .imageDataManager],
            linkPreviewManager: dependencies[singleton: .linkPreviewManager],
            sessionProStatePublisher: dependencies[singleton: .sessionProState].isSessionProActivePublisher,
            onQuoteCancelled: onQuoteCancelled,
            didLoadLinkPreview: { [weak self] result in
                self?.didLoadLinkPreview?(result)
                
                switch result {
                    case .error(let error):
                        /// In the case of an error we want to update the `MediaMessageView` to show the error
                        self?.viewControllers?.forEach { viewController in
                            guard let prepViewController: AttachmentPrepViewController = viewController as? AttachmentPrepViewController else {
                                return
                            }
                            
                            switch error {
                                case LinkPreviewError.featureDisabled:
                                    prepViewController.mediaMessageView.setError(
                                        title: "linkPreviewsTurnedOff".localized(),
                                        subtitle: "linkPreviewsTurnedOffDescription"
                                            .put(key: "app_name", value: Constants.app_name)
                                            .localized()
                                    )
                                    
                                case LinkPreviewError.insecureLink:
                                    prepViewController.mediaMessageView.setError(
                                        title: nil,
                                        subtitle: "linkPreviewsErrorUnsecure".localized()
                                    )
                                
                                default:
                                    prepViewController.mediaMessageView.setError(
                                        title: nil,
                                        subtitle: "linkPreviewsErrorLoad".localized()
                                    )
                            }
                        }
                        
                    default: break
                }
            }
        )
        result.text = initialMessageText
        result.setMessageInputState(
            InputView.InputState(
                inputs: {
                    guard !disableLinkPreviewImageDownload else { return [.text] }
                    
                    return [.text, .attachmentsHidden]
                }(),
                alwaysShowSendButton: true
            )
        )
        result.quoteViewModel = quoteViewModel
        
        return result
    }()
    
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

    private lazy var pagerScrollView: UIScrollView? = {
        // This is kind of a hack. Since we don't have first class access to the superview's `scrollView`
        // we traverse the view hierarchy until we find it.
        let pagerScrollView = view.subviews.first { $0 is UIScrollView } as? UIScrollView
        assert(pagerScrollView != nil)

        return pagerScrollView
    }()

    // MARK: - Lifecycle

    override public func viewDidLoad() {
        super.viewDidLoad()

        self.view.themeBackgroundColor = .newConversation_background
        
        // Message requests view & scroll to bottom
        view.addSubview(inputBackgroundView)
        view.addSubview(footerControlsStackView)
        
        footerControlsStackView.pin(.leading, to: .leading, of: view)
        footerControlsStackView.pin(.trailing, to: .trailing, of: view)
        footerControlsStackView.pin(.bottom, to: .top, of: view.keyboardLayoutGuide)
        
        inputBackgroundView.pin(.top, to: .top, of: footerControlsStackView)
        inputBackgroundView.pin(.leading, to: .leading, of: view)
        inputBackgroundView.pin(.trailing, to: .trailing, of: view)
        inputBackgroundView.pin(.bottom, to: .bottom, of: view)
        
        // Avoid an unpleasant "bounce" which doesn't make sense in the context of a single item.
        pagerScrollView?.isScrollEnabled = (attachmentItems.count > 1)

        guard let firstItem = attachmentItems.first else {
            Log.error(.cat, "firstItem was unexpectedly nil")
            return
        }

        self.setCurrentItem(firstItem, direction: .forward, animated: false)

        // layout immediately to avoid animating the layout process during the transition
        UIView.performWithoutAnimation {
            self.currentPageViewController?.view.layoutIfNeeded()
        }
        
        /// If the first item is just text, or is a URL and LinkPreviews are disabled then just fill the 'message' box with it
        Task {
            let firstItemIsPlainText: Bool = {
                switch firstItem.attachment.source {
                    case .text: return true
                    default: return false
                }
            }()
            let hasNoLinkPreview: Bool = (firstItem.attachment.utType.conforms(to: .url) ?
                await dependencies[singleton: .linkPreviewManager].previewUrl(
                    for: firstItem.attachment.toText()
                ) == nil :
                false
            )
            if firstItemIsPlainText || hasNoLinkPreview {
                snInputView.text = (firstItem.attachment.toText() ?? "")
            }
        }
    }

    override public func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)

        updateContents()
    }

    override public func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        updateContents()
    }
    
    // MARK: - Notifications

    @objc func didBecomeActive() {
        Log.assertOnMainThread()

        updateContents()
    }
    
    // MARK: - Contents
    
    @MainActor private func updateContents() {
        updateNavigationBar()
    }

    // MARK: - Navigation Bar

    public func updateNavigationBar() {
        guard !shouldHideControls else {
            self.navigationItem.leftBarButtonItem = nil
            self.navigationItem.rightBarButtonItem = nil
            return
        }

        var navigationBarItems = [UIView]()

        if viewControllers?.count == 1, let firstViewController: AttachmentPrepViewController = viewControllers?.first as? AttachmentPrepViewController {
            navigationBarItems = firstViewController.navigationBarItems()
        }

        updateNavigationBar(navigationBarItems: navigationBarItems)

        if mode != .sharedNavigation {
            // Mimic a UIBarButtonItem of type .cancel, but with a shadow.
            let cancelButton = OWSButton(title: "cancel".localized()) { [weak self] in
                self?.cancelPressed()
            }
            cancelButton.titleLabel?.font = .systemFont(ofSize: 17.0)
            cancelButton.setThemeTitleColor(.textPrimary, for: .normal)
            cancelButton.setThemeTitleColor(.textSecondary, for: .highlighted)
            cancelButton.sizeToFit()
            navigationItem.leftBarButtonItem = UIBarButtonItem(customView: cancelButton)
        }
        else {
            navigationItem.leftBarButtonItem = nil
        }
    }

    // MARK: - View Helpers

    func remove(attachmentItem: PendingAttachmentRailItem) {
        if attachmentItem.isEqual(to: currentItem) {
            if let nextItem = attachmentRailItemCollection.itemAfter(item: attachmentItem) {
                setCurrentItem(nextItem, direction: .forward, animated: true)
            }
            else if let prevItem = attachmentRailItemCollection.itemBefore(item: attachmentItem) {
                setCurrentItem(prevItem, direction: .reverse, animated: true)
            }
            else {
                Log.error(.cat, "Removing last item shouldn't be possible because rail should not be visible")
                return
            }
        }

        self.attachmentRailItemCollection.remove(item: attachmentItem)
        self.approvalDelegate?.attachmentApproval(self, didRemoveAttachment: attachmentItem.attachment)
        self.updateMediaRail()
    }

    // MARK: - UIPageViewControllerDelegate

    public func pageViewController(_ pageViewController: UIPageViewController, willTransitionTo pendingViewControllers: [UIViewController]) {

        assert(pendingViewControllers.count == 1)
        pendingViewControllers.forEach { viewController in
            guard let pendingPage = viewController as? AttachmentPrepViewController else {
                Log.error(.cat, "Unexpected viewController: \(viewController)")
                return
            }

            // use compact scale when keyboard is popped.
            let scale: AttachmentPrepViewController.AttachmentViewScale = self.isFirstResponder ? .fullsize : .compact
            pendingPage.setAttachmentViewScale(scale, animated: false)
        }
    }

    public func pageViewController(_ pageViewController: UIPageViewController, didFinishAnimating finished: Bool, previousViewControllers: [UIViewController], transitionCompleted: Bool) {
        assert(previousViewControllers.count == 1)
        previousViewControllers.forEach { viewController in
            guard let previousPage = viewController as? AttachmentPrepViewController else {
                Log.error(.cat, "Unexpected viewController: \(viewController)")
                return
            }

            if transitionCompleted {
                previousPage.zoomOut(animated: false)
                updateMediaRail()
            }
        }
    }

    // MARK: - UIPageViewControllerDataSource

    public func pageViewController(_ pageViewController: UIPageViewController, viewControllerBefore viewController: UIViewController) -> UIViewController? {
        guard let currentViewController = viewController as? AttachmentPrepViewController else {
            Log.error(.cat, "Unexpected viewController: \(viewController)")
            return nil
        }

        let currentItem = currentViewController.attachmentItem
        guard let previousItem = attachmentItem(before: currentItem) else { return nil }
        guard let previousPage: AttachmentPrepViewController = buildPage(item: previousItem) else {
            return nil
        }

        return previousPage
    }

    public func pageViewController(_ pageViewController: UIPageViewController, viewControllerAfter viewController: UIViewController) -> UIViewController? {
        guard let currentViewController = viewController as? AttachmentPrepViewController else {
            Log.error(.cat, "Unexpected viewController: \(viewController)")
            return nil
        }

        let currentItem = currentViewController.attachmentItem
        guard let nextItem = attachmentItem(after: currentItem) else { return nil }
        guard let nextPage: AttachmentPrepViewController = buildPage(item: nextItem) else {
            return nil
        }

        return nextPage
    }

    @objc
    public override func setViewControllers(_ viewControllers: [UIViewController]?, direction: UIPageViewController.NavigationDirection, animated: Bool, completion: ((Bool) -> Void)? = nil) {
        super.setViewControllers(
            viewControllers,
            direction: direction,
            animated: animated
        ) { [weak self] finished in
            completion?(finished)
            
            Task { @MainActor [weak self] in self?.updateContents() }
        }
    }

    private func buildPage(item: PendingAttachmentRailItem) -> AttachmentPrepViewController? {
        if let cachedPage = cachedPages[item.uniqueIdentifier] {
            Log.debug(.cat, "Cache hit.")
            return cachedPage
        }

        Log.debug(.cat, "Cache miss.")
        let viewController = AttachmentPrepViewController(attachmentItem: item, using: dependencies)
        viewController.prepDelegate = self
        cachedPages[item.uniqueIdentifier] = viewController

        return viewController
    }

    private func setCurrentItem(_ item: PendingAttachmentRailItem?, direction: UIPageViewController.NavigationDirection, animated isAnimated: Bool) {
        guard let item: PendingAttachmentRailItem = item, let page = self.buildPage(item: item) else {
            Log.error(.cat, "Unexpectedly unable to build new page")
            return
        }

        page.loadViewIfNeeded()

        self.setViewControllers([page], direction: direction, animated: isAnimated, completion: nil)
        updateMediaRail()
    }

    func updateMediaRail() {
        guard let currentItem = self.currentItem else {
            Log.error(.cat, "currentItem was unexpectedly nil")
            return
        }

        let cellViewBuilder: (GalleryRailItem) -> GalleryRailCellView = { [weak self] railItem in
            switch railItem {
                case is AddMoreRailItem:
                    return GalleryRailCellView()
                    
                case is PendingAttachmentRailItem:
                    let cell = ApprovalRailCellView()
                    cell.approvalRailCellDelegate = self
                    return cell
                    
                default:
                    Log.error(.cat, "Unexpted rail item type: \(railItem)")
                    return GalleryRailCellView()
            }
        }
        
        galleryRailView.configureCellViews(
            album: (attachmentRailItemCollection.attachmentItems as [GalleryRailItem])
                .appending(attachmentRailItemCollection.isAddMoreVisible ?
                    AddMoreRailItem() :
                    nil
                ),
            focusedItem: currentItem,
            using: dependencies,
            cellViewBuilder: cellViewBuilder
        )

        if isAddMoreVisible {
            galleryRailView.isHidden = false
        }
        else if attachmentRailItemCollection.attachmentItems.count > 1 {
            galleryRailView.isHidden = false
        }
        else {
            galleryRailView.isHidden = true
        }
        
        galleryRailTopSeparator.isHidden = galleryRailView.isHidden
    }

    // For any attachments edited with the image editor, returns a
    // new PendingAttachment that reflects those changes.  Otherwise,
    // returns the original attachment.
    //
    // If any errors occurs in the export process, we fail over to
    // sending the original attachment.  This seems better than trying
    // to involve the user in resolving the issue.
    func processedAttachment(forAttachmentItem attachmentItem: PendingAttachmentRailItem) -> PendingAttachment {
        guard let imageEditorModel = attachmentItem.imageEditorModel else {
            // Image was not edited.
            return attachmentItem.attachment
        }
        guard imageEditorModel.isDirty() else {
            // Image editor has no changes.
            return attachmentItem.attachment
        }
        guard let dstImage = ImageEditorCanvasView.renderForOutput(model: imageEditorModel, transform: imageEditorModel.currentTransform(), using: dependencies) else {
            Log.error(.cat, "Could not render for output.")
            return attachmentItem.attachment
        }
        var dataType: UTType = .image
        let maybeDstData: Data? = {
            let isLossy: Bool = (attachmentItem.attachment.utType == .jpeg)
            
            if isLossy {
                dataType = .jpeg
                return dstImage.jpegData(compressionQuality: 0.9)
            }
            else {
                dataType = .png
                return dstImage.pngData()
            }
        }()
        
        guard let dstData: Data = maybeDstData else {
            Log.error(.cat, "Could not export for output.")
            return attachmentItem.attachment
        }
        
        guard let filePath: String = try? dependencies[singleton: .fileManager].write(dataToTemporaryFile: dstData) else {
            Log.error(.cat, "Could not save output to disk.")
            return attachmentItem.attachment
        }

        // Rewrite the filename's extension to reflect the output file format.
        var filename: String? = attachmentItem.attachment.sourceFilename
        if let sourceFilename = attachmentItem.attachment.sourceFilename {
            if let fileExtension: String = dataType.sessionFileExtension(sourceFilename: sourceFilename) {
                filename = ((sourceFilename as NSString)
                    .deletingPathExtension as NSString)
                    .appendingPathExtension(fileExtension)
            }
        }
        
        return PendingAttachment(
            source: .media(URL(fileURLWithPath: filePath)),
            utType: dataType,
            sourceFilename: filename,
            using: dependencies
        )
    }

    func attachmentItem(before currentItem: PendingAttachmentRailItem) -> PendingAttachmentRailItem? {
        guard let currentIndex = attachmentItems.firstIndex(of: currentItem) else {
            Log.error(.cat, "currentIndex was unexpectedly nil")
            return nil
        }

        let index: Int = attachmentItems.index(before: currentIndex)
        guard let previousItem = attachmentItems[safe: index] else {
            // already at first item
            return nil
        }

        return previousItem
    }

    func attachmentItem(after currentItem: PendingAttachmentRailItem) -> PendingAttachmentRailItem? {
        guard let currentIndex = attachmentItems.firstIndex(of: currentItem) else {
            Log.error(.cat, "currentIndex was unexpectedly nil")
            return nil
        }

        let index: Int = attachmentItems.index(after: currentIndex)
        guard let nextItem = attachmentItems[safe: index] else {
            // already at last item
            return nil
        }

        return nextItem
    }

    // MARK: - Event Handlers
    
    private func cancelPressed() {
        self.approvalDelegate?.attachmentApprovalDidCancel(self)
    }
    
    @MainActor func showModalForMessagesExceedingCharacterLimit(isSessionPro: Bool) {
        guard dependencies[singleton: .sessionProState].showSessionProCTAIfNeeded(
            .longerMessages,
            onConfirm: { [weak self, dependencies] in
                dependencies[singleton: .sessionProState].showSessionProBottomSheetIfNeeded(
                    afterClosed: {
                        self?.snInputView.updateNumberOfCharactersLeft(self?.snInputView.text ?? "")
                    },
                    presenting: { bottomSheet in
                        self?.present(bottomSheet, animated: true)
                    }
                )
            },
            onCancel: { [weak self] in
                self?.snInputView.updateNumberOfCharactersLeft(self?.snInputView.text ?? "")
            },
            presenting: { [weak self] modal in
                self?.present(modal, animated: true)
            }
        ) else {
            return
        }
        
        let confirmationModal: ConfirmationModal = ConfirmationModal(
            info: ConfirmationModal.Info(
                title: "modalMessageCharacterTooLongTitle".localized(),
                body: .text(
                    "modalMessageTooLongDescription"
                        .put(key: "limit", value: (isSessionPro ? LibSession.ProCharacterLimit : LibSession.CharacterLimit))
                        .localized(),
                    scrollMode: .never
                ),
                cancelTitle: "okay".localized(),
                cancelStyle: .alert_text
            )
        )
        present(confirmationModal, animated: true, completion: nil)
    }
}

// MARK: - InputViewDelegate

extension AttachmentApprovalViewController: InputViewDelegate {
    public func showLinkPreviewSuggestionModal() {}
    public func handleDisabledInputTapped() {}
    public func handleAttachmentButtonTapped() {}
    public func handleDisabledAttachmentButtonTapped() {}
    public func handleDisabledVoiceMessageButtonTapped() {}
    public func handleMentionSelected(_ viewModel: MentionSelectionView.ViewModel, from view: MentionSelectionView) {}
    public func didPasteImageDataFromPasteboard(_ imageData: Data) {}
    public func startVoiceMessageRecording() {}
    public func endVoiceMessageRecording() {}
    public func cancelVoiceMessageRecording() {}
    
    public func handleCharacterLimitLabelTapped() {
        guard dependencies[singleton: .sessionProState].showSessionProCTAIfNeeded(
            .longerMessages,
            onConfirm: { [weak self, dependencies] in
                dependencies[singleton: .sessionProState].showSessionProBottomSheetIfNeeded(
                    afterClosed: {
                        self?.snInputView.updateNumberOfCharactersLeft(self?.snInputView.text ?? "")
                    },
                    presenting: { bottomSheet in
                        self?.present(bottomSheet, animated: true)
                    }
                )
            },
            onCancel: { [weak self] in
                self?.snInputView.updateNumberOfCharactersLeft(self?.snInputView.text ?? "")
            },
            presenting: { [weak self] modal in
                self?.present(modal, animated: true)
            }
        ) else {
            return
        }
        
        let confirmationModal: ConfirmationModal = ConfirmationModal(
            info: ConfirmationModal.Info(
                title: "modalMessageCharacterTooLongTitle".localized(),
                body: .text(
                    "modalMessageTooLongDescription"
                        .put(key: "limit", value: (isSessionPro ? LibSession.ProCharacterLimit : LibSession.CharacterLimit))
                        .localized(),
                    scrollMode: .never
                ),
                cancelTitle: "okay".localized(),
                cancelStyle: .alert_text
            )
        )
        present(confirmationModal, animated: true, completion: nil)
    }

    public func handleSendButtonTapped() {
        guard
            LibSession.numberOfCharactersLeft(
                for: snInputView.text.trimmingCharacters(in: .whitespacesAndNewlines),
                isSessionPro: isSessionPro
            ) >= 0
        else {
            showModalForMessagesExceedingCharacterLimit(isSessionPro: isSessionPro)
            return
        }
        
        // Toolbar flickers in and out if there are errors
        // and remains visible momentarily after share extension is dismissed.
        // It's easiest to just hide it at this point since we're done with it.
        currentPageViewController?.shouldAllowAttachmentViewResizing = false

        approvalDelegate?.attachmentApproval(
            self,
            didApproveAttachments: attachments,
            forThreadId: threadId,
            threadVariant: threadVariant,
            messageText: snInputView.text,
            quoteViewModel: snInputView.quoteViewModel
        )
    }

    public func inputTextViewDidChangeContent(_ inputTextView: InputTextView) {
        approvalDelegate?.attachmentApproval(self, didChangeMessageText: inputTextView.text)
    }
}

// MARK: -

extension AttachmentApprovalViewController: AttachmentPrepViewControllerDelegate {
    @MainActor func prepViewControllerUpdateNavigationBar() {
        updateNavigationBar()
    }
}

// MARK: GalleryRail

extension PendingAttachmentRailItem: GalleryRailItem {
    func buildRailItemView(using dependencies: Dependencies) -> UIView {
        let imageView: SessionImageView = SessionImageView(dataManager: dependencies[singleton: .imageDataManager])
        imageView.contentMode = .scaleAspectFill
        imageView.themeBackgroundColor = .backgroundSecondary
        
        switch attachment.source {
            case .file, .voiceMessage, .text: break;
            case .media(let dataSource):
                Task.detached(priority: .userInitiated) { [attachment, attachmentManager = dependencies[singleton: .attachmentManager]] in
                    /// Can't thumbnail animated images so just load the full file in this case
                    if attachment.utType.isAnimated {
                        return await imageView.loadImage(dataSource)
                    }
                    
                    /// Videos have a custom method for generating their thumbnails so use that instead
                    if attachment.utType.isVideo {
                        return await imageView.loadImage(dataSource)
                    }
                    
                    /// We only support generating a thumbnail for a file that is on disk, so if the source isn't a `url` then just
                    /// load it directly
                    guard case .url(let url) = dataSource else {
                        return await imageView.loadImage(dataSource)
                    }
                    
                    /// Otherwise, generate the thumbnail
                    await imageView.loadImage(.urlThumbnail(url, .small, attachmentManager))
                }
        }

        return imageView
    }
    
    func isEqual(to other: GalleryRailItem?) -> Bool {
        guard let otherAttachmentItem: PendingAttachmentRailItem = other as? PendingAttachmentRailItem else { return false }
        
        return (self.attachment == otherAttachmentItem.attachment)
    }
}

// MARK: -

extension AttachmentApprovalViewController: GalleryRailViewDelegate {
    public func galleryRailView(_ galleryRailView: GalleryRailView, didTapItem imageRailItem: GalleryRailItem) {
        if imageRailItem is AddMoreRailItem {
            self.approvalDelegate?.attachmentApprovalDidTapAddMore(self)
            return
        }

        guard let targetItem = imageRailItem as? PendingAttachmentRailItem else {
            Log.error(.cat, "Unexpected imageRailItem: \(imageRailItem)")
            return
        }

        guard let currentItem: PendingAttachmentRailItem = currentItem, let currentIndex = attachmentItems.firstIndex(of: currentItem) else {
            Log.error(.cat, "currentIndex was unexpectedly nil")
            return
        }

        guard let targetIndex = attachmentItems.firstIndex(of: targetItem) else {
            Log.error(.cat, "targetIndex was unexpectedly nil")
            return
        }

        let direction: UIPageViewController.NavigationDirection = (currentIndex < targetIndex ? .forward : .reverse)

        self.setCurrentItem(targetItem, direction: direction, animated: true)
    }
}

// MARK: -

extension AttachmentApprovalViewController: ApprovalRailCellViewDelegate {
    func approvalRailCellView(_ approvalRailCellView: ApprovalRailCellView, didRemoveItem attachmentItem: PendingAttachmentRailItem) {
        remove(attachmentItem: attachmentItem)
    }

    func canRemoveApprovalRailCellView(_ approvalRailCellView: ApprovalRailCellView) -> Bool {
        return self.attachmentItems.count > 1
    }
}
