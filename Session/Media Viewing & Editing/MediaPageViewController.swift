// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import GRDB
import SessionUIKit
import SessionMessagingKit
import SignalUtilitiesKit
import SessionUtilitiesKit
import SessionSnodeKit

class MediaPageViewController: UIPageViewController, UIPageViewControllerDataSource, UIPageViewControllerDelegate, MediaDetailViewControllerDelegate, InteractivelyDismissableViewController {
    class DynamicallySizedView: UIView {
        override var intrinsicContentSize: CGSize { CGSize.zero }
    }
    
    fileprivate var mediaInteractiveDismiss: MediaInteractiveDismiss?
    
    public let viewModel: MediaGalleryViewModel
    private var dataChangeObservable: DatabaseCancellable? {
        didSet { oldValue?.cancel() }   // Cancel the old observable if there was one
    }
    private var initialPage: MediaDetailViewController
    private var cachedPages: [Int64: [MediaGalleryViewModel.Item: MediaDetailViewController]] = [:]
    
    public var currentViewController: MediaDetailViewController? {
        return viewControllers?.first as? MediaDetailViewController
    }

    public var currentItem: MediaGalleryViewModel.Item? {
        return currentViewController?.galleryItem
    }

    public func setCurrentItem(_ item: MediaGalleryViewModel.Item, direction: UIPageViewController.NavigationDirection, animated isAnimated: Bool) {
        guard let galleryPage = self.buildGalleryPage(galleryItem: item) else {
            Log.error("[MediaPageViewController] Unexpectedly unable to build new gallery page")
            return
        }
        
        // Cache and retrieve the new album items
        viewModel.loadAndCacheAlbumData(
            for: item.interactionId,
            in: self.viewModel.threadId
        )
        
        // Swap out the database observer
        stopObservingChanges()
        viewModel.replaceAlbumObservation(toObservationFor: item.interactionId)
        startObservingChanges()

        updateTitle(item: item)
        updateCaption(item: item)
        setViewControllers([galleryPage], direction: direction, animated: isAnimated) { [weak galleryPage] _ in
            galleryPage?.parentDidAppear() // Trigger any custom appearance animations
        }
        updateFooterBarButtonItems()
        updateMediaRail(item: item)
    }

    private let showAllMediaButton: Bool
    private let sliderEnabled: Bool

    init(
        viewModel: MediaGalleryViewModel,
        initialItem: MediaGalleryViewModel.Item,
        options: [MediaGalleryOption]
    ) {
        self.viewModel = viewModel
        self.showAllMediaButton = options.contains(.showAllMediaButton)
        self.sliderEnabled = options.contains(.sliderEnabled)
        self.initialPage = MediaDetailViewController(galleryItem: initialItem, using: viewModel.dependencies)

        super.init(
            transitionStyle: .scroll,
            navigationOrientation: .horizontal,
            options: [ .interPageSpacing: 20 ]
        )
        
        self.cachedPages[initialItem.interactionId] = [initialItem: self.initialPage]
        self.initialPage.delegate = self
        self.dataSource = self
        self.delegate = self
        self.modalPresentationStyle = .overFullScreen
        self.transitioningDelegate = self
        self.setViewControllers([initialPage], direction: .forward, animated: false, completion: nil)
    }

    @available(*, unavailable, message: "Unimplemented")
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Subview
    
    private var hasAppeared: Bool = false
    override var canBecomeFirstResponder: Bool { hasAppeared }

    override var inputAccessoryView: UIView? {
        return bottomContainer
    }

    // MARK: - Bottom Bar
    
    var bottomContainer: UIView = {
        let result: DynamicallySizedView = DynamicallySizedView()
        result.clipsToBounds = true
        result.autoresizingMask = .flexibleHeight
        result.themeBackgroundColor = .backgroundPrimary
        
        return result
    }()
    
    var footerBar: UIToolbar = {
        let result: UIToolbar = UIToolbar()
        result.clipsToBounds = true // hide 1px top-border
        result.themeTintColor = .textPrimary
        result.themeBarTintColor = .backgroundPrimary
        result.themeBackgroundColor = .backgroundPrimary
        result.setBackgroundImage(UIImage(), forToolbarPosition: .any, barMetrics: UIBarMetrics.default)
        result.setShadowImage(UIImage(), forToolbarPosition: .any)
        result.isTranslucent = false

        return result
    }()
    
    let captionContainerView: CaptionContainerView = CaptionContainerView()
    var galleryRailView: GalleryRailView = GalleryRailView()

    var pagerScrollView: UIScrollView!

