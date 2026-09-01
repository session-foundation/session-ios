// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import SessionUIKit
import Combine
import SessionUtilitiesKit

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
        /// **An entitlement indicator, so it reads ACCESS** - it says "you have this", and it has one while the proof
        /// is live even if the plan has lapsed.
        ///
        /// Deliberately the opposite source to the composer's badge (`InputView`), which is the same widget class and
        /// the same property in the opposite role - an upsell, reading DISPLAY. Do not reconcile the two: making this
        /// one read DISPLAY would take a subscriber's badge away during the overhang, which is the inverse of the bug
        /// that split them
        sessionProBadge.isHidden = !sessionProUIManager.currentUserHasProAccess
        /// Replaces the generic identifier the badge carries by default, so an assertion aimed at this one cannot
        /// match the composer's badge instead - they are the same widget in opposite roles
        sessionProBadge.accessibilityIdentifier = SessionProBadge.AccessibilityIdentifier.homeHeader
        
        let stackView: UIStackView = UIStackView(arrangedSubviews: [ headingImageView, sessionProBadge ])
        stackView.semanticContentAttribute = .forceLeftToRight
        stackView.axis = .horizontal
        stackView.alignment = .center
        stackView.spacing = 0
        
        proObservationTask?.cancel()
        proObservationTask = Task.detached(priority: .userInitiated) { [weak sessionProBadge] in
            for await isPro in sessionProUIManager.currentUserHasProAccessStream {
                await MainActor.run { [weak sessionProBadge] in
                    sessionProBadge?.isHidden = !isPro
                }
            }
        }
        
        navigationItem.titleView = stackView
    }
}
