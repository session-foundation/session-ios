// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import GRDB
import YYImage
import SessionUIKit
import SessionMessagingKit

public final class ProfilePictureView: UIView {
    public var size: CGFloat = 0
    
    // Constraints
    private var imageViewWidthConstraint: NSLayoutConstraint!
    private var imageViewHeightConstraint: NSLayoutConstraint!
    private var additionalImageViewWidthConstraint: NSLayoutConstraint!
    private var additionalImageViewHeightConstraint: NSLayoutConstraint!
    
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
        result.layer.borderWidth = 1
        result.layer.cornerRadius = (Values.smallProfilePictureSize / 2)
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
    
    // MARK: - Lifecycle
    
    public override init(frame: CGRect) {
        super.init(frame: frame)
        setUpViewHierarchy()
    }
    
    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUpViewHierarchy()
    }
    
    private func setUpViewHierarchy() {
        let imageViewSize = CGFloat(Values.mediumProfilePictureSize)
        let additionalImageViewSize = CGFloat(Values.smallProfilePictureSize)
        
        addSubview(imageContainerView)
        addSubview(additionalImageContainerView)
        
        imageContainerView.pin(.leading, to: .leading, of: self)
        imageContainerView.pin(.top, to: .top, of: self)
        imageViewWidthConstraint = imageContainerView.set(.width, to: imageViewSize)
        imageViewHeightConstraint = imageContainerView.set(.height, to: imageViewSize)
        additionalImageContainerView.pin(.trailing, to: .trailing, of: self)
        additionalImageContainerView.pin(.bottom, to: .bottom, of: self)
        additionalImageViewWidthConstraint = additionalImageContainerView.set(.width, to: additionalImageViewSize)
        additionalImageViewHeightConstraint = additionalImageContainerView.set(.height, to: additionalImageViewSize)
        
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
    }