    // MARK: UIViewController overrides

    override func viewDidLoad() {
        super.viewDidLoad()

        // Navigation

        let backButton = UIViewController.createOWSBackButton(target: self, selector: #selector(didPressDismissButton), using: viewModel.dependencies)
        self.navigationItem.leftBarButtonItem = backButton
        self.navigationItem.titleView = portraitHeaderView

        if showAllMediaButton {
            self.navigationItem.rightBarButtonItem = UIBarButtonItem(title: "conversationsSettingsAllMedia".localized(), style: .plain, target: self, action: #selector(didPressAllMediaButton))
        }

        // Even though bars are opaque, we want content to be layed out behind them.
        // The bars might obscure part of the content, but they can easily be hidden by tapping
        // The alternative would be that content would shift when the navbars hide.
        self.extendedLayoutIncludesOpaqueBars = true
        self.automaticallyAdjustsScrollViewInsets = false
        
        // Disable the interactivePopGestureRecognizer as we want to be able to swipe between
        // different pages
        self.navigationController?.interactivePopGestureRecognizer?.isEnabled = false
        self.mediaInteractiveDismiss = MediaInteractiveDismiss(targetViewController: self)
        self.mediaInteractiveDismiss?.addGestureRecognizer(to: view)

        // Get reference to paged content which lives in a scrollView created by the superclass
        // We show/hide this content during presentation
        for view in self.view.subviews {
            if let pagerScrollView = view as? UIScrollView {
                pagerScrollView.contentInsetAdjustmentBehavior = .never
                self.pagerScrollView = pagerScrollView
            }
        }

        // Hack to avoid "page" bouncing when not in gallery view.
        // e.g. when getting to media details via message details screen, there's only
        // one "Page" so the bounce doesn't make sense.
        pagerScrollView.isScrollEnabled = sliderEnabled
        pagerScrollViewContentOffsetObservation = pagerScrollView.observe(\.contentOffset, options: [.new]) { [weak self] _, change in
            guard let strongSelf = self else { return }
            strongSelf.pagerScrollView(strongSelf.pagerScrollView, contentOffsetDidChange: change)
        }

        // Views
        pagerScrollView.themeBackgroundColor = .newConversation_background

        view.themeBackgroundColor = .newConversation_background

        captionContainerView.delegate = self
        updateCaptionContainerVisibility()

        galleryRailView.isHidden = true
        galleryRailView.delegate = self
        galleryRailView.set(.height, to: 72)
        footerBar.set(.height, to: 44)

        let bottomStack = UIStackView(arrangedSubviews: [captionContainerView, galleryRailView, footerBar])
        bottomStack.axis = .vertical
        bottomStack.isLayoutMarginsRelativeArrangement = true
        bottomContainer.addSubview(bottomStack)
        bottomStack.pin(to: bottomContainer)
        
        let galleryRailBlockingView: UIView = UIView()
        galleryRailBlockingView.themeBackgroundColor = .backgroundPrimary
        bottomStack.addSubview(galleryRailBlockingView)
        galleryRailBlockingView.pin(.top, to: .bottom, of: footerBar)
        galleryRailBlockingView.pin(.left, to: .left, of: bottomStack)
        galleryRailBlockingView.pin(.right, to: .right, of: bottomStack)
        galleryRailBlockingView.pin(.bottom, to: .bottom, of: bottomStack)
        
        updateTitle(item: currentItem)
        updateCaption(item: currentItem)
        updateMediaRail(item: currentItem)
        updateFooterBarButtonItems()

        // Gestures

        let verticalSwipe = UISwipeGestureRecognizer(target: self, action: #selector(didSwipeView))
        verticalSwipe.direction = [.up, .down]
        view.addGestureRecognizer(verticalSwipe)
    }
    
    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        
        startObservingChanges()
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        
        hasAppeared = true
        becomeFirstResponder()
        
        children.forEach { child in
            switch child {
                case let detailViewController as MediaDetailViewController:
                    detailViewController.parentDidAppear()
                    
                default: break
            }
        }
    }
    
    public override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        
        stopObservingChanges()
        
        resignFirstResponder()
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        let isLandscape = size.width > size.height
        self.navigationItem.titleView = isLandscape ? nil : self.portraitHeaderView
    }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()

        self.cachedPages = [:]
    }

    // MARK: KVO

