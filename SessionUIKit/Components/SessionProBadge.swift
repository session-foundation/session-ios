// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import UIKit

public class SessionProBadge: UIView {
    public static let accessibilityLabel: String = Constants.app_pro

    public static let identifier: String = "ProBadge"   // stringlint:ignore

    /// Accessibility identifiers for the pro badge and the label it sits beside
    ///
    /// **Note:** These exact strings are a cross-platform contract with Android (its
    /// `content-descriptions` module defines the same values as `qa_pro_badge_component` / `_text` / `_icon`)
    /// so a single Appium locator serves both platforms - renaming one means renaming it in three repos
    // stringlint:ignore_contents
    public enum AccessibilityIdentifier {
        /// The container holding the label and the badge together (Android: `ProBadgeText`'s row)
        public static let component: String = "pro-badge-component"

        /// The label beside the badge (ie. the display name), **not** the badge itself
        public static let text: String = "pro-badge-text"

        /// The badge itself
        public static let icon: String = "pro-badge-icon"

        /// The badge in the conversation header specifically
        ///
        /// **Note:** Deliberately on the *badge* rather than the header name - the name renders for every
        /// conversation while the badge renders only for a Pro sender, so an assertion scoped to the name
        /// can never fail. Android made the same distinction after it caught a false positive
        public static let conversationHeader: String = "conversation-header-pro-badge"

        /// The badge in the home screen's nav heading specifically
        ///
        /// **Note:** Scoped rather than relying on the generic `icon`, because the same widget class appears in the
        /// composer in the opposite role - this one is an entitlement indicator reading ACCESS, that one an upsell
        /// reading DISPLAY (see `BaseVC.setUpNavBarSessionHeading`). An unscoped locator could match either, so a test
        /// aimed at one could pass against the other without anyone noticing
        public static let homeHeader: String = "home-header-pro-badge"

        /// The badge in the message composer specifically
        ///
        /// **Note:** The counterpart to `homeHeader`, and the reason both are scoped. This one is an upsell and
        /// follows the plan (DISPLAY); that one is an entitlement indicator and follows the proof (ACCESS). They are
        /// visible in opposite circumstances, so an unscoped locator finding "a badge" proves nothing about which
        public static let composer: String = "composer-pro-badge"
    }

    public enum Size {
        case mini, small, medium, large
        
        // stringlint:ignore_contents
        public var cacheKey: String {
            switch self {
                case .mini: return "SessionProBadge.Mini"
                case .small: return "SessionProBadge.Small"
                case .medium: return "SessionProBadge.Medium"
                case .large: return "SessionProBadge.Large"
            }
        }
        
        public var width: CGFloat {
            switch self {
                case .mini: return 24
                case .small: return 32
                case .medium: return 40
                case .large: return 52
            }
        }
        public var height: CGFloat {
            switch self {
                case .mini: return 11
                case .small: return 14.5
                case .medium: return 18
                case .large: return 26
            }
        }
        public var cornerRadius: CGFloat {
            switch self {
                case .mini: return 2.5
                case .small: return 3.5
                case .medium: return 4
                case .large: return 6
            }
        }
        public var proFontHeight: CGFloat {
            switch self {
                case .mini: return 5
                case .small: return 6
                case .medium: return 7
                case .large: return 11
            }
        }
        public var proFontWidth: CGFloat {
            switch self {
                case .mini: return 17
                case .small: return 24
                case .medium: return 28
                case .large: return 40
            }
        }
    }
    
    public var size: Size {
        didSet {
            widthConstraint.constant = size.width
            heightConstraint.constant = size.height
            proImageWidthConstraint.constant = size.proFontWidth
            proImageHeightConstraint.constant = size.proFontHeight
            self.layer.cornerRadius = size.cornerRadius
        }
    }
    
    // MARK: -  Initialization
    
    public init(size: Size, themeBackgroundColor: ThemeValue = .primary) {
        self.size = size
        super.init(frame: CGRect(x: 0, y: 0, width: size.width, height: size.height))

        /// The badge is a plain `UIView` wrapping an image so it wouldn't otherwise appear in the accessibility
        /// tree at all - make it an element in its own right (it has no accessible children to hide)
        self.isAccessibilityElement = true
        self.accessibilityLabel = SessionProBadge.accessibilityLabel
        self.accessibilityIdentifier = SessionProBadge.AccessibilityIdentifier.icon

        setUpViewHierarchy()
        self.themeBackgroundColor = themeBackgroundColor
    }
    
    public override init(frame: CGRect) {
        preconditionFailure("Use init(size:) instead.")
    }
    
    public required init?(coder: NSCoder) {
        preconditionFailure("Use init(size:) instead.")
    }
    
    // MARK: - UI
    
    private lazy var proImageView: UIImageView = {
        let result: UIImageView = UIImageView(image: UIImage(named: "session_pro"))
        result.contentMode = .scaleAspectFit
        
        return result
    }()
    
    private var widthConstraint: NSLayoutConstraint!
    private var heightConstraint: NSLayoutConstraint!
    private var proImageWidthConstraint: NSLayoutConstraint!
    private var proImageHeightConstraint: NSLayoutConstraint!
    
    private func setUpViewHierarchy() {
        self.addSubview(proImageView)
        proImageHeightConstraint = proImageView.set(.height, to: self.size.proFontHeight)
        proImageWidthConstraint = proImageView.set(.width, to: self.size.proFontWidth)
        proImageView.center(in: self)
        
        self.clipsToBounds = true
        self.layer.cornerRadius = self.size.cornerRadius
        widthConstraint = self.set(.width, to: self.size.width)
        heightConstraint = self.set(.height, to: self.size.height)
        
        self.proImageView.frame = CGRect(
            x: (size.width - size.proFontWidth) / 2,
            y: (size.height - size.proFontHeight) / 2,
            width: size.proFontWidth,
            height: size.proFontHeight
        )
    }
}
