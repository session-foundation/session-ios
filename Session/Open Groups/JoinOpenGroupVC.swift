// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import Combine
import AVFoundation
import GRDB
import SessionUIKit
import SessionMessagingKit
import SessionUtilitiesKit
import SignalUtilitiesKit

final class JoinOpenGroupVC: BaseVC, UIPageViewControllerDataSource, UIPageViewControllerDelegate, QRScannerDelegate, NavigatableStateHolder {
    private let dependencies: Dependencies
    public let navigatableState: NavigatableState = NavigatableState()
    private var disposables: Set<AnyCancellable> = Set()
    
    private let pageVC = UIPageViewController(transitionStyle: .scroll, navigationOrientation: .horizontal, options: nil)
    private var pages: [UIViewController] = []
    private var isJoining = false
    private var targetVCIndex: Int?

    // MARK: - Components
    
    private lazy var tabBar: TabBar = {
        let tabs: [TabBar.Tab] = [
            TabBar.Tab(title: "communityUrl".localized()) { [weak self] in
                guard let self = self else { return }
                self.pageVC.setViewControllers([ self.pages[0] ], direction: .forward, animated: false, completion: nil)
            },
            TabBar.Tab(title: "qrScan".localized()) { [weak self] in
                guard let self = self else { return }
                self.pageVC.setViewControllers([ self.pages[1] ], direction: .forward, animated: false, completion: nil)
            }
        ]
        
        return TabBar(tabs: tabs)
    }()

    private lazy var enterURLVC: EnterURLVC = {
        let result: EnterURLVC = EnterURLVC(using: dependencies)
        result.joinOpenGroupVC = self
        
        return result
    }()

    private lazy var scanQRCodePlaceholderVC: ScanQRCodePlaceholderVC = {
        let result: ScanQRCodePlaceholderVC = ScanQRCodePlaceholderVC(using: dependencies)
        result.joinOpenGroupVC = self
        
        return result
    }()

    private lazy var scanQRCodeWrapperVC: ScanQRCodeWrapperVC = {
        let result: ScanQRCodeWrapperVC = ScanQRCodeWrapperVC()
        result.delegate = self
        
        return result
    }()
    
    // MARK: - Initialization
    
    init(using dependencies: Dependencies) {
        self.dependencies = dependencies
        
        super.init(nibName: nil, bundle: nil)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    // MARK: - Lifecycle
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        setNavBarTitle("communityJoin".localized())
        view.themeBackgroundColor = .newConversation_background
        let navBarHeight: CGFloat = (navigationController?.navigationBar.frame.size.height ?? 0)
        
        let closeButton = UIBarButtonItem(image: #imageLiteral(resourceName: "X"), style: .plain, target: self, action: #selector(close))
        closeButton.themeTintColor = .textPrimary
        navigationItem.rightBarButtonItem = closeButton
        
        // Page VC
        let hasCameraAccess = (AVCaptureDevice.authorizationStatus(for: .video) == .authorized)
        pages = [ enterURLVC, (hasCameraAccess ? scanQRCodeWrapperVC : scanQRCodePlaceholderVC) ]
        pageVC.dataSource = self
        pageVC.delegate = self
        pageVC.setViewControllers([ enterURLVC ], direction: .forward, animated: false, completion: nil)
        
        // Tab bar
        view.addSubview(tabBar)
        tabBar.pin(.leading, to: .leading, of: view)
        tabBar.pin(.top, to: .top, of: view, withInset: navBarHeight)
        tabBar.pin(.trailing, to: .trailing, of: view)
        
        // Page VC constraints
        let pageVCView = pageVC.view!
        view.addSubview(pageVCView)
        pageVCView.pin(.leading, to: .leading, of: view)
        pageVCView.pin(.top, to: .bottom, of: tabBar)
        pageVCView.pin(.trailing, to: .trailing, of: view)
        pageVCView.pin(.bottom, to: .bottom, of: view)
        
        let statusBarHeight: CGFloat = UIApplication.shared.statusBarFrame.size.height
        let height: CGFloat = ((navigationController?.view.bounds.height ?? 0) - navBarHeight - TabBar.snHeight - statusBarHeight)
        let size: CGSize = CGSize(width: UIScreen.main.bounds.width, height: height)
        enterURLVC.constrainSize(to: size)
        scanQRCodePlaceholderVC.constrainSize(to: size)
        
        navigatableState.setupBindings(viewController: self, disposables: &disposables)
    }
    
    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        let height: CGFloat = (size.height - TabBar.snHeight)
        let size: CGSize = CGSize(width: size.width, height: height)
        enterURLVC.constrainSize(to: size)
        scanQRCodePlaceholderVC.constrainSize(to: size)
        enterURLVC.suggestionGrid.refreshLayout(with: size.width - 2 * Values.largeSpacing)
    }

