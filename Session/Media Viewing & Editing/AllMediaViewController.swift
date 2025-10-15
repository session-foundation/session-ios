// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import QuartzCore
import GRDB
import DifferenceKit
import SessionUIKit
import SessionMessagingKit
import SessionUtilitiesKit
import SignalUtilitiesKit

public class AllMediaViewController: UIViewController, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
    private let threadTitle: String?
    private let dependencies: Dependencies
    private let pageVC = UIPageViewController(transitionStyle: .scroll, navigationOrientation: .horizontal, options: nil)
    private var pages: [UIViewController] = []
    private var targetVCIndex: Int?
    
    // MARK: - Components
    
    private lazy var tabBar: TabBar = {
        let result: TabBar = TabBar(
            tabs: [
                TabBar.Tab(title: "media".localized()) { [weak self] in
                    guard let self = self else { return }
                    self.pageVC.setViewControllers([ self.pages[0] ], direction: .forward, animated: false, completion: nil)
                    self.updateSelectButton(
                        threadVariant: self.mediaTitleViewController.viewModel.threadVariant,
                        updatedData: self.mediaTitleViewController.viewModel.galleryData,
                        inBatchSelectMode: self.mediaTitleViewController.isInBatchSelectMode,
                        using: self.mediaTitleViewController.viewModel.dependencies
                    )
                },
                TabBar.Tab(title: "files".localized()) { [weak self] in
                    guard let self = self else { return }
                    self.pageVC.setViewControllers([ self.pages[1] ], direction: .forward, animated: false, completion: nil)
                    self.endSelectMode()
                    self.navigationItem.rightBarButtonItem = nil
                }
            ]
        )
        result.themeBackgroundColor = .backgroundPrimary
        
        return result
    }()
    
    private var mediaTitleViewController: MediaTileViewController
    private var documentTitleViewController: DocumentTileViewController
    
    init(
        threadTitle: String?,
        mediaTitleViewController: MediaTileViewController,
        documentTitleViewController: DocumentTileViewController,
        using dependencies: Dependencies
    ) {
        self.threadTitle = threadTitle
        self.dependencies = dependencies
        self.mediaTitleViewController = mediaTitleViewController
        self.documentTitleViewController = documentTitleViewController
        
        super.init(nibName: nil, bundle: nil)
        
        self.mediaTitleViewController.delegate = self
        self.documentTitleViewController.delegate = self
        
        addChild(self.mediaTitleViewController)
        addChild(self.documentTitleViewController)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    // MARK: Lifecycle
    public override func viewDidLoad() {
        super.viewDidLoad()
        
        view.themeBackgroundColor = .newConversation_background
        
        // Add a custom back button if this is the only view controller
        if self.navigationController?.viewControllers.first == self {
            let backButton = UIViewController.createOWSBackButton(target: self, selector: #selector(didPressDismissButton), using: dependencies)
            self.navigationItem.leftBarButtonItem = backButton
        }
        
        ViewControllerUtilities.setUpDefaultSessionStyle(
            for: self,
            title: (self.threadTitle ?? "conversationsSettingsAllMedia".localized()),
            hasCustomBackButton: false
        )
        
        // Set up page VC
        pages = [ mediaTitleViewController, documentTitleViewController ]
        pageVC.dataSource = self
        pageVC.delegate = self
        pageVC.setViewControllers([ mediaTitleViewController ], direction: .forward, animated: false, completion: nil)
        addChild(pageVC)
        
        // Set up tab bar
        view.addSubview(tabBar)
        tabBar.pin([ UIView.HorizontalEdge.leading, UIView.HorizontalEdge.trailing, UIView.VerticalEdge.top ], to: view)
        // Set up page VC constraints
        let pageVCView = pageVC.view!
        view.addSubview(pageVCView)
        pageVCView.pin([ UIView.HorizontalEdge.leading, UIView.HorizontalEdge.trailing, UIView.VerticalEdge.bottom ], to: view)
        pageVCView.pin(.top, to: .bottom, of: tabBar)
    }
    
    // MARK: General
    public func pageViewController(_ pageViewController: UIPageViewController, viewControllerBefore viewController: UIViewController) -> UIViewController? {
        guard let index = pages.firstIndex(of: viewController), index != 0 else { return nil }
        return pages[index - 1]
    }
    
    public func pageViewController(_ pageViewController: UIPageViewController, viewControllerAfter viewController: UIViewController) -> UIViewController? {
        guard let index = pages.firstIndex(of: viewController), index != (pages.count - 1) else { return nil }
        return pages[index + 1]
    }
    
    // MARK: Updating
    public func pageViewController(_ pageViewController: UIPageViewController, willTransitionTo pendingViewControllers: [UIViewController]) {
        guard let targetVC = pendingViewControllers.first, let index = pages.firstIndex(of: targetVC) else { return }
        targetVCIndex = index
    }
    
    public func pageViewController(_ pageViewController: UIPageViewController, didFinishAnimating isFinished: Bool, previousViewControllers: [UIViewController], transitionCompleted isCompleted: Bool) {
        guard isCompleted, let index = targetVCIndex else { return }
        tabBar.selectTab(at: index)
    }
    
    // MARK: Interaction
    @objc public func didPressDismissButton() {
        dismiss(animated: true, completion: nil)
    }
    
    // MARK: Batch Selection
    @objc func didTapSelect(_ sender: Any) {
        self.mediaTitleViewController.didTapSelect(sender)

        // Don't allow the user to leave mid-selection, so they realized they have
        // to cancel (lose) their selection if they leave.
        self.navigationItem.hidesBackButton = true
    }

    @objc func didCancelSelect(_ sender: Any) {
        endSelectMode()
    }

    func endSelectMode() {
        self.mediaTitleViewController.endSelectMode()
        self.navigationItem.hidesBackButton = false
    }
}

// MARK: - UIDocumentInteractionControllerDelegate

extension AllMediaViewController: UIDocumentInteractionControllerDelegate {
    public func documentInteractionControllerViewControllerForPreview(_ controller: UIDocumentInteractionController) -> UIViewController {
        return self
    }
    
    public func documentInteractionControllerDidEndPreview(_ controller: UIDocumentInteractionController) {
        guard let temporaryFileUrl: URL = controller.url else { return }
        
        /// Now that we are finished with it we want to remove the temporary file (just to be safe ensure that it starts with the
        /// `temporaryDirectory` so we don't accidentally delete a proper file if logic elsewhere changes)
        if temporaryFileUrl.path.starts(with: dependencies[singleton: .fileManager].temporaryDirectory) {
            try? dependencies[singleton: .fileManager].removeItem(atPath: temporaryFileUrl.path)
        }
    }
}

// MARK: - DocumentTitleViewControllerDelegate

extension AllMediaViewController: DocumentTileViewControllerDelegate {
    public func share(temporaryFileUrl: URL) {
        let shareVC = UIActivityViewController(activityItems: [ temporaryFileUrl ], applicationActivities: nil)
        shareVC.completionWithItemsHandler = { [dependencies] _, success, _, _ in
            UIActivityViewController.notifyIfNeeded(success, using: dependencies)
        }
        
        if UIDevice.current.isIPad {
            shareVC.excludedActivityTypes = []
            shareVC.popoverPresentationController?.permittedArrowDirections = []
            shareVC.popoverPresentationController?.sourceView = self.view
            shareVC.popoverPresentationController?.sourceRect = self.view.bounds
        }
        
        navigationController?.present(shareVC, animated: true) { [dependencies] in
            /// Now that we are finished with it we want to remove the temporary file (just to be safe ensure that it starts with the
            /// `temporaryDirectory` so we don't accidentally delete a proper file if logic elsewhere changes)
            if temporaryFileUrl.path.starts(with: dependencies[singleton: .fileManager].temporaryDirectory) {
                try? dependencies[singleton: .fileManager].removeItem(atPath: temporaryFileUrl.path)
            }
        }
    }
    
    public func preview(temporaryFileUrl: URL) {
        let interactionController: UIDocumentInteractionController = UIDocumentInteractionController(url: temporaryFileUrl)
        interactionController.delegate = self
        interactionController.presentPreview(animated: true)
    }
}

// MARK: - DocumentTitleViewControllerDelegate

extension AllMediaViewController: MediaTileViewControllerDelegate {
    public func presentdetailViewController(_ detailViewController: UIViewController, animated: Bool) {
        self.present(detailViewController, animated: animated)
    }
    
    public func updateSelectButton(
        threadVariant: SessionThread.Variant,
        updatedData: [MediaGalleryViewModel.SectionModel],
        inBatchSelectMode: Bool,
        using dependencies: Dependencies
    ) {
        guard
            !updatedData.isEmpty,
            threadVariant != .legacyGroup
        else {
            self.navigationItem.rightBarButtonItem = nil
            return
        }
        
        if inBatchSelectMode {
            self.navigationItem.rightBarButtonItem = UIBarButtonItem(
                barButtonSystemItem: .cancel,
                target: self,
                action: #selector(didCancelSelect)
            )
        }
        else {
            self.navigationItem.hidesBackButton = false
            
            self.navigationItem.rightBarButtonItem = UIBarButtonItem(
                title: "select".localized(),
                style: .plain,
                target: self,
                action: #selector(didTapSelect)
            )
        }
    }
}

// MARK: - UIViewControllerTransitioningDelegate

extension AllMediaViewController: UIViewControllerTransitioningDelegate {
    public func animationController(forPresented presented: UIViewController, presenting: UIViewController, source: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        return self.mediaTitleViewController.animationController(forPresented: presented, presenting: presenting, source: source)
    }

    public func animationController(forDismissed dismissed: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        return self.mediaTitleViewController.animationController(forDismissed: dismissed)
    }
}


// MARK: - MediaPresentationContextProvider

extension AllMediaViewController: MediaPresentationContextProvider {
    func mediaPresentationContext(mediaId: String, in coordinateSpace: UICoordinateSpace) -> MediaPresentationContext? {
        return self.mediaTitleViewController.mediaPresentationContext(mediaId: mediaId, in: coordinateSpace)
    }

    func snapshotOverlayView(in coordinateSpace: UICoordinateSpace) -> (UIView, CGRect)? {
        return self.mediaTitleViewController.snapshotOverlayView(in: coordinateSpace)
    }
}

