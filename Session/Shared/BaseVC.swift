// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import SessionUIKit
import Combine

public class BaseVC: UIViewController {
    private var proObservationTask: Task<Void, Never>?
    public var onViewWillAppear: ((UIViewController) -> Void)?
    public var onViewWillDisappear: ((UIViewController) -> Void)?
    public var onViewDidDisappear: ((UIViewController) -> Void)?
    
    public override var preferredStatusBarStyle: UIStatusBarStyle {
        return ThemeManager.currentTheme.statusBarStyle
    }

    lazy var navBarTitleLabel: UILabel = {
        let result = UILabel()
        result.font = .boldSystemFont(ofSize: Values.veryLargeFontSize)
        result.themeTextColor = .textPrimary
        result.textAlignment = .center
        result.alpha = 1
        
        return result
    }()

    lazy var crossfadeLabel: UILabel = {
        let result = UILabel()
        result.font = .boldSystemFont(ofSize: Values.veryLargeFontSize)
        result.themeTextColor = .textPrimary
        result.textAlignment = .center
        result.alpha = 0
        
        return result
    }()
    
    deinit {
        proObservationTask?.cancel()
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        
        navigationItem.backButtonTitle = ""
        view.themeBackgroundColor = .backgroundPrimary
        
        setNeedsStatusBarAppearanceUpdate()
    }
    
    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        
        /// Apply the nav styling in `viewWillAppear` instead of `viewDidLoad` as it's possible the nav stack isn't fully setup
        /// and could crash when trying to access it (whereas by the time `viewWillAppear` is called it should be setup)
        ThemeManager.applyNavigationStylingIfNeeded(to: self)
        onViewWillAppear?(self)
    }
    
    public override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        
        onViewWillDisappear?(self)
    }
    
    public override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        
        onViewDidDisappear?(self)
    }

    internal func setNavBarTitle(_ title: String, customFontSize: CGFloat? = nil) {
        let container = UIView()
        navBarTitleLabel.text = title
        crossfadeLabel.text = title
        
        if let customFontSize = customFontSize {
            navBarTitleLabel.font = .boldSystemFont(ofSize: customFontSize)
            crossfadeLabel.font = .boldSystemFont(ofSize: customFontSize)
        }
        
        container.addSubview(navBarTitleLabel)
        container.addSubview(crossfadeLabel)
        
        navBarTitleLabel.pin(to: container)
        crossfadeLabel.pin(to: container)
        
        navigationItem.titleView = container
    }
    
    internal func setUpNavBarSessionHeading(sessionProUIManager: SessionProUIManagerType) {
        let headingImageView = UIImageView(
            image: UIImage(named: "SessionHeading")?
                .withRenderingMode(.alwaysTemplate)
        )
        headingImageView.themeTintColor = .textPrimary
        headingImageView.contentMode = .scaleAspectFit
        headingImageView.set(.width, to: 140)
        headingImageView.set(.height, to: Values.mediumFontSize)
        
        let sessionProBadge: SessionProBadge = SessionProBadge(size: .medium)
        sessionProBadge.isHidden = !sessionProUIManager.currentUserIsCurrentlyPro
        
        let stackView: UIStackView = UIStackView(
            arrangedSubviews: MainAppContext.determineDeviceRTL() ? [ sessionProBadge, headingImageView ] : [ headingImageView, sessionProBadge ]
        )
        stackView.axis = .horizontal
        stackView.alignment = .center
        stackView.spacing = 0
        
        proObservationTask?.cancel()
        proObservationTask = Task.detached(priority: .userInitiated) { [weak sessionProBadge] in
            for await isPro in sessionProUIManager.currentUserIsPro {
                await MainActor.run { [weak sessionProBadge] in
                    sessionProBadge?.isHidden = !isPro
                }
            }
        }
        
        navigationItem.titleView = stackView
    }
}
