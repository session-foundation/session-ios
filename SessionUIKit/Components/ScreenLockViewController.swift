// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import UIKit

open class ScreenLockViewController: UIViewController {
    public enum State {
        case none
        
        /// Shown while app is inactive or background, if enabled.
        case protection
        
        /// Shown while app is active, if enabled.
        case lock
    }
    
    public override var preferredStatusBarStyle: UIStatusBarStyle {
        return ThemeManager.currentTheme.statusBarStyle
    }
    
    public override var canBecomeFirstResponder: Bool { true }
    
    public var onUnlockPressed: (@MainActor () -> ())?
    
    // MARK: - UI
    
    private let logoView: UIImageView = {
        let result: UIImageView = UIImageView(image: #imageLiteral(resourceName: "SessionGreen64"))
        result.contentMode = .scaleAspectFit
        
        return result
    }()
    
    public lazy var unlockButton: SessionButton = {
        let result: SessionButton = SessionButton(style: .bordered, size: .medium)
        result.translatesAutoresizingMaskIntoConstraints = false
        result.setTitle("lockAppUnlock".localized(), for: .normal)
        result.addTarget(self, action: #selector(showUnlockUI), for: .touchUpInside)
        result.isHidden = true
        
        // Need to match the launch screen so force the styling to be the primary green
        result.setThemeTitleColor(.explicitPrimary(.green), for: .normal)
        result.setThemeBackgroundColor(.explicitPrimary(.green), for: .highlighted)
        result.themeBorderColor = .explicitPrimary(.green)

        return result
    }()
    
    // MARK: - Lifecycle
                                  
    public init(onUnlockPressed: (@MainActor () -> ())? = nil) {
        self.onUnlockPressed = onUnlockPressed
        
        super.init(nibName: nil, bundle: nil)
    }
                                  
    required public init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
                                  
    open override func loadView() {
        super.loadView()
        
        view.themeBackgroundColorForced = .theme(.classicDark, color: .black)  // Need to match the Launch screen

        view.addSubview(logoView)
        logoView.center(in: view)
        logoView.set(.width, to: 64)
        logoView.set(.height, to: 64)

        view.addSubview(unlockButton)
        unlockButton.pin(.top, to: .bottom, of: logoView, withInset: Values.mediumSpacing)
        unlockButton.center(.horizontal, in: view)
    }
    
    /// The "screen blocking" window has three possible states:
    ///
    /// * "Just a logo".  Used when app is launching and in app switcher.  Must match the "Launch Screen" storyboard pixel-for-pixel.
    /// * "Screen Lock, local auth UI presented". Must match the "Launch Screen" storyboard pixel-for-pixel.
    /// * "Screen Lock, local auth UI not presented". Show "unlock" button.
    public func updateUI(state: State, animated: Bool) {
        guard isViewLoaded else { return }

        let shouldHaveScreenLock: Bool = (state == .lock)

        guard animated else {
            unlockButton.isHidden = !shouldHaveScreenLock
            view.setNeedsLayout()
            return
        }
        
        UIView.animate(withDuration: 0.3) { [weak self] in
            self?.unlockButton.isHidden = !shouldHaveScreenLock
            self?.view.layoutIfNeeded()
        }
    }
    
    @MainActor @objc private func showUnlockUI() {
        self.onUnlockPressed?()
    }
}