    var pagerScrollViewContentOffsetObservation: NSKeyValueObservation?
    func pagerScrollView(_ pagerScrollView: UIScrollView, contentOffsetDidChange change: NSKeyValueObservedChange<CGPoint>) {
        guard let newValue = change.newValue else {
            Log.error("[MediaPageViewController] newValue was unexpectedly nil")
            return
        }

        let width = pagerScrollView.frame.size.width
        guard width > 0 else {
            return
        }
        let ratioComplete = abs((newValue.x - width) / width)
        captionContainerView.updatePagerTransition(ratioComplete: ratioComplete)
    }

    // MARK: View Helpers

    public func willBePresentedAgain() {
        updateFooterBarButtonItems()
    }

    public func wasPresented() {
        let currentViewController = self.currentViewController

        if currentViewController?.galleryItem.isVideo == true {
            currentViewController?.playVideo()
        }
    }

    private var shouldHideToolbars: Bool = false {
        didSet {
            guard oldValue != shouldHideToolbars else { return }
            
            self.navigationController?.setNavigationBarHidden(shouldHideToolbars, animated: false)

            UIView.animate(withDuration: 0.1) {
                self.bottomContainer.isHidden = self.shouldHideToolbars
            }
        }
    }

    // MARK: Bar Buttons

    lazy var shareBarButton: UIBarButtonItem = {
        let shareBarButton = UIBarButtonItem(
            barButtonSystemItem: .action,
            target: self,
            action: #selector(didPressShare)
        )
        shareBarButton.themeTintColor = .textPrimary
        
        return shareBarButton
    }()

    lazy var deleteBarButton: UIBarButtonItem = {
        let deleteBarButton = UIBarButtonItem(
            barButtonSystemItem: .trash,
            target: self,
            action: #selector(didPressDelete)
        )
        deleteBarButton.themeTintColor = .textPrimary
        
        return deleteBarButton
    }()

