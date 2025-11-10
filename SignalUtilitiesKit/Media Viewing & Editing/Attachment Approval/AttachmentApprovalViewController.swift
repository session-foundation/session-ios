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
        messageText: String?
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
    private var isSessionPro: Bool {
        dependencies[cache: .libSession].isSessionPro
    }
    
    var isKeyboardVisible: Bool = false
    private let disableLinkPreviewImageDownload: Bool
    private let didLoadLinkPreview: ((LinkPreviewDraft) -> Void)?

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
    
    override public var inputAccessoryView: UIView? {
        bottomToolView.layoutIfNeeded()
        return bottomToolView
    }

    override public var canBecomeFirstResponder: Bool {
        return !shouldHideControls
    }
    
    public var messageText: String? {
        get { return bottomToolView.attachmentTextToolbar.text }
        set { bottomToolView.attachmentTextToolbar.text = newValue }
    }

    // MARK: - Initializers

    @available(*, unavailable, message:"use attachment: constructor instead.")
    required public init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    required public init?(
        mode: Mode,
        threadId: String,
        threadVariant: SessionThread.Variant,
        attachments: [PendingAttachment],
        disableLinkPreviewImageDownload: Bool,
        didLoadLinkPreview: ((LinkPreviewDraft) -> Void)?,
        using dependencies: Dependencies
    ) {
        guard !attachments.isEmpty else { return nil }
        
        self.dependencies = dependencies
        self.mode = mode
        self.threadId = threadId
        self.threadVariant = threadVariant
        let attachmentItems = attachments.map {
            PendingAttachmentRailItem(attachment: $0, using: dependencies)
        }
        self.isAddMoreVisible = (mode == .sharedNavigation)
        self.disableLinkPreviewImageDownload = disableLinkPreviewImageDownload
        self.didLoadLinkPreview = didLoadLinkPreview

        self.attachmentRailItemCollection = PendingAttachmentRailItemCollection(attachmentItems: attachmentItems, isAddMoreVisible: isAddMoreVisible)

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

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    public class func wrappedInNavController(
        threadId: String,
        threadVariant: SessionThread.Variant,
        attachments: [PendingAttachment],
        approvalDelegate: AttachmentApprovalViewControllerDelegate,
        disableLinkPreviewImageDownload: Bool,
        didLoadLinkPreview: ((LinkPreviewDraft) -> Void)?,
        using dependencies: Dependencies
    ) -> UINavigationController? {
        guard let vc = AttachmentApprovalViewController(
            mode: .modal,
            threadId: threadId,
            threadVariant: threadVariant,
            attachments: attachments,
            disableLinkPreviewImageDownload: disableLinkPreviewImageDownload,
            didLoadLinkPreview: didLoadLinkPreview,
            using: dependencies
        ) else { return nil }
        vc.approvalDelegate = approvalDelegate
        
        let navController = StyledNavigationController(rootViewController: vc)
        
        return navController
    }

    // MARK: - UI
    
    private let kSpacingBetweenItems: CGFloat = 20
    
    private lazy var bottomToolView: AttachmentApprovalInputAccessoryView = {
        let bottomToolView = AttachmentApprovalInputAccessoryView(delegate: self, using: dependencies)
        bottomToolView.delegate = self
        bottomToolView.attachmentTextToolbar.delegate = self
        bottomToolView.galleryRailView.delegate = self

        return bottomToolView
    }()

    private var galleryRailView: GalleryRailView { return bottomToolView.galleryRailView }

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
        
        // If the first item is just text, or is a URL and LinkPreviews are disabled
        // then just fill the 'message' box with it
        let firstItemIsPlainText: Bool = {
            switch firstItem.attachment.source {
                case .text: return true
                default: return false
            }
        }()
        if firstItemIsPlainText || (firstItem.attachment.utType.conforms(to: .url) && LinkPreview.previewUrl(for: firstItem.attachment.toText(), using: dependencies) == nil) {
            bottomToolView.attachmentTextToolbar.text = firstItem.attachment.toText()
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
        updateInputAccessory()
    }

    // MARK: - Input Accessory

    @MainActor public func updateInputAccessory() {
        var currentPageViewController: AttachmentPrepViewController?
        
        if pageViewControllers?.count == 1 {
            currentPageViewController = pageViewControllers?.first
        }
        let currentAttachmentItem: PendingAttachmentRailItem? = currentPageViewController?.attachmentItem

        let hasPresentedView = (self.presentedViewController != nil)
        let isToolbarFirstResponder = bottomToolView.hasFirstResponder
        
        if !shouldHideControls, !isFirstResponder, !hasPresentedView, !isToolbarFirstResponder {
            becomeFirstResponder()
        }

        bottomToolView.update(
            currentAttachmentItem: currentAttachmentItem,
            shouldHideControls: shouldHideControls
        )
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
        let viewController = AttachmentPrepViewController(
            attachmentItem: item,
            disableLinkPreviewImageDownload: disableLinkPreviewImageDownload,
            didLoadLinkPreview: didLoadLinkPreview,
            using: dependencies
        )
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
    
    func hideInputAccessoryView() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async {
                self.hideInputAccessoryView()
            }
            return
        }
        self.isKeyboardVisible = self.bottomToolView.isEditingMediaMessage
        self.inputAccessoryView?.resignFirstResponder()
        self.inputAccessoryView?.isHidden = true
        self.inputAccessoryView?.alpha = 0
    }
    
    func showInputAccessoryView() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async {
                self.showInputAccessoryView()
            }
            return
        }
        UIView.animate(withDuration: 0.25, animations: {
            self.inputAccessoryView?.isHidden = false
            self.inputAccessoryView?.alpha = 1
            if self.isKeyboardVisible {
                self.inputAccessoryView?.becomeFirstResponder()
            }
        })
    }

    // MARK: - Event Handlers
    
    private func cancelPressed() {
        self.approvalDelegate?.attachmentApprovalDidCancel(self)
    }
    
    @MainActor func showModalForMessagesExceedingCharacterLimit(isSessionPro: Bool) {
        guard dependencies[singleton: .sessionProState].showSessionProCTAIfNeeded(
            .longerMessages,
            beforePresented: { [weak self] in
                self?.hideInputAccessoryView()
            },
            onConfirm: { [weak self, dependencies] in
                dependencies[singleton: .sessionProState].showSessionProBottomSheetIfNeeded(
                    presenting: { bottomSheet in
                        self?.present(bottomSheet, animated: true)
                    }
                )
            },
            afterClosed: { [weak self] in
                self?.showInputAccessoryView()
                self?.bottomToolView.attachmentTextToolbar.updateNumberOfCharactersLeft(self?.bottomToolView.attachmentTextToolbar.text ?? "")
            },
            presenting: { [weak self] modal in
                self?.present(modal, animated: true)
            }
        ) else {
            return
        }
        
        self.hideInputAccessoryView()
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
                cancelStyle: .alert_text,
                afterClosed: { [weak self] in
                    self?.showInputAccessoryView()
                }
            )
        )
        present(confirmationModal, animated: true, completion: nil)
    }
}