    // MARK: - General
    
    func pageViewController(_ pageViewController: UIPageViewController, viewControllerBefore viewController: UIViewController) -> UIViewController? {
        guard let index = pages.firstIndex(of: viewController), index != 0 else { return nil }
        
        return pages[index - 1]
    }

    func pageViewController(_ pageViewController: UIPageViewController, viewControllerAfter viewController: UIViewController) -> UIViewController? {
        guard let index = pages.firstIndex(of: viewController), index != (pages.count - 1) else { return nil }
        
        return pages[index + 1]
    }

    fileprivate func handleCameraAccessGranted() {
        DispatchQueue.main.async {
            self.pages[1] = self.scanQRCodeWrapperVC
            self.pageVC.setViewControllers([ self.scanQRCodeWrapperVC ], direction: .forward, animated: false, completion: nil)
        }
    }

    // MARK: - Updating
    
    func pageViewController(_ pageViewController: UIPageViewController, willTransitionTo pendingViewControllers: [UIViewController]) {
        guard let targetVC = pendingViewControllers.first, let index = pages.firstIndex(of: targetVC) else { return }
        
        targetVCIndex = index
    }

    func pageViewController(_ pageViewController: UIPageViewController, didFinishAnimating isFinished: Bool, previousViewControllers: [UIViewController], transitionCompleted isCompleted: Bool) {
        guard isCompleted, let index = targetVCIndex else { return }
        
        tabBar.selectTab(at: index)
    }

    // MARK: - Interaction
    
    @objc private func close() {
        dismiss(animated: true, completion: nil)
    }

    func controller(_ controller: QRCodeScanningViewController, didDetectQRCodeWith string: String, onSuccess: (() -> ())?, onError: (() -> ())?) {
        joinOpenGroup(with: string, onError: onError)
    }

    fileprivate func joinOpenGroup(with urlString: String, onError: (() -> ())?) {
        // A V2 open group URL will look like: <optional scheme> + <host> + <optional port> + <room> + <public key>
        // The host doesn't parse if no explicit scheme is provided
        guard let (room, server, publicKey) = LibSession.parseCommunity(url: urlString) else {
            showError(
                title: "communityEnterUrlErrorInvalid".localized(),
                message: "communityEnterUrlErrorInvalidDescription".localized(),
                onError: onError
            )
            return
        }
        
        joinOpenGroup(roomToken: room, server: server, publicKey: publicKey, shouldOpenCommunity: true, onError: onError)
    }

    fileprivate func joinOpenGroup(
        roomToken: String,
        server: String,
        publicKey: String,
        shouldOpenCommunity: Bool,
        onError: (() -> ())?
    ) {
        guard !isJoining, let navigationController: UINavigationController = navigationController else { return }
        
        guard dependencies[singleton: .openGroupManager].hasExistingOpenGroup(
            roomToken: roomToken,
            server: server,
            publicKey: publicKey
        ) != true else {
            self.showToast(
                text: "communityJoinedAlready".localized(),
                backgroundColor: .backgroundSecondary
            )
            return
        }
        
        isJoining = true
        
        ModalActivityIndicatorViewController.present(fromViewController: navigationController, canCancel: false) { [weak self, dependencies] _ in
            dependencies[singleton: .storage]
                .writePublisher { db in
                    dependencies[singleton: .openGroupManager].add(
                        db,
                        roomToken: roomToken,
                        server: server,
                        publicKey: publicKey,
                        forceVisible: false
                    )
                }
                .flatMap { successfullyAddedGroup in
                    dependencies[singleton: .openGroupManager].performInitialRequestsAfterAdd(
                        queue: DispatchQueue.global(qos: .userInitiated),
                        successfullyAddedGroup: successfullyAddedGroup,
                        roomToken: roomToken,
                        server: server,
                        publicKey: publicKey
                    )
                }
                .subscribe(on: DispatchQueue.global(qos: .userInitiated))
                .receive(on: DispatchQueue.main)
                .sinkUntilComplete(
                    receiveCompletion: { result in
                        switch result {
                            case .failure(let error):
                                // If there was a failure then the group will be in invalid state until
                                // the next launch so remove it (the user will be left on the previous
                                // screen so can re-trigger the join)
                                dependencies[singleton: .storage].writeAsync { db in
                                    try dependencies[singleton: .openGroupManager].delete(
                                        db,
                                        openGroupId: OpenGroup.idFor(roomToken: roomToken, server: server),
                                        skipLibSessionUpdate: false
                                    )
                                }
                                
                                // Show the user an error indicating they failed to properly join the group
                                self?.isJoining = false
                                self?.dismiss(animated: true) { // Dismiss the loader
                                    self?.showError(
                                        title: "communityJoinError".localized(),
                                        message: "\(error)",
                                        onError: onError
                                    )
                                }
                                
                            case .finished:
                                self?.presentingViewController?.dismiss(animated: true, completion: nil)
                                
                                if shouldOpenCommunity {
                                    dependencies[singleton: .app].presentConversationCreatingIfNeeded(
                                        for: OpenGroup.idFor(roomToken: roomToken, server: server),
                                        variant: .community,
                                        action: .none,
                                        dismissing: nil,
                                        animated: false
                                    )
                                }
                        }
                    }
                )
        }
    }

