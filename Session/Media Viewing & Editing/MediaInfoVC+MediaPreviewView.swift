// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import SessionUIKit
import SessionUtilitiesKit

extension MediaInfoVC {
    final class MediaPreviewView: UIView {
        private static let cornerRadius: CGFloat = 8
        
        private let attachment: Attachment
        private let isOutgoing: Bool
        
        // MARK: - UI
        
        private lazy var mediaView: MediaView = {
            let result: MediaView = MediaView.init(
                attachment: attachment,
                isOutgoing: isOutgoing,
                cornerRadius: 0
            )
            
            return result
        }()
        
        // MARK: - Lifecycle
        
        init(attachment: Attachment, isOutgoing: Bool) {
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
            set(.width, to: MediaInfoVC.mediaSize)
            set(.height, to: MediaInfoVC.mediaSize)
            
            addSubview(mediaView)
            mediaView.pin(to: self)
            
            mediaView.loadMedia()
        }
        
        // MARK: - Copy
        
        /// This function is used to make sure the carousel view contains this class can loop infinitely
        func copyView() -> MediaPreviewView {
            return MediaPreviewView(attachment: self.attachment, isOutgoing: self.isOutgoing)
        }
    }
}
