// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import GRDB
import YYImage
import SessionUIKit
import SessionMessagingKit

public final class ProfilePictureView: UIView {
    public enum Size {
        case navigation
        case message
        case list
        case hero
        
        public var viewSize: CGFloat {
            switch self {
                case .navigation, .message: return 26
                case .list: return 46
                case .hero: return 110
            }
        }
        
        var imageSize: CGFloat {
            switch self {
                case .navigation, .message: return 26
                case .list: return 46
                case .hero: return 80
            }
        }
        
        var multiImageSize: CGFloat {
            switch self {
                case .navigation, .message: return 18  // Shouldn't be used
                case .list: return 32
                case .hero: return 80
            }
        }
        
        var iconSize: CGFloat {
            switch self {
                case .navigation, .message: return 8
                case .list: return 16
                case .hero: return 24
            }
        }
        
        var iconVerticalInset: CGFloat {
            switch self {
                case .navigation, .message: return 1
                case .list: return 3
                case .hero: return 5
            }
        }
    }
    
    public enum ProfileIcon {
        case none
        case crown
        case rightPlus
    }
    
    public var size: Size {
        didSet {
            widthConstraint.constant = (customWidth ?? size.viewSize)
            heightConstraint.constant = size.viewSize
            profileIconTopConstraint.constant = size.iconVerticalInset
            profileIconBottomConstraint.constant = -size.iconVerticalInset
            profileIconBackgroundWidthConstraint.constant = size.iconSize
            profileIconBackgroundHeightConstraint.constant = size.iconSize
            additionalProfileIconTopConstraint.constant = size.iconVerticalInset
            additionalProfileIconBottomConstraint.constant = -size.iconVerticalInset
            additionalProfileIconBackgroundWidthConstraint.constant = size.iconSize
            additionalProfileIconBackgroundHeightConstraint.constant = size.iconSize
            
            profileIconBackgroundView.layer.cornerRadius = (size.iconSize / 2)
            additionalProfileIconBackgroundView.layer.cornerRadius = (size.iconSize / 2)
        }
    }
    public var customWidth: CGFloat? {
        didSet {
            self.widthConstraint.constant = (customWidth ?? self.size.viewSize)
        }
    }
    private var hasTappableProfilePicture: Bool = false
    
    // MARK: - Constraints
    
    private var widthConstraint: NSLayoutConstraint!
    private var heightConstraint: NSLayoutConstraint!
    private var imageViewTopConstraint: NSLayoutConstraint!
    private var imageViewLeadingConstraint: NSLayoutConstraint!
    private var imageViewCenterXConstraint: NSLayoutConstraint!
    private var imageViewCenterYConstraint: NSLayoutConstraint!
    private var imageViewWidthConstraint: NSLayoutConstraint!
    private var imageViewHeightConstraint: NSLayoutConstraint!
    private var additionalImageViewWidthConstraint: NSLayoutConstraint!
    private var additionalImageViewHeightConstraint: NSLayoutConstraint!
    private var profileIconTopConstraint: NSLayoutConstraint!
    private var profileIconBottomConstraint: NSLayoutConstraint!
    private var profileIconBackgroundLeftAlignConstraint: NSLayoutConstraint!
    private var profileIconBackgroundRightAlignConstraint: NSLayoutConstraint!
    private var profileIconBackgroundWidthConstraint: NSLayoutConstraint!
    private var profileIconBackgroundHeightConstraint: NSLayoutConstraint!
    private var additionalProfileIconTopConstraint: NSLayoutConstraint!
    private var additionalProfileIconBottomConstraint: NSLayoutConstraint!
    private var additionalProfileIconBackgroundLeftAlignConstraint: NSLayoutConstraint!
    private var additionalProfileIconBackgroundRightAlignConstraint: NSLayoutConstraint!
    private var additionalProfileIconBackgroundWidthConstraint: NSLayoutConstraint!
    private var additionalProfileIconBackgroundHeightConstraint: NSLayoutConstraint!
    
    // MARK: - Components
    
    private lazy var imageContainerView: UIView = {
        let result: UIView = UIView()
        result.translatesAutoresizingMaskIntoConstraints = false
        result.clipsToBounds = true
        result.themeBackgroundColor = .backgroundSecondary
        
        return result
    }()
    