    // MARK: - Convenience

    private func showError(title: String, message: String = "", onError: (() -> ())?) {
        let confirmationModal: ConfirmationModal = ConfirmationModal(
            info: ConfirmationModal.Info(
                title: title,
                body: .text(message),
                cancelTitle: "okay".localized(),
                cancelStyle: .alert_text,
                afterClosed: onError
            )
        )
        self.navigationController?.present(confirmationModal, animated: true, completion: nil)
    }
}

// MARK: - EnterURLVC

private final class EnterURLVC: UIViewController, UIGestureRecognizerDelegate, OpenGroupSuggestionGridDelegate {
    weak var joinOpenGroupVC: JoinOpenGroupVC?
    
    private let dependencies: Dependencies
    private var isKeyboardShowing = false
    private var bottomConstraint: NSLayoutConstraint!
    private let bottomMargin: CGFloat = (UIDevice.current.isIPad ? Values.largeSpacing : 0)

    // MARK: - UI
    
    private var keyboardTransitionSnapshot1: UIView?
    private var keyboardTransitionSnapshot2: UIView?
    
    private lazy var urlTextView: SNTextView = {
        let result: SNTextView = SNTextView(placeholder: "communityEnterUrl".localized())
        result.keyboardType = .URL
        result.autocapitalizationType = .none
        result.autocorrectionType = .no
        
        return result
    }()
    
    private lazy var suggestionGridTitleLabel: UILabel = {
        let result: UILabel = UILabel()
        result.setContentHuggingPriority(.required, for: .vertical)
        result.font = .boldSystemFont(ofSize: Values.largeFontSize)
        result.text = "communityJoinOfficial".localized()
        result.themeTextColor = .textPrimary
        result.lineBreakMode = .byWordWrapping
        result.numberOfLines = 0
        
        return result
    }()

    lazy var suggestionGrid: OpenGroupSuggestionGrid = {
        let maxWidth: CGFloat = (UIScreen.main.bounds.width - Values.largeSpacing * 2)
        let result: OpenGroupSuggestionGrid = OpenGroupSuggestionGrid(maxWidth: maxWidth, using: dependencies)
        result.delegate = self
        
        return result
    }()
    
    private var viewWidth: NSLayoutConstraint?
    private var viewHeight: NSLayoutConstraint?
    
    // MARK: - Initialization
    
