// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Lucide
import UIKit
import SessionUIKit
import SessionMessagingKit

final class DocumentView: UIView {
    // MARK: - Lifecycle
    
    init(attachment: Attachment, textColor: ThemeValue) {
        super.init(frame: CGRect.zero)
        
        setUpViewHierarchy(attachment: attachment, textColor: textColor)
    }
    
    override init(frame: CGRect) {
        preconditionFailure("Use init(viewItem:textColor:) instead.")
    }
    
    required init?(coder: NSCoder) {
        preconditionFailure("Use init(viewItem:textColor:) instead.")
    }
    
    private func setUpViewHierarchy(attachment: Attachment, textColor: ThemeValue) {
        let documentIconSize = CGSize(width: 24, height: 32)
        
        let imageBackgroundView: UIView = UIView()
        imageBackgroundView.themeBackgroundColor = .messageBubble_overlay
        addSubview(imageBackgroundView)
        
        // Image view
        let imageView = UIImageView(
            image: Lucide.image(icon: .file, size: documentIconSize.height)?
                .withRenderingMode(.alwaysTemplate)
        )
        imageView.setContentCompressionResistancePriority(.required, for: .horizontal)
        imageView.setContentHuggingPriority(.required, for: .horizontal)
        imageView.contentMode = .scaleAspectFit
        imageView.themeTintColor = textColor
        imageView.set(.width, to: documentIconSize.width)
        imageView.set(.height, to: documentIconSize.height)
        
        if attachment.isAudio {
            let audioIconSize = documentIconSize.height * 0.32
            
            let audioImageView = UIImageView(
                image: Lucide.image(icon: .music2, size: audioIconSize)?
                    .withRenderingMode(.alwaysTemplate)
            )
            audioImageView.contentMode = .scaleAspectFit
            audioImageView.themeTintColor = textColor
            imageView.addSubview(audioImageView)
            audioImageView.center(.horizontal, in: imageView)
            audioImageView.center(.vertical, in: imageView, withInset: 2)
            audioImageView.set(.height, to: audioIconSize)
        }
        
        // Body label
        let titleLabel = UILabel()
        titleLabel.font = .systemFont(ofSize: Values.mediumFontSize)
        titleLabel.text = attachment.documentFileName
        titleLabel.themeTextColor = textColor
        titleLabel.lineBreakMode = .byTruncatingTail
        
        // Size label
        let sizeLabel = UILabel()
        sizeLabel.font = .systemFont(ofSize: Values.verySmallFontSize)
        sizeLabel.text = attachment.documentFileInfo
        sizeLabel.themeTextColor = textColor
        sizeLabel.lineBreakMode = .byTruncatingTail
        
        // Label stack view
        let labelStackView = UIStackView(arrangedSubviews: [ titleLabel, sizeLabel ])
        labelStackView.axis = .vertical
        
        // Download image view
        let rightContainerView: UIView = UIView()
        rightContainerView.set(.height, to: 24)
        
        let activityIndicator = UIActivityIndicatorView(style: .medium)
        activityIndicator.themeColor = textColor
        activityIndicator.startAnimating()
        activityIndicator.hidesWhenStopped = true
        activityIndicator.isHidden = (attachment.state != .uploading && attachment.state != .downloading)
        rightContainerView.addSubview(activityIndicator)
        activityIndicator.pin(to: rightContainerView, withInset: 8)
        
        let accessoryIconSize = 24.0
        
        let rightImageView = UIImageView(
            image: {
                guard attachment.state != .failedDownload && attachment.state != .failedUpload else {
                    return Lucide.image(icon: .fileWarning, size: accessoryIconSize)
                }
                
                switch attachment.isAudio {
                    case true: return UIImage(systemName: "play.fill")
                    case false: return Lucide.image(icon: .arrowDown, size: accessoryIconSize)
                }
            }()?.withRenderingMode(.alwaysTemplate)
        )
        rightImageView.setContentCompressionResistancePriority(.required, for: .horizontal)
        rightImageView.setContentHuggingPriority(.required, for: .horizontal)
        rightImageView.contentMode = .scaleAspectFit
        rightImageView.themeTintColor = textColor
        rightImageView.isHidden = (attachment.state == .uploading || attachment.state == .downloading)
        rightImageView.set(.height, to: accessoryIconSize)
        rightContainerView.addSubview(rightImageView)
        rightImageView.center(in: rightContainerView)
        
        // Stack view
        let stackView = UIStackView(
            arrangedSubviews: [
                imageView,
                UIView.spacer(withWidth: 0),
                labelStackView,
                rightContainerView
            ]
        )
        stackView.axis = .horizontal
        stackView.spacing = Values.mediumSpacing
        stackView.alignment = .center
        addSubview(stackView)
        stackView.pin(.top, to: .top, of: self, withInset: Values.smallSpacing)
        stackView.pin(.leading, to: .leading, of: self, withInset: Values.mediumSpacing)
        stackView.pin(.trailing, to: .trailing, of: self, withInset: -Values.mediumSpacing)
        stackView.pin(.bottom, to: .bottom, of: self, withInset: -Values.smallSpacing)
        
        imageBackgroundView.pin(.top, to: .top, of: self)
        imageBackgroundView.pin(.leading, to: .leading, of: self)
        imageBackgroundView.pin(.trailing, to: .trailing, of: imageView, withInset: Values.mediumSpacing)
        imageBackgroundView.pin(.bottom, to: .bottom, of: self)
    }
}
