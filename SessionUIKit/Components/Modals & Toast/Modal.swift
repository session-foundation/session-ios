// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit

open class Modal: UIViewController, UIGestureRecognizerDelegate, ModalHostIdentifiable {
    private static let cornerRadius: CGFloat = 11
    
    public enum DismissType: Equatable, Hashable {
        case single
        case recursive
    }
    
    private let dismissType: DismissType
    private let afterClosed: (() -> ())?
    
    // MARK: - Components
    
    private lazy var dimmingView: UIView = {
        let result = UIVisualEffectView()
        
        ThemeManager.onThemeChange(observer: result) { [weak result] theme, _, _ in
            result?.effect = UIBlurEffect(
                style: (theme.interfaceStyle == .light ?
                    UIBlurEffect.Style.systemUltraThinMaterialLight :
                    UIBlurEffect.Style.systemUltraThinMaterial
                )
            )
        }
        
        return result
    }()
    
    lazy var containerView: UIView = {
        let result: UIView = UIView()
        result.clipsToBounds = false
        result.themeBackgroundColor = .alert_background
        result.themeShadowColor = .black
        result.layer.cornerRadius = Modal.cornerRadius
        result.layer.shadowRadius = 10
        result.layer.shadowOpacity = 0.4
        
        return result
    }()
    
    public lazy var contentView: UIView = {
        let result: UIView = UIView()
        result.clipsToBounds = true
        result.layer.cornerRadius = Modal.cornerRadius
        
        return result
    }()
    
    public lazy var cancelButton: UIButton = {
        let result: UIButton = Modal.createButton(
            title: "cancel".localized(),
            titleColor: .textPrimary
        )
        result.addTarget(self, action: #selector(cancel), for: .touchUpInside)
                
        return result
    }()
    
    // MARK: - Lifecycle
    
    public init(
        targetView: UIView? = nil,
        dismissType: DismissType = .recursive,
        afterClosed: (() -> ())? = nil
    ) {
        self.dismissType = dismissType
        self.afterClosed = afterClosed
        
        super.init(nibName: nil, bundle: nil)
        
        // Ensure the modal doesn't crash on iPad when being presented
        Modal.setupForIPadIfNeeded(self, targetView: (targetView ?? self.view))
    }
    
    required public init?(coder: NSCoder) {
        fatalError("Use init(targetView:afterClosed:) instead")
    }
    
    public override func viewDidLoad() {
        super.viewDidLoad()
        
        navigationItem.backButtonTitle = ""
        view.themeBackgroundColor = .clear

        setNeedsStatusBarAppearanceUpdate()
        
        view.addSubview(dimmingView)
        view.addSubview(containerView)
        
        containerView.addSubview(contentView)
        
        dimmingView.pin(to: view)
        contentView.pin(to: containerView)
        
        if UIDevice.current.isIPad {
            containerView.set(.width, to: Values.iPadModalWidth)
        }
        else {
            containerView.leadingAnchor
                .constraint(equalTo: view.leadingAnchor, constant: Values.veryLargeSpacing)
                .isActive = true
            view.trailingAnchor
                .constraint(equalTo: containerView.trailingAnchor, constant: Values.veryLargeSpacing)
                .isActive = true
        }
        
        containerView.center(.horizontal, in: view)
        containerView.center(.vertical, in: view).setting(priority: .defaultHigh)
        containerView.pin(.top, greaterThanOrEqualTo: .top, of: view, withInset: 20)
        containerView.pin(.bottom, lessThanOrEqualTo: .top, of: view.keyboardLayoutGuide, withInset: -20)
        
        // Gestures
        let swipeGestureRecognizer = UISwipeGestureRecognizer(target: self, action: #selector(close))
        swipeGestureRecognizer.direction = .down
        dimmingView.addGestureRecognizer(swipeGestureRecognizer)
        
        let tapGestureRecognizer = UITapGestureRecognizer(target: self, action: #selector(close))
        tapGestureRecognizer.delegate = self
        dimmingView.addGestureRecognizer(tapGestureRecognizer)
        
        populateContentView()
    }
    
    open override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        
        /// Apply the nav styling in `viewWillAppear` instead of `viewDidLoad` as it's possible the nav stack isn't fully setup
        /// and could crash when trying to access it (whereas by the time `viewWillAppear` is called it should be setup)
        ThemeManager.applyNavigationStylingIfNeeded(to: self)
    }
    
    open override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        
        afterClosed?()
    }
    
    /// To be overridden by subclasses.
    open func populateContentView() {
        preconditionFailure("populateContentView() is abstract and must be overridden.")
    }
    
    public static func createButton(title: String, titleColor: ThemeValue) -> UIButton {
        let result: UIButton = UIButton()
        result.titleLabel?.font = .boldSystemFont(ofSize: Values.mediumFontSize)
        result.titleLabel?.numberOfLines = 0
        result.titleLabel?.textAlignment = .center
        result.setTitle(title, for: .normal)
        result.setThemeTitleColor(titleColor, for: .normal)
        result.setThemeBackgroundColor(.alert_buttonBackground, for: .normal)
        result.setThemeBackgroundColor(.highlighted(.alert_buttonBackground), for: .highlighted)
        result.set(.height, to: Values.alertButtonHeight)
        result.contentEdgeInsets = UIEdgeInsets(
            top: 0,
            left: Values.mediumSpacing,
            bottom: 0,
            right: Values.mediumSpacing
        )
                
        return result
    }
    
    // MARK: - Interaction
    
    @objc open func cancel() {
        close()
    }
    
    @objc public final func close() {
        // Recursively dismiss all modals (ie. find the first modal presented by a non-modal
        // and get that to dismiss it's presented view controller)
        var targetViewController: UIViewController? = self
        
        switch dismissType {
            case .single: break
            
            case .recursive:
                while targetViewController?.presentingViewController is ModalHostIdentifiable {
                    targetViewController = targetViewController?.presentingViewController
                }
        }
        
        targetViewController?.presentingViewController?.dismiss(animated: true)
    }
    
    // MARK: - UIGestureRecognizerDelegate
    
    public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        let location: CGPoint = touch.location(in: contentView)
        
        return !contentView.point(inside: location, with: nil)
    }
}

// MARK: - Convenience

public extension Modal {
    static func setupForIPadIfNeeded(_ viewController: UIViewController, targetView: UIView) {
        if UIDevice.current.isIPad {
            viewController.popoverPresentationController?.permittedArrowDirections = []
            viewController.popoverPresentationController?.sourceView = targetView
            viewController.popoverPresentationController?.sourceRect = targetView.bounds
        }
    }
}