    func buildFlexibleSpace() -> UIBarButtonItem {
        return UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil)
    }

    lazy var videoPlayBarButton: UIBarButtonItem = {
        let videoPlayBarButton = UIBarButtonItem(
            barButtonSystemItem: .play,
            target: self,
            action: #selector(didPressPlayBarButton)
        )
        videoPlayBarButton.themeTintColor = .textPrimary
        
        return videoPlayBarButton
    }()

    private func updateFooterBarButtonItems() {
        self.footerBar.setItems(
            [
                shareBarButton,
                buildFlexibleSpace(),
                (self.currentItem?.isVideo == true ? self.videoPlayBarButton : nil),
                (self.currentItem?.isVideo == true ? buildFlexibleSpace() : nil),
                (self.viewModel.threadVariant != .legacyGroup ? deleteBarButton : nil)
            ].compactMap { $0 },
            animated: false
        )
    }

    func updateMediaRail(item: MediaGalleryViewModel.Item?) {
        guard let item: MediaGalleryViewModel.Item = item else { return }
        
        galleryRailView.configureCellViews(
            album: (self.viewModel.albumData[item.interactionId] ?? []),
            focusedItem: currentItem,
            using: viewModel.dependencies,
            cellViewBuilder: { _ in return GalleryRailCellView() }
        )
    }
    
    // MARK: - Updating
    
    private func startObservingChanges() {
        guard dataChangeObservable == nil else { return }
        
        // Start observing for data changes
        dataChangeObservable = viewModel.dependencies[singleton: .storage].start(
            viewModel.observableAlbumData,
            onError: { _ in },
            onChange: { [weak self] albumData in
                // The default scheduler emits changes on the main thread
                self?.handleUpdates(albumData)
            }
        )
    }
    
    private func stopObservingChanges() {
        dataChangeObservable?.cancel()
        dataChangeObservable = nil
    }
    
    private func handleUpdates(_ updatedViewData: [MediaGalleryViewModel.Item]) {
        // Determine if we swapped albums (if so we don't need to do anything else)
        guard
            let interactionId: Int64 = currentItem?.interactionId,
            updatedViewData.contains(where: { $0.interactionId == interactionId })
        else {
            if let updatedInteractionId: Int64 = updatedViewData.first?.interactionId {
                self.viewModel.updateAlbumData(updatedViewData, for: updatedInteractionId)
            }
            return
        }
        
        // Clear the cached pages that no longer match
        let updatedCachedPages: [MediaGalleryViewModel.Item: MediaDetailViewController] = cachedPages[interactionId]
            .defaulting(to: [:])
            .filter { key, _ -> Bool in updatedViewData.contains(key) }
        
        // If there are no more items in the album then dismiss the screen
        guard
            !updatedViewData.isEmpty,
            let currentItem: MediaGalleryViewModel.Item = currentItem,
            let oldIndex: Int = self.viewModel.albumData[interactionId]?.firstIndex(of: currentItem)
        else {
            self.dismissSelf(animated: true)
            return
        }
        
        // Update the caches
        self.viewModel.updateAlbumData(updatedViewData, for: interactionId)
        self.cachedPages[interactionId] = updatedCachedPages
        
        // If the current item is still available then do nothing else
        guard updatedCachedPages[currentItem] == nil else { return }
        
        // If the current item was modified within the current update then reload it (just in case)
        if let updatedCurrentItem: MediaGalleryViewModel.Item = updatedViewData.first(where: { item in item.attachment.id == currentItem.attachment.id }) {
            setCurrentItem(updatedCurrentItem, direction: .forward, animated: false)
            return
        }
        
        // Determine the next index (if it's less than 0 then pop the screen)
        let nextIndex: Int = min(oldIndex, (updatedViewData.count - 1))
        
        guard nextIndex >= 0 else {
            self.dismissSelf(animated: true)
            return
        }
        
        self.setCurrentItem(
            updatedViewData[nextIndex],
            direction: (nextIndex < oldIndex ?
                .reverse :
                .forward
            ),
            animated: true
        )
    }

    // MARK: - Actions

    @objc public func didPressAllMediaButton(sender: Any) {
        // If the screen wasn't presented or it was presented from a location which isn't the
        // MediaTileViewController then just pop/dismiss the screen
        let parentNavController: UINavigationController? = {
            switch self.presentingViewController {
                case let topBannerController as TopBannerController:
                    return topBannerController.children.first as? UINavigationController
                    
                default: return self.presentingViewController as? UINavigationController
            }
        }()
        
        guard
            let presentingNavController: UINavigationController = parentNavController,
            !(presentingNavController.viewControllers.last is AllMediaViewController)
        else {
            guard self.navigationController?.viewControllers.count == 1 else {
                self.navigationController?.popViewController(animated: true)
                return
            }
            
            self.dismiss(animated: true)
            return
        }
        
        // Otherwise if we came via the conversation screen we need to push a new
        // instance of MediaTileViewController
        let allMediaViewController: AllMediaViewController = MediaGalleryViewModel.createAllMediaViewController(
            threadId: self.viewModel.threadId,
            threadVariant: self.viewModel.threadVariant,
            focusedAttachmentId: currentItem?.attachment.id,
            performInitialQuerySync: true,
            using: viewModel.dependencies
        )
        
        let navController: MediaGalleryNavigationController = MediaGalleryNavigationController()
        navController.viewControllers = [allMediaViewController]
        navController.modalPresentationStyle = .overFullScreen
        navController.transitioningDelegate = allMediaViewController
        
        self.navigationController?.present(navController, animated: true)
    }

    @objc public func didSwipeView(sender: Any) {
        self.dismissSelf(animated: true)
    }

    @objc public func didPressDismissButton(_ sender: Any) {
        dismissSelf(animated: true)
    }

    @objc public func didPressShare(_ sender: Any) { share() }
    
    public func share() {
        guard let currentViewController = self.viewControllers?[0] as? MediaDetailViewController else {
            Log.error("[MediaPageViewController] currentViewController was unexpectedly nil")
            return
        }
        guard let originalFilePath: String = currentViewController.galleryItem.attachment.originalFilePath(using: viewModel.dependencies) else {
            return
        }
        
        let shareVC = UIActivityViewController(activityItems: [ URL(fileURLWithPath: originalFilePath) ], applicationActivities: nil)
        
        if UIDevice.current.isIPad {
            shareVC.excludedActivityTypes = []
            shareVC.popoverPresentationController?.permittedArrowDirections = []
            shareVC.popoverPresentationController?.sourceView = self.view
            shareVC.popoverPresentationController?.sourceRect = self.view.bounds
        }
        
        shareVC.completionWithItemsHandler = { [dependencies = viewModel.dependencies] activityType, completed, returnedItems, activityError in
            if let activityError = activityError {
                Log.error("[MediaPageViewController] Failed to share with activityError: \(activityError)")
            }
            else if completed {
                Log.info("[MediaPageViewController] Did share with activityType: \(activityType.debugDescription)")
            }
            
            guard
                let activityType = activityType,
                activityType == .saveToCameraRoll,
                currentViewController.galleryItem.interactionVariant == .standardIncoming,
                self.viewModel.threadVariant == .contact
            else { return }
            
            let threadId: String = self.viewModel.threadId
            let threadVariant: SessionThread.Variant = self.viewModel.threadVariant
            
            dependencies[singleton: .storage].write { db in
                try MessageSender.send(
                    db,
                    message: DataExtractionNotification(
                        kind: .mediaSaved(
                            timestamp: UInt64(currentViewController.galleryItem.interactionTimestampMs)
                        ),
                        sentTimestampMs: dependencies[cache: .snodeAPI].currentOffsetTimestampMs()
                    )
                    .with(DisappearingMessagesConfiguration
                        .fetchOne(db, id: threadId)?
                        .forcedWithDisappearAfterReadIfNeeded()
                    ),
                    interactionId: nil, // Show no interaction for the current user
                    threadId: threadId,
                    threadVariant: threadVariant,
                    using: dependencies
                )
            }
        }
        self.present(shareVC, animated: true, completion: nil)
    }

    @objc public func didPressDelete(_ sender: Any) {
        guard let itemToDelete: MediaGalleryViewModel.Item = self.currentItem else { return }
        
        let actionSheet: UIAlertController = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
        let deleteAction = UIAlertAction(
            title: "clearMessagesForMe".localized(),
            style: .destructive
        ) { [dependencies = viewModel.dependencies] _ in
            dependencies[singleton: .storage].writeAsync { db in
                _ = try Attachment
                    .filter(id: itemToDelete.attachment.id)
                    .deleteAll(db)
                
                // Add the garbage collection job to delete orphaned attachment files
                dependencies[singleton: .jobRunner].add(
                    db,
                    job: Job(
                        variant: .garbageCollection,
                        behaviour: .runOnce,
                        details: GarbageCollectionJob.Details(
                            typesToCollect: [.orphanedAttachmentFiles]
                        )
                    ),
                    canStartJob: true
                )
                
                // Delete any interactions which had all of their attachments removed
                _ = try Interaction
                    .filter(id: itemToDelete.interactionId)
                    .having(Interaction.interactionAttachments.isEmpty)
                    .deleteAll(db)
            }
        }
        actionSheet.addAction(UIAlertAction(title: "cancel".localized(), style: .cancel))
        actionSheet.addAction(deleteAction)

        Modal.setupForIPadIfNeeded(actionSheet, targetView: self.view)
        self.present(actionSheet, animated: true)
    }

    // MARK: - Video interaction

    @objc public func didPressPlayBarButton() {
        guard let currentViewController = self.viewControllers?.first as? MediaDetailViewController else {
            Log.error("[MediaPageViewController] currentViewController was unexpectedly nil")
            return
        }
        
        currentViewController.didPressPlayBarButton()
    }

    // MARK: UIPageViewControllerDelegate

    var pendingViewController: MediaDetailViewController?
    public func pageViewController(_ pageViewController: UIPageViewController, willTransitionTo pendingViewControllers: [UIViewController]) {

        Log.assert(pendingViewControllers.count == 1)
        pendingViewControllers.forEach { viewController in
            guard let pendingViewController = viewController as? MediaDetailViewController else {
                Log.error("[MediaPageViewController] Unexpected mediaDetailViewController: \(viewController)")
                return
            }
            self.pendingViewController = pendingViewController

            if let pendingCaptionText = pendingViewController.galleryItem.captionForDisplay, pendingCaptionText.count > 0 {
                self.captionContainerView.pendingText = pendingCaptionText
            } else {
                self.captionContainerView.pendingText = nil
            }
        }
    }

    public func pageViewController(_ pageViewController: UIPageViewController, didFinishAnimating finished: Bool, previousViewControllers: [UIViewController], transitionCompleted: Bool) {

        Log.assert(previousViewControllers.count == 1)
        previousViewControllers.forEach { viewController in
            guard let previousPage = viewController as? MediaDetailViewController else {
                Log.error("[MediaPageViewController] Unexpected mediaDetailViewController: \(viewController)")
                return
            }

            // Do any cleanup for the no-longer visible view controller
            if transitionCompleted {
                pendingViewController = nil

                // This can happen when trying to page past the last (or first) view controller
                // In that case, we don't want to change the captionView.
                if (previousPage != currentViewController) {
                    captionContainerView.completePagerTransition()
                }

                currentViewController?.parentDidAppear() // Trigger any custom appearance animations
                updateTitle(item: currentItem)
                updateMediaRail(item: currentItem)
                previousPage.zoomOut(animated: false)
                updateFooterBarButtonItems()
            } else {
                captionContainerView.pendingText = nil
            }
        }
    }

    // MARK: UIPageViewControllerDataSource

    public func pageViewController(_ pageViewController: UIPageViewController, viewControllerBefore viewController: UIViewController) -> UIViewController? {
        guard let mediaViewController: MediaDetailViewController = viewController as? MediaDetailViewController else {
            return nil
        }
        
        // First check if there is another item in the current album
        let interactionId: Int64 = mediaViewController.galleryItem.interactionId
        
        if
            let currentAlbum: [MediaGalleryViewModel.Item] = self.viewModel.albumData[interactionId],
            let index: Int = currentAlbum.firstIndex(of: mediaViewController.galleryItem),
            index > 0,
            let previousPage: MediaDetailViewController = buildGalleryPage(galleryItem: currentAlbum[index - 1])
        {
            return previousPage
        }
        
        // Then check if there is an interaction before the current album interaction
        guard let interactionIdAfter: Int64 = self.viewModel.interactionIdAfter[interactionId] else {
            return nil
        }
        
        // Cache and retrieve the new album items
        let newAlbumItems: [MediaGalleryViewModel.Item] = viewModel.loadAndCacheAlbumData(
            for: interactionIdAfter,
            in: self.viewModel.threadId
        )
        
        guard
            !newAlbumItems.isEmpty,
            let previousPage: MediaDetailViewController = buildGalleryPage(
                galleryItem: newAlbumItems[newAlbumItems.count - 1]
            )
        else {
            // Invalid state, restart the observer
            startObservingChanges()
            return nil
        }
        
        // Swap out the database observer
        stopObservingChanges()
        viewModel.replaceAlbumObservation(toObservationFor: interactionIdAfter)
        startObservingChanges()
        
        return previousPage
    }

    public func pageViewController(_ pageViewController: UIPageViewController, viewControllerAfter viewController: UIViewController) -> UIViewController? {
        guard let mediaViewController: MediaDetailViewController = viewController as? MediaDetailViewController else {
            return nil
        }
        
        // First check if there is another item in the current album
        let interactionId: Int64 = mediaViewController.galleryItem.interactionId
        
        if
            let currentAlbum: [MediaGalleryViewModel.Item] = self.viewModel.albumData[interactionId],
            let index: Int = currentAlbum.firstIndex(of: mediaViewController.galleryItem),
            index < (currentAlbum.count - 1),
            let nextPage: MediaDetailViewController = buildGalleryPage(galleryItem: currentAlbum[index + 1])
        {
            return nextPage
        }
        
        // Then check if there is an interaction before the current album interaction
        guard let interactionIdBefore: Int64 = self.viewModel.interactionIdBefore[interactionId] else {
            return nil
        }

        // Cache and retrieve the new album items
        let newAlbumItems: [MediaGalleryViewModel.Item] = viewModel.loadAndCacheAlbumData(
            for: interactionIdBefore,
            in: self.viewModel.threadId
        )
        
        guard
            !newAlbumItems.isEmpty,
            let nextPage: MediaDetailViewController = buildGalleryPage(galleryItem: newAlbumItems[0])
        else {
            // Invalid state, restart the observer
            startObservingChanges()
            return nil
        }
        
        // Swap out the database observer
        stopObservingChanges()
        viewModel.replaceAlbumObservation(toObservationFor: interactionIdBefore)
        startObservingChanges()
        
        return nextPage
    }

    private func buildGalleryPage(galleryItem: MediaGalleryViewModel.Item) -> MediaDetailViewController? {
        if let cachedPage: MediaDetailViewController = cachedPages[galleryItem.interactionId]?[galleryItem] {
            return cachedPage
        }
        
        cachedPages[galleryItem.interactionId] = (cachedPages[galleryItem.interactionId] ?? [:])
            .setting(galleryItem, MediaDetailViewController(galleryItem: galleryItem, delegate: self, using: viewModel.dependencies))
        
        return cachedPages[galleryItem.interactionId]?[galleryItem]
    }

    public func dismissSelf(animated isAnimated: Bool, completion: (() -> Void)? = nil) {
        // If we have presented a MediaTileViewController from this screen then it will continue
        // to observe media changes and if all the items in the album this screen is showing are
        // deleted it will attempt to auto-dismiss
        guard self.presentedViewController == nil else { return }
        
        // Swapping mediaView for presentationView will be perceptible if we're not zoomed out all the way.
        // currentVC
        currentViewController?.zoomOut(animated: true)

        self.navigationController?.view.isUserInteractionEnabled = false
        self.navigationController?.dismiss(animated: true, completion: { [weak self] in
            if !UIDevice.current.isIPad {
                UIDevice.current.ows_setOrientation(.portrait)
            }
            
            UIApplication.shared.isStatusBarHidden = false
            self?.navigationController?.presentingViewController?.setNeedsStatusBarAppearanceUpdate()
            completion?()
        })
    }

    // MARK: MediaDetailViewControllerDelegate

    public func mediaDetailViewControllerDidTapMedia(_ mediaDetailViewController: MediaDetailViewController) {
        self.shouldHideToolbars = !self.shouldHideToolbars
    }

    // MARK: - Dynamic Header

    private lazy var dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short

        return formatter
    }()

    lazy private var portraitHeaderNameLabel: UILabel = {
        let label: UILabel = UILabel()
        label.font = .systemFont(ofSize: Values.mediumFontSize)
        label.themeTextColor = .textPrimary
        label.textAlignment = .center
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.8

        return label
    }()

    lazy private var portraitHeaderDateLabel: UILabel = {
        let label: UILabel = UILabel()
        label.font = .systemFont(ofSize: Values.verySmallFontSize)
        label.themeTextColor = .textPrimary
        label.textAlignment = .center
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.8

        return label
    }()

    private lazy var portraitHeaderView: UIView = {
        let stackView: UIStackView = UIStackView()
        stackView.axis = .vertical
        stackView.alignment = .center
        stackView.spacing = 0
        stackView.distribution = .fillProportionally
        stackView.addArrangedSubview(portraitHeaderNameLabel)
        stackView.addArrangedSubview(portraitHeaderDateLabel)

        let containerView = UIView()
        containerView.layoutMargins = UIEdgeInsets(top: 2, left: 8, bottom: 4, right: 8)

        containerView.addSubview(stackView)
        stackView.pin(.top, greaterThanOrEqualTo: .top, of: containerView)
        stackView.pin(.trailing, greaterThanOrEqualTo: .trailing, of: containerView)
        stackView.pin(.bottom, lessThanOrEqualTo: .bottom, of: containerView)
        stackView.pin(.leading, lessThanOrEqualTo: .leading, of: containerView)
        stackView.setContentHugging(to: .required)
        stackView.center(in: containerView)

        return containerView
    }()

    private func updateCaption(item: MediaGalleryViewModel.Item?) {
        captionContainerView.currentText = item?.captionForDisplay
    }

    private func updateTitle(item: MediaGalleryViewModel.Item?) {
        guard let targetItem: MediaGalleryViewModel.Item = item else { return }
        let threadVariant: SessionThread.Variant = self.viewModel.threadVariant
        
        let name: String = {
            switch targetItem.interactionVariant {
                case .standardIncoming:
                    return viewModel.dependencies[singleton: .storage]
                        .read { [dependencies = viewModel.dependencies] db in
                            Profile.displayName(
                                db,
                                id: targetItem.interactionAuthorId,
                                threadVariant: threadVariant,
                                using: dependencies
                            )
                        }
                        .defaulting(to: Profile.truncated(id: targetItem.interactionAuthorId, truncating: .middle))
                    
                case .standardOutgoing:
                    return "you".localized() // "Short sender label for media sent by you"
                        
                default:
                    Log.error("[MediaPageViewController] Unsupported message variant: \(targetItem.interactionVariant)")
                    return ""
            }
        }()
        
        portraitHeaderNameLabel.text = name

        // use sent date
        let date = Date(timeIntervalSince1970: (Double(targetItem.interactionTimestampMs) / 1000))
        let formattedDate = dateFormatter.string(from: date)
        portraitHeaderDateLabel.text = formattedDate

        let landscapeHeaderText = "attachmentsMedia"
            .put(key: "name", value: name)
            .put(key: "date_time", value: formattedDate)
            .localized()
        self.title = landscapeHeaderText
        self.navigationItem.title = landscapeHeaderText
    }
    
    // MARK: - InteractivelyDismissableViewController
    
    func performInteractiveDismissal(animated: Bool) {
        dismissSelf(animated: true)
    }
}