// TODO: Update this to be more explicit? (or add a helper method? current code requires duplicate logic around deciding what properties should be set in what cases)
    private func prepareForReuse() {
        imageView.contentMode = .scaleAspectFill
        imageView.isHidden = true
        animatedImageView.contentMode = .scaleAspectFill
        animatedImageView.isHidden = true
        imageContainerView.themeBackgroundColor = .backgroundSecondary
        additionalImageContainerView.isHidden = true
        animatedImageView.image = nil
        additionalImageView.image = nil
        additionalAnimatedImageView.image = nil
        additionalImageView.isHidden = true
        additionalAnimatedImageView.isHidden = true
        additionalProfilePlaceholderImageView.isHidden = true
    }
    
    private func getProfilePicture(
        of size: CGFloat,
        for publicKey: String,
        profile: Profile?,
        threadVariant: SessionThread.Variant
    ) -> (image: UIImage?, animatedImage: YYImage?) {
        guard let profile: Profile = profile, let profileData: Data = ProfileManager.profileAvatar(profile: profile) else {
            return (
                Identicon.generatePlaceholderIcon(
                    seed: publicKey,
                    text: (profile?.displayName(for: threadVariant))
                        .defaulting(to: publicKey),
                    size: size
                ),
                nil
            )
        }
        
        switch profileData.guessedImageFormat {
            case .gif, .webp: return (nil, YYImage(data: profileData))
            default: return (UIImage(data: profileData), nil)
        }
    }
    
    public func update(
        publicKey: String,
        threadVariant: SessionThread.Variant,
        customImageData: Data?,
        profile: Profile?,
        additionalProfile: Profile?
    ) {
        prepareForReuse()
        
        // If we are given 'customImageData' then only use that
        if let customImageData: Data = customImageData {
            switch customImageData.guessedImageFormat {
                case .gif, .webp:
                    animatedImageView.image = YYImage(data: customImageData)
                    animatedImageView.isHidden = false
                    
                default:
                    imageView.image = UIImage(data: customImageData)
                    imageView.isHidden = false
            }
            
            imageViewWidthConstraint.constant = self.size
            imageViewHeightConstraint.constant = self.size
            imageContainerView.layer.cornerRadius = (self.size / 2)
            return
        }
        
        // Otherwise there are conversation-type-specific behaviours
        switch threadVariant {
            case .openGroup:
                switch self.size {
                    case Values.smallProfilePictureSize..<Values.mediumProfilePictureSize:
                        imageView.image = #imageLiteral(resourceName: "SessionWhite16")
                        
                    case Values.mediumProfilePictureSize..<Values.largeProfilePictureSize:
                        imageView.image = #imageLiteral(resourceName: "SessionWhite24")
                        
                    default: imageView.image = #imageLiteral(resourceName: "SessionWhite40")
                }
                
                imageView.contentMode = .center
                imageView.isHidden = false
                imageContainerView.themeBackgroundColorForced = .theme(.classicDark, color: .borderSeparator)
                imageViewWidthConstraint.constant = self.size
                imageViewHeightConstraint.constant = self.size
                imageContainerView.layer.cornerRadius = (self.size / 2)
                
            case .closedGroup:
                guard !publicKey.isEmpty else { return }
                
                // If the `publicKey` we were given matches the first profile id then we have
                // provided a "ClosedGroupProfile" (which is essentially a profile object populated
                // with `ClosedGroup` data) so we don't want to add the 'additionalProfile' content
                let isCustomGroupImage: Bool = (publicKey == profile?.id)
                
                let targetSize: CGFloat = {
                    guard !isCustomGroupImage else { return self.size }
                    
                    switch self.size {
                        case 40: return 32
                        case 80: return 64
                        case Values.largeProfilePictureSize: return 56
                        default: return Values.smallProfilePictureSize
                    }
                }()
                
                // Set the content for the first `profile` object
                let (image, animatedImage): (UIImage?, YYImage?) = getProfilePicture(
                    of: targetSize,
                    for: publicKey,
                    profile: profile,
                    threadVariant: threadVariant
                )
                imageView.image = image
                imageView.isHidden = (animatedImage != nil)
                animatedImageView.image = animatedImage
                animatedImageView.isHidden = (animatedImage == nil)
                imageViewWidthConstraint.constant = targetSize
                imageViewHeightConstraint.constant = targetSize
                imageContainerView.layer.cornerRadius = (targetSize / 2)
                
                // If the `publicKey` we were given matches the first profile id then we have
                // provided a "ClosedGroupProfile" (which is essentially a profile object populated
                // with `ClosedGroup` data) so we don't want to add the 'additionalProfile' content
                guard !isCustomGroupImage else { return }
                
                additionalImageViewWidthConstraint.constant = targetSize
                additionalImageViewHeightConstraint.constant = targetSize
                additionalImageContainerView.layer.cornerRadius = (targetSize / 2)
                additionalImageContainerView.isHidden = false
                
                if let additionalProfile: Profile = additionalProfile {
                    let (image, animatedImage): (UIImage?, YYImage?) = getProfilePicture(
                        of: targetSize,
                        for: additionalProfile.id,
                        profile: additionalProfile,
                        threadVariant: threadVariant
                    )
                    
                    // Set the images and show the appropriate imageView (non-animated should be
                    // visible if there is no image)
                    additionalImageView.image = image
                    additionalAnimatedImageView.image = animatedImage
                    additionalImageView.isHidden = (animatedImage != nil)
                    additionalAnimatedImageView.isHidden = (animatedImage == nil)
                }
                else {
                    additionalProfilePlaceholderImageView.isHidden = false
                }
                
            case .contact:
                guard !publicKey.isEmpty else { return }
                
                let (image, animatedImage): (UIImage?, YYImage?) = getProfilePicture(
                    of: self.size,
                    for: publicKey,
                    profile: profile,
                    threadVariant: threadVariant
                )
                imageView.image = image
                imageView.isHidden = (animatedImage != nil)
                animatedImageView.image = animatedImage
                animatedImageView.isHidden = (animatedImage == nil)
                imageViewWidthConstraint.constant = self.size
                imageViewHeightConstraint.constant = self.size
                imageContainerView.layer.cornerRadius = (self.size / 2)
        }
    }
}
