// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import Lucide

public final class ProCTAModal: Modal {
    public enum TouchPoint {
        case generic
        case longerMessages
        case animatedProfileImage(isActivated: Bool)
        case morePinnedConvos(isGrandfathered: Bool)
        case groupLimit(isAdmin: Bool)
        
        // stringlint:ignore_contents
        public var backgroundImageName: String {
            switch self {
                case .generic:
                    return "GenericCTA.webp"
                case .longerMessages:
                    return "HigherCharLimitCTA.webp"
                case .animatedProfileImage:
                    return "AnimatedProfileCTA.webp"
                case .morePinnedConvos:
                    return "PinnedConversationsCTA.webp"
                case .groupLimit(let isAdmin):
                    return isAdmin ? "" : ""
            }
        }
        // stringlint:ignore_contents
        public var animatedAvatarImageName: String? {
            switch self {
                case .generic: return "GenericCTAAnimation"
                case .animatedProfileImage: return "AnimatedProfileCTAAnimation"
                default: return nil
            }
        }
        
        // TODO: Localization
        public var subtitle: String {
            switch self {
                case .generic:
                    return "Want to use Session to its fullest potential? Upgrade to Session Pro to gain access to loads exclusive perks and features."
                case .longerMessages:
                    return "proCallToActionLongerMessages".localized()
                case .animatedProfileImage(let isActivated):
                    return isActivated ?
                        "proAnimatedDisplayPicture".localized() :
                        "proAnimatedDisplayPictureCallToActionDescription".localized()
                case .morePinnedConvos(let isGrandfathered):
                    return isGrandfathered ?
                        "proCallToActionPinnedConversations".localized() :
                        "proCallToActionPinnedConversationsMoreThan".localized()
                case .groupLimit(let isAdmin):
                    return "Want to increase the number of members you can invite to your group? Upgrade to Session Pro to invite up to 300 contacts."
            }
        }
        
        public var benefits: [String] {
            switch self {
                case .generic:
                    return  [
                        "proFeatureListLargerGroups".localized(),
                        "proFeatureListLongerMessages".localized(),
                        "proFeatureListLoadsMore".localized()
                    ]
                case .longerMessages:
                    return [
                        "proFeatureListLongerMessages".localized(),
                        "proFeatureListLargerGroups".localized(),
                        "proFeatureListLoadsMore".localized()
                    ]
                case .animatedProfileImage:
                    return [
                        "proFeatureListAnimatedDisplayPicture".localized(),
                        "proFeatureListLargerGroups".localized(),
                        "proFeatureListLoadsMore".localized()
                    ]
                case .morePinnedConvos:
                    return [
                        "proFeatureListPinnedConversations".localized(),
                        "proFeatureListLargerGroups".localized(),
                        "proFeatureListLoadsMore".localized()
                    ]
                case .groupLimit(let isAdmin):
                    return !isAdmin ? [] :
                        [
                            "proFeatureListLargerGroups".localized(),
                            "proFeatureListLongerMessages".localized(),
                            "proFeatureListLoadsMore".localized()
                        ]
            }
        }
    }
    
    private var delegate: SessionProCTADelegate?
    private let touchPoint: TouchPoint
    private var dataManager: ImageDataManagerType
    
    // MARK: - Initialization
    