// MARK: - AttachmentTextToolbarDelegate

extension AttachmentApprovalViewController: AttachmentTextToolbarDelegate {
    @MainActor func attachmentTextToolBarDidTapCharacterLimitLabel(_ attachmentTextToolbar: AttachmentTextToolbar) {
        guard dependencies[singleton: .sessionProState].showSessionProCTAIfNeeded(
            .longerMessages,
            beforePresented: { [weak self] in
                self?.hideInputAccessoryView()
            },
            onConfirm: { [weak self, dependencies] in
                dependencies[singleton: .sessionProState].showSessionProBottomSheetIfNeeded(
                    presenting: { bottomSheet in
                        self?.present(bottomSheet, animated: true)
                    }
                )
            },
            afterClosed: { [weak self] in
                self?.showInputAccessoryView()
                self?.bottomToolView.attachmentTextToolbar.updateNumberOfCharactersLeft(self?.bottomToolView.attachmentTextToolbar.text ?? "")
            },
            presenting: { [weak self] modal in
                self?.present(modal, animated: true)
            }
        ) else {
            return
        }
        
        self.hideInputAccessoryView()
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
                cancelStyle: .alert_text,
                afterClosed: { [weak self] in
                    self?.showInputAccessoryView()
                }
            )
        )
        present(confirmationModal, animated: true, completion: nil)
    }

    @MainActor func attachmentTextToolbarDidTapSend(_ attachmentTextToolbar: AttachmentTextToolbar) {
        guard
            let text = attachmentTextToolbar.text,
            LibSession.numberOfCharactersLeft(
                for: text.trimmingCharacters(in: .whitespacesAndNewlines),
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
        attachmentTextToolbar.isUserInteractionEnabled = false
        attachmentTextToolbar.isHidden = true

        approvalDelegate?.attachmentApproval(
            self,
            didApproveAttachments: attachments,
            forThreadId: threadId,
            threadVariant: threadVariant,
            messageText: attachmentTextToolbar.text
        )
    }

    @MainActor func attachmentTextToolbarDidChange(_ attachmentTextToolbar: AttachmentTextToolbar) {
        approvalDelegate?.attachmentApproval(self, didChangeMessageText: attachmentTextToolbar.text)
    }
}

// MARK: -

extension AttachmentApprovalViewController: AttachmentPrepViewControllerDelegate {
    @MainActor func prepViewControllerUpdateNavigationBar() {
        updateNavigationBar()
    }

    @MainActor func prepViewControllerUpdateControls() {
        updateInputAccessory()
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

// MARK: -

extension AttachmentApprovalViewController: AttachmentApprovalInputAccessoryViewDelegate {
    public func attachmentApprovalInputUpdateMediaRail() {
        updateMediaRail()
    }
}
