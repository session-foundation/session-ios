// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import Lucide
import SignalUtilitiesKit
import SessionUIKit
import SessionUtilitiesKit

final class SAEScreenLockViewController: ScreenLockViewController {
    private var hasShownAuthUIOnce: Bool = false
    private var isShowingAuthUI: Bool = false
    
    private let hasUserMetadata: Bool
    private let onUnlock: () -> Void
    private let onCancel: () -> Void
    
    // MARK: - Initialization
    
    init(hasUserMetadata: Bool, onUnlock: @escaping () -> Void, onCancel: @escaping () -> Void) {
        self.hasUserMetadata = hasUserMetadata
        self.onUnlock = onUnlock
        self.onCancel = onCancel
        
        super.init()
        
        self.onUnlockPressed = { [weak self] in self?.unlockButtonWasTapped() }
    }
    
    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    // MARK: - UI
    
    private lazy var titleLabel: UILabel = {
        let titleLabel: UILabel = UILabel()
        titleLabel.font = UIFont.boldSystemFont(ofSize: Values.veryLargeFontSize)
        titleLabel.text = "shareToSession"
            .put(key: "app_name", value: Constants.app_name)
            .localized()
        titleLabel.themeTextColor = .textPrimary
        
        return titleLabel
    }()
    
    private lazy var closeButton: UIBarButtonItem = {
        let closeButton: UIBarButtonItem = UIBarButtonItem(
            image: Lucide.image(icon: .x, size: IconSize.medium.size)?
                .withRenderingMode(.alwaysTemplate),
            style: .plain,
            target: self,
            action: #selector(dismissPressed)
        )
        closeButton.themeTintColor = .textPrimary
        
        return closeButton
    }()
    
    // MARK: - Lifecycle
    
    public override func loadView() {
        super.loadView()
        
        UIView.appearance().themeTintColor = .textPrimary
        
        self.view.themeBackgroundColor = .backgroundPrimary
        self.navigationItem.titleView = titleLabel
        self.navigationItem.leftBarButtonItem = closeButton
        
        unlockButton.setThemeTitleColor(
            .dynamicForInterfaceStyle(light: .textPrimary, dark: .explicitPrimary(.green)),
            for: .normal
        )
        unlockButton.setThemeBackgroundColor(
            .dynamicForInterfaceStyle(
                light: .textPrimary,
                dark: .value(.explicitPrimary(.green), alpha: 0.3)
            ),
            for: .highlighted
        )
        unlockButton.themeBorderColor = .dynamicForInterfaceStyle(
            light: .textPrimary,
            dark: .explicitPrimary(.green)
        )
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        
        self.ensureUI()
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        
        self.ensureUI()
        
        // Auto-show the auth UI f
        if !hasShownAuthUIOnce {
            hasShownAuthUIOnce = true
            
            self.tryToPresentAuthUIToUnlockScreenLock()
        }
    }
    
    // MARK: - Functions
    
    private func tryToPresentAuthUIToUnlockScreenLock() {
        Log.assertOnMainThread()

        // If we're already showing the auth UI; abort.
        if self.isShowingAuthUI { return }
        
        Log.info("try to unlock screen lock")

        isShowingAuthUI = true
        
        ScreenLock.tryToUnlockScreenLock(
            localizedReason: "authenticateToOpen"
                .put(key: "app_name", value:  Constants.app_name)
                .localized(),
            errorMap: ScreenLockErrors.errorMap,
            defaultErrorDescription: ScreenLockErrors.defaultError,
            success: { [weak self] in
                Log.assertOnMainThread()
                Log.info("unlock screen lock succeeded.")
                
                self?.isShowingAuthUI = false
                self?.onUnlock()
            },
            failure: { [weak self] error in
                Log.assertOnMainThread()
                Log.info("unlock screen lock failed.")
                
                self?.isShowingAuthUI = false
                self?.ensureUI()
                self?.showScreenLockFailureAlert(message: "\(error)")
            },
            unexpectedFailure: { [weak self] error in
                Log.assertOnMainThread()
                Log.info("unlock screen lock unexpectedly failed.")
                
                self?.isShowingAuthUI = false
                
                // Local Authentication isn't working properly.
                // This isn't covered by the docs or the forums but in practice
                // it appears to be effective to retry again after waiting a bit.
                DispatchQueue.main.async {
                    self?.ensureUI()
                }
            },
            cancel: { [weak self] in
                Log.assertOnMainThread()
                Log.info("unlock screen lock cancelled.")
                
                self?.isShowingAuthUI = false
                self?.ensureUI()
            }
        )
        
        self.ensureUI()
    }
    
    private func ensureUI() {
        self.updateUI(state: .lock, animated: false)
    }
    
    private func showScreenLockFailureAlert(message: String) {
        Log.assertOnMainThread()
        
        let modal: ConfirmationModal = ConfirmationModal(
            targetView: self.view,
            info: ConfirmationModal.Info(
                title: "authenticateFailed".localized(),
                body: .text(message),
                cancelTitle: "okay".localized(),
                cancelStyle: .alert_text,
                afterClosed: { [weak self] in self?.ensureUI() } // After the alert, update the UI
            )
        )
        self.present(modal, animated: true)
    }
    
    func unlockButtonWasTapped() {
        Log.assertOnMainThread()
        Log.info("unlockButtonWasTapped")
        
        self.tryToPresentAuthUIToUnlockScreenLock()
    }
    
    // MARK: - Transitions
    
    @objc private func dismissPressed() {
        Log.debug("unlock screen lock cancelled.")
        
        self.cancelShareExperience()
    }

    private func cancelShareExperience() {
        self.onCancel()
    }
}