extension MediaGalleryViewModel.Item: GalleryRailItem {
    public func buildRailItemView(using dependencies: Dependencies) -> UIView {
        let imageView: UIImageView = UIImageView()
        imageView.contentMode = .scaleAspectFill
        
        self.thumbnailImage(using: dependencies) { [weak imageView] image in
            DispatchQueue.main.async {
                imageView?.image = image
            }
        }

        return imageView
    }
    
    public func isEqual(to other: GalleryRailItem?) -> Bool {
        guard let otherItem: MediaGalleryViewModel.Item = other as? MediaGalleryViewModel.Item else {
            return false
        }
        
        return (self == otherItem)
    }
}

extension MediaPageViewController: GalleryRailViewDelegate {
    func galleryRailView(_ galleryRailView: GalleryRailView, didTapItem imageRailItem: GalleryRailItem) {
        guard let targetItem = imageRailItem as? MediaGalleryViewModel.Item else {
            Log.error("[MediaPageViewController] Unexpected imageRailItem: \(imageRailItem)")
            return
        }

        self.setCurrentItem(
            targetItem,
            direction: ((currentItem?.attachmentAlbumIndex ?? -1) < targetItem.attachmentAlbumIndex ?
                .forward :
                .reverse
            ),
            animated: true
        )
    }
}