    private lazy var imageView: UIImageView = {
        let result: UIImageView = UIImageView()
        result.translatesAutoresizingMaskIntoConstraints = false
        result.contentMode = .scaleAspectFill
        result.isHidden = true
        
        return result
    }()
    
    private lazy var animatedImageView: YYAnimatedImageView = {
        let result: YYAnimatedImageView = YYAnimatedImageView()
        result.translatesAutoresizingMaskIntoConstraints = false
        result.contentMode = .scaleAspectFill
        result.isHidden = true
        
        return result
    }()
    
    private lazy var additionalImageContainerView: UIView = {
        let result: UIView = UIView()
        result.translatesAutoresizingMaskIntoConstraints = false
        result.clipsToBounds = true
        result.themeBackgroundColor = .primary
        result.themeBorderColor = .backgroundPrimary
        result.isHidden = true
        
        return result
    }()
    
    private lazy var additionalProfilePlaceholderImageView: UIImageView = {
        let result: UIImageView = UIImageView(
            image: UIImage(systemName: "person.fill")?.withRenderingMode(.alwaysTemplate)
        )
        result.translatesAutoresizingMaskIntoConstraints = false
        result.contentMode = .scaleAspectFill
        result.themeTintColor = .textPrimary
        result.isHidden = true
        
        return result
    }()
    
    private lazy var additionalImageView: UIImageView = {
        let result: UIImageView = UIImageView()
        result.translatesAutoresizingMaskIntoConstraints = false
        result.contentMode = .scaleAspectFill
        result.themeTintColor = .textPrimary
        result.isHidden = true
        
        return result
    }()
    
    private lazy var additionalAnimatedImageView: YYAnimatedImageView = {
        let result: YYAnimatedImageView = YYAnimatedImageView()
        result.translatesAutoresizingMaskIntoConstraints = false
        result.contentMode = .scaleAspectFill
        result.isHidden = true
        
        return result
    }()
    
    private lazy var profileIconBackgroundView: UIView = {
        let result: UIView = UIView()
        result.isHidden = true
        
        return result
    }()
    
    private lazy var profileIconImageView: UIImageView = {
        let result: UIImageView = UIImageView()
        result.contentMode = .scaleAspectFit
        
        return result
    }()
    
    private lazy var additionalProfileIconBackgroundView: UIView = {
        let result: UIView = UIView()
        result.isHidden = true
        
        return result
    }()
    
    private lazy var additionalProfileIconImageView: UIImageView = {
        let result: UIImageView = UIImageView()
        result.contentMode = .scaleAspectFit
        
        return result
    }()
    
    // MARK: - Lifecycle
    
    public init(size: Size) {
        self.size = size
        
        super.init(frame: CGRect(x: 0, y: 0, width: size.viewSize, height: size.viewSize))
        
        setUpViewHierarchy()
    }
    
    public required init?(coder: NSCoder) {
        preconditionFailure("Use init(size:) instead.")
    }
    