    init(using dependencies: Dependencies) {
        self.dependencies = dependencies
        
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
        // Remove background color
        view.themeBackgroundColor = .clear
        
        // Next button
        let joinButton = SessionButton(style: .bordered, size: .large)
        joinButton.setTitle("join".localized(), for: UIControl.State.normal)
        joinButton.addTarget(self, action: #selector(joinOpenGroup), for: UIControl.Event.touchUpInside)
        
        let joinButtonContainer = UIView(
            wrapping: joinButton,
            withInsets: UIEdgeInsets(top: 0, leading: 80, bottom: 0, trailing: 80),
            shouldAdaptForIPadWithWidth: Values.iPadButtonWidth
        )
        
        // Stack view
        let stackView = UIStackView(
            arrangedSubviews: [
                urlTextView,
                UIView.spacer(withHeight: Values.mediumSpacing),
                suggestionGridTitleLabel,
                UIView.spacer(withHeight: Values.mediumSpacing),
                suggestionGrid,
                UIView.vStretchingSpacer(),
                joinButtonContainer
            ]
        )
        stackView.axis = .vertical
        stackView.alignment = .fill
        stackView.layoutMargins = UIEdgeInsets(
            top: Values.largeSpacing,
            leading: Values.largeSpacing,
            bottom: Values.smallSpacing,
            trailing: Values.largeSpacing
        )
        stackView.isLayoutMarginsRelativeArrangement = true
        view.addSubview(stackView)
        
        stackView.pin(.leading, to: .leading, of: view)
        stackView.pin(.top, to: .top, of: view)
        view.pin(.trailing, to: .trailing, of: stackView)
        
        bottomConstraint = view.pin(.bottom, to: .bottom, of: stackView, withInset: bottomMargin)
        
        // Constraints
        viewWidth = view.set(.width, to: UIScreen.main.bounds.width)
        
        // Dismiss keyboard on tap
        let tapGestureRecognizer = UITapGestureRecognizer(target: self, action: #selector(dismissKeyboard))
        tapGestureRecognizer.delegate = self
        view.addGestureRecognizer(tapGestureRecognizer)
        
        // Listen to keyboard notifications
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleKeyboardWillChangeFrameNotification(_:)),
            name: UIResponder.keyboardWillChangeFrameNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleKeyboardWillHideNotification(_:)),
            name: UIResponder.keyboardWillHideNotification,
            object: nil
        )
    }
    
    // MARK: - General
    
    func constrainSize(to size: CGSize) {
        if viewWidth == nil {
            viewWidth = view.set(.width, to: size.width)
        } else {
            viewWidth?.constant = size.width
        }
        
        if viewHeight == nil {
            viewHeight = view.set(.height, to: size.height)
        } else {
            viewHeight?.constant = size.height
        }
    }

    @objc private func dismissKeyboard() {
        urlTextView.resignFirstResponder()
    }

    // MARK: - Interaction
    
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        let location = gestureRecognizer.location(in: view)
        
        return (
            (!suggestionGrid.isHidden && !suggestionGrid.frame.contains(location)) ||
            (suggestionGrid.isHidden && location.y > urlTextView.frame.maxY)
        )
    }
    
    func join(_ room: OpenGroupAPI.Room) {
        joinOpenGroupVC?.joinOpenGroup(
            roomToken: room.token,
            server: OpenGroupAPI.defaultServer,
            publicKey: OpenGroupAPI.defaultServerPublicKey,
            shouldOpenCommunity: true,
            onError: nil
        )
    }

    @objc private func joinOpenGroup() {
        let url = urlTextView.text?.trimmingCharacters(in: .whitespaces) ?? ""
        joinOpenGroupVC?.joinOpenGroup(with: url, onError: nil)
    }
    
    // MARK: - Updating
    
    @objc private func handleKeyboardWillChangeFrameNotification(_ notification: Notification) {
        guard !isKeyboardShowing else { return }
        isKeyboardShowing = true
        
        guard let endFrame: CGRect = (notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue else { return }
        guard endFrame.minY < UIScreen.main.bounds.height else { return }
        
        let duration = max(0.25, ((notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? TimeInterval) ?? 0))
        
        // Add snapshots for the suggestion grid
        UIView.performWithoutAnimation {
            self.keyboardTransitionSnapshot1 = self.suggestionGridTitleLabel.snapshotView(afterScreenUpdates: false)
            self.keyboardTransitionSnapshot1?.frame = self.suggestionGridTitleLabel.frame
            self.suggestionGridTitleLabel.alpha = 0
            
            if let snapshot1: UIView = self.keyboardTransitionSnapshot1 {
                self.suggestionGridTitleLabel.superview?.addSubview(snapshot1)
            }
            
            self.keyboardTransitionSnapshot2 = self.suggestionGrid.snapshotView(afterScreenUpdates: false)
            self.keyboardTransitionSnapshot2?.frame = self.suggestionGrid.frame
            self.suggestionGrid.alpha = 0
            
            if let snapshot2: UIView = self.keyboardTransitionSnapshot2 {
                self.suggestionGrid.superview?.addSubview(snapshot2)
            }
            self.view.setNeedsLayout()
            self.view.layoutIfNeeded()
        }
        
        UIView.animate(
            withDuration: duration,
            animations: { [weak self] in
                self?.keyboardTransitionSnapshot1?.alpha = 0
                self?.keyboardTransitionSnapshot2?.alpha = 0
                self?.suggestionGridTitleLabel.isHidden = true
                self?.suggestionGrid.isHidden = true
                self?.bottomConstraint.constant = (endFrame.size.height + (self?.bottomMargin ?? 0))
                self?.view.layoutIfNeeded()
            },
            completion: nil
        )
    }
    
    @objc private func handleKeyboardWillHideNotification(_ notification: Notification) {
        guard isKeyboardShowing else { return }
        
        let duration = max(0.25, ((notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? TimeInterval) ?? 0))
        isKeyboardShowing = false
        
        self.suggestionGrid.alpha = 0
        self.suggestionGridTitleLabel.alpha = 0
        
        UIView.animate(
            withDuration: duration,
            animations: { [weak self] in
                self?.keyboardTransitionSnapshot1?.alpha = 1
                self?.keyboardTransitionSnapshot2?.alpha = 1
                self?.suggestionGrid.isHidden = false
                self?.suggestionGridTitleLabel.isHidden = false
                self?.bottomConstraint.constant = (self?.bottomMargin ?? 0)
                self?.view.layoutIfNeeded()
            },
            completion: { [weak self] _ in
                self?.keyboardTransitionSnapshot1?.removeFromSuperview()
                self?.keyboardTransitionSnapshot2?.removeFromSuperview()
                self?.keyboardTransitionSnapshot1 = nil
                self?.keyboardTransitionSnapshot2 = nil
                self?.suggestionGridTitleLabel.alpha = 1
                self?.suggestionGrid.alpha = 1
            }
        )
    }
}

