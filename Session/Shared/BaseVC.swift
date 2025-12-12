// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import SessionUIKit
import Combine
import SessionUtilitiesKit

public class BaseVC: UIViewController {
    private var disposables: Set<AnyCancellable> = Set()
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
    
    internal func setUpNavBarSessionHeading(currentUserSessionProState: SessionProManagerType) {
        let headingImageView = UIImageView(
            image: UIImage(named: "SessionHeading")?
                .withRenderingMode(.alwaysTemplate)
        )
        headingImageView.themeTintColor = .textPrimary
        headingImageView.contentMode = .scaleAspectFit
        headingImageView.set(.width, to: 140)
        headingImageView.set(.height, to: Values.mediumFontSize)
        
        let sessionProBadge: SessionProBadge = SessionProBadge(size: .medium)
        let isPro: Bool = {
            if case .active = currentUserSessionProState.sessionProStateSubject.value {
                return true
            } else {
                return false
            }
        }()
        sessionProBadge.isHidden = !isPro
        
        let stackView: UIStackView = UIStackView(
            arrangedSubviews: MainAppContext.determineDeviceRTL() ? [ sessionProBadge, headingImageView ] : [ headingImageView, sessionProBadge ]
        )
        stackView.axis = .horizontal
        stackView.alignment = .center
        stackView.spacing = 0
        
        currentUserSessionProState.sessionProStatePublisher
            .subscribe(on: DispatchQueue.main)
            .receive(on: DispatchQueue.main)
            .sink(
                receiveValue: { [weak sessionProBadge] sessionProPlanState in
                    let isPro: Bool = {
                        if case .active = sessionProPlanState {
                            return true
                        } else {
                            return false
                        }
                    }()
                    sessionProBadge?.isHidden = !isPro
                }
            )
            .store(in: &disposables)
        
        navigationItem.titleView = stackView
    }
}
