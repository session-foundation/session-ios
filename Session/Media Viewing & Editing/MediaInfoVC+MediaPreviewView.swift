// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import SessionUIKit
import SessionUtilitiesKit

extension MediaInfoVC {
    final class MediaPreviewView: UIView {
        private static let cornerRadius: CGFloat = 8
        
        private let mediaCache: NSCache<NSString, AnyObject>
        private let attachment: Attachment
        private let isOutgoing: Bool
        
        // MARK: - UI
        
        private lazy var mediaView: MediaView = {
            let result: MediaView = MediaView.init(
                mediaCache: mediaCache,
                attachment: attachment,
                isOutgoing: isOutgoing
            )
            
            return result
        }()
        
        private lazy var fullScreenButton: UIButton = {
            let result: UIButton = UIButton(type: .custom)
            result.setImage(
                UIImage(systemName: "arrow.up.left.and.arrow.down.right")?
                    .withRenderingMode(.alwaysTemplate),
                for: .normal
            )
            result.themeTintColor = .textPrimary
            result.backgroundColor = .init(white: 0, alpha: 0.4)
            result.layer.cornerRadius = 14
            result.set(.width, to: 28)
            result.set(.height, to: 28)
            
            return result
        }()
        
        // MARK: - Lifecycle
        
        init(
            mediaCache: NSCache<NSString, AnyObject>,
            attachment: Attachment,
            isOutgoing: Bool
        ) {
            self.mediaCache = mediaCache
            self.attachment = attachment
            self.isOutgoing = isOutgoing
            
            super.init(frame: CGRect.zero)
            self.accessibilityLabel = "Media info"
            setUpViewHierarchy()
        }

        override init(frame: CGRect) {
            preconditionFailure("Use init(attachment:) instead.")
        }

        required init?(coder: NSCoder) {
            preconditionFailure("Use init(attachment:) instead.")
        }

        private func setUpViewHierarchy() {
            set(.width, to: 293)
            set(.height, to: 293)
            
            addSubview(mediaView)
            mediaView.pin(to: self)
            
            addSubview(fullScreenButton)
            fullScreenButton.pin(.trailing, to: .trailing, of: self, withInset: -Values.smallSpacing)
            fullScreenButton.pin(.bottom, to: .bottom, of: self, withInset: -Values.smallSpacing)
            
            mediaView.loadMedia()
        }
        
    }
}