    public init(
        delegate: SessionProCTADelegate? = nil,
        touchPoint: TouchPoint = .generic,
        dataManager: ImageDataManagerType,
        targetView: UIView? = nil,
        dismissType: DismissType = .recursive,
        afterClosed: (() -> ())? = nil
    ) {
        self.touchPoint = touchPoint
        self.delegate = delegate
        self.dataManager = dataManager
        
        super.init(targetView: targetView, dismissType: dismissType, afterClosed: afterClosed)
        
        self.modalPresentationStyle = .overFullScreen
        self.modalTransitionStyle = .crossDissolve
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    // MARK: - Components
    
    private lazy var backgroundImageView: UIImageView = {
        let result: UIImageView = UIImageView(image: UIImage(named: self.touchPoint.backgroundImageName))
        result.contentMode = .scaleAspectFill
        result.set(.height, to: .width, of: result, multiplier: (1258.0/1522))
        
        return result
    }()
    
    private lazy var animatedAvatarImageView: SessionImageView = {
        let result: SessionImageView = SessionImageView(
            dataManager: self.dataManager
        )
        result.contentMode = .scaleAspectFill
        
        return result
    }()
    
    private lazy var fadeView: GradientView = {
        let height: CGFloat = 90
        let result: GradientView = GradientView()
        result.themeBackgroundGradient = [
            .clear,
            .alert_background
        ]
        result.set(.height, to: height)

        return result
    }()
    
    private lazy var backgroundImageContainer: UIView = {
        let result: UIView = UIView()
        result.themeBackgroundColor = .primary
        
        return result
    }()
    
    private lazy var titleLabel: UILabel = {
        let result: UILabel = UILabel()
        result.font = .boldSystemFont(ofSize: Values.largeFontSize)
        result.themeTextColor = .textPrimary
        result.text = "upgradeTo".localized()
        
        return result
    }()
    
    private lazy var titleStackView: UIStackView = {
        let sessionProBadge: SessionProBadge = SessionProBadge(size: .large)
        let result: UIStackView = UIStackView(arrangedSubviews: [ titleLabel, sessionProBadge ])
        result.axis = .horizontal
        result.spacing = Values.smallSpacing
        
        return result
    }()
    
    private lazy var titleContainer: UIView = {
        let result: UIView = UIView()
        result.addSubview(titleStackView)
        titleStackView.center(in: result)
        result.pin(.top, to: .top, of: titleStackView)
        result.pin(.bottom, to: .bottom, of: titleStackView)
        return result
    }()
    
    private lazy var proActivatedStackView: UIStackView = {
        let sessionProBadge: SessionProBadge = SessionProBadge(size: .small)
        let label: UILabel = UILabel()
        label.font = .systemFont(ofSize: Values.smallFontSize)
        label.themeTextColor = .textSecondary
        label.textAlignment = .center
        label.text = "proAlreadyPurchased".localized()
        
        let result: UIStackView = UIStackView(arrangedSubviews: [ label, sessionProBadge ])
        result.axis = .horizontal
        result.spacing = Values.smallSpacing
        result.isHidden = true
        
        return result
    }()
    
    private lazy var subtitleLabel: UILabel = {
        let result: UILabel = UILabel()
        result.font = .systemFont(ofSize: Values.smallFontSize)
        result.themeTextColor = .textSecondary
        result.text = self.touchPoint.subtitle
        result.textAlignment = .center
        result.lineBreakMode = .byWordWrapping
        result.numberOfLines = 0
        
        return result
    }()
    
    private lazy var subtitleStackView: UIStackView = {
        let result: UIStackView = UIStackView(arrangedSubviews: [ proActivatedStackView, subtitleLabel ])
        result.axis = .vertical
        result.spacing = 0
        
        return result
    }()
    
    private lazy var benefitsStackView: UIStackView = {
        let result: UIStackView = UIStackView(
            arrangedSubviews: self.touchPoint.benefits.enumerated().map { index, string in
                let label: UILabel = UILabel()
                label.font = .systemFont(ofSize: Values.smallFontSize)
                label.themeTextColor = .textPrimary
                label.text = string
                
                let icon: UIImageView = {
                    guard index < (self.touchPoint.benefits.count - 1) else {
                        return CyclicGradientImageView(
                            image: Lucide.image(icon: .sparkles, size: 17)?
                                .withRenderingMode(.alwaysTemplate)
                        )
                    }
                    
                    let result: UIImageView = UIImageView(
                        image: Lucide.image(icon: .circleCheck, size: 17)?
                            .withRenderingMode(.alwaysTemplate)
                    )
                    result.themeTintColor = .primary
                    return result
                }()
                
                let stackView: UIStackView = UIStackView(arrangedSubviews: [ icon, label ])
                stackView.axis = .horizontal
                stackView.spacing = Values.smallSpacing
                
                return stackView
            }
        )
        result.axis = .vertical
        result.spacing = Values.mediumSmallSpacing
        result.alignment = .leading
        
        return result
    }()
    
    private lazy var contentStackView: UIStackView = {
        let result: UIStackView = UIStackView(arrangedSubviews: [ titleContainer, subtitleStackView, benefitsStackView ])
        result.axis = .vertical
        result.spacing = Values.largeSpacing
        result.alignment = .fill
        
        return result
    }()
    
    private lazy var upgradeButton: ShineButton = {
        let result: ShineButton = ShineButton()
        result.titleLabel?.font = .systemFont(ofSize: Values.mediumFontSize)
        result.setTitle("theContinue".localized(), for: .normal)
        result.setThemeTitleColor(.sessionButton_primaryFilledText, for: .normal)
        result.setThemeBackgroundColor(.sessionButton_primaryFilledBackground, for: .normal)
        result.set(.height, to: Values.largeButtonHeight)
        result.addTarget(self, action: #selector(upgrade), for: .touchUpInside)
        result.layer.cornerRadius = 6
        result.clipsToBounds = true
                
        return result
    }()
    
    private lazy var proCancelButton: UIButton = {
        let result: UIButton = UIButton()
        result.titleLabel?.font = .systemFont(ofSize: Values.mediumFontSize)
        result.setTitle("cancel".localized(), for: .normal)
        result.setThemeTitleColor(.textPrimary, for: .normal)
        result.setThemeBackgroundColor(.inputButton_background, for: .normal)
        result.set(.height, to: Values.largeButtonHeight)
        result.addTarget(self, action: #selector(cancel), for: .touchUpInside)
        result.layer.cornerRadius = 6
        result.clipsToBounds = true
                
        return result
    }()
    
    private lazy var buttonStackView: UIStackView = {
        let result: UIStackView = UIStackView(arrangedSubviews: [ upgradeButton, proCancelButton ])
        result.axis = .horizontal
        result.spacing = Values.smallSpacing
        result.distribution = .fillEqually
        
        return result
    }()
    
    private lazy var mainStackView: UIStackView = {
        let result = UIStackView(arrangedSubviews: [ contentStackView, buttonStackView ])
        result.axis = .vertical
        result.spacing = Values.largeSpacing
        
        return result
    }()
    
    // MARK: - Lifecycle
    
    public override func populateContentView() {
        if let animatedAvatarImageName: String = self.touchPoint.animatedAvatarImageName,
           let imageURL = Bundle.main.url(forResource: animatedAvatarImageName, withExtension: "webp")
        {
            backgroundImageContainer.addSubview(animatedAvatarImageView)
            animatedAvatarImageView.pin(to: backgroundImageContainer)
            animatedAvatarImageView.loadImage(from: imageURL)
        }
        
        backgroundImageContainer.addSubview(backgroundImageView)
        backgroundImageContainer.pin(to: backgroundImageView)
        
        backgroundImageContainer.addSubview(fadeView)
        fadeView.pin(.leading, to: .leading, of: backgroundImageContainer)
        fadeView.pin(.trailing, to: .trailing, of: backgroundImageContainer)
        fadeView.pin(.bottom, to: .bottom, of: backgroundImageContainer)
        
        contentView.addSubview(backgroundImageContainer)
        backgroundImageContainer.pin(.top, to: .top, of: contentView)
        backgroundImageContainer.pin(.leading, to: .leading, of: contentView)
        backgroundImageContainer.pin(.trailing, to: .trailing, of: contentView)
        
        contentView.addSubview(mainStackView)
        mainStackView.pin(.bottom, to: .bottom, of: contentView, withInset: -Values.mediumSpacing)
        mainStackView.pin(.leading, to: .leading, of: contentView, withInset: Values.mediumSpacing)
        mainStackView.pin(.trailing, to: .trailing, of: contentView, withInset: -Values.mediumSpacing)
        mainStackView.pin(.top, to: .bottom, of: backgroundImageView, withInset: Values.mediumSpacing)
    }
    
    // MARK: - Interaction
    
    @objc private func upgrade() {
        delegate?.upgradeToPro { [weak self] in
            self?.close()
        }
    }
}

public protocol SessionProCTADelegate: AnyObject {
    func upgradeToPro(completion: (() -> Void)?)
}