private final class ScanQRCodePlaceholderVC: UIViewController {
    private let dependencies: Dependencies
    weak var joinOpenGroupVC: JoinOpenGroupVC?
    
    private var viewWidth: NSLayoutConstraint?
    private var viewHeight: NSLayoutConstraint?
    
    // MARK: - Initialization

    init(using dependencies: Dependencies) {
        self.dependencies = dependencies

        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    // MARK: - Lifecycle

    override func viewDidLoad() {
        // Remove background color
        view.themeBackgroundColor = .clear
        
        // Explanation label
        let explanationLabel = UILabel()
        explanationLabel.font = .systemFont(ofSize: Values.smallFontSize)
        explanationLabel.text = "cameraGrantAccessQr"
            .put(key: "app_name", value: Constants.app_name)
            .localized()
        explanationLabel.themeTextColor = .textPrimary
        explanationLabel.textAlignment = .center
        explanationLabel.lineBreakMode = .byWordWrapping
        explanationLabel.numberOfLines = 0
        
        // Call to action button
        let callToActionButton = UIButton()
        callToActionButton.titleLabel?.font = .boldSystemFont(ofSize: Values.mediumFontSize)
        callToActionButton.setTitle("theContinue".localized(), for: .normal)
        callToActionButton.setThemeTitleColor(.primary, for: .normal)
        callToActionButton.addTarget(self, action: #selector(requestCameraAccess), for: .touchUpInside)
        
        // Stack view
        let stackView = UIStackView(arrangedSubviews: [ explanationLabel, callToActionButton ])
        stackView.axis = .vertical
        stackView.spacing = Values.mediumSpacing
        stackView.alignment = .center
        
        // Constraints
        view.addSubview(stackView)
        stackView.pin(.leading, to: .leading, of: view, withInset: Values.massiveSpacing)
        view.pin(.trailing, to: .trailing, of: stackView, withInset: Values.massiveSpacing)
        
        let verticalCenteringConstraint = stackView.center(.vertical, in: view)
        verticalCenteringConstraint.constant = -16 // Makes things appear centered visually
    }

    func constrainSize(to size: CGSize) {
        if viewWidth == nil {
            viewWidth = view.set(.width, to: size.width)
        } else {
            viewWidth?.constant = size.width
        }
        
        if viewHeight == nil {
            viewHeight = view.set(.height, to: size.height)
        } else {
            viewHeight?.constant = size.height
        }
    }

    @objc private func requestCameraAccess() {
        Permissions.requestCameraPermissionIfNeeded(using: dependencies) { [weak self] granted in
            guard granted else { return }
            self?.joinOpenGroupVC?.handleCameraAccessGranted()
        }
    }
}