extension MediaPageViewController: CaptionContainerViewDelegate {

    func captionContainerViewDidUpdateText(_ captionContainerView: CaptionContainerView) {
        updateCaptionContainerVisibility()
    }

    // MARK: Helpers

    func updateCaptionContainerVisibility() {
        if let currentText = captionContainerView.currentText, currentText.count > 0 {
            captionContainerView.isHidden = false
            return
        }

        if let pendingText = captionContainerView.pendingText, pendingText.count > 0 {
            captionContainerView.isHidden = false
            return
        }

        captionContainerView.isHidden = true
    }
}

// MARK: - UIViewControllerTransitioningDelegate

extension MediaPageViewController: UIViewControllerTransitioningDelegate {
    public func animationController(forPresented presented: UIViewController, presenting: UIViewController, source: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        guard let currentItem: MediaGalleryViewModel.Item = currentItem else { return nil }
        guard self == presented || self.navigationController == presented else { return nil }

        return MediaZoomAnimationController(galleryItem: currentItem, using: viewModel.dependencies)
    }

    public func animationController(forDismissed dismissed: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        guard let currentItem: MediaGalleryViewModel.Item = currentItem else { return nil }
        guard self == dismissed || self.navigationController == dismissed else { return nil }
        guard !self.viewModel.albumData.isEmpty else { return nil }

        let animationController = MediaDismissAnimationController(galleryItem: currentItem, interactionController: mediaInteractiveDismiss, using: viewModel.dependencies)
        mediaInteractiveDismiss?.interactiveDismissDelegate = animationController

        return animationController
    }