    private func setUpViewHierarchy() {
        addSubview(imageContainerView)
        addSubview(profileIconBackgroundView)
        addSubview(additionalImageContainerView)
        addSubview(additionalProfileIconBackgroundView)
        
        profileIconBackgroundView.addSubview(profileIconImageView)
        additionalProfileIconBackgroundView.addSubview(additionalProfileIconImageView)
        
        widthConstraint = self.set(.width, to: self.size.viewSize)
        heightConstraint = self.set(.height, to: self.size.viewSize)
        
        imageViewTopConstraint = imageContainerView.pin(.top, to: .top, of: self)
        imageViewLeadingConstraint = imageContainerView.pin(.leading, to: .leading, of: self)
        imageViewCenterXConstraint = imageContainerView.center(.horizontal, in: self)
        imageViewCenterXConstraint.isActive = false
        imageViewCenterYConstraint = imageContainerView.center(.vertical, in: self)
        imageViewCenterYConstraint.isActive = false
        imageViewWidthConstraint = imageContainerView.set(.width, to: size.imageSize)
        imageViewHeightConstraint = imageContainerView.set(.height, to: size.imageSize)
        additionalImageContainerView.pin(.trailing, to: .trailing, of: self)
        additionalImageContainerView.pin(.bottom, to: .bottom, of: self)
        additionalImageViewWidthConstraint = additionalImageContainerView.set(.width, to: size.multiImageSize)
        additionalImageViewHeightConstraint = additionalImageContainerView.set(.height, to: size.multiImageSize)
        
        imageContainerView.addSubview(imageView)
        imageContainerView.addSubview(animatedImageView)
        additionalImageContainerView.addSubview(additionalImageView)
        additionalImageContainerView.addSubview(additionalAnimatedImageView)
        additionalImageContainerView.addSubview(additionalProfilePlaceholderImageView)
        
        imageView.pin(to: imageContainerView)
        animatedImageView.pin(to: imageContainerView)
        additionalImageView.pin(to: additionalImageContainerView)
        additionalAnimatedImageView.pin(to: additionalImageContainerView)
        
        additionalProfilePlaceholderImageView.pin(.top, to: .top, of: additionalImageContainerView, withInset: 3)
        additionalProfilePlaceholderImageView.pin(.left, to: .left, of: additionalImageContainerView)
        additionalProfilePlaceholderImageView.pin(.right, to: .right, of: additionalImageContainerView)
        additionalProfilePlaceholderImageView.pin(.bottom, to: .bottom, of: additionalImageContainerView, withInset: 5)
        
        profileIconTopConstraint = profileIconImageView.pin(
            .top,
            to: .top,
            of: profileIconBackgroundView,
            withInset: size.iconVerticalInset
        )
        profileIconImageView.pin(.left, to: .left, of: profileIconBackgroundView)
        profileIconImageView.pin(.right, to: .right, of: profileIconBackgroundView)
        profileIconBottomConstraint = profileIconImageView.pin(
            .bottom,
            to: .bottom,
            of: profileIconBackgroundView,
            withInset: -size.iconVerticalInset
        )
        profileIconBackgroundLeftAlignConstraint = profileIconBackgroundView.pin(.leading, to: .leading, of: imageContainerView)
        profileIconBackgroundRightAlignConstraint = profileIconBackgroundView.pin(.trailing, to: .trailing, of: imageContainerView)
        profileIconBackgroundView.pin(.bottom, to: .bottom, of: imageContainerView)
        profileIconBackgroundWidthConstraint = profileIconBackgroundView.set(.width, to: size.iconSize)
        profileIconBackgroundHeightConstraint = profileIconBackgroundView.set(.height, to: size.iconSize)
        profileIconBackgroundLeftAlignConstraint.isActive = false
        profileIconBackgroundRightAlignConstraint.isActive = false
        
        additionalProfileIconTopConstraint = additionalProfileIconImageView.pin(
            .top,
            to: .top,
            of: additionalProfileIconBackgroundView,
            withInset: size.iconVerticalInset
        )
        additionalProfileIconImageView.pin(.left, to: .left, of: additionalProfileIconBackgroundView)
        additionalProfileIconImageView.pin(.right, to: .right, of: additionalProfileIconBackgroundView)
        additionalProfileIconBottomConstraint = additionalProfileIconImageView.pin(
            .bottom,
            to: .bottom,
            of: additionalProfileIconBackgroundView,
            withInset: -size.iconVerticalInset
        )
        additionalProfileIconBackgroundLeftAlignConstraint = additionalProfileIconBackgroundView.pin(.leading, to: .leading, of: additionalImageContainerView)
        additionalProfileIconBackgroundRightAlignConstraint = additionalProfileIconBackgroundView.pin(.trailing, to: .trailing, of: additionalImageContainerView)
        additionalProfileIconBackgroundView.pin(.bottom, to: .bottom, of: additionalImageContainerView)
        additionalProfileIconBackgroundWidthConstraint = additionalProfileIconBackgroundView.set(.width, to: size.iconSize)
        additionalProfileIconBackgroundHeightConstraint = additionalProfileIconBackgroundView.set(.height, to: size.iconSize)
        additionalProfileIconBackgroundLeftAlignConstraint.isActive = false
        additionalProfileIconBackgroundRightAlignConstraint.isActive = false
    }
    
    // MARK: - Content
    
