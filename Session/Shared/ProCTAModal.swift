// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import Lucide
import SessionUIKit
import SessionUtilitiesKit

final class ProCTAModal: Modal {
    public enum TouchPoint {
        case generic
        case longerMessages
        case animatedProfileImage
        case largerFiles
        case morePinnedConvos
        case groupLimit
        case groupLimitNonAdmin
        
        public var backgroundImageName: String {
            switch self {
                case .generic:
                    return "session_pro_modal_background_generic"
                case .longerMessages:
                    return "session_pro_modal_background_longer_messages"
                case .animatedProfileImage:
                    return "session_pro_modal_background_animated_profile_image"
                case .largerFiles:
                    return "session_pro_modal_background_larger_files"
                case .morePinnedConvos:
                    return "session_pro_modal_background_more_pinned_convos"
                case .groupLimit:
                    return "session_pro_modal_background_group_limit"
                case .groupLimitNonAdmin:
                    return "session_pro_modal_background_group_limit_non_admin"
            }
        }
        // TODO: Localization
        public var subtitle: String {
            switch self {
                case .generic:
                    return "Want to use Session to its fullest potential? Upgrade to Session Pro to gain access to loads exclusive perks and features."
                case .longerMessages:
                    return "Want to send longer messages? Upgrade to Session Pro to send longer messages up to 10,000 characters."
                case .animatedProfileImage:
                    return "Want to use gifs? Upgrade to Session Pro to upload animated display pictures and gain access to loads of other exclusive features."
                case .largerFiles:
                    return "Want to send larger files? Upgrade to Session Pro to send files beyond the 10MB limit."
                case .morePinnedConvos:
                    return "Want to pin more conversations? Upgrade to Session Pro to pin more than 5 conversations."
                case .groupLimit:
                    return "Want to increase the number of members you can invite to your group? Upgrade to Session Pro to invite up to 300 contacts."
                case .groupLimitNonAdmin:
                    return "Want to increase the number of members? Let your admin know they can upgrade to Session Pro to invite up to 300 contacts."
            }
        }
        // TODO: Localization
        public var benefits: [String] {
            switch self {
                case .generic:
                    return  [
                        "Upload animated display pictures",
                        "Share files beyond the 10MB limit",
                        "Heaps more exclusive features"
                    ]
                case .longerMessages:
                    return [
                        "Send messages up to 10k characters",
                        "Increase group sizes to 300 members",
                        "Heaps more exclusive features"
                    ]
                case .animatedProfileImage:
                    return [
                        "Upload animated display pictures",
                        "Increase group sizes to 300 members",
                        "Heaps more exclusive features"
                    ]
                case .largerFiles:
                    return [
                        "Share files beyond the 10MB limit",
                        "Increase group sizes to 300 members",
                        "Heaps more exclusive features"
                    ]
                case .morePinnedConvos:
                    return [
                        "Pin unlimited conversations",
                        "Increase group sizes to 300 members",
                        "Heaps more exclusive features"
                    ]
                case .groupLimit:
                    return [
                        "Increase group sizes to 300 members",
                        "Send messages up to 10k characters",
                        "Heaps more exclusive features"
                    ]
                case .groupLimitNonAdmin:
                    return [
                        "Invite up to 300 group members",
                        "Send messages up to 10k characters",
                        "Heaps more exclusive features"
                    ]
            }
        }
    }
    
    private let dependencies: Dependencies
    private let touchPoint: TouchPoint
    
    // MARK: - Initialization
    
    init(touchPoint: TouchPoint = .generic, targetView: UIView? = nil, dismissType: DismissType = .recursive, using dependencies: Dependencies, afterClosed: (() -> ())? = nil) {
        self.touchPoint = touchPoint
        self.dependencies = dependencies
        
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
        result.clipsToBounds = true
        
        return result
    }()
    
    private lazy var titleLabel: UILabel = {
        let result: UILabel = UILabel()
        result.font = .boldSystemFont(ofSize: Values.largeFontSize)
        result.themeTextColor = .textPrimary
        result.text = "Upgrade to" // TODO: Localization
        
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
    
    private lazy var benefitsStackView: UIStackView = {
        let result: UIStackView = UIStackView(
            arrangedSubviews: self.touchPoint.benefits.map {
                let label: UILabel = UILabel()
                label.font = .systemFont(ofSize: Values.smallFontSize)
                label.themeTextColor = .textPrimary
                label.text = $0
                
                let icon: UIImageView = UIImageView(image: Lucide.image(icon: .circleCheck, size: 17)?.withRenderingMode(.alwaysTemplate))
                icon.themeTintColor = .primary
                
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
        let result: UIStackView = UIStackView(arrangedSubviews: [ titleContainer, subtitleLabel, benefitsStackView ])
        result.axis = .vertical
        result.spacing = Values.largeSpacing
        result.alignment = .fill
        
        return result
    }()
    
    private lazy var upgradeButton: UIButton = {
        let result: UIButton = UIButton()
        result.titleLabel?.font = .systemFont(ofSize: Values.mediumFontSize)
        result.setTitle("Upgrade", for: .normal) // TODO: Localization
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
    
    override func populateContentView() {
        contentView.addSubview(backgroundImageView)
        backgroundImageView.pin(.top, to: .top, of: contentView)
        backgroundImageView.pin(.leading, to: .leading, of: contentView)
        backgroundImageView.pin(.trailing, to: .trailing, of: contentView)
        
        contentView.addSubview(mainStackView)
        mainStackView.pin(.bottom, to: .bottom, of: contentView, withInset: -Values.mediumSpacing)
        mainStackView.pin(.leading, to: .leading, of: contentView, withInset: Values.mediumSpacing)
        mainStackView.pin(.trailing, to: .trailing, of: contentView, withInset: -Values.mediumSpacing)
        mainStackView.pin(.top, to: .bottom, of: backgroundImageView, withInset: Values.mediumSpacing)
    }
    
    // MARK: - Interaction
    
    @objc private func upgrade() {
        // TODO: To be implemented
        dependencies.mutate(cache: .libSession) { $0.isSessionPro = true }
        close()
    }
}