    public func interactionControllerForDismissal(using animator: UIViewControllerAnimatedTransitioning) -> UIViewControllerInteractiveTransitioning? {
        guard let animator = animator as? MediaDismissAnimationController,
              let interactionController = animator.interactionController,
              interactionController.interactionInProgress
        else {
            return nil
        }
        
        return interactionController
    }
}

// MARK: - MediaPresentationContextProvider

extension MediaPageViewController: MediaPresentationContextProvider {
    func mediaPresentationContext(mediaItem: Media, in coordinateSpace: UICoordinateSpace) -> MediaPresentationContext? {
        guard
            let mediaView: SessionImageView = currentViewController?.mediaView,
            let mediaSuperview: UIView = mediaView.superview,
            let mediaSize: CGSize = {
                /// Because we load images in the background now it can take a small amount of time for the image to actually be
                /// loaded in that case we want to use the size of the image found in the image metadata (which we read in
                /// synchronously when scheduling an image to be loaded)
                guard let image: UIImage = mediaView.image else {
                    return mediaView.imageSizeMetadata
                }
                
                return image.size
            }()
        else { return nil }
        
        var topInset: CGFloat = 0
        var leftInset: CGFloat = 0
        var scaledWidth: CGFloat = mediaSize.width
        var scaledHeight: CGFloat = mediaSize.height

        if mediaSize.width > mediaSize.height {
            scaledWidth = mediaSuperview.frame.width
            scaledHeight = (mediaSize.height * (mediaSuperview.frame.width / mediaSize.width))
            topInset = ((mediaSuperview.frame.height - scaledHeight) / 2.0)
        }
        else if mediaSize.width < mediaSize.height {
            scaledWidth = (mediaSize.width * (mediaSuperview.frame.height / mediaSize.height))
            scaledHeight = mediaSuperview.frame.height
            leftInset = ((mediaSuperview.frame.width - scaledWidth) / 2.0)
        }
        
        return MediaPresentationContext(
            mediaView: mediaView,
            presentationFrame: CGRect(
                x: leftInset,
                y: topInset,
                width: scaledWidth,
                height: scaledHeight
            ),
            cornerRadius: 0,
            cornerMask: CACornerMask()
        )
    }

    func snapshotOverlayView(in coordinateSpace: UICoordinateSpace) -> (UIView, CGRect)? {
        return self.navigationController?.navigationBar.generateSnapshot(in: coordinateSpace)
    }
}