    private func updateIconView(
        icon: ProfileIcon,
        imageView: UIImageView,
        backgroundView: UIView,
        leftAlignConstraint: NSLayoutConstraint,
        rightAlignConstraint: NSLayoutConstraint
    ) {
        backgroundView.isHidden = (icon == .none)
        leftAlignConstraint.isActive = (
            icon == .none ||
            icon == .crown
        )
        rightAlignConstraint.isActive = (
            icon == .rightPlus
        )
        
        switch icon {
            case .none: imageView.image = nil
            
            case .crown:
                imageView.image = UIImage(systemName: "crown.fill")
                backgroundView.themeBackgroundColor = .profileIcon_background
                
                ThemeManager.onThemeChange(observer: imageView) { [weak imageView] _, primaryColor in
                    let targetColor: ThemeValue = (primaryColor == .green ?
                        .profileIcon_greenPrimaryColor :
                        .profileIcon
                    )
                    
                    guard imageView?.themeTintColor != targetColor else { return }
                    
                    imageView?.themeTintColor = targetColor
                }
                
            case .rightPlus:
                imageView.image = UIImage(systemName: "plus")
                imageView.themeTintColor = .black
                backgroundView.themeBackgroundColor = .primary
        }
    }

    public func update(
        publicKey: String = "",
        profile: Profile? = nil,
        icon: ProfileIcon = .none,
        additionalProfile: Profile? = nil,
        additionalIcon: ProfileIcon = .none,
        threadVariant: SessionThread.Variant,
        openGroupProfilePictureData: Data? = nil,
        useFallbackPicture: Bool = false,
        showMultiAvatarForClosedGroup: Bool = false
    ) {
        AssertIsOnMainThread()
        
        // Sort out the profile icon first
        updateIconView(
            icon: icon,
            imageView: profileIconImageView,
            backgroundView: profileIconBackgroundView,
            leftAlignConstraint: profileIconBackgroundLeftAlignConstraint,
            rightAlignConstraint: profileIconBackgroundRightAlignConstraint
        )
        
        guard !useFallbackPicture else {
            switch self.size {
                case .navigation, .message: imageView.image = #imageLiteral(resourceName: "SessionWhite16")
                case .list: imageView.image = #imageLiteral(resourceName: "SessionWhite24")
                case .hero: imageView.image = #imageLiteral(resourceName: "SessionWhite40")
            }
            
            imageView.contentMode = .center
            imageView.isHidden = false
            animatedImageView.isHidden = true
            imageContainerView.themeBackgroundColorForced = .theme(.classicDark, color: .borderSeparator)
            imageContainerView.layer.cornerRadius = (self.size.imageSize / 2)
            imageViewWidthConstraint.constant = self.size.imageSize
            imageViewHeightConstraint.constant = self.size.imageSize
            profileIconBackgroundWidthConstraint.constant = self.size.iconSize
            profileIconBackgroundHeightConstraint.constant = self.size.iconSize
            profileIconBackgroundView.layer.cornerRadius = (self.size.iconSize / 2)
            additionalProfileIconBackgroundWidthConstraint.constant = self.size.iconSize
            additionalProfileIconBackgroundHeightConstraint.constant = self.size.iconSize
            additionalProfileIconBackgroundView.layer.cornerRadius = (self.size.iconSize / 2)
            additionalImageContainerView.isHidden = true
            animatedImageView.image = nil
            additionalImageView.image = nil
            additionalAnimatedImageView.image = nil
            additionalImageView.isHidden = true
            additionalAnimatedImageView.isHidden = true
            additionalProfilePlaceholderImageView.isHidden = true
            return
        }
        guard !publicKey.isEmpty || openGroupProfilePictureData != nil else { return }
        
        func getProfilePicture(of size: CGFloat, for publicKey: String, profile: Profile?) -> (image: UIImage?, animatedImage: YYImage?, isTappable: Bool) {
            if let profile: Profile = profile, let profileData: Data = ProfileManager.profileAvatar(profile: profile) {
                let format: ImageFormat = profileData.guessedImageFormat
                
                let image: UIImage? = (format == .gif || format == .webp ?
                    nil :
                    UIImage(data: profileData)
                )
                let animatedImage: YYImage? = (format != .gif && format != .webp ?
                    nil :
                    YYImage(data: profileData)
                )
                
                if image != nil || animatedImage != nil {
                    return (image, animatedImage, true)
                }
            }
            
            return (
                Identicon.generatePlaceholderIcon(
                    seed: publicKey,
                    text: (profile?.displayName(for: threadVariant))
                        .defaulting(to: publicKey),
                    size: size
                ),
                nil,
                false
            )
        }
        
        // Calulate the sizes (and set the additional image content)
        let targetSize: CGFloat
        
        switch (threadVariant, showMultiAvatarForClosedGroup) {
            case (.closedGroup, true):
                targetSize = self.size.multiImageSize
                additionalImageContainerView.isHidden = false
                imageViewTopConstraint.isActive = true
                imageViewLeadingConstraint.isActive = true
                imageViewCenterXConstraint.isActive = false
                imageViewCenterYConstraint.isActive = false
                
                // Sort out the additinoal profile icon if needed
                updateIconView(
                    icon: additionalIcon,
                    imageView: additionalProfileIconImageView,
                    backgroundView: additionalProfileIconBackgroundView,
                    leftAlignConstraint: additionalProfileIconBackgroundLeftAlignConstraint,
                    rightAlignConstraint: additionalProfileIconBackgroundRightAlignConstraint
                )
                
                if let additionalProfile: Profile = additionalProfile {
                    let (image, animatedImage, _): (UIImage?, YYImage?, Bool) = getProfilePicture(
                        of: self.size.multiImageSize,
                        for: additionalProfile.id,
                        profile: additionalProfile
                    )

                    // Set the images and show the appropriate imageView (non-animated should be
                    // visible if there is no image)
                    additionalImageView.image = image
                    additionalAnimatedImageView.image = animatedImage
                    additionalImageView.isHidden = (animatedImage != nil)
                    additionalAnimatedImageView.isHidden = (animatedImage == nil)
                    additionalProfilePlaceholderImageView.isHidden = true
                }
                else {
                    additionalImageView.isHidden = true
                    additionalAnimatedImageView.isHidden = true
                    additionalProfilePlaceholderImageView.isHidden = false
                }
                
            default:
                targetSize = self.size.imageSize
                
                additionalImageContainerView.isHidden = true
                additionalProfileIconBackgroundView.isHidden = true
                additionalImageView.image = nil
                additionalImageView.isHidden = true
                additionalAnimatedImageView.image = nil
                additionalAnimatedImageView.isHidden = true
                additionalProfilePlaceholderImageView.isHidden = true
                imageViewTopConstraint.isActive = false
                imageViewLeadingConstraint.isActive = false
                imageViewCenterXConstraint.isActive = true
                imageViewCenterYConstraint.isActive = true
        }
        
        // Set the image
        if let openGroupProfilePictureData: Data = openGroupProfilePictureData {
            let format: ImageFormat = openGroupProfilePictureData.guessedImageFormat
            
            let image: UIImage? = (format == .gif || format == .webp ?
                nil :
                UIImage(data: openGroupProfilePictureData)
            )
            let animatedImage: YYImage? = (format != .gif && format != .webp ?
                nil :
                YYImage(data: openGroupProfilePictureData)
            )
            
            imageView.image = image
            animatedImageView.image = animatedImage
            imageView.isHidden = (animatedImage != nil)
            animatedImageView.isHidden = (animatedImage == nil)
            hasTappableProfilePicture = true
        }
        else {
            let (image, animatedImage, isTappable): (UIImage?, YYImage?, Bool) = getProfilePicture(
                of: targetSize,
                for: publicKey,
                profile: profile
            )
            imageView.image = image
            animatedImageView.image = animatedImage
            imageView.isHidden = (animatedImage != nil)
            animatedImageView.isHidden = (animatedImage == nil)
            hasTappableProfilePicture = isTappable
        }
        
        imageView.contentMode = .scaleAspectFill
        animatedImageView.contentMode = .scaleAspectFill
        imageContainerView.themeBackgroundColor = .backgroundSecondary
        imageViewWidthConstraint.constant = targetSize
        imageViewHeightConstraint.constant = targetSize
        imageContainerView.layer.cornerRadius = (targetSize / 2)
        additionalImageViewWidthConstraint.constant = targetSize
        additionalImageViewHeightConstraint.constant = targetSize
        additionalImageContainerView.layer.cornerRadius = (targetSize / 2)
        profileIconBackgroundView.layer.cornerRadius = (size.iconSize / 2)
        additionalProfileIconBackgroundView.layer.cornerRadius = (size.iconSize / 2)
    }
    
    // MARK: - Convenience
    
    @objc public func getProfilePicture() -> UIImage? {
        return (hasTappableProfilePicture ? imageView.image : nil)
    }
}
